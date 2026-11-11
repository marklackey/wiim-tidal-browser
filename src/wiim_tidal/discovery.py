"""Discover WiiM renderers through their local UPnP advertisements."""
import ipaddress
import socket
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor

SERVICE = 'urn:schemas-wiimu-com:service:PlayQueue:1'
NS = {'d': 'urn:schemas-upnp-org:device-1-0'}


def local_url(url, host):
    """Only follow HTTP URLs on the device that answered discovery."""
    parsed = urllib.parse.urlsplit(url)
    address = ipaddress.ip_address(host)
    return (parsed.scheme == 'http' and parsed.hostname == host
            and not parsed.username and not parsed.password
            and address.is_private and not address.is_loopback
            and not address.is_unspecified and not address.is_multicast)


def describe_device(candidate):
    location, host = candidate
    try:
        if not local_url(location, host):
            return None
        # Do not send local discovery traffic through a configured HTTP proxy,
        # or follow redirects away from the responding device.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        with opener.open(location, timeout=2) as response:
            root = ET.fromstring(response.read(256 * 1024))
        base = root.findtext('d:URLBase', default=location, namespaces=NS)
        for device in root.findall('.//d:device', NS):
            def field(name):
                return device.findtext('d:' + name, default='', namespaces=NS).strip()
            identity = ' '.join(field(key) for key in ('manufacturer', 'modelName', 'friendlyName'))
            if 'wiim' not in identity.lower():
                continue
            for service in device.findall('d:serviceList/d:service', NS):
                if service.findtext('d:serviceType', namespaces=NS) != SERVICE:
                    continue
                control = service.findtext('d:controlURL', default='', namespaces=NS)
                url = urllib.parse.urljoin(base, control)
                if control and field('UDN') and local_url(url, host):
                    return {'id': field('UDN'), 'name': field('friendlyName') or field('modelName'),
                            'host': host, 'url': url}
    except (OSError, ValueError, ET.ParseError):
        pass  # One malformed or unavailable renderer must not stop the search.
    return None


def discover_devices(timeout=3):
    candidates = set()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP) as sock:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
        sock.bind(('', 0))
        for _ in range(2):
            for target in ('urn:schemas-upnp-org:device:MediaRenderer:1', SERVICE):
                packet = ('M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n'
                          'MAN: "ssdp:discover"\r\nMX: 2\r\n'
                          f'ST: {target}\r\n\r\n').encode('ascii')
                sock.sendto(packet, ('239.255.255.250', 1900))
        deadline = time.monotonic() + timeout
        while len(candidates) < 16:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            sock.settimeout(remaining)
            try:
                data, (host, _) = sock.recvfrom(65535)
            except socket.timeout:
                break
            lines = data.decode('utf-8', errors='replace').splitlines()
            if not lines or not lines[0].upper().startswith('HTTP/1.1 200'):
                continue
            headers = dict((key.strip().lower(), value.strip()) for line in lines[1:]
                           if ':' in line for key, value in [line.split(':', 1)])
            if headers.get('location'):
                candidates.add((headers['location'], host))
    with ThreadPoolExecutor(max_workers=8) as pool:
        devices = {device['id']: device for device in pool.map(describe_device, sorted(candidates))
                   if device}
    return sorted(devices.values(), key=lambda device: (device['name'].lower(), device['host']))
