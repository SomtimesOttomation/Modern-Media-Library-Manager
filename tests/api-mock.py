# A stand-in for TMDB and OMDb error replies, for tests\Test-MmlmFetchErrors.ps1. Port 8098.
# The path says which service it plays (/omdbapi.com/..., /themoviedb.org/...); the query says how to answer.
import http.server, json, urllib.parse
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query); how = q.get('how', [''])[0]
        if how == 'limit': return self.reply(401, {'Response': 'False', 'Error': 'Request limit reached!'})
        if how == 'badkey': return self.reply(401, {'Response': 'False', 'Error': 'Invalid API key!'})
        if how == 'tmdbkey': return self.reply(401, {'success': False, 'status_code': 7, 'status_message': 'Invalid API key: You must be granted a valid key.'})
        if how == 'limit200': return self.reply(200, {'Response': 'False', 'Error': 'Request limit reached!'})
        if how == 'notfound': return self.reply(200, {'Response': 'False', 'Error': 'Movie not found!'})
        if how == 'gone': return self.reply(404, {'status_message': 'The resource you requested could not be found.'})
        if how == 'down': return self.reply(503, {'Error': 'Service Unavailable'})
        return self.reply(200, {'Response': 'True', 'Title': 'Fine'})
http.server.ThreadingHTTPServer(('127.0.0.1', 8098), H).serve_forever()
