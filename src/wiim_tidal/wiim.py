"""WiiM device selection and native playback transport."""
import errno
import ipaddress
import json
import os
import sys
import ssl
import threading
import urllib.request
import urllib.error
import urllib.parse
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape
from .adapters import PlayerError
from .discovery import SERVICE, discover_devices, local_url
from .config import write_private_json

def track_metadata(track):
    """DIDL-Lite for display; WiiM still resolves audio using the TIDAL ID."""
    didl = 'urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/'
    dc = 'http://purl.org/dc/elements/1.1/'
    upnp = 'urn:schemas-upnp-org:metadata-1-0/upnp/'
    root = ET.Element('DIDL-Lite', {'xmlns': didl, 'xmlns:dc': dc, 'xmlns:upnp': upnp})
    item = ET.SubElement(root, 'item', {'id': str(track.id), 'parentID': '0', 'restricted': '1'})
    for tag, value in (
        ('dc:title', track.title), ('dc:creator', track.artist), ('upnp:artist', track.artist),
        ('upnp:album', track.album),
        ('upnp:originalTrackNumber', track.number),
        ('upnp:class', 'object.item.audioItem.musicTrack'),
    ):
        if value is not None:
            ET.SubElement(item, tag).text = str(value)
    if track.art:
        ET.SubElement(item, 'upnp:albumArtURI').text = track.art
    return ET.tostring(root, encoding='unicode')

class WiiM:
    id = 'wiim'
    name = 'WiiM'
    catalogs = frozenset({'tidal'})
    manual_port = 49152

    def __init__(self, settings):
        self.settings = settings
        self.lock = threading.RLock()
        self.discovery_lock = threading.Lock()
        self.discovered = {}
        self._device = self._load_device()

    def _load_device(self):
        host = os.environ.get('WIIM_HOST')
        if host:
            port = int(os.environ.get('WIIM_UPNP_PORT', str(self.manual_port)))
            return self._manual_device(host, port)
        try:
            device = json.loads(self.settings.device_file.read_text())
            if (isinstance(device, dict) and isinstance(device.get('id'), str)
                    and isinstance(device.get('name'), str) and local_url(device['url'], device['host'])):
                return device
        except (OSError, ValueError, KeyError, TypeError):
            pass
        return None

    @property
    def selected_device(self):
        with self.lock:
            return dict(self._device) if self._device else None

    @staticmethod
    def _network_help():
        if getattr(sys, 'frozen', False):
            return ('Check that your Mac and WiiM are on the same network. From the WiiM TIDAL '
                    'menu bar icon, choose Local Network Access, then Request Access. '
                    'Choose Allow if prompted and try again.')
        return ('Check your Wi-Fi and Local Network access in System Settings → Privacy & Security. '
                'If the WiiM address changed, find it again in Setup.')

    @staticmethod
    def _local_network_error(error):
        return sys.platform == 'darwin' and getattr(error, 'errno', None) in (
            errno.EACCES, errno.EPERM, errno.EHOSTUNREACH, errno.ENETUNREACH,
        )

    def discover(self):
        if not self.discovery_lock.acquire(blocking=False):
            raise PlayerError('Discovery is already running', 409)
        try:
            try:
                devices = discover_devices()
            except OSError as error:
                if self._local_network_error(error):
                    raise PlayerError(self._network_help(), 503) from error
                raise
            with self.lock:
                self.discovered = {device['id']: device for device in devices}
                current_id = (self._device or {}).get('id')
                selected = self.discovered.get(current_id)
                if not current_id and len(devices) == 1:
                    selected = devices[0]
                if selected:
                    self.select(selected)
                return {'devices': devices, 'selected': selected}
        finally:
            self.discovery_lock.release()

    def select_discovered(self, id_):
        with self.lock:
            device = self.discovered.get(id_)
            if device is None:
                raise ValueError('Discover WiiM first, then select a device')
            self.select(device)
            return device

    @property
    def device(self):
        with self.lock:
            if not self._device:
                raise ValueError('Select a WiiM using Discover WiiM or enter its address in Setup.')
            return dict(self._device)

    def select(self, device):
        with self.lock:
            write_private_json(self.settings.device_file, device)
            self._device = dict(device)

    @staticmethod
    def _manual_device(host, port):
        address = ipaddress.ip_address(host)
        if not address.is_private or address.is_loopback or address.is_unspecified or address.is_multicast:
            raise ValueError('Enter a private local-network IP address')
        if type(port) is not int or not 1 <= port <= 65535:
            raise ValueError('Port must be between 1 and 65535')
        device = {'id': '', 'name': 'WiiM (manual)', 'host': str(address),
                  'url': f'http://{address}:{port}/upnp/control/PlayQueue1'}
        if address.version != 4:
            raise ValueError('Use the WiiM IPv4 address for this release')
        return device

    def manual(self, host, port):
        device = self._manual_device(host, port)
        self.select(device)
        return device

    def command(self, command):
        host = self.device['host']
        url = f'https://{host}/httpapi.asp?' + urllib.parse.urlencode({'command': command})
        # WiiM uses a self-signed local certificate.
        with urllib.request.urlopen(url, timeout=4, context=ssl._create_unverified_context()) as response:
            return response.read().decode('utf-8')

    def soap(self, action, arguments):
        el = ''.join(f'<{key}>{escape(str(value))}</{key}>' for key, value in arguments.items())
        payload = (f'<?xml version="1.0" encoding="UTF-8"?>'
                   f'<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
                   f'<s:Body><u:{action} xmlns:u="{SERVICE}">{el}</u:{action}></s:Body></s:Envelope>')
        req = urllib.request.Request(self.device["url"], data=payload.encode('utf-8'),
               headers={'Content-Type': 'text/xml; charset="utf-8"',
                        'SOAPAction': f'"{SERVICE}#{action}"'}, method='POST')
        try:
            with urllib.request.urlopen(req, timeout=12) as response:
                raw = response.read()
        except urllib.error.HTTPError as e:
            raise RuntimeError(f'WiiM HTTP {e.code}: {e.read().decode(errors="replace")[:500]}') from e
        root = ET.fromstring(raw)
        fault = next((node for node in root.iter() if node.tag.endswith('Fault')), None)
        if fault is not None:
            raise RuntimeError(f'WiiM SOAP fault: {ET.tostring(fault, encoding="unicode")[:500]}')
        return root


    def queue(self, catalog_id, tracks, name):
        if catalog_id not in self.catalogs:
            raise ValueError(f'WiiM does not support the {catalog_id} catalog.')
        if not 1 <= len(tracks) <= 100:
            raise ValueError('Supply 1 to 100 tracks')
        count = len(tracks)
        track_xml = ''.join(f'<Track{i}><Id>{escape(str(track.id))}</Id><URL></URL>'
                            f'<Metadata>{escape(track_metadata(track))}</Metadata>'
                            f'<Source>Tidal</Source></Track{i}>' for i, track in enumerate(tracks, 1))
        playlist = (f'<?xml version="1.0"?><PlayList><ListName>{escape(name)}</ListName><ListInfo>'
                    f'<QueueVersion>2.0</QueueVersion><SourceName>Tidal</SourceName>'
                    f'<ContentType>songlist</ContentType><TotalNumber>{count}</TotalNumber>'
                    f'<TrackNumber>{count}</TrackNumber><LastPlayIndex>1</LastPlayIndex>'
                    f'</ListInfo><Tracks>{track_xml}</Tracks></PlayList>')
        self.soap('CreateQueue', {'QueueContext': playlist})
        return count

    def control(self, action, value):
        commands = {'previous': 'prev', 'next': 'next', 'toggle': 'onepause', 'play': 'resume', 'pause': 'pause'}
        if action in ('volume', 'seek'):
            command = f'{"vol" if action == "volume" else "seek"}:{value}'
        else:
            command = commands[action]
        if self.command('setPlayerCmd:' + command).strip().strip('"').upper() != 'OK':
            raise PlayerError('WiiM rejected command')

    def now_playing(self):
        def read_object(command):
            value = json.loads(self.command(command))
            return value if isinstance(value, dict) else {}

        metadata = None
        try:
            info = read_object('getMetaInfo').get('metaData')
            if isinstance(info, dict):
                metadata = info
        except (OSError, ValueError):
            # A player can answer controls while its current source offers no track metadata.
            pass

        fields = {'status': 'playbackStatus', 'vol': 'volume', 'curpos': 'positionMs', 'totlen': 'durationMs'}
        status = None
        network_error = None
        for command in ('getPlayerStatusEx', 'getPlayerStatus'):
            try:
                candidate = read_object(command)
                if any(candidate.get(key) is not None for key in fields):
                    status = candidate
                    break
            except (urllib.error.HTTPError, ValueError):
                # Some firmware responds to unsupported commands with HTTP errors or plain text.
                continue
            except OSError as exc:
                network_error = exc.reason if isinstance(exc, urllib.error.URLError) else exc
                break

        if metadata is None and status is None:
            if self._local_network_error(network_error):
                raise PlayerError(self._network_help(), 503)
            if network_error is not None:
                raise PlayerError('WiiM did not respond at its saved address. Check that it is on and find it again in Setup.', 503)
            raise PlayerError('WiiM responded without playback information. Try Refresh after starting playback in WiiM Home.')

        result = {**(metadata or {}), 'controlsAvailable': status is not None}
        if status is not None:
            result.update({dest: status.get(source) for source, dest in fields.items()})
        return result
