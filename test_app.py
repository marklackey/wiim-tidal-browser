import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
import xml.etree.ElementTree as ET
from types import SimpleNamespace
from unittest.mock import Mock, patch

import tidalapi
from wiim_tidal import catalog as metadata
from wiim_tidal.adapters import QueueTrack
from wiim_tidal.config import Settings
from wiim_tidal.web import create_app


class AppTest(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.app = create_app(Settings(Path(temp.name)))
        self.client = self.app.test_client()
        self.catalog = self.app.extensions['catalog']
        self.catalog.connected = True
        self.wiim = self.app.extensions['player']
        self.headers = {'X-Local-Token': self.app.config['LOCAL_TOKEN']}

    def post(self, path, **kwargs):
        return self.client.post(path, headers=self.headers, **kwargs)



class SearchTests(AppTest):
    def test_search_returns_selected_types_and_separates_artist_only_hits(self):
        beck = SimpleNamespace(id=1, name='Beck')
        unrelated = SimpleNamespace(id=2, name='The Other Band')
        album = SimpleNamespace(id=10, name='Sea Change', artist=beck)
        title_hit = SimpleNamespace(id=11, name='Beck Sessions', artist=unrelated)
        track = SimpleNamespace(id=20, name='Beck Tribute', artist=unrelated, album=title_hit)
        with patch.object(self.catalog, 'session') as session:
            beck.get_albums = Mock(return_value=[album])
            session.search.return_value = {'albums': [album, title_hit], 'artists': [beck], 'tracks': [track]}
            reply = self.client.get('/api/search?q=beck&types=artist,album,track')
            self.assertEqual(reply.status_code, 200)
            session.search.assert_called_once_with('beck', models=[tidalapi.Artist, tidalapi.Album, tidalapi.Track], limit=300)
            self.assertEqual([a['id'] for a in reply.json['artistAlbums']], [10])
            self.assertEqual([a['id'] for a in reply.json['albums']], [11])
            self.assertEqual([t['id'] for t in reply.json['tracks']], [20])

    def test_track_only_search_does_not_load_albums_or_artists(self):
        with patch.object(self.catalog, 'session') as session:
            session.search.return_value = {'tracks': []}
            reply = self.client.get('/api/search?q=test&types=track')
            self.assertEqual(reply.status_code, 200)
            session.search.assert_called_once_with('test', models=[tidalapi.Track], limit=300)


class QueueMetadataTests(AppTest):
    def test_queue_contains_escaped_catalog_metadata(self):
        album = SimpleNamespace(name='Sea & Change', cover=True,
                                image=lambda size: 'https://example.com/art?a=1&b=2')
        track = SimpleNamespace(id=123, name='Title <Live>',
                                artist=SimpleNamespace(name='Beck & Guest'),
                                album=album, track_num=2)
        with patch.object(self.catalog, 'session') as session, patch.object(self.wiim, 'soap') as soap:
            session.track.return_value = track
            reply = self.post('/api/play', json={'ids': [123, 123]})
            self.assertEqual(reply.status_code, 200)
            self.assertEqual(reply.json['count'], 2)
            session.track.assert_called_once_with(123)
        queue = ET.fromstring(soap.call_args.args[1]['QueueContext'])
        self.assertEqual(queue.findtext('ListName'), 'Hi-Res Browser')
        entries = list(queue.find('Tracks'))
        self.assertEqual(len(entries), 2)
        for entry in entries:
            self.assertEqual(entry.findtext('Id'), '123')
            self.assertEqual(entry.findtext('Source'), 'Tidal')
            self.assertFalse(entry.findtext('URL'))
            metadata = ET.fromstring(entry.findtext('Metadata'))
            values = {node.tag.rsplit('}', 1)[-1]: node.text for node in metadata.iter()}
            self.assertEqual(values['title'], 'Title <Live>')
            self.assertEqual(values['artist'], 'Beck & Guest')
            self.assertEqual(values['album'], 'Sea & Change')
            self.assertEqual(values['originalTrackNumber'], '2')
            self.assertEqual(values['albumArtURI'], album.image(640))

    def test_metadata_failure_does_not_submit_queue(self):
        with patch.object(self.catalog, 'session') as session, patch.object(self.wiim, 'soap') as soap:
            session.track.side_effect = RuntimeError('Catalog unavailable')
            self.assertEqual(self.post('/api/play', json={'ids':[123]}).status_code, 502)
            soap.assert_not_called()


class QualityLabelTests(unittest.TestCase):
    def test_hi_res_catalog_tag_overrides_lossless(self):
        album = SimpleNamespace(audio_quality='LOSSLESS', media_metadata_tags=['HIRES_LOSSLESS'])
        self.assertEqual(metadata.quality_name(album), 'Hi-Res Lossless')

    def test_lossless_without_hi_res_tag(self):
        self.assertEqual(metadata.quality_name(SimpleNamespace(audio_quality='LOSSLESS')), 'LOSSLESS')


class ResolutionTests(AppTest):
    def test_session_requests_hi_res_lossless(self):
        self.assertEqual(self.catalog.session.audio_quality, tidalapi.Quality.hi_res_lossless)

    def test_first_track_resolution(self):
        with patch.object(self.catalog, 'session') as session:
            session.check_login.return_value = True
            session.album.return_value.get_audio_resolution.return_value = [(24, 192000)]
            response = self.client.get('/api/resolution/123')

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json['bits'], 24)
        self.assertEqual(response.json['hz'], 192000)

    def test_missing_or_malformed_resolution(self):
        for result in (None, [], [None], [(24,)]):
            with self.subTest(result=result), patch.object(self.catalog, 'session') as session:
                session.check_login.return_value = True
                session.album.return_value.get_audio_resolution.return_value = result
                response = self.client.get('/api/resolution/123')

            self.assertEqual(response.status_code, 400)
            self.assertEqual(response.json['error'], 'No resolution returned')


class PlaybackControlTests(AppTest):
    def test_allowed_controls(self):
        for action, command in [('previous', 'prev'), ('next', 'next'), ('toggle', 'onepause')]:
            with self.subTest(action=action), patch.object(self.wiim, 'command', return_value='OK') as send:
                self.assertEqual(self.post('/api/control', json={'action': action}).status_code, 200)
                send.assert_called_once_with('setPlayerCmd:' + command)
        with patch.object(self.wiim, 'command', return_value='OK') as send:
            self.assertEqual(self.post('/api/control', json={'action': 'volume', 'value': 30}).status_code, 200)
            send.assert_called_once_with('setPlayerCmd:vol:30')

    def test_invalid_controls_do_not_reach_device(self):
        with patch.object(self.wiim, 'command') as send:
            for payload in ({'action': 'reboot'}, {'action': 'volume', 'value': 101},
                            {'action': 'volume', 'value': True}):
                self.assertEqual(self.post('/api/control', json=payload).status_code, 400)
            send.assert_not_called()

    def test_seek_command(self):
        with patch.object(self.wiim, 'command', return_value='OK') as send:
            response = self.post('/api/control', json={'action': 'seek', 'value': 90})
            self.assertEqual(response.status_code, 200)
            send.assert_called_once_with('setPlayerCmd:seek:90')
        with patch.object(self.wiim, 'command') as send:
            for value in (-1, True, '90', 86401):
                self.assertEqual(self.post('/api/control', json={'action': 'seek', 'value': value}).status_code, 400)
            send.assert_not_called()

    def test_device_rejection(self):
        with patch.object(self.wiim, 'command', return_value='Failed'):
            self.assertEqual(self.post('/api/control', json={'action': 'next'}).status_code, 502)

    def test_current_track_resolution_uses_track_stream(self):
        with patch.object(self.catalog, 'session') as session:
            session.track.return_value.get_stream.return_value.get_audio_resolution.return_value = (24, 96000)
            response = self.client.get('/api/track-resolution/123')
            session.track.assert_called_once_with(123)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json['bits'], 24)
        self.assertEqual(response.json['hz'], 96000)

    def test_now_preserves_detected_bitrate(self):
        with patch.object(self.wiim, 'command', side_effect=[
            '{"metaData":{"title":"Track","bitRate":"4567","sampleRate":"192000"}}',
            '{"status":"play","vol":"25"}',
        ]):
            response = self.client.get('/api/now')
        self.assertEqual(response.json['bitRate'], '4567')
        self.assertEqual(response.json['playbackStatus'], 'play')

    def test_now_uses_standard_status_if_metadata_and_extended_status_are_missing(self):
        with patch.object(self.wiim, 'command', side_effect=[
            'unknown', 'unsupported', '{"status":"play","vol":"23","curpos":"12000"}',
        ]) as command:
            reply = self.client.get('/api/now')
        self.assertEqual(reply.status_code, 200)
        self.assertTrue(reply.json['controlsAvailable'])
        self.assertEqual(reply.json['volume'], '23')
        self.assertEqual(reply.json['positionMs'], '12000')
        self.assertEqual(command.call_args.args, ('getPlayerStatus',))

    def test_now_reports_unreadable_wiim_responses_as_device_error(self):
        with patch.object(self.wiim, 'command', return_value='unknown'):
            reply = self.client.get('/api/now')
        self.assertEqual(reply.status_code, 502)
        self.assertIn('without playback information', reply.json['error'])


class FirstRunTests(AppTest):
    def test_blocks_cross_origin_and_untokened_commands(self):
        with patch.object(self.wiim, 'command') as command:
            self.assertEqual(self.client.post('/api/control', json={'action': 'pause'}).status_code, 403)
            response = self.client.post('/api/control', data='{"action":"pause"}',
                                        content_type='text/plain',
                                        headers={**self.headers, 'Origin': 'https://unrelated.invalid'})
            self.assertEqual(response.status_code, 403)
            self.assertEqual(self.post('/api/control', json=[]).status_code, 400)
            command.assert_not_called()

    def test_discovery_recovers_moved_device_and_persists_new_address(self):
        device = {'id': 'uuid:mini', 'name': 'WiiM Mini', 'host': '192.168.1.10',
                  'url': 'http://192.168.1.10:49152/upnp/control/PlayQueue1'}
        moved = {**device, 'host': '192.168.1.11',
                 'url': 'http://192.168.1.11:49153/upnp/control/PlayQueue1'}
        with patch('wiim_tidal.wiim.discover_devices', side_effect=[[device], [moved]]):
            self.assertEqual(self.post('/api/wiim/discover', json={}).json['selected'], device)
            self.assertEqual(self.post('/api/wiim/discover', json={}).json['selected'], moved)
        restarted = create_app(self.app.extensions['settings']).test_client()
        self.assertEqual(restarted.get('/api/health').json['wiim'], moved['host'])

    def test_manual_device_validates_local_ipv4(self):
        self.assertEqual(self.post('/api/wiim/manual', json={'host': '8.8.8.8'}).status_code, 400)
        self.assertEqual(self.post('/api/wiim/manual', json={'host': '192.168.1.10'}).status_code, 200)

    def test_browser_login_uses_pending_session_and_private_file(self):
        pending = SimpleNamespace(
            config=SimpleNamespace(pkce_uri_redirect='https://login.example/callback'),
            pkce_login_url=lambda: 'https://login.example/authorize',
            pkce_get_auth_token=lambda url: {'token': 'mock'},
            process_auth_token=lambda token, is_pkce_token: None,
            check_login=lambda: True, token_type='Bearer', session_id='mock',
            access_token='mock', refresh_token='mock', is_pkce=True,
        )
        with patch.object(self.catalog, 'new_session', return_value=pending):
            self.assertEqual(self.post('/api/auth/start', json={}).json['url'], pending.pkce_login_url())
            self.assertEqual(self.post('/api/auth/finish', json={'redirect': 'https://unrelated.invalid/callback?code=mock'}).status_code, 400)
            response = self.post('/api/auth/finish', json={'redirect': 'https://login.example/callback?code=mock'})
        self.assertEqual(response.status_code, 200)
        self.assertIs(self.catalog.session, pending)
        self.assertEqual(self.app.extensions['settings'].session_file.stat().st_mode & 0o777, 0o600)


class AdapterIntegrationTests(unittest.TestCase):
    def test_installed_adapters_can_search_select_play_and_report_status(self):
        catalog = SimpleNamespace(
            id='example-catalog', name='Example Catalog', login_required=False,
            connected=True, restoring=False, start_restore=Mock(),
            search=Mock(return_value={'albums': [], 'artistAlbums': [], 'tracks': []}),
            album=Mock(return_value={'album': {'id': 'record:abc'}, 'tracks': []}),
            track=Mock(return_value={'id': 'track:abc'}),
            resolution=Mock(return_value={'bits': 24, 'hz': 96000}),
            queue_tracks=Mock(return_value=[QueueTrack('track:abc', 'Example Track')]),
        )
        device = {'id':'player:abc', 'name':'Living Room', 'host':'192.168.1.25'}
        player = SimpleNamespace(
            id='example-player', name='Example Player', catalogs=frozenset({catalog.id}), manual_port=None,
            selected_device=device, discover=Mock(return_value={'devices':[device], 'selected':None}),
            select_discovered=Mock(return_value=device), queue=Mock(return_value=1), control=Mock(),
            now_playing=Mock(return_value={'trackId':'track:abc', 'playbackStatus':'play'}),
        )

        def entry_points(group, name):
            adapter = {'wiim_tidal.catalogs': catalog, 'wiim_tidal.players': player}[group]
            if adapter.id != name:
                return []
            return [SimpleNamespace(load=lambda: lambda settings: adapter)]

        with TemporaryDirectory() as directory, patch.dict('os.environ', {
            'WIIM_TIDAL_CATALOG':catalog.id, 'WIIM_TIDAL_PLAYER':player.id,
        }), patch('wiim_tidal.adapters.entry_points', side_effect=entry_points):
            app = create_app(Settings(directory), restore=True)
            client = app.test_client()
            headers = {'X-Local-Token': app.config['LOCAL_TOKEN']}

            self.assertIn(b'Example Player + Example Catalog', client.get('/').data)
            self.assertEqual(client.get('/api/health').json['playerDevice'], device)
            self.assertEqual(client.get('/api/identity').json['catalog'], catalog.id)
            self.assertEqual(client.get('/api/search?q=Example&types=track').status_code, 200)
            self.assertEqual(client.get('/api/album/record:abc').json['album']['id'], 'record:abc')
            self.assertEqual(client.get('/api/track-resolution/track:abc').json['hz'], 96000)
            self.assertEqual(client.post('/api/player/discover', json={}, headers=headers).json['devices'], [device])
            self.assertEqual(client.post('/api/player/select', json={'id':device['id']}, headers=headers).json['selected'], device)
            self.assertEqual(client.post('/api/player/manual', json={'host':'192.168.1.25'}, headers=headers).status_code, 400)
            self.assertEqual(client.post('/api/auth/start', json={}, headers=headers).status_code, 400)
            self.assertEqual(client.post('/api/play', json={'ids':['track:abc']}, headers=headers).json['count'], 1)
            self.assertEqual(client.post('/api/control', json={'action':'pause'}, headers=headers).status_code, 200)
            self.assertEqual(client.get('/api/now').json['trackId'], 'track:abc')

            player.catalogs = frozenset({'some-other-catalog'})
            with self.assertRaisesRegex(ValueError, 'does not support'):
                create_app(Settings(directory), catalog=catalog, player=player)

        catalog.start_restore.assert_called_once_with()
        catalog.search.assert_called_once_with('Example', ['track'], separate_artist_matches=True)
        catalog.queue_tracks.assert_called_once_with(['track:abc'])
        player.queue.assert_called_once_with(catalog.id, [QueueTrack('track:abc', 'Example Track')], 'Hi-Res Browser')
        player.control.assert_called_once_with('pause', None)


if __name__ == '__main__':
    unittest.main()
