"""Keep the server and its native launcher in the same macOS process."""
import argparse
import ctypes
import errno
import sys
from pathlib import Path
from threading import Thread

from waitress import create_server
from wiim_tidal import __version__
from wiim_tidal.web import create_app


def bind_server(app, ports):
    for port in ports:
        try:
            return create_server(app, host='127.0.0.1', port=port)
        except OSError as error:
            if error.errno != errno.EADDRINUSE:
                raise
    raise RuntimeError('No requested local port is available.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--version', action='version', version=__version__)
    parser.add_argument('--port', type=int, choices=range(1024, 65536), metavar='PORT')
    parser.add_argument('--no-browser', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    launcher = ctypes.CDLL(str(Path(sys._MEIPASS) / 'libWiiMLauncher.dylib'))
    launcher.wiim_run_launcher.argtypes = (ctypes.c_char_p, ctypes.c_int32)
    launcher.wiim_run_launcher.restype = None
    launcher.wiim_startup_error.argtypes = (ctypes.c_char_p,)
    launcher.wiim_startup_error.restype = None
    try:
        app = create_app(restore=True, shutdown=True)
        server = bind_server(app, [args.port] if args.port else range(8765, 8775))
    except (OSError, RuntimeError, ValueError) as error:
        launcher.wiim_startup_error(str(error).encode())
        return 1

    thread = Thread(target=server.run, daemon=True)
    thread.start()
    try:
        url = f'http://127.0.0.1:{server.effective_port}'
        launcher.wiim_run_launcher(url.encode(), not args.no_browser)
    finally:
        server.close()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
