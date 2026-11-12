# A tiny stand-in for a Jellyfin server (4 movies, 6 episodes in 2 shows) for headless tests. API key: tok. Port 8099.
# The JSON follows Jellyfin 10.9's shapes (only the fields MMLM reads). Asking for an unknown Fields name gets a 400,
# as a real server does, so a typo in MMLM's field list shows up in the tests.
import http.server, urllib.parse, re, json, zlib, struct

def _png(w=24, h=36, rgb=(200, 120, 60)):
    raw = b''.join(b'\x00' + bytes(rgb) * w for _ in range(h))
    chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')
PIC = _png()
FIELDS = {'Etag', 'MediaSources', 'MediaStreams', 'Path', 'ProviderIds', 'Genres', 'Studios', 'People', 'Overview', 'Taglines',
          'ProductionLocations', 'DateCreated', 'OriginalTitle', 'Tags', 'SortName', 'ParentId', 'DateLastSaved'}
MOVIES_LIB, TV_LIB = 'f137a2dd21bbc1b99aa5c0f6bf02a805', '767bffe4f11c93ef34b805451a696a4e'

def vstream(w, h, codec, **kw):
    s = {'Type': 'Video', 'Codec': codec, 'Width': w, 'Height': h, 'BitRate': 20000000, 'BitDepth': 10, 'RealFrameRate': 23.976,
         'AspectRatio': '16:9', 'IsInterlaced': False, 'PixelFormat': 'yuv420p10le', 'Profile': 'Main 10', 'ColorRange': 'tv',
         'ColorSpace': 'bt2020nc', 'ColorTransfer': 'smpte2084', 'ColorPrimaries': 'bt2020', 'VideoRange': 'HDR', 'VideoRangeType': 'HDR10'}
    s.update(kw); return s
def astream(codec, ch, lang='eng', default=True, **kw):
    s = {'Type': 'Audio', 'Codec': codec, 'Channels': ch, 'Language': lang, 'IsDefault': default, 'BitRate': 640000, 'SampleRate': 48000, 'DisplayTitle': f'{lang} {codec}'}
    s.update(kw); return s

def movie(i, title, year, streams, extra=None):
    iid = '%032x' % (0xa000 + i)
    m = {'Id': iid, 'Name': title, 'Type': 'Movie', 'ProductionYear': year, 'PremiereDate': f'{year}-06-01T00:00:00.0000000Z', 'OfficialRating': 'PG-13',
         'CommunityRating': 7.1 + i / 10, 'CriticRating': 80 + i, 'RunTimeTicks': 72000000000, 'Etag': f'etag{i}', 'Genres': ['Drama', 'Thriller'],
         'Studios': [{'Name': 'Studio J'}], 'People': [{'Name': 'Dee Rector', 'Type': 'Director'}, {'Name': 'Ann Actor', 'Role': 'Lead', 'Type': 'Actor'}],
         'Overview': f'Movie {i} plot.', 'Taglines': [f'Tagline {i}'], 'ProductionLocations': ['Canada'], 'DateCreated': '2024-03-0%dT10:00:00.0000000Z' % i,
         'ProviderIds': {'Imdb': 'tt00%05d' % i, 'Tmdb': str(500 + i)}, 'ImageTags': {'Primary': 'p'}, 'ParentId': MOVIES_LIB,
         'MediaSources': [{'Path': f'/media/movies/{title} ({year})/{title} ({year}).mkv', 'Container': 'mkv', 'Size': 8000000000 + i, 'Bitrate': 25000000, 'RunTimeTicks': 72000000000, 'MediaStreams': streams}],
         'MediaStreams': streams}
    if extra: m.update(extra)
    return m

MOVIES = [
    movie(1, 'Jelly Dawn', 2019, [vstream(3840, 2160, 'hevc', VideoRangeType='DOVIWithHDR10', DvProfile=8, DvLevel=6, DvBlSignalCompatibilityId=1, ElPresentFlag=0),
                                  astream('truehd', 8, DisplayTitle='English - Dolby TrueHD + Dolby Atmos - 7.1 - Default', Profile=''),
                                  {'Type': 'Subtitle', 'Codec': 'subrip', 'Language': 'eng'}]),
    movie(2, 'Old Reel', 1972, [vstream(1920, 1080, 'h264', BitDepth=8, PixelFormat='yuv420p', VideoRange='SDR', VideoRangeType='SDR', ColorTransfer='bt709', Profile='High'),
                                astream('dts', 6, Profile='DTS-HD MA', DisplayTitle='English - DTS-HD MA - 5.1')]),
    movie(3, 'Bright Plus', 2021, [vstream(3840, 2160, 'hevc', VideoRangeType='HDR10Plus'), astream('eac3', 6), {'Type': 'Subtitle', 'Codec': 'PGSSUB', 'Language': 'fre'}]),
    movie(4, 'Two Layers', 2018, [vstream(3840, 2160, 'hevc', VideoRangeType='DOVIWithHDR10', DvProfile=7, DvLevel=6, DvBlSignalCompatibilityId=6, ElPresentFlag=1), astream('truehd', 8)],
          {'ProviderIds': {}, 'Genres': [], 'Overview': ''}),
]
SERIES = {
    'Show J': {'Id': '%032x' % 0xb001, 'Name': 'Show J', 'Type': 'Series', 'ProductionYear': 2010, 'OfficialRating': 'TV-14', 'CommunityRating': 8.4,
               'Genres': ['Comedy'], 'Studios': [{'Name': 'Net J'}], 'People': [{'Name': 'Cast One', 'Type': 'Actor'}], 'Overview': 'A show.',
               'ProviderIds': {'Imdb': 'tt0900001', 'Tmdb': '9001', 'Tvdb': '7001'}, 'Status': 'Ended', 'ImageTags': {'Primary': 'p'}},
    'Show K': {'Id': '%032x' % 0xb002, 'Name': 'Show K', 'Type': 'Series', 'ProductionYear': 2020, 'OfficialRating': 'TV-MA',
               'Genres': ['Drama'], 'Studios': [], 'People': [], 'Overview': 'Another.', 'ProviderIds': {'Tvdb': '7002'}, 'Status': 'Continuing', 'ImageTags': {}},
}
def episode(i, show, s, e):
    ser = SERIES[show]; iid = '%032x' % (0xc000 + i)
    st = [vstream(1920, 1080, 'h264', BitDepth=8, PixelFormat='yuv420p', VideoRange='SDR', VideoRangeType='SDR', ColorTransfer='bt709'), astream('aac', 2)]
    ep = {'Id': iid, 'Name': f'Ep {e}', 'Type': 'Episode', 'SeriesName': show, 'SeriesId': ser['Id'], 'ParentIndexNumber': s, 'IndexNumber': e,
          'PremiereDate': f'2015-0{s}-1{e}T00:00:00.0000000Z', 'RunTimeTicks': 27000000000, 'Etag': f'etagE{i}', 'Overview': f'Episode {e}.',
          'DateCreated': '2024-04-01T10:00:00.0000000Z', 'ImageTags': {'Primary': 'p'}, 'ProviderIds': {}, 'Genres': [], 'Studios': [], 'People': [],
          'MediaSources': [{'Path': f'/media/tv/{show}/Season {s}/{show} S0{s}E0{e}.mkv', 'Container': 'mkv', 'Size': 900000000, 'Bitrate': 4000000, 'MediaStreams': st}], 'MediaStreams': st}
    if ser['ImageTags'].get('Primary'): ep['SeriesPrimaryImageTag'] = 'sp'
    return ep
EPISODES = [episode(1, 'Show J', 1, 1), episode(2, 'Show J', 1, 2), episode(3, 'Show J', 1, 4), episode(4, 'Show K', 1, 1), episode(5, 'Show K', 2, 1), episode(6, 'Show K', 2, 2)]
BY_ID = {x['Id']: x for x in MOVIES + EPISODES + list(SERIES.values())}
IMAGES = {('%032x' % 0xa001, 'Backdrop'), ('%032x' % 0xa001, 'Logo'), ('%032x' % 0xb001, 'Banner'), ('%032x' % 0xb001, 'Backdrop'), ('%032x' % 0xb001, 'Logo')}

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, body, ct='application/json', code=200):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code); self.send_header('Content-Type', ct); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query); p = u.path
        auth = self.headers.get('Authorization', '') + ' ' + self.headers.get('X-Emby-Token', '')
        if 'Token="tok"' not in auth and self.headers.get('X-Emby-Token') != 'tok':
            return self.send('', code=401)
        if 'api_key' in q: return self.send('{"error":"key in the address"}', code=400)   # MMLM must never put the key in a URL
        if p == '/System/Info': return self.send(json.dumps({'ServerName': 'Test Jellyfin', 'Version': '10.10.3', 'Id': 'abc'}))
        if p == '/Library/VirtualFolders':
            return self.send(json.dumps([{'Name': 'Films', 'CollectionType': 'movies', 'ItemId': MOVIES_LIB}, {'Name': 'Series', 'CollectionType': 'tvshows', 'ItemId': TV_LIB},
                                         {'Name': 'Music', 'CollectionType': 'music', 'ItemId': 'eee'}]))
        if p == '/Items':
            fields = [f for f in q.get('Fields', [''])[0].split(',') if f]
            bad = [f for f in fields if f not in FIELDS]
            if bad: return self.send(json.dumps({'title': 'One or more validation errors occurred.', 'errors': {'fields': bad}}), code=400)
            if 'Ids' in q:
                items = [BY_ID[i] for i in q['Ids'][0].split(',') if i in BY_ID]
                return self.send(json.dumps({'Items': items, 'TotalRecordCount': len(items)}))
            parent = q.get('ParentId', [''])[0]; types = q.get('IncludeItemTypes', [''])[0]
            pool = MOVIES if (parent == MOVIES_LIB and types == 'Movie') else EPISODES if (parent == TV_LIB and types == 'Episode') else []
            start = int(q.get('StartIndex', ['0'])[0]); lim = int(q.get('Limit', ['100'])[0])
            page = [{'Id': x['Id'], 'Name': x['Name'], 'Type': x['Type'], 'Etag': x['Etag']} for x in pool[start:start + lim]]
            return self.send(json.dumps({'Items': page, 'TotalRecordCount': len(pool), 'StartIndex': start}))
        m = re.match(r'^/Items/([0-9a-f]{32})/Images/(Primary|Backdrop|Logo|Banner)$', p)
        if m:
            iid, kind = m.group(1), m.group(2)
            has = (kind == 'Primary' and BY_ID.get(iid, {}).get('ImageTags', {}).get('Primary')) or (iid, kind) in IMAGES
            if not has: return self.send('', code=404)
            return self.send(PIC, 'image/png')
        self.send('', code=404)
http.server.ThreadingHTTPServer(('127.0.0.1', 8099), H).serve_forever()
