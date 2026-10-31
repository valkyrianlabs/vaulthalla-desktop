#!/usr/bin/env python3
"""The browser's resumable-upload contract (the server's web/src/features/files/upload/engine.ts) against a private
test instance's web listener (docs/interop-testing.md): a human session's `refresh` cookie, then a file larger than
Cloudflare's 100 MB body limit in parts no larger than the web listener's cap (64 MiB), up to three at a time, each with
an RFC 9530 Content-Digest, the session's status, finish, and the bytes as `vh fs get` reads them.

Runs on the instance's box as the account that started it (stdlib only):

    python3 web-resumable.py [--run /tmp/vhi_interop] [--mb 150]

It creates a throwaway user (`interop-web-<random>`, role unprivileged, the vault role manager on the seeded vault)
whose generated password stays in this process (never printed), logs in over /ws to get the cookie, and deletes the
user at the end. Exit status 0 when every check passed.
"""
import argparse
import base64
import concurrent.futures
import hashlib
import http.client
import json
import os
import re
import secrets
import socket
import struct
import subprocess
import sys
import time
import uuid

MIB = 1 << 20


def vh(run, *args, admin=True):
    wrapper = f"{run}/vh-admin" if admin else f"{run}/vh"
    return subprocess.run([wrapper, *args], capture_output=True, text=True, check=False)


def ports(run):
    text = open(f"{run}/config.yaml").read()
    found = {}
    for section in ("websocket_server", "http_preview_server"):
        match = re.search(rf"^{section}:\s*(?:\{{[^}}]*port:\s*(\d+)|\n(?:[ \t]+.*\n)*?[ \t]+port:\s*(\d+))", text, re.M)
        if not match:
            sys.exit(f"no {section} port in {run}/config.yaml")
        found[section] = int(match.group(1) or match.group(2))
    return found["websocket_server"], found["http_preview_server"]


class MiniWs:
    """Just enough RFC 6455 for one login: handshake (keeping Set-Cookie), masked text frames out, frames in."""

    def __init__(self, port, path="/ws"):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=20)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
                           f"User-Agent: vh-interop-web/1\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("ws handshake: connection closed")
            head += chunk
        head, self.buffer = head.split(b"\r\n\r\n", 1)
        lines = head.decode("latin-1").split("\r\n")
        if " 101 " not in lines[0] + " ":
            raise RuntimeError(f"ws handshake: {lines[0]}")
        self.cookies = {}
        for line in lines[1:]:
            name, _, value = line.partition(":")
            if name.strip().lower() == "set-cookie":
                cookie_name, _, rest = value.strip().partition("=")
                self.cookies[cookie_name] = rest.split(";", 1)[0]

    def cookie_header(self):
        return "; ".join(f"{k}={v}" for k, v in self.cookies.items())

    def send(self, obj):
        payload = json.dumps(obj).encode()
        mask = os.urandom(4)
        header = bytes([0x81])
        n = len(payload)
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 1 << 16:
            header += bytes([0x80 | 126]) + struct.pack("!H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack("!Q", n)
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def _read(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("ws: connection closed")
            self.buffer += chunk
        data, self.buffer = self.buffer[:n], self.buffer[n:]
        return data

    def receive(self):
        message = b""
        while True:
            b0, b1 = self._read(2)
            opcode, length = b0 & 0x0F, b1 & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._read(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._read(8))[0]
            mask = self._read(4) if b1 & 0x80 else None
            data = self._read(length)
            if mask:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            if opcode == 0x8:
                raise RuntimeError("ws: closed by the server")
            if opcode in (0x9, 0xA):
                continue
            message += data
            if b0 & 0x80:
                return json.loads(message)

    def call(self, command, payload):
        rid = str(uuid.uuid4())
        self.send({"command": command, "payload": payload, "requestId": rid})
        while True:
            msg = self.receive()
            if msg.get("requestId") == rid:
                return msg

    def close(self):
        self.sock.close()


class Web:
    def __init__(self, port, cookie):
        self.port, self.cookie = port, cookie

    def headers_only(self, method, path, length):
        """Sends a request's headers (Content-Length `length`) and no body; returns the status and the answer."""
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=20)
        try:
            sock.sendall((f"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nCookie: {self.cookie}\r\n"
                          f"Content-Type: application/octet-stream\r\nContent-Length: {length}\r\n\r\n").encode())
            answer = b""
            while True:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                answer += chunk
                head, _, rest = answer.partition(b"\r\n\r\n")
                match = re.search(rb"content-length:\s*(\d+)", head, re.I)
                if match and len(rest) >= int(match.group(1)):
                    break
        except (ConnectionError, socket.timeout):
            pass
        finally:
            sock.close()
        text = answer.decode("latin-1")
        status = re.match(r"HTTP/1\.[01] (\d+)", text)
        return (int(status.group(1)) if status else 0), text

    def request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=300)
        h = {"Cookie": self.cookie, "User-Agent": "vh-interop-web/1"}
        h.update(headers or {})
        try:
            conn.request(method, path, body=body, headers=h)
            resp = conn.getresponse()
            data = resp.read()
            try:
                parsed = json.loads(data) if data else None
            except ValueError:
                parsed = None
            return resp.status, parsed, dict(resp.getheaders())
        except (ConnectionError, http.client.HTTPException) as exc:
            return 0, {"error": {"code": "connection", "message": str(exc)}}, {}
        finally:
            conn.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--run", default="/tmp/vhi_interop")
    parser.add_argument("--mb", type=int, default=150, help="file size in MB (10^6 bytes)")
    args = parser.parse_args()
    status = json.load(open(f"{args.run}/status.json"))
    vault = status["vault_id"]
    ws_port, http_port = ports(args.run)
    failures = []

    def check(condition, what):
        print(("ok    " if condition else "FAIL  ") + what)
        if not condition:
            failures.append(what)

    user = f"interop-web-{secrets.token_hex(3)}"
    created = vh(args.run, "user", "create", user, "--role", "unprivileged")
    match = re.search(r"^Password:\s*(\S+)\s*$", created.stdout, re.M)
    if created.returncode != 0 or not match:
        sys.exit(f"user create failed (rc={created.returncode}; output withheld: it may hold the password)")
    password = match.group(1)
    try:
        assign = vh(args.run, "vault", "role", "assign", str(vault), "manager", "-u", user)
        check(assign.returncode == 0, f"vault role manager on vault {vault} for {user}")

        ws = MiniWs(ws_port)
        login = ws.call("auth.login", {"name": user, "password": password})
        ws_ok = str(login.get("status", "")).upper() in ("OK", "SUCCESS")
        check(ws_ok and "refresh" in ws.cookies, "auth.login over /ws; the handshake set the refresh cookie")
        web = Web(http_port, ws.cookie_header())

        size = args.mb * 1_000_000
        data = os.urandom(size)
        digest = hashlib.sha256(data).hexdigest()
        path = f"/web/{user}-{uuid.uuid4().hex[:8]}.bin"

        code, body, _ = web.request("POST", "/upload/sessions",
                                    json.dumps({"vault_id": vault, "files": [{"file_id": "f0", "path": path, "size": size,
                                                "mime_type": "application/octet-stream",
                                                "duplicate_policy": "reject"}]}),
                                    {"Content-Type": "application/json"})
        check(code == 201, f"POST /upload/sessions -> {code}")
        if code != 201:
            raise SystemExit(f"create: {body}")
        upload, part = body["upload_id"], body["part"]
        print(f"      part limits on the web listener: {part}")
        check(part["max_bytes"] == 64 * MIB, "part.max_bytes is the web cap (64 MiB, under Cloudflare's 100 MB)")
        part_bytes = min(part["default_bytes"], part["max_bytes"])

        # A part over the cap is refused from its headers, before a body byte is read (and the connection closes).
        over = part["max_bytes"] + MIB
        code, answer = web.headers_only("PUT", f"/upload/sessions/{upload}/files/f0?offset=0", over)
        check(code == 413 and '"part_too_large"' in answer, f"a {over // MIB} MiB part's headers -> {code}")
        # A client that writes the whole body anyway (fetch/XHR) may lose that answer to the reset.
        code, body, _ = web.request("PUT", f"/upload/sessions/{upload}/files/f0?offset=0", data[:over],
                                    {"Content-Type": "application/octet-stream"})
        print(f"      the same part with its body sent: {code} {body and body.get('error', {}).get('code')}")

        def put(offset):
            chunk = data[offset:offset + part_bytes]
            header = "sha-256=:" + base64.b64encode(hashlib.sha256(chunk).digest()).decode() + ":"
            started = time.monotonic()
            code, body, headers = web.request("PUT", f"/upload/sessions/{upload}/files/f0?offset={offset}", chunk,
                                              {"Content-Type": "application/octet-stream", "Content-Digest": header})
            return offset, len(chunk), code, body, headers.get("Server-Timing"), time.monotonic() - started

        offsets = list(range(0, size, part_bytes))
        started = time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(3, part["max_in_flight"])) as pool:
            results = list(pool.map(put, offsets))
        elapsed = time.monotonic() - started
        for offset, length, code, body, timing, seconds in results:
            ok = code == 200 and body["offset"] == offset and body["length"] == length
            ok = ok and body["sha256"] == hashlib.sha256(data[offset:offset + length]).hexdigest()
            check(ok, f"part {offset // part_bytes} ({length} bytes) -> {code} in {seconds:.2f}s [{timing}]")
        print(f"      {len(offsets)} parts in {elapsed:.2f}s ({size / elapsed / 1e6:.0f} MB/s over loopback)")

        code, body, _ = web.request("GET", f"/upload/sessions/{upload}")
        file = (body or {}).get("files", [{}])[0]
        check(code == 200 and file.get("received_bytes") == size and file.get("ranges") == [[0, size]],
              f"status: {file.get('state')} {file.get('received_bytes')} bytes {file.get('ranges')}")

        deadline = time.monotonic() + 120
        while True:
            code, body, headers = web.request("POST", f"/upload/sessions/{upload}/finish")
            if code != 202 or time.monotonic() > deadline:
                break
            time.sleep(float(headers.get("Retry-After", "1")))
        check(code == 200 and body.get("state") == "complete", f"finish -> {code} {body and body.get('state')}")

        got = subprocess.run(f"{args.run}/vh fs get {vault} '{path}' | sha256sum", shell=True, capture_output=True,
                             text=True)
        check(got.stdout[:64] == digest, f"vh fs get {path}: sha256 matches ({size} bytes)")
        ws.close()
    finally:
        removed = vh(args.run, "user", "delete", user, "--yes")
        if removed.returncode != 0:
            removed = vh(args.run, "user", "delete", user)
        print(f"      removed {user}: rc={removed.returncode}")
    print("PASS" if not failures else f"FAIL ({len(failures)})")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
