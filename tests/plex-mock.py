# A tiny stand-in for a Plex server (7 movies, 10 episodes in 2 shows) for headless tests. Token: tok. Port 32499.
import http.server, urllib.parse, re

import zlib, struct
def _png(w=24, h=36, rgb=(90, 110, 200)):
    raw = b''.join(b'\x00' + bytes(rgb) * w for _ in range(h))
    chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')
POSTER = _png()   # a real (tiny) picture; browsers show it whatever the file name says

MOV=[(str(100+i),f"Movie {i}",2000+i) for i in range(1,8)]
EPS=[(str(1000+i),"Show A" if i<6 else "Show B","2" if i<6 else "3",1+(i%2),i) for i in range(1,11)]
def video_movie(k,t,y):
    return f'<Video ratingKey="{k}" key="/library/metadata/{k}" type="movie" title="{t}" year="{y}" updatedAt="1700000{k}" addedAt="1690000000" duration="7200000" rating="7.5" contentRating="PG-13" studio="Studio" thumb="/library/metadata/{k}/thumb/1" originallyAvailableAt="{y}-05-01"><Media videoResolution="4k" videoCodec="hevc" audioCodec="eac3" audioChannels="6" bitrate="20000" container="mkv"><Part file="/m/{t}.mkv" size="1000000000"><Stream streamType="1" codec="hevc" bitDepth="10" width="3840" height="2160" frameRate="23.976" DOVIPresent="1" DOVIProfile="8" /><Stream streamType="2" codec="eac3" channels="6" language="English" /></Part></Media><Genre tag="Drama"/></Video>'
def video_ep(k,show,sk,s,e):
    return f'<Video ratingKey="{k}" type="episode" title="Ep {e}" grandparentTitle="{show}" grandparentRatingKey="{sk}" parentIndex="{s}" index="{e}" year="2015" updatedAt="1700000{k}" addedAt="1690000000" duration="2700000" grandparentThumb="/library/metadata/{sk}/thumb/2" thumb="/library/metadata/{k}/thumb/1" summary="Something happens in episode {e}." viewCount="{1 if e<4 else 0}" originallyAvailableAt="2015-0{s}-1{e%10}"><Media videoResolution="1080" videoCodec="h264" audioCodec="aac" audioChannels="2"><Part file="/tv/{show}/{k}.mkv" size="500000000"><Stream streamType="1" codec="h264" bitDepth="8" width="1920" height="1080" frameRate="23.976"/></Part></Media></Video>'
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def send(self,body,ct='text/xml'):
        b=body.encode() if isinstance(body,str) else body
        self.send_response(200); self.send_header('Content-Type',ct); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        u=urllib.parse.urlparse(self.path); q=urllib.parse.parse_qs(u.query); p=u.path
        if self.headers.get('X-Plex-Token')!='tok' and q.get('X-Plex-Token',[''])[0]!='tok':
            self.send_response(401); self.end_headers(); return
        if p=='/library/sections':
            return self.send('<MediaContainer><Directory key="1" title="Movies" type="movie"/><Directory key="2" title="TV" type="show"/></MediaContainer>')
        m=re.match(r'/library/sections/(\d)/all',p)
        if m:
            st=int(q.get('X-Plex-Container-Start',['0'])[0]); sz=int(q.get('X-Plex-Container-Size',['200'])[0])
            items=[video_movie(*x) for x in MOV] if m.group(1)=='1' else [video_ep(*x) for x in EPS]
            page=items[st:st+3]
            return self.send(f'<MediaContainer totalSize="{len(items)}" size="{len(page)}">'+''.join(page)+'</MediaContainer>')
        m=re.match(r'/library/metadata/([\d,]+)$',p)
        if m:
            out=[]
            for k in m.group(1).split(','):
                for x in MOV:
                    if x[0]==k: out.append(video_movie(*x))
                for x in EPS:
                    if x[0]==k: out.append(video_ep(*x))
                if k in ('2','3'):
                    other='3' if k=='2' else '2'
                    out.append(f'<Directory ratingKey="{k}" type="show" title="Show {k}" year="2015" summary="A show about a bar." studio="FX" contentRating="TV-MA" rating="8.8" originallyAvailableAt="2015-01-10" thumb="/library/metadata/{k}/thumb/2"><Genre tag="Comedy"/>'
                               + ''.join(f'<Role tag="Actor {i}" role="Character {i}" thumb="https://metadata-static.plex.tv/people/{i}.jpg"/>' for i in range(1,6))
                               + f'<Related><Hub title="More like this"><Directory ratingKey="{other}" type="show" title="Show {other}" year="2016" childCount="2" leafCount="5" viewedLeafCount="1" thumb="/library/metadata/{other}/thumb/2"/><Directory ratingKey="77" type="show" title="Elsewhere" year="2001" childCount="4" leafCount="40" viewedLeafCount="40" thumb="/library/metadata/77/thumb/2"/></Hub></Related></Directory>')
            return self.send('<MediaContainer>'+''.join(out)+'</MediaContainer>')
        m=re.match(r'/library/metadata/(\d+)/(children|allLeaves)$',p)
        if m:
            k=m.group(1); eps=[x for x in EPS if x[2]==k]
            if m.group(2)=='allLeaves': return self.send('<MediaContainer>'+''.join(video_ep(*x) for x in eps)+'</MediaContainer>')
            seasons=sorted(set(x[3] for x in eps))
            return self.send('<MediaContainer>'+''.join(f'<Directory ratingKey="{k}0{n}" type="season" index="{n}" title="Season {n}" leafCount="{sum(1 for x in eps if x[3]==n)}" viewedLeafCount="1" thumb="/library/metadata/{k}0{n}/thumb/3"/>' for n in seasons)+'</MediaContainer>')
        if p=='/photo/:/transcode':
            if re.search(r'/(banner|clearLogo)$', q.get('url',[''])[0]) and q.get('minSize',['1'])[0] != '0':   # logos and banners must never be cropped
                self.send_response(500); self.end_headers(); return
            if q.get('url',[''])[0].endswith('/102/clearLogo'):      # a title Plex has no clear logo for
                self.send_response(404); self.end_headers(); return
            return self.send(POSTER,'image/jpeg')
        self.send_response(404); self.end_headers()
http.server.ThreadingHTTPServer(('127.0.0.1',32499),H).serve_forever()
