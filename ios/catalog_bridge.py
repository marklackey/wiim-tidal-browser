"""Call the shared TIDAL adapter from the iPhone app."""

from functools import partial
from dataclasses import asdict
import json
import logging

from requests import RequestException

from wiim_tidal.config import Settings
from wiim_tidal.tidal import TidalCatalog


class MobileCatalog(TidalCatalog):
    @staticmethod
    def new_session():
        session = TidalCatalog.new_session()
        session.request_session.request = partial(session.request_session.request, timeout=(5, 12))
        return session

    def status(self):
        return {'connected': self.connected, 'resolutionAvailable': self.resolution_available}


_catalog = None


def _dispatch(action, payload, data_dir):
    global _catalog
    if action == 'probe_device':
        from wiim_tidal.discovery import describe_device
        from ipaddress import IPv4Address
        host = str(IPv4Address(payload['host']))
        port = int(payload['port'])
        if not 1 <= port <= 65535:
            return {'error': 'Invalid player port.'}
        device = describe_device((f'http://{host}:{port}/description.xml', host))
        return {'device': device}
    if _catalog is None:
        # Upstream diagnostics can contain redirect URLs or response data.
        logging.getLogger('tidalapi').disabled = True
        logging.getLogger('tidalapi').setLevel(logging.CRITICAL)
        settings = Settings(data_dir)
        settings.prepare()
        _catalog = MobileCatalog(settings)
        _catalog.restore()

    if action == 'status':
        return _catalog.status()
    if action in ('begin_device_login', 'check_device_login'):
        try:
            if action == 'begin_device_login':
                return _catalog.begin_device_login()
            connected = _catalog.check_device_login(payload['id'])
            return {'connected': connected}
        except ValueError as error:
            return {'error': str(error)}
    if action == 'begin_login':
        return {'url': _catalog.begin_login()}
    if action == 'finish_login':
        redirect = payload['redirect']
        if len(redirect) > 8192:
            return {'error': 'The TIDAL redirect URL is too long.'}
        try:
            _catalog.finish_login(redirect)
        except ValueError as error:
            return {'error': str(error)}
        return _catalog.status()
    if action == 'disconnect':
        settings = _catalog.settings
        settings.session_file.unlink(missing_ok=True)
        _catalog = MobileCatalog(settings)
        return _catalog.status()
    if not _catalog.connected:
        return {'error': 'Connect TIDAL before browsing the catalog.'}
    if action == 'search':
        query = payload['query'].strip()
        kinds = payload.get('types', [payload.get('kind')])
        if (not 1 <= len(query) <= 150 or not isinstance(kinds, list)
                or not 1 <= len(kinds) <= 3 or any(kind not in ('album', 'track', 'artist') for kind in kinds)):
            return {'error': 'Enter a search from 1 to 150 characters.'}
        return _catalog.search(query, kinds, separate_artist_matches=True)
    if action == 'album':
        return _catalog.album(payload['id'])
    if action == 'track':
        return _catalog.track(payload['id'])
    if action == 'queue_tracks':
        ids = payload['ids']
        if not isinstance(ids, list) or not 1 <= len(ids) <= 100:
            return {'error': 'Choose between 1 and 100 tracks.'}
        return [{**asdict(track), 'id': str(track.id)} for track in _catalog.queue_tracks(ids)]
    if action == 'resolution':
        try:
            return _catalog.resolution(payload['id'], track=payload['track'])
        except ValueError:
            return {'error': 'TIDAL did not return a resolution estimate.'}
    return {'error': 'This catalog operation is unavailable.'}


def handle(action, raw, data_dir):
    try:
        result = _dispatch(action, json.loads(raw), data_dir)
        return json.dumps(result, allow_nan=False).encode('utf-8')
    except RequestException:
        return b'{"error":"TIDAL did not respond. Check your connection or reconnect TIDAL in Setup."}'
    except Exception:
        return b'{"error":"The TIDAL catalog could not complete this request."}'
