"""Local HTTP API. All application state belongs to an app instance."""
import errno
import hmac
import json
import secrets
import os
import signal
import sys
import threading
from urllib.error import HTTPError, URLError
from flask import Flask, jsonify, render_template, request
from werkzeug.exceptions import HTTPException
from . import __version__
from .auth import Catalog
from .catalog import album_data, search_key, track_data
from .config import Settings
from .discovery import discover_devices
from .wiim import WiiM


def create_app(settings=None, restore=False, shutdown=False):
    settings = settings or Settings()
    settings.prepare()
    app = Flask(__name__)
    app.config.update(MAX_CONTENT_LENGTH=64 * 1024, LOCAL_TOKEN=secrets.token_urlsafe(32))
    catalog = Catalog(settings)
    wiim = WiiM(settings, catalog)
    app.extensions.update(catalog=catalog, wiim=wiim, settings=settings)
    if restore and settings.session_file.exists():
        catalog.restoring = True
        # Starting the browser must not wait for a slow TIDAL connection.
        threading.Thread(target=catalog.restore, daemon=True).start()

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
        if isinstance(exc, HTTPException):
            return jsonify(error=exc.description), exc.code
        if isinstance(exc, (ValueError, TypeError)):
            return jsonify(error=str(exc)), 400
        # Third-party exceptions may contain tokens, redirect URLs or request bodies.
        app.logger.warning('Operation failed (%s)', type(exc).__name__)
        return jsonify(error='The service could not complete this request. Check the connection and try again.'), 502

    @app.get('/')
    def home():
        return render_template('index.html', token=app.config['LOCAL_TOKEN'])

    @app.post('/api/shutdown')
    def stop():
        if not shutdown:
            return jsonify(error='Stop the server from its terminal.'), 403
        threading.Timer(0.4, lambda: os.kill(os.getpid(), signal.SIGTERM)).start()
        return jsonify(ok=True)

    @app.get('/api/identity')
    def identity():
        return jsonify(app='wiim-tidal-browser', version=__version__)

    @app.get('/api/health')
    def health():
        device = wiim._device or {}
        return jsonify(tidal=catalog.connected, restoring=catalog.restoring,
                       wiim=device.get('host'), wiimName=device.get('name'), version=__version__)

    @app.post('/api/auth/start')
    def auth_start():
        return jsonify(url=catalog.begin_login())

    @app.post('/api/auth/finish')
    def auth_finish():
        redirect = request.json.get('redirect', '')
        if not isinstance(redirect, str) or len(redirect) > 8192:
            raise ValueError('Invalid redirect URL')
        catalog.finish_login(redirect)
        return jsonify(ok=True)

    @app.post('/api/wiim/manual')
    def manual():
        return jsonify(selected=wiim.manual(request.json.get('host', ''), request.json.get('port', 49152)))

    def wiim_network_help():
        if getattr(sys, 'frozen', False):
            return ('Check that your Mac and WiiM are on the same network. From the WiiM TIDAL '
                    'menu bar icon, choose Local Network Access, then Request Access. '
                    'Choose Allow if prompted and try again.')
        return ('Check your Wi-Fi and Local Network access in System Settings → Privacy & Security. '
                'If the WiiM address changed, find it again in Setup.')

    @app.post('/api/wiim/discover')
    def discover():
        if not wiim.discovery_lock.acquire(blocking=False):
            return jsonify(error='Discovery is already running'), 409
        try:
            try:
                devices = discover_devices()
            except OSError as exc:
                app.logger.warning('WiiM discovery socket error: %s', exc.errno)
                if sys.platform == 'darwin' and exc.errno in (
                    errno.EACCES, errno.EPERM, errno.EHOSTUNREACH, errno.ENETUNREACH,
                ):
                    return jsonify(error=wiim_network_help()), 503
                raise
            with wiim.lock:
                wiim.discovered = {d['id']: d for d in devices}
                current_id = (wiim._device or {}).get('id')
                selected = next((d for d in devices if d['id'] == current_id), None)
                if not current_id and len(devices) == 1:
                    selected = devices[0]
                if selected:
                    wiim.select(selected)
                return jsonify(devices=devices, selected=selected)
        finally:
            wiim.discovery_lock.release()

    @app.post('/api/wiim/select')
    def select():
        device_id = request.json.get('id')
        if not isinstance(device_id, str):
            raise ValueError('Select a discovered device')
        with wiim.lock:
            device = wiim.discovered.get(device_id)
            if device is None:
                raise ValueError('Discover WiiM first, then select a device')
            wiim.select(device)
        return jsonify(selected=device)

    @app.get('/api/search')
    def search():
        query = request.args.get('q', '').strip()
        if not 1 <= len(query) <= 150:
            raise ValueError('Search must be 1–150 characters')
        import tidalapi
        models = {'album': tidalapi.Album, 'track': tidalapi.Track, 'artist': tidalapi.Artist}
        # Keep the original album-only response for callers without category selection.
        types = request.args.get('types', 'album').split(',')
        if any(kind not in models for kind in types):
            raise ValueError('Select one or more of album, track, and artist')

        query_key = search_key(query)
        with catalog.lock:
            catalog.ensure_login()
            found = catalog.session.search(query, models=[models[kind] for kind in dict.fromkeys(types)], limit=300)
            albums = [album_data(a) for a in found.get('albums', [])] if 'album' in types else []
            tracks = [track_data(t) for t in found.get('tracks', [])] if 'track' in types else []
            artist_albums = {}
            if 'artist' in types:
                artists = found.get('artists', [])
                named = [artist for artist in artists if query_key in search_key(artist.name)]
                matching_artists = sorted(named or artists, key=lambda artist: search_key(artist.name) != query_key)
                # Bound the number of follow-up TIDAL requests per search.
                for artist in matching_artists[:8]:
                    for album in artist.get_albums(limit=50):
                        artist_albums[album.id] = album_data(album)

        if 'artist' in types:
            for album in albums:
                if query_key in search_key(album['artist']):
                    artist_albums.setdefault(album['id'], album)
        if 'types' in request.args:
            # Album search can also return records whose only textual match is the artist.
            albums = [album for album in albums if query_key in search_key(album['name'])
                      or query_key not in search_key(album['artist'])]
        return jsonify(albums=albums, artistAlbums=list(artist_albums.values()), tracks=tracks)

    @app.get('/api/album/<int:id_>')
    def album(id_):
        with catalog.lock:
            catalog.ensure_login()
            value = catalog.session.album(id_)
            return jsonify(album=album_data(value), tracks=[track_data(t) for t in value.tracks()])

    @app.get('/api/track/<int:id_>')
    def track(id_):
        with catalog.lock:
            catalog.ensure_login()
            return jsonify(track_data(catalog.session.track(id_)))

    @app.get('/api/resolution/<int:id_>')
    @app.get('/api/track-resolution/<int:id_>')
    def resolution(id_):
        with catalog.lock:
            catalog.ensure_login()
            if request.path.startswith('/api/track-resolution/'):
                value = catalog.session.track(id_).get_stream().get_audio_resolution()
            else:
                values = catalog.session.album(id_).get_audio_resolution()
                value = values[0] if values else None
            if not isinstance(value, (tuple, list)) or len(value) < 2:
                raise ValueError('No resolution returned')
            return jsonify(bits=value[0], hz=value[1], source='TIDAL stream metadata')

    @app.post('/api/play')
    def play():
        ids = request.json.get('ids')
        if not isinstance(ids, list) or any(type(v) is not int or v <= 0 for v in ids):
            raise ValueError('Supply a list of positive integer track IDs')
        return jsonify(ok=True, count=wiim.create_playlist(ids, 'Hi-Res Browser'))

    @app.post('/api/control')
    def control():
        action, value = request.json.get('action'), request.json.get('value')
        commands = {'previous': 'prev', 'next': 'next', 'toggle': 'onepause', 'play': 'resume', 'pause': 'pause'}
        if action in ('volume', 'seek'):
            maximum = 100 if action == 'volume' else 86400
            if type(value) is not int or not 0 <= value <= maximum:
                raise ValueError(f'{action.title()} must be an integer from 0 to {maximum}')
            command = f'{"vol" if action == "volume" else "seek"}:{value}'
        elif isinstance(action, str) and action in commands:
            command = commands[action]
        else:
            raise ValueError('Unsupported playback action')
        if wiim.command('setPlayerCmd:' + command).strip().strip('"').upper() != 'OK':
            raise RuntimeError('WiiM rejected command')
        return jsonify(ok=True)

    @app.get('/api/now')
    def now():
        def read_object(command):
            value = json.loads(wiim.command(command))
            return value if isinstance(value, dict) else {}

        metadata = None
        try:
            info = read_object('getMetaInfo').get('metaData')
            if isinstance(info, dict):
                metadata = info
        except (OSError, ValueError):
            # A player can answer controls while its current source offers no track metadata.
            pass

        fields = {'status': 'playbackStatus', 'vol': 'volume', 'curpos': 'positionMs', 'totlen': 'durationMs'}
        status = None
        network_error = None
        for command in ('getPlayerStatusEx', 'getPlayerStatus'):
            try:
                candidate = read_object(command)
                if any(candidate.get(key) is not None for key in fields):
                    status = candidate
                    break
            except (HTTPError, ValueError):
                # Some firmware responds to unsupported commands with HTTP errors or plain text.
                continue
            except OSError as exc:
                network_error = exc.reason if isinstance(exc, URLError) else exc
                break

        if metadata is None and status is None:
            if getattr(network_error, 'errno', None) in (
                errno.EACCES, errno.EPERM, errno.EHOSTUNREACH, errno.ENETUNREACH,
            ) and sys.platform == 'darwin':
                return jsonify(error=wiim_network_help()), 503
            if network_error is not None:
                return jsonify(error='WiiM did not respond at its saved address. Check that it is on and find it again in Setup.'), 503
            return jsonify(error='WiiM responded without playback information. Try Refresh after starting playback in WiiM Home.'), 502

        result = {**(metadata or {}), 'controlsAvailable': status is not None}
        if status is not None:
            result.update({dest: status.get(source) for source, dest in fields.items()})
        return jsonify(result)

    return app
