"""WiiM device selection and native playback transport."""
import ipaddress
import ssl
import threading
import urllib.request
import urllib.error
import urllib.parse
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape
from .catalog import track_metadata
from .config import write_private_json

SERVICE = 'urn:schemas-wiimu-com:service:PlayQueue:1'

class WiiM:
    def __init__(self, settings, catalog):
        self.settings, self.catalog = settings, catalog
        self.lock = threading.RLock()
        self.discovery_lock = threading.Lock()
        self.discovered = {}
        self._device = settings.load_device()

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

    def manual(self, host, port):
        address = ipaddress.ip_address(host)
        if not address.is_private or address.is_loopback or address.is_unspecified or address.is_multicast:
            raise ValueError('Enter a private local-network IP address')
        if type(port) is not int or not 1 <= port <= 65535:
            raise ValueError('Port must be between 1 and 65535')
        device = {'id': '', 'name': 'WiiM (manual)', 'host': str(address),
                  'url': f'http://{address}:{port}/upnp/control/PlayQueue1'}
        if address.version != 4:
            raise ValueError('Use the WiiM IPv4 address for this release')
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


    def create_playlist(self, tracks, name):
        """Resolve catalog metadata before submitting the native TIDAL queue."""
        if not tracks or len(tracks) > 100:
            raise ValueError('Supply 1 to 100 tracks')
        clean = []
        for id_ in tracks:
            value = int(id_)
            if value <= 0:
                raise ValueError('Invalid track ID')
            clean.append(value)
        count = len(clean)
        with self.catalog.lock:
            self.catalog.ensure_login()
            metadata = {id_: track_metadata(self.catalog.session.track(id_)) for id_ in dict.fromkeys(clean)}
        track_xml = ''.join(f'<Track{i}><Id>{id_}</Id><URL></URL>'
                            f'<Metadata>{escape(metadata[id_])}</Metadata>'
                            f'<Source>Tidal</Source></Track{i}>' for i, id_ in enumerate(clean, 1))
        playlist = (f'<?xml version="1.0"?><PlayList><ListName>{escape(name)}</ListName><ListInfo>'
                    f'<QueueVersion>2.0</QueueVersion><SourceName>Tidal</SourceName>'
                    f'<ContentType>songlist</ContentType><TotalNumber>{count}</TotalNumber>'
                    f'<TrackNumber>{count}</TrackNumber><LastPlayIndex>1</LastPlayIndex>'
                    f'</ListInfo><Tracks>{track_xml}</Tracks></PlayList>')
        self.soap('CreateQueue', {'QueueContext': playlist})
        return count
