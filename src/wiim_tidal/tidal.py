"""TIDAL authentication and catalog adapter."""
from concurrent.futures import Future
from dataclasses import dataclass
from functools import partial
import logging
import secrets
import threading
import time
from urllib.parse import urlsplit, parse_qs
import tidalapi
from .adapters import QueueTrack
from .catalog import album_data, search_key, track_data
from .config import write_private_json


@dataclass
class DeviceLogin:
    id: str
    url: str
    session: tidalapi.Session
    result: Future[bool]


def _wait_for_device_login(session, link, result):
    try:
        result.set_result(session.process_link_login(link))
    except Exception as error:
        result.set_exception(error)


class TidalCatalog:
    id = 'tidal'
    name = 'TIDAL'
    login_required = True

    def __init__(self, settings):
        self.settings = settings
        self.lock = threading.RLock()
        self.session = self.new_session()
        self.pending = None
        self.pending_at = 0
        self.device_login = None
        self.connected = False
        self.restoring = False

    @staticmethod
    def new_session():
        return tidalapi.Session(tidalapi.Config(quality=tidalapi.Quality.hi_res_lossless))

    def start_restore(self):
        if self.settings.session_file.exists():
            self.restoring = True
            threading.Thread(target=self.restore, daemon=True).start()

    def restore(self):
        try:
            with self.lock:
                if not self.settings.session_file.exists():
                    return
                self.connected = bool(self.session.load_session_from_file(self.settings.session_file))
                if self.connected:
                    self.save()
        except Exception:
            logging.getLogger(__name__).warning('Saved TIDAL session could not be restored. Reconnect in Setup.')
            self.connected = False
        finally:
            self.restoring = False

    def save(self, session=None):
        session = session or self.session
        write_private_json(self.settings.session_file, {
            key: {'data': getattr(session, key)} for key in
            ('token_type', 'session_id', 'access_token', 'refresh_token', 'is_pkce')})

    def ensure_login(self):
        if not self.connected:
            raise ValueError('Connect your TIDAL account in Setup first.')

    @property
    def resolution_available(self):
        return self.connected and bool(self.session.is_pkce)

    def begin_device_login(self):
        with self.lock:
            login = self.device_login
            if login and login.result.done() and (login.session is self.session or login.result.exception() is not None):
                login = None
            if login is None:
                session = self.new_session()
                session.request_session.request = partial(session.request_session.request, timeout=(5, 12))
                try:
                    link = session.get_link_login()
                    url = link.verification_uri_complete
                    if '://' not in url:
                        url = 'https://' + url
                    parsed = urlsplit(url)
                    if parsed.scheme != 'https' or parsed.netloc != 'link.tidal.com':
                        raise ValueError('Unexpected verification URL')
                except Exception:
                    raise ValueError('Could not start TIDAL sign-in. Try again or use Hi-Res sign-in.') from None
                login = self.device_login = DeviceLogin(secrets.token_urlsafe(18), url, session, Future())
                threading.Thread(target=_wait_for_device_login, args=(session, link, login.result), daemon=True).start()
            self.pending = None
            return {'id': login.id, 'url': login.url}

    def check_device_login(self, login_id):
        with self.lock:
            login = self.device_login
            if login is None or login.id != login_id:
                raise ValueError('Start TIDAL sign-in again.')
            if not login.result.done():
                return False
            if login.session is not self.session:
                try:
                    if not login.result.result() or not login.session.check_login():
                        raise ValueError('Login could not be verified')
                except TimeoutError:
                    self.device_login = None
                    raise ValueError('The TIDAL sign-in link expired. Start again for a new link.') from None
                except Exception:
                    self.device_login = None
                    raise ValueError('TIDAL sign-in failed. Try again or use Hi-Res sign-in.') from None
                self._activate(login.session)
            return True

    def _activate(self, session):
        self.save(session)
        self.session = session
        self.connected = True

    def begin_login(self):
        with self.lock:
            self.device_login = None
            self.pending = self.new_session()
            self.pending_at = time.monotonic()
            return self.pending.pkce_login_url()

    def finish_login(self, redirect):
        with self.lock:
            if not self.pending or time.monotonic() - self.pending_at > 600:
                self.pending = None
                raise ValueError('Login expired. Start TIDAL login again.')
            parsed = urlsplit(redirect)
            expected = urlsplit(self.pending.config.pkce_uri_redirect)
            if (parsed.scheme, parsed.netloc, parsed.path) != (expected.scheme, expected.netloc, expected.path) or not parse_qs(parsed.query).get('code'):
                raise ValueError('Paste the complete TIDAL redirect URL containing the authorization code.')
            pending, self.pending = self.pending, None
            try:
                token = pending.pkce_get_auth_token(redirect)
                pending.process_auth_token(token, is_pkce_token=True)
                if not pending.check_login():
                    raise ValueError('Login could not be verified')
            except Exception:
                raise ValueError('TIDAL login failed. Start again and paste the new redirect URL.') from None
            self._activate(pending)

    def search(self, query, types, *, separate_artist_matches):
        models = {'album': tidalapi.Album, 'track': tidalapi.Track, 'artist': tidalapi.Artist}
        query_key = search_key(query)
        with self.lock:
            self.ensure_login()
            found = self.session.search(query, models=[models[kind] for kind in dict.fromkeys(types)], limit=300)
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
        if separate_artist_matches:
            # Album search can also return records whose only textual match is the artist.
            albums = [album for album in albums if query_key in search_key(album['name'])
                      or query_key not in search_key(album['artist'])]
        return {'albums': albums, 'artistAlbums': list(artist_albums.values()), 'tracks': tracks}

    @staticmethod
    def _id(value):
        if not str(value).isascii() or not str(value).isdigit() or int(value) <= 0:
            raise ValueError('Invalid TIDAL ID')
        return int(value)

    def album(self, id_):
        with self.lock:
            self.ensure_login()
            album = self.session.album(self._id(id_))
            return {'album': album_data(album), 'tracks': [track_data(t) for t in album.tracks()]}

    def track(self, id_):
        with self.lock:
            self.ensure_login()
            return track_data(self.session.track(self._id(id_)))

    def resolution(self, id_, *, track):
        with self.lock:
            self.ensure_login()
            if not self.resolution_available:
                raise ValueError('Use Hi-Res sign-in to see bit depth and sample rate.')
            id_ = self._id(id_)
            if track:
                value = self.session.track(id_).get_stream().get_audio_resolution()
            else:
                values = self.session.album(id_).get_audio_resolution()
                value = values[0] if values else None
            if not isinstance(value, (tuple, list)) or len(value) < 2:
                raise ValueError('No resolution returned')
            return {'bits': value[0], 'hz': value[1], 'source': 'TIDAL stream metadata'}

    def queue_tracks(self, ids):
        clean = [self._id(id_) for id_ in ids]
        with self.lock:
            self.ensure_login()
            tracks = {}
            for id_ in dict.fromkeys(clean):
                track = self.session.track(id_)
                data = track_data(track)
                album = getattr(track, 'album', None)
                art = album.image(640) if getattr(album, 'cover', None) else None
                tracks[id_] = QueueTrack(id_, data['title'], data['artist'], data['album'], data['number'], art)
        return [tracks[id_] for id_ in clean]
