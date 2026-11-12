"""Per-user settings and private, atomic persistence."""
import json
import os
import sys
import tempfile
from pathlib import Path


def write_private_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix='.wiim-')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream)
            stream.write('\n')
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


class Settings:
    def __init__(self, data_dir=None):
        default = (Path.home() / 'Library/Application Support/WiiM TIDAL' if sys.platform == 'darwin'
                   else Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share')) / 'wiim-tidal')
        self.data_dir = Path(data_dir or os.environ.get('WIIM_TIDAL_DATA_DIR', default)).expanduser()
        self.catalog_id = os.environ.get('WIIM_TIDAL_CATALOG', 'tidal')
        self.player_id = os.environ.get('WIIM_TIDAL_PLAYER', 'wiim')
        self.session_file = Path(os.environ.get('TIDAL_SESSION_FILE', self.data_dir / 'tidal-session.json')).expanduser()
        self.device_file = self.data_dir / 'device.json'

    def prepare(self, legacy_dir=None):
        self.data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        if self.catalog_id == 'tidal':
            self.session_file.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if legacy_dir:
            files = []
            if self.catalog_id == 'tidal':
                files.append((Path(legacy_dir) / '.tidal-session.json', self.session_file))
            if self.player_id == 'wiim':
                files.append((Path(legacy_dir) / '.wiim-device.json', self.device_file))
            for source, target in files:
                if source.is_file() and not target.exists():
                    # Read only the known legacy files; never add them to a distribution.
                    try:
                        write_private_json(target, json.loads(source.read_text()))
                    except (OSError, ValueError):
                        continue
        if self.catalog_id == 'tidal' and self.session_file.exists():
            self.session_file.chmod(0o600)
