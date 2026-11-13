# A tiny stand-in for a Plex server (7 movies, 10 episodes in 2 shows) for headless tests. Token: tok. Port 32499.
# Environment switches (all optional; with none set it behaves exactly as the small server the older tests expect):
#   PLEX_MOCK_PORT=<n>          listen on another port
#   PLEX_MOCK_SCALE=<n>         a generated library instead: n episodes in n//120+1 shows, n//10 movies, with varied files
#   PLEX_MOCK_DELAY_MS=<n>      wait this long before each reply (imitates a real server)
#   PLEX_MOCK_FAIL_ONCE=<text>  the first request whose address contains <text> gets a 500
# GET /__stats -> {"requests": n, "maxConcurrent": m, "paths": {...}}; GET /__reset zeroes them.
import http.server, urllib.parse, re, os, gzip, json, threading, time

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

PORT=int(os.environ.get('PLEX_MOCK_PORT','32499')); SCALE=int(os.environ.get('PLEX_MOCK_SCALE','0')); DELAY=int(os.environ.get('PLEX_MOCK_DELAY_MS','0'))/1000.0
FAIL_ONCE=[os.environ.get('PLEX_MOCK_FAIL_ONCE','')]
LOCK=threading.Lock(); STATS={'requests':0,'now':0,'maxConcurrent':0,'paths':{}}

# ---- the generated library (PLEX_MOCK_SCALE): every item differs by its index so the record builder is exercised ----
def pick(opts,i,salt=0): return opts[(i+salt)%len(opts)]
VCODEC=['hevc','h264','vc1','mpeg2video','mpeg4','av1','vp9','wmv3','']
HDR=['', 'colorTrc="smpte2084"', 'colorTrc="arib-std-b67"', 'DOVIPresent="1" DOVIProfile="5" DOVILevel="6" colorTrc="smpte2084"',
     'DOVIPresent="1" DOVIProfile="7" DOVIELPresent="1" DOVIBLCompatID="6" DOVILevel="6" colorTrc="smpte2084"',
     'DOVIPresent="1" DOVIProfile="8" DOVIBLCompatID="1" DOVILevel="5" colorTrc="smpte2084"', 'DOVIPresent="true" DOVIProfile="8" DOVIBLCompatID="2"',
     'DOVIPresent="1" DOVIProfile="8" DOVIBLCompatID="4" colorTrc="arib-std-b67"', 'DOVIPresent="1" DOVIProfile="10" DOVIBLCompatID="1"',
     'displayTitle="4K DoVi (HEVC Main 10)"', 'DOVIPresent="1" DOVIProfile="4" DOVIBLCompatID="2"', 'colorTrc="bt709"', 'DOVIPresent="1" DOVIProfile="8" DOVIELPresent="true" DOVIBLCompatID="9"']
ACODEC=[('truehd','','English (TrueHD 7.1 Atmos)'),('eac3','','English (EAC3 5.1) Dolby Atmos'),('ac3','',''),('dca','ma',''),('dca','hra',''),('dca','es',''),('dts','',''),
        ('dca','dts-x','DTS:X 7.1'),('aac','lc',''),('flac','',''),('mp3','',''),('opus','',''),('vorbis','',''),('pcm_s16le','',''),('wmav2','',''),('','',''),('dca','ma','English (DTS-X 7.1)')]
CHANS=[6,2,8,1,7,3,0]; LANGS=['English','French','Japanese','','Spanish']; SUBC=['srt','pgs','ass','']; CONT=['mkv','mp4','avi','mpegts','m2ts','wmv','','mov']
NAMES=['{t} (2019) Remux-2160p','{t}.BluRay.1080p','{t}.WEB-DL.AMZN','{t}.WEBRip','{t}.HDTV','{t}.DVDRip','{t}.Hybrid.2160p','{t}','{t} BD x264','{t}.WEB.h264','{t}.NF.1080p']
RES=[(3840,2160),(1920,1080),(1280,720),(720,480),(2560,1440),(0,0),(1920,800)]
def ratings(i):
    r=i%8
    if r==0: return ('rating="7.5"','')
    if r==1: return ('', '<Rating image="imdb://image.rating" value="8.1" type="audience"/><Rating image="rottentomatoes://image.rating.ripe" value="9.1" type="critic"/><Rating image="rottentomatoes://image.rating.upright" value="8.4" type="audience"/><Rating image="themoviedb://image.rating" value="7.7" type="audience"/>')
    if r==2: return ('rating="6.7" ratingImage="rottentomatoes://image.rating.rotten" audienceRating="5.5" audienceRatingImage="rottentomatoes://image.rating.spilled"','')
    if r==3: return ('', '<Rating image="themoviedb://image.rating" value="6.9" type="audience"/>')
    if r==4: return ('audienceRating="8.2" audienceRatingImage="imdb://image.rating"','')
    if r==5: return ('rating="12.5" ratingImage="rottentomatoes://image.rating.ripe"','')
    if r==6: return ('audienceRating="7.9"','')
    return ('','')
def guids(i):
    r=i%5
    if r==0: return ('', f'<Guid id="imdb://tt{1000000+i}"/><Guid id="tmdb://{5000+i}"/><Guid id="tvdb://{70+i}"/>')
    if r==1: return (f'guid="com.plexapp.agents.imdb://tt{2000000+i}?lang=en"','')
    if r==2: return (f'guid="com.plexapp.agents.themoviedb://{9000+i}?lang=en"','')
    if r==3: return ('', f'<Guid id="tmdb://{6000+i}"/>')
    return ('guid="plex://movie/abc"','')
def media_xml(i,title):
    if i%53==52: return ''
    w,h=pick(RES,i); vc=pick(VCODEC,i); ac,ap,adis=pick(ACODEC,i); ch=pick(CHANS,i); cont=pick(CONT,i)
    name=pick(NAMES,i).format(t=title.replace('&amp;','and')); ext=cont or 'mkv'
    path=(f'D:\\Media\\{title[:6]}\\{name}.{ext}' if i%4==1 else f'/data/media/{title[:6]}/{name}.{ext}') if i%17!=16 else ''
    part_attr=(f'file="{path}" ' if path else '')+f'size="{700000000+i*1234567}"'
    streams=''
    if i%11!=10:
        vattr=f'streamType="1"'+(f' codec="{vc}"' if vc else '')+(f' width="{w}" height="{h}"' if w and i%3 else '')
        vattr+=(' frameRate="23.976"' if i%5 else '')+f' bitDepth="{pick([8,10,12],i)}" profile="{pick(["main 10","high","main","",],i)}"'
        vattr+=(f' bitrate="{4000+i%9000}"' if i%4 else '')+f' scanType="{pick(["progressive","interlaced",""],i)}" chromaSubsampling="{pick(["4:2:0","4:2:2",""],i)}" colorRange="{pick(["tv","pc","","full"],i)}" colorPrimaries="{pick(["bt2020","bt709",""],i)}" colorSpace="{pick(["bt2020nc","bt709",""],i)}"'
        hd=pick(HDR,i)
        if 'displayTitle' not in hd: vattr+=' displayTitle="1080p (H.264)" extendedDisplayTitle="'+('Dolby Vision 4K' if i%29==28 else 'Main')+'"'
        streams+=f'<Stream {vattr} {hd}/>'
        na=pick([1,2,3,0,1],i)
        for a in range(na):
            c2,p2,d2=pick(ACODEC,i+a*3)
            sel=' selected="1"' if (na>1 and a==1 and i%2) else ''
            streams+=f'<Stream streamType="2" codec="{c2}" profile="{p2}" channels="{pick(CHANS,i+a)}" language="{pick(LANGS,i+a)}" displayTitle="{d2}" extendedDisplayTitle="" title="{("Commentary" if a==2 else "")}" bitrate="{640+a}" samplingRate="48000" bitDepth="{pick(["16","24",""],i)}"{sel}/>'
        for b in range(i%4):
            streams+=f'<Stream streamType="3" codec="{pick(SUBC,i+b)}" language="{pick(LANGS,i+b+1)}"/>'
    def one(w,h,br,extra=''):
        m=f'<Media videoResolution="{h}"'+(f' width="{w}" height="{h}"' if w else '')+f' bitrate="{br}" container="{cont}" videoCodec="{vc}" audioCodec="{ac}" audioProfile="{ap}" audioChannels="{ch}" aspectRatio="{pick(["1.78","2.35","",],i)}" videoFrameRate="{pick(["24p","60p","NTSC","PAL"],i)}"'+(f' duration="{5400000+i*1000}"' if i%6 else '')+f'{extra}>'
        return m+f'<Part {part_attr}>{streams}</Part>'+(f'<Part file="/data/extra/part2-{i}.mkv" size="1000"/>' if i%13==12 else '')+'</Media>'
    out=one(w,h,8000+(i%700)*10)
    if i%7==0: out='<Media videoResolution="480" width="720" height="480" bitrate="99999" container="avi" videoCodec="mpeg4" audioCodec="mp3" audioChannels="2"><Part file="/data/low/low.avi" size="5"/></Media>'+out
    return out
def tags(i,n_role=8):
    return ''.join(f'<Genre tag="{g}"/>' for g in pick([['Drama','Crime'],['Comedy'],[],['Sci-Fi','Action','Thriller']],i)) \
        + ''.join(f'<Role tag="Actor {i%50}-{r}" role="R{r}"/>' for r in range(n_role if i%9 else 0)) \
        + ''.join(f'<Country tag="{c}"/>' for c in pick([['United States of America'],['United Kingdom','France'],[]],i))
def rich_movie(i):
    k=str(2000000+i); t=f'Film {i} &amp; Co' if i%10==3 else f'Film {i}'
    ra,rc=ratings(i); ga,gc=guids(i)
    yr=f' year="{1960+i%65}"' if i%6 else ''; av=f' originallyAvailableAt="{1960+i%65}-0{1+i%9}-1{i%10}"' if i%7 else ''
    return (f'<Video ratingKey="{k}" key="/library/metadata/{k}" type="movie" title="{t}"{yr}{av} updatedAt="17{i%90+10:02d}0{i%10}4320" addedAt="16{i%90+10:02d}043200" duration="7200000" {ra} {ga}'
            f' contentRating="{pick(["PG-13","R","","TV-MA"],i)}" studio="{pick(["Studio A","","Studio B"],i)}" thumb="/library/metadata/{k}/thumb/1" tagline="{pick(["","A tagline."],i)}" summary="Plot of film {i}.&#10;  Second line.   Spaces."'
            +(f' viewCount="{i%4}" lastViewedAt="17{i%90+10:02d}043200"' if i%3==0 else '')+'>'
            + media_xml(i,t)+tags(i)+rc+gc+''.join(f'<Director tag="Dir {i%30}-{d}"/>' for d in range(i%5))+''.join(f'<Collection tag="Set {i%4}-{c}"/>' for c in range(i%3))+'</Video>')
def show_key(si): return str(900000+si)
def rich_show(si):
    k=show_key(si); ra,rc=ratings(si+3); ga,gc=guids(si)
    return (f'<Directory ratingKey="{k}" type="show" title="Series {si}"'+(f' year="{1990+si%35}"' if si%4 else '')+f' summary="About series {si}." studio="{pick(["Net A","","Net B"],si)}" contentRating="{pick(["TV-14","TV-MA",""],si)}" {ra} {ga} thumb="/library/metadata/{k}/thumb/2">'
            + tags(si+1)+rc+gc+'</Directory>')
def rich_ep(i):
    si=i//120; k=str(1000000+i); sk=show_key(si); s=1+(i%120)//12; e=1+(i%12)
    ra,rc=ratings(i+1) if i%3==0 else ('','')
    gt=f' grandparentThumb="/library/metadata/{sk}/thumb/2"' if si%6!=5 else ''
    yr=f' year="{1990+si%35}"' if i%5 else ''; av=f' originallyAvailableAt="{1990+si%35}-0{1+i%9}-1{i%10}"' if i%7 else ''
    return (f'<Video ratingKey="{k}" type="episode" title="Episode {e}" grandparentTitle="Series {si}" grandparentRatingKey="{sk}" parentIndex="{s}" index="{e}"{yr}{av} updatedAt="17{i%90+10:02d}0{i%10}4320" addedAt="16{i%90+10:02d}043200" duration="2700000"{gt}'
            f' thumb="/library/metadata/{k}/thumb/1" summary="Episode {e} of series {si}." {ra}'+(f' contentRating="TV-PG"' if i%8==0 else '')+(f' viewCount="1"' if i%2 else '')+'>'
            + media_xml(i+5,f'Series {si}')+rc+''.join(f'<Director tag="EpDir {d}"/>' for d in range(i%2))+'</Video>')
NMOV=SCALE//10; NSHOW=SCALE//120+1 if SCALE else 0
def scale_item(k):
    n=int(k)
    if 1000000<=n<1000000+SCALE: return rich_ep(n-1000000)
    if 2000000<=n<2000000+NMOV: return rich_movie(n-2000000)
    if 900000<=n<900000+NSHOW: return rich_show(n-900000)
    return ''
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def send(self,body,ct='text/xml'):
        b=body.encode() if isinstance(body,str) else body
        gz='gzip' in (self.headers.get('Accept-Encoding') or '') and ct.startswith('text/')
        if gz: b=gzip.compress(b,1)
        self.send_response(200); self.send_header('Content-Type',ct)
        if gz: self.send_header('Content-Encoding','gzip')
        self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        u=urllib.parse.urlparse(self.path); p=u.path
        if p=='/__stats':
            with LOCK: body=json.dumps({'requests':STATS['requests'],'maxConcurrent':STATS['maxConcurrent'],'paths':STATS['paths']})
            return self.send(body,'application/json')
        if p=='/__reset':
            with LOCK: STATS.update(requests=0,maxConcurrent=0,paths={}); FAIL_ONCE[0]=os.environ.get('PLEX_MOCK_FAIL_ONCE','')
            return self.send('{}','application/json')
        if p=='/__failonce':
            FAIL_ONCE[0]=urllib.parse.parse_qs(u.query).get('text',[''])[0]; return self.send('{}','application/json')
        with LOCK:
            STATS['requests']+=1; STATS['now']+=1; STATS['maxConcurrent']=max(STATS['maxConcurrent'],STATS['now'])
            kind=re.sub(r'[\d,]+','N',p); STATS['paths'][kind]=STATS['paths'].get(kind,0)+1
            fail=bool(FAIL_ONCE[0]) and FAIL_ONCE[0] in self.path
            if fail: FAIL_ONCE[0]=''
        try:
            if DELAY: time.sleep(DELAY)
            if fail: self.send_response(500); self.send_header('Content-Length','0'); self.end_headers(); return
            self.handle_get(u)
        finally:
            with LOCK: STATS['now']-=1
    def handle_get(self,u):
        q=urllib.parse.parse_qs(u.query); p=u.path
        if self.headers.get('X-Plex-Token')!='tok' and q.get('X-Plex-Token',[''])[0]!='tok':
            self.send_response(401); self.end_headers(); return
        if p=='/library/sections':
            return self.send('<MediaContainer><Directory key="1" title="Movies" type="movie"/><Directory key="2" title="TV" type="show"/></MediaContainer>')
        m=re.match(r'/library/sections/(\d)/all',p)
        if m:
            st=int(q.get('X-Plex-Container-Start',['0'])[0]); sz=int(q.get('X-Plex-Container-Size',['200'])[0])
            if SCALE:
                total=NMOV if m.group(1)=='1' else SCALE
                gen=rich_movie if m.group(1)=='1' else rich_ep
                page=[gen(i) for i in range(st,min(total,st+sz))]
                return self.send(f'<MediaContainer totalSize="{total}" size="{len(page)}">'+''.join(page)+'</MediaContainer>')
            items=[video_movie(*x) for x in MOV] if m.group(1)=='1' else [video_ep(*x) for x in EPS]
            page=items[st:st+3]
            return self.send(f'<MediaContainer totalSize="{len(items)}" size="{len(page)}">'+''.join(page)+'</MediaContainer>')
        m=re.match(r'/library/metadata/([\d,]+)$',p)
        if m:
            out=[]
            if SCALE: return self.send('<MediaContainer>'+''.join(scale_item(k) for k in m.group(1).split(','))+'</MediaContainer>')
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
class S(http.server.ThreadingHTTPServer):
    daemon_threads=True; request_queue_size=64
S(('127.0.0.1',PORT),H).serve_forever()
