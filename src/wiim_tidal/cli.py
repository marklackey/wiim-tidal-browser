"""Launch or reuse the local server and open the default browser."""
import argparse
import json
import os
import socket
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import build_opener, ProxyHandler
import webbrowser

from . import __version__
from .config import Settings

HOST = '127.0.0.1'


def server_running(url, settings):
    opener = build_opener(ProxyHandler({}))
    try:
        with opener.open(url + '/api/identity', timeout=0.5) as response:
            identity = json.loads(response.read(4096))
            return (identity.get('app') == 'wiim-tidal-browser'
                    and identity.get('catalog', 'tidal') == settings.catalog_id
                    and identity.get('player', 'wiim') == settings.player_id)
    except (HTTPError, URLError, OSError, ValueError, AttributeError):
        return False


def pick_port(settings):
    ports = range(8765, 8775)
    for port in ports:
        if server_running(f'http://{HOST}:{port}', settings):
            return port
    for port in ports:
        with socket.socket() as probe:
            try:
                probe.bind((HOST, port))
            except OSError:
                continue
            return port
    raise RuntimeError('No local port is available between 8765 and 8774.')


def main(argv=None, legacy_dir=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', nargs='?', default='open', choices=['open', 'setup', 'serve'])
    parser.add_argument('--port', type=int)
    parser.add_argument('--version', action='version', version=__version__)
    args = parser.parse_args(argv)
    if args.port is not None and not 1024 <= args.port <= 65535:
        parser.error('port must be between 1024 and 65535')
    settings = Settings()
    try:
        port = args.port or (8765 if args.command == 'serve' else pick_port(settings))
        url = f'http://{HOST}:{port}'
        settings.prepare(legacy_dir)
        if args.command == 'serve':
            from waitress import serve
            from .web import create_app
            print(f'WiiM TIDAL is running at {url}', flush=True)
            serve(create_app(settings, restore=True, shutdown=True), host=HOST, port=port)
            return 0
        if not server_running(url, settings):
            executable = [sys.executable] if getattr(sys, 'frozen', False) else [sys.executable, '-m', 'wiim_tidal']
            log = settings.data_dir / 'server.log'
            with log.open('a') as stream:
                child = subprocess.Popen(executable + ['serve', '--port', str(port)],
                                         stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT,
                                         start_new_session=True)
            deadline = time.monotonic() + 12
            while not server_running(url, settings):
                if child.poll() is not None or time.monotonic() > deadline:
                    if child.poll() is None:
                        child.terminate()
                    if server_running(url, settings):
                        break
                    raise RuntimeError(f'The server could not start. Check that port {port} is free. Log: {log}')
                time.sleep(0.15)
        target = url + ('/?setup=1' if args.command == 'setup' else '/')
        print(target)
        if not webbrowser.open(target):
            raise RuntimeError(f'Open {target} in your browser.')
        return 0
    except (OSError, RuntimeError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
