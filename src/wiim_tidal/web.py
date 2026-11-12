"""Local HTTP API. All application state belongs to an app instance."""
import hmac
import secrets
import os
import signal
import threading
from urllib.parse import urlsplit
from flask import Flask, jsonify, render_template, request
from werkzeug.exceptions import HTTPException
from . import __version__
from .adapters import PlayerError, load_catalog, load_player, media_id
from .config import Settings


def create_app(settings=None, restore=False, shutdown=False, *, catalog=None, player=None):
    settings = settings or Settings()
    settings.prepare()
    app = Flask(__name__)
    app.config.update(MAX_CONTENT_LENGTH=64 * 1024, LOCAL_TOKEN=secrets.token_urlsafe(32))
    catalog = load_catalog(settings) if catalog is None else catalog
    player = load_player(settings) if player is None else player
    if catalog.id not in player.catalogs:
        raise ValueError(f'{player.name} does not support the {catalog.name} catalog.')
    app.extensions.update(catalog=catalog, player=player, settings=settings)
    if restore:
        catalog.start_restore()

    @app.before_request
    def local_only():
        if request.host.split(':')[0] not in ('127.0.0.1', 'localhost'):
            return jsonify(error='Invalid local host'), 403
        if request.headers.get('Sec-Fetch-Site') == 'cross-site':
            return jsonify(error='Cross-site requests are not allowed'), 403
        origin = request.headers.get('Origin')
        if origin and origin != request.host_url.rstrip('/'):
            return jsonify(error='Invalid request origin'), 403
        if request.method == 'POST':
            token = request.headers.get('X-Local-Token', '')
            if not hmac.compare_digest(token, app.config['LOCAL_TOKEN']):
                return jsonify(error='Reload this page to reconnect securely.'), 403
            if not request.is_json:
                return jsonify(error='Expected application/json'), 415
            if not isinstance(request.get_json(), dict):
                return jsonify(error='Expected a JSON object'), 400

    @app.after_request
    def browser_headers(response):
        response.headers['Cache-Control'] = 'no-store'
        response.headers['X-Content-Type-Options'] = 'nosniff'
        response.headers['Referrer-Policy'] = 'no-referrer'
        response.headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' https: data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
        return response

    @app.errorhandler(Exception)
    def error(exc):
        if isinstance(exc, PlayerError):
            return jsonify(error=str(exc)), exc.status
        if isinstance(exc, HTTPException):
            return jsonify(error=exc.description), exc.code
        if isinstance(exc, (ValueError, TypeError)):
            return jsonify(error=str(exc)), 400
        # Third-party exceptions may contain tokens, redirect URLs or request bodies.
        app.logger.warning('Operation failed (%s)', type(exc).__name__)
        return jsonify(error='The service could not complete this request. Check the connection and try again.'), 502

    @app.get('/')
    def home():
        return render_template('index.html', token=app.config['LOCAL_TOKEN'],
                               catalog=catalog, player=player)

    @app.post('/api/shutdown')
    def stop():
        if not shutdown:
            return jsonify(error='Stop the server from its terminal.'), 403
        threading.Timer(0.4, lambda: os.kill(os.getpid(), signal.SIGTERM)).start()
        return jsonify(ok=True)

    @app.get('/api/identity')
    def identity():
        return jsonify(app='wiim-tidal-browser', version=__version__, catalog=catalog.id, player=player.id)

    @app.get('/api/health')
    def health():
        device = player.selected_device
        summary = {key: device.get(key) for key in ('id', 'name', 'host')} if device else None
        return jsonify(catalogConnected=catalog.connected, restoring=catalog.restoring,
                       playerDevice=summary, version=__version__,
                       tidal=catalog.connected if catalog.id == 'tidal' else False,
                       wiim=summary.get('host') if summary and player.id == 'wiim' else None,
                       wiimName=summary.get('name') if summary and player.id == 'wiim' else None)

    @app.post('/api/auth/start')
    def auth_start():
        if not catalog.login_required:
            raise ValueError('This catalog does not require sign-in.')
        url = catalog.begin_login()
        parsed = urlsplit(url)
        if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username is not None:
            raise ValueError('The catalog returned an invalid sign-in URL.')
        return jsonify(url=url)

    @app.post('/api/auth/finish')
    def auth_finish():
        if not catalog.login_required:
            raise ValueError('This catalog does not require sign-in.')
        redirect = request.json.get('redirect', '')
        if not isinstance(redirect, str) or len(redirect) > 8192:
            raise ValueError('Invalid redirect URL')
        catalog.finish_login(redirect)
        return jsonify(ok=True)

    @app.post('/api/wiim/manual')
    @app.post('/api/player/manual')
    def manual():
        if player.manual_port is None:
            raise ValueError('This player does not support entering an address manually.')
        return jsonify(selected=player.manual(request.json.get('host', ''), request.json.get('port', player.manual_port)))

    @app.post('/api/wiim/discover')
    @app.post('/api/player/discover')
    def discover():
        return jsonify(player.discover())

    @app.post('/api/wiim/select')
    @app.post('/api/player/select')
    def select():
        device_id = request.json.get('id')
        if not isinstance(device_id, str):
            raise ValueError('Select a discovered device')
        return jsonify(selected=player.select_discovered(device_id))

    @app.get('/api/search')
    def search():
        query = request.args.get('q', '').strip()
        if not 1 <= len(query) <= 150:
            raise ValueError('Search must be 1–150 characters')
        types = request.args.get('types', 'album').split(',')
        if any(kind not in ('album', 'track', 'artist') for kind in types):
            raise ValueError('Select one or more of album, track, and artist')
        return jsonify(catalog.search(query, types, separate_artist_matches='types' in request.args))

    @app.get('/api/album/<id_>')
    def album(id_):
        return jsonify(catalog.album(media_id(id_)))

    @app.get('/api/track/<id_>')
    def track(id_):
        return jsonify(catalog.track(media_id(id_)))

    @app.get('/api/resolution/<id_>')
    @app.get('/api/track-resolution/<id_>')
    def resolution(id_):
        return jsonify(catalog.resolution(media_id(id_), track=request.path.startswith('/api/track-resolution/')))

    @app.post('/api/play')
    def play():
        ids = request.json.get('ids')
        if not isinstance(ids, list) or not 1 <= len(ids) <= 100:
            raise ValueError('Supply 1 to 100 track IDs')
        tracks = catalog.queue_tracks([media_id(value) for value in ids])
        return jsonify(ok=True, count=player.queue(catalog.id, tracks, 'Hi-Res Browser'))

    @app.post('/api/control')
    def control():
        action, value = request.json.get('action'), request.json.get('value')
        if action in ('volume', 'seek'):
            maximum = 100 if action == 'volume' else 86400
            if type(value) is not int or not 0 <= value <= maximum:
                raise ValueError(f'{action.title()} must be an integer from 0 to {maximum}')
        elif action in ('previous', 'next', 'toggle', 'play', 'pause'):
            value = None
        else:
            raise ValueError('Unsupported playback action')
        player.control(action, value)
        return jsonify(ok=True)

    @app.get('/api/now')
    def now():
        return jsonify(player.now_playing())

    return app
