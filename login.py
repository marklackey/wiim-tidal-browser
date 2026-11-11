"""Open the browser setup page, migrating an existing source checkout."""
from pathlib import Path
from wiim_tidal.cli import main

if __name__ == '__main__':
    raise SystemExit(main(['setup'], legacy_dir=Path(__file__).resolve().parent))
