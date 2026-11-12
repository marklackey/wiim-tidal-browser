"""Smoke test the installed CLI and its localhost server from a clean directory."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
from urllib.error import URLError
from urllib.request import urlopen


def main():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        env = {**os.environ, 'WIIM_TIDAL_DATA_DIR': str(root / 'app-data')}
        for name in ('TIDAL_SESSION_FILE', 'WIIM_HOST', 'WIIM_UPNP_PORT', 'WIIM_TIDAL_CATALOG', 'WIIM_TIDAL_PLAYER'):
            env.pop(name, None)
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        url = f'http://127.0.0.1:{port}'
        log_path = root / 'server.log'
        with log_path.open('wb') as log:
            server = subprocess.Popen(
                ['wiim-tidal', 'serve', '--port', str(port)],
                cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT,
            )
            try:
                deadline = time.monotonic() + 12
                while True:
                    try:
                        with urlopen(url + '/api/identity', timeout=1) as response:
                            identity = json.load(response)
                        break
                    except URLError:
                        if server.poll() is not None or time.monotonic() >= deadline:
                            raise RuntimeError(log_path.read_text(errors='replace')) from None
                        time.sleep(0.2)
                assert identity['app'] == 'wiim-tidal-browser'
                assert identity['catalog'] == 'tidal' and identity['player'] == 'wiim'
                with urlopen(url, timeout=2) as response:
                    assert b'Hi-Res Finder' in response.read()
                with urlopen(url + '/static/app.js', timeout=2) as response:
                    assert b'searchForm' in response.read()
                print('Installed CLI served the browser UI and JavaScript from a clean directory.')
            finally:
                if server.poll() is None:
                    server.terminate()
                    try:
                        server.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait()


if __name__ == '__main__':
    main()
