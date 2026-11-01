import http.server
import json
import pathlib
import sys
import threading
import time

requests = []
lock = threading.Lock()


class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/requests":
            with lock:
                body = json.dumps(requests).encode()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(body)
            return
        with lock:
            requests.append(path)
        if path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/token/consume")
            self.end_headers()
            return
        if path in ("/hang", "/slow-image"):
            time.sleep(25)
        status = 403 if path == "/isolated-denied" else 401 if path == "/restricted" else 200
        self.send_response(status)
        if path == "/isolated-denied":
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        if path == "/download":
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="must-not-download.bin"')
            self.end_headers()
            self.wfile.write(b"synthetic download")
            return
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Set-Cookie", "snapshot_fixture=only_this_session; Path=/")
        self.end_headers()
        previous_cookie = bool(self.headers.get("Cookie"))
        body = f'''<!doctype html><meta property="og:site_name" content="合成站点">
        <style>body{{margin:0}}.top{{height:400px;background:rgb(255,0,0)}}.bottom{{height:400px;background:rgb(0,0,255)}}</style>
        <div class="top"></div><div class="bottom"></div>
        <script>setTimeout(() => document.title = innerWidth+'x'+innerHeight+':'+{json.dumps("reused" if previous_cookie else "fresh")}, 500);</script>'''
        if path == "/gate":
            body = '<input type="password" style="display:block;width:100px;height:30px">'
        if path == "/popup":
            body += "<script>window.open('/popup-target');alert('synthetic');confirm('synthetic');prompt('synthetic');</script>"
        if path == "/cancel":
            body += '<img src="/slow-image">'
        try:
            self.wfile.write(body.encode())
        except (BrokenPipeError, ConnectionResetError):
            pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2]) if len(sys.argv) > 2 else 0), Fixture)
server.daemon_threads = True
pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
