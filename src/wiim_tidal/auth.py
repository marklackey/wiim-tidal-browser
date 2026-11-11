"""Serialized TIDAL session lifecycle and browser-based PKCE setup."""
import logging
import threading
import time
from urllib.parse import urlsplit, parse_qs
import tidalapi
from .config import write_private_json


class Catalog:
    def __init__(self, settings):
        self.settings = settings
        self.lock = threading.RLock()
        self.session = self.new_session()
        self.pending = None
        self.pending_at = 0
        self.connected = False
        self.restoring = False

    @staticmethod
    def new_session():
        return tidalapi.Session(tidalapi.Config(quality=tidalapi.Quality.hi_res_lossless))

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

    def begin_login(self):
        with self.lock:
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
            self.save(pending)
            self.session = pending
            self.connected = True
