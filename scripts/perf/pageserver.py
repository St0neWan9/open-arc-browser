#!/usr/bin/env python3
# Local page server for the B107 first-select self-test. Serves a realistic page per path
# (title, favicon, stylesheet, script, images, ~60 KB of text) on 127.0.0.1:<port>; the fixture
# points tabs at http://site<N>.localhost:<port>/page/<N> (Chromium resolves *.localhost to
# loopback itself, so every tab is its own site and gets its own renderer, like real sites).
# Logs one line per page request to stdout.
import http.server, socketserver, sys, random, hashlib

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765

WORDS = ("lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut "
         "labore et dolore magna aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris").split()

CSS = b"""
body{font:15px/1.5 -apple-system,Helvetica,sans-serif;margin:0;color:#222;background:#fafafa}
header{position:sticky;top:0;background:#335;color:#fff;padding:12px 24px;display:flex;gap:16px}
nav a{color:#cde;margin-right:12px}main{max-width:820px;margin:24px auto;padding:0 16px}
article{background:#fff;border-radius:8px;box-shadow:0 1px 3px rgba(0,0,0,.1);padding:16px 24px;margin:16px 0}
.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}.card{border:1px solid #ddd;border-radius:6px;padding:8px}
img{max-width:100%;border-radius:4px}footer{padding:24px;text-align:center;color:#888}
"""

JS = b"""
document.addEventListener('DOMContentLoaded',function(){
  var n=0;document.querySelectorAll('article').forEach(function(a){n+=a.textContent.length});
  var s=document.createElement('div');s.textContent='chars: '+n;document.querySelector('footer').appendChild(s);
});
"""

def svg(seed):
    h = hashlib.md5(seed.encode()).hexdigest()
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="320" height="180"><rect width="320" height="180" fill="#%s"/>'
            '<circle cx="160" cy="90" r="60" fill="#%s"/></svg>' % (h[:6], h[6:12])).encode()

FAVICON = ('<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="32" height="32" rx="6" fill="#36c"/>'
           '<text x="16" y="23" font-size="18" text-anchor="middle" fill="#fff">P</text></svg>').encode()

def page(path):
    rnd = random.Random(path)
    title = "Page %s - %s" % (path.rsplit('/', 1)[-1], " ".join(rnd.choice(WORDS) for _ in range(4)).title())
    parts = ['<!doctype html><html lang="en"><head><meta charset="utf-8"><title>%s</title>' % title,
             '<meta name="viewport" content="width=device-width"><link rel="icon" href="/favicon.svg" type="image/svg+xml">',
             '<link rel="stylesheet" href="/style.css"><script src="/app.js" defer></script></head><body>',
             '<header><strong>Site</strong><nav>' + "".join('<a href="/page/%d">Link %d</a>' % (i, i) for i in range(8)) + '</nav></header><main>']
    for a in range(12):
        parts.append('<article><h2>%s</h2>' % " ".join(rnd.choice(WORDS) for _ in range(6)).capitalize())
        for p in range(4):
            parts.append('<p>%s.</p>' % " ".join(rnd.choice(WORDS) for _ in range(60)).capitalize())
        if a % 3 == 0:
            parts.append('<div class="grid">' + "".join('<div class="card"><img src="/img/%d-%d.svg" alt=""></div>' % (a, i) for i in range(3)) + '</div>')
        parts.append('</article>')
    parts.append('</main><footer>Footer</footer></body></html>')
    return "".join(parts).encode()

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def send(self, body, ctype, cache=True):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if cache:
            self.send_header("Cache-Control", "max-age=3600")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        p = self.path.split('?')[0]
        if p == "/style.css": return self.send(CSS, "text/css")
        if p == "/app.js": return self.send(JS, "text/javascript")
        if p == "/favicon.svg" or p == "/favicon.ico": return self.send(FAVICON, "image/svg+xml")
        if p.startswith("/img/"): return self.send(svg(self.headers.get("Host", "") + p), "image/svg+xml")
        sys.stdout.write("PAGE %s%s\n" % (self.headers.get("Host", ""), p)); sys.stdout.flush()
        self.send(page(self.headers.get("Host", "") + p), "text/html; charset=utf-8", cache=False)

    def log_message(self, *args):
        pass

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

Server(("127.0.0.1", PORT), Handler).serve_forever()
