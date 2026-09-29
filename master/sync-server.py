#!/usr/bin/env python3
# sync-server.py: persistencia event/contest (hnetsync). Solo stdlib.
#
# PUT/GET /sync/<machine-id>/<disk>.tar.gz
#   - machine-id: MAC sin ":" en minuscula (ver hnetsync-push / livekitlib)
#   - disk: "event" o "contest"
#
# Escucha solo en 127.0.0.1:8081 -- nginx expone /sync/ en el puerto 80
# (proxy_pass) para quedar dentro del allowlist de firewall de las
# directivas (libhfirewall.so solo permite INPUT de vuelta en 80/443/8080).
#
# No hay historial: cada PUT sobrescribe el respaldo anterior de esa
# maquina/disco en sync-data/<machine-id>/<disk>.tar.gz (volumen Docker).
import os
import re
import http.server
import socketserver

HOST = "127.0.0.1"
PORT = 8081
BASE_DIR = "/var/sync-data"

PATH_RE = re.compile(r"^/sync/([0-9a-f]{12})/(event|contest)\.tar\.gz$")


class SyncHandler(http.server.BaseHTTPRequestHandler):
    server_version = "hnetsync-server/1.0"

    def _target_path(self):
        match = PATH_RE.match(self.path)
        if not match:
            self.send_error(404, "Not Found")
            return None
        machine_id, disk = match.groups()
        machine_dir = os.path.join(BASE_DIR, machine_id)
        return os.path.join(machine_dir, f"{disk}.tar.gz")

    def do_PUT(self):
        target = self._target_path()
        if target is None:
            return

        length = self.headers.get("Content-Length")
        if length is None:
            self.send_error(411, "Content-Length required")
            return
        try:
            length = int(length)
        except ValueError:
            self.send_error(400, "Invalid Content-Length")
            return

        os.makedirs(os.path.dirname(target), exist_ok=True)
        tmp_path = f"{target}.tmp-{os.getpid()}"
        remaining = length
        try:
            with open(tmp_path, "wb") as f:
                while remaining > 0:
                    chunk = self.rfile.read(min(65536, remaining))
                    if not chunk:
                        break
                    f.write(chunk)
                    remaining -= len(chunk)
            if remaining > 0:
                os.remove(tmp_path)
                self.send_error(400, "Truncated upload")
                return
            os.replace(tmp_path, target)
        except OSError as e:
            try:
                os.remove(tmp_path)
            except OSError:
                pass
            self.send_error(500, f"Storage error: {e}")
            return

        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        target = self._target_path()
        if target is None:
            return

        if not os.path.isfile(target):
            self.send_error(404, "No backup for this machine/disk")
            return

        size = os.path.getsize(target)
        self.send_response(200)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Length", str(size))
        self.end_headers()
        with open(target, "rb") as f:
            while True:
                chunk = f.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)

    def log_message(self, fmt, *args):
        print(f"[sync-server] {self.address_string()} {fmt % args}", flush=True)


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    os.makedirs(BASE_DIR, exist_ok=True)
    server = ThreadingHTTPServer((HOST, PORT), SyncHandler)
    print(f"[sync-server] Escuchando en {HOST}:{PORT}, datos en {BASE_DIR}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
