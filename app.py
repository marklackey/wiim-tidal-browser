"""Compatibility entry point for the original source checkout."""
from pathlib import Path
from wiim_tidal.cli import main

if __name__ == '__main__':
    raise SystemExit(main(['serve'], legacy_dir=Path(__file__).resolve().parent))
