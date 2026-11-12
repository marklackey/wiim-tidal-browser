"""Contracts for catalog providers and network-controlled players."""
from dataclasses import dataclass
from importlib.metadata import entry_points
import re
from typing import Protocol

_MEDIA_ID = re.compile(r'[A-Za-z0-9._~:-]{1,200}', re.ASCII)


def media_id(value):
    """Validate a catalog identifier while preserving numeric IDs for existing clients."""
    if type(value) is int and value > 0 and len(str(value)) <= 200:
        return value
    if isinstance(value, str) and value not in ('.', '..') and _MEDIA_ID.fullmatch(value):
        return value
    raise ValueError('Invalid catalog ID')


@dataclass(frozen=True)
class QueueTrack:
    id: str | int
    title: str
    artist: str = ''
    album: str = ''
    number: int | None = None
    art: str | None = None


class PlayerError(RuntimeError):
    """An error with a message safe to display to the user."""

    def __init__(self, message: str, status: int = 502):
        super().__init__(message)
        self.status = status


class CatalogAdapter(Protocol):
    id: str
    name: str
    login_required: bool
    connected: bool
    restoring: bool

    def start_restore(self) -> None: ...
    def begin_login(self) -> str: ...
    def finish_login(self, redirect: str) -> None: ...
    def search(self, query: str, types: list[str], *, separate_artist_matches: bool) -> dict: ...
    def album(self, id_: str | int) -> dict: ...
    def track(self, id_: str | int) -> dict: ...
    def resolution(self, id_: str | int, *, track: bool) -> dict: ...
    def queue_tracks(self, ids: list[str | int]) -> list[QueueTrack]: ...


class PlayerAdapter(Protocol):
    id: str
    name: str
    catalogs: frozenset[str]
    manual_port: int | None

    @property
    def selected_device(self) -> dict | None: ...
    def discover(self) -> dict: ...
    def select_discovered(self, id_: str) -> dict: ...
    def manual(self, host: str, port: int) -> dict: ...
    def queue(self, catalog_id: str, tracks: list[QueueTrack], name: str) -> int: ...
    def control(self, action: str, value: int | None) -> None: ...
    def now_playing(self) -> dict: ...


def load_catalog(settings) -> CatalogAdapter:
    if settings.catalog_id == 'tidal':
        from .tidal import TidalCatalog
        return TidalCatalog(settings)
    return _load_extension('catalogs', settings.catalog_id, settings)


def load_player(settings) -> PlayerAdapter:
    if settings.player_id == 'wiim':
        from .wiim import WiiM
        return WiiM(settings)
    return _load_extension('players', settings.player_id, settings)


def _load_extension(kind, name, settings):
    matches = list(entry_points(group=f'wiim_tidal.{kind}', name=name))
    if len(matches) != 1:
        raise ValueError(f'Expected one installed {kind[:-1]} adapter named {name!r}, found {len(matches)}.')
    adapter = matches[0].load()(settings)
    if adapter.id != name:
        raise ValueError(f'Adapter {name!r} declares a different ID.')
    return adapter
