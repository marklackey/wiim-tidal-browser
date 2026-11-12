"""TIDAL catalog serialization; stream URLs never leave this process."""
from datetime import datetime
import unicodedata

def quality_name(a):
    q = getattr(a, 'audio_quality', '')
    tags = getattr(a, 'media_metadata_tags', []) or []
    labels = [str(getattr(t, 'value', t)).upper().replace('_', '') for t in [q, *tags]]
    if 'HIRESLOSSLESS' in labels:
        return 'Hi-Res Lossless'
    return getattr(q, 'value', str(q or 'Unknown'))


def search_key(value):
    return ' '.join(unicodedata.normalize('NFKC', value or '').lower().split())


def release_date(album):
    value = getattr(album, 'release_date', None)
    if isinstance(value, datetime):
        return value.date().isoformat()
    return None


def album_data(a):
    tags = getattr(a, 'media_metadata_tags', []) or []
    return {
        'id': int(a.id), 'name': a.name or '(Untitled)',
        'artist': getattr(getattr(a, 'artist', None), 'name', 'Unknown artist'),
        'year': getattr(a, 'year', None), 'releaseDate': release_date(a),
        'version': getattr(a, 'version', None),
        'quality': quality_name(a), 'tags': [str(getattr(t, 'value', t)) for t in tags],
        'art': a.image(320) if getattr(a, 'cover', None) else None,
        'url': f'https://tidal.com/browse/album/{a.id}',
    }


def track_data(t):
    artist = getattr(t, 'artist', None)
    album = getattr(t, 'album', None)
    return {'id': int(t.id), 'title': t.name or 'Unknown',
            'artist': getattr(artist, 'name', 'Unknown'),
            'album': getattr(album, 'name', '') or '',
            'album_id': int(getattr(album, 'id', 0) or 0),
            'releaseDate': release_date(album), 'year': getattr(album, 'year', None),
            'number': getattr(t, 'track_num', None),
            'quality': quality_name(t)}
