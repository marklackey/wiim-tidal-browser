"""The iOS bridge uses the same catalog semantics as the desktop routes."""
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import Mock, patch
from wiim_tidal.adapters import QueueTrack

spec = importlib.util.spec_from_file_location('mobile_bridge', Path(__file__).parents[1] / 'catalog_bridge.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.catalog = Mock(connected=True)
        bridge._catalog = self.catalog

    def call(self, action, payload):
        return json.loads(bridge.handle(action, json.dumps(payload), '/unused-test-path'))

    def test_combined_search(self):
        self.catalog.search.return_value = {'albums': [], 'artistAlbums': [], 'tracks': []}
        self.call('search', {'query': 'Music', 'types': ['album', 'artist', 'track']})
        self.catalog.search.assert_called_once_with('Music', ['album', 'artist', 'track'], separate_artist_matches=True)

    def test_queue_preserves_order_duplicates_and_metadata(self):
        self.catalog.queue_tracks.return_value = [QueueTrack(2, 'A & B'), QueueTrack(1, 'Second'), QueueTrack(2, 'A & B')]
        tracks = self.call('queue_tracks', {'ids': ['2', '1', '2']})
        self.assertEqual([track['id'] for track in tracks], ['2', '1', '2'])
        self.assertEqual(tracks[0]['title'], 'A & B')
        self.catalog.queue_tracks.assert_called_once_with(['2', '1', '2'])

    def test_invalid_queue_or_search_never_calls_catalog(self):
        self.assertIn('error', self.call('queue_tracks', {'ids': []}))
        self.assertIn('error', self.call('search', {'query': 'Music', 'types': ['invalid']}))
        self.catalog.queue_tracks.assert_not_called()
        self.catalog.search.assert_not_called()

    def test_device_login_and_optional_resolution_status(self):
        self.catalog.begin_device_login.return_value = {'id': 'attempt', 'url': 'https://link.tidal.com/test'}
        self.assertEqual(self.call('begin_device_login', {})['id'], 'attempt')
        self.catalog.check_device_login.return_value = True
        self.assertTrue(self.call('check_device_login', {'id': 'attempt'})['connected'])
        self.catalog.check_device_login.assert_called_once_with('attempt')

    def test_discovery_does_not_require_a_catalog_session(self):
        bridge._catalog = None
        with patch('wiim_tidal.discovery.describe_device', return_value=None) as describe:
            self.assertIsNone(self.call('probe_device', {'host': '192.168.1.20', 'port': 49152})['device'])
            describe.assert_called_once_with(('http://192.168.1.20:49152/description.xml', '192.168.1.20'))
        self.assertIsNone(bridge._catalog)


if __name__ == '__main__':
    unittest.main()
