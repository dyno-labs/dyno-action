"""A fake dynoapp.io and a fake GitHub OIDC token service, for test.sh.

GitHub's side gives a new token for each request. The site's side takes each token once, as a
check that dyno.sh asks for a fresh one before every call. Every request is logged as one line of
JSON. Usage: fake_site.py <state folder> <archive> [bad-sha] [refuse <game id>]
"""

import hashlib
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

state, archive_path, *mode = sys.argv[1:]
archive = open(archive_path, "rb").read()
sha256 = "0" * 64 if "bad-sha" in mode else hashlib.sha256(archive).hexdigest()
refused = mode[mode.index("refuse") + 1] if "refuse" in mode else None
issued = []
used = set()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, status, body, kind="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def note(self, **fields):
        with open(f"{state}/requests.log", "a") as log:
            log.write(json.dumps({"method": self.command, "path": self.path, **fields}) + "\n")

    def fresh_token(self):
        """The bearer, when it is a token GitHub gave and the site has not seen yet."""
        token = self.headers.get("Authorization", "").removeprefix("Bearer ")
        if token not in issued or token in used:
            return None
        used.add(token)
        return token

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/token":
            audience = parse_qs(url.query).get("audience")
            ok = self.headers.get("Authorization") == "Bearer request-token"
            self.note(audience=audience, ok=ok)
            if not ok:
                return self.answer(401, {"message": "bad request token"})
            issued.append(f"oidc-{len(issued) + 1}")
            return self.answer(200, {"value": issued[-1]})
        if url.path.startswith("/api/dist/"):
            token = self.fresh_token()
            self.note(token=token)
            if token is None:
                return self.answer(401, {"error": "the GitHub Actions token is not valid"})
            port = self.server.server_address[1]
            return self.answer(
                200,
                {
                    "version": "a" * 40,
                    "target": url.path.rsplit("/", 1)[-1],
                    "url": f"http://127.0.0.1:{port}/archive.tar.gz",
                    "sha256": sha256,
                    "expires_at": "2026-11-10T00:05:00Z",
                },
            )
        if url.path == "/archive.tar.gz":
            self.note()
            return self.answer(200, archive, "application/gzip")
        self.note()
        self.answer(404, {"error": "not found"})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        token = self.fresh_token()
        game = body["run"]["release"]["game_id"]
        self.note(token=token, game=game)
        if token is None:
            return self.answer(401, {"error": "the GitHub Actions token is not valid"})
        if game == refused:
            return self.answer(403, {"error": "the repo is not connected to dyno"})
        port = self.server.server_address[1]
        self.answer(201, {"id": game, "url": f"http://127.0.0.1:{port}/#/runs/{game}"})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(f"{state}/port", "w") as file:
    file.write(str(server.server_address[1]))
server.serve_forever()
