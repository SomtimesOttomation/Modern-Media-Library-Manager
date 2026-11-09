# A tiny stand-in for a Plex server (7 movies, 10 episodes in 2 shows) for headless tests. Token: tok. Port 32499.
import http.server, urllib.parse, re
MOV=[(str(100+i),f"Movie {i}",2000+i) for i in range(1,8)]
EPS=[(str(1000+i),"Show A" if i<6 else "Show B","2" if i<6 else "3",1+(i%2),i) for i in range(1,11)]
def video_movie(k,t,y):
    return f'<Video ratingKey="{k}" key="/library/metadata/{k}" type="movie" title="{t}" year="{y}" updatedAt="1700000{k}" addedAt="1690000000" duration="7200000" rating="7.5" contentRating="PG-13" studio="Studio" thumb="/library/metadata/{k}/thumb/1" originallyAvailableAt="{y}-05-01"><Media videoResolution="4k" videoCodec="hevc" audioCodec="eac3" audioChannels="6" bitrate="20000" container="mkv"><Part file="/m/{t}.mkv" size="1000000000"><Stream streamType="1" codec="hevc" bitDepth="10" width="3840" height="2160" frameRate="23.976" DOVIPresent="1" DOVIProfile="8" /><Stream streamType="2" codec="eac3" channels="6" language="English" /></Part></Media><Genre tag="Drama"/></Video>'
def video_ep(k,show,sk,s,e):
    return f'<Video ratingKey="{k}" type="episode" title="Ep {e}" grandparentTitle="{show}" grandparentRatingKey="{sk}" parentIndex="{s}" index="{e}" year="2015" updatedAt="1700000{k}" addedAt="1690000000" duration="2700000" grandparentThumb="/library/metadata/{sk}/thumb/2" thumb="/library/metadata/{k}/thumb/1" originallyAvailableAt="2015-0{s}-1{e%10}"><Media videoResolution="1080" videoCodec="h264" audioCodec="aac" audioChannels="2"><Part file="/tv/{show}/{k}.mkv" size="500000000"><Stream streamType="1" codec="h264" bitDepth="8" width="1920" height="1080" frameRate="23.976"/></Part></Media></Video>'
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
                if k in ('2','3'): out.append(f'<Directory ratingKey="{k}" type="show" title="Show {k}" year="2015" thumb="/library/metadata/{k}/thumb/2"><Genre tag="Comedy"/></Directory>')
            return self.send('<MediaContainer>'+''.join(out)+'</MediaContainer>')
        if p=='/photo/:/transcode':
            return self.send(b'\xff\xd8\xff\xe0fakejpeg','image/jpeg')
        self.send_response(404); self.end_headers()
http.server.ThreadingHTTPServer(('127.0.0.1',32499),H).serve_forever()
