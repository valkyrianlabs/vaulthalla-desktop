#!/usr/bin/env python3
"""File Provider end to end for one domain (desktop#4), through POSIX access only, with the Desktop app quit.

  finder-e2e.py --root <~/Library/CloudStorage/Vaulthalla-…> --domain <node id>.<vault id> --vault <vault id> \
                --vh "<command prefix that runs vh as the account the device acts for>" [--app <Vaulthalla.app>]

The vault holds what tools/interop/vh-instance.sh seeds (/hello.txt, /docs/blob.bin, byte i = (7i + 3) mod 256) plus
/big.bin, 48 MiB with byte i = (13i + 5) mod 251. The oracle is `vh` on the node. Steps: listings equal `vh fs ls`;
whole reads and a `dd` partial read (only the range lands on disk); an edit reaches the server; a concurrent server
edit makes the Mac's edit a conflict copy and loses neither; create, mkdir, rename, move and delete reach the server;
the deleted file comes back through `vh recovery list`/`restore` (the vault needs local versioning on). Signals the
working set with `Vaulthalla --developer signal` (a Debug build), or with `--agent` leaves that to the background agent
of a Release build (desktop#5). Prints PASS/FAIL per step; exits 0 only if every step passed. See
docs/interop-testing.md, "Finder (File Provider)" and "Finder E2E matrix" (desktop#9).

Matrix groups (desktop#9), each opt-in:
  --agent                 Release build: no developer signal; the agent must run, and a server change must reach Finder
                          with the app quit.
  --large GIB             a GIB GiB file written through Finder reaches the server intact, and reads back intact after
                          eviction, with a partial read near its end.
  --restart-cmd CMD       restarts the node during that read-back (needs --large); the read still completes intact.
  --stop-cmd/--start-cmd  an edit made while the node is down reconciles on reconnect: the server's own edit from before
                          stays, the Mac's edit becomes a conflict copy.
  --revoke-cmd CMD        last and destructive: revokes this Mac; the agent must remove the domain (needs --agent).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

APP = Path.home() / "Applications/Vaulthalla.app/Contents/MacOS/Vaulthalla"  # --app overrides
results: list[bool] = []


def step(name: str, ok: bool, detail: str = "") -> bool:
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} {name}{': ' + detail if detail else ''}", flush=True)
    return ok


class Node:
    def __init__(self, prefix: str, vault: int):
        self.prefix, self.vault = shlex.split(prefix), vault

    def run(self, *args: str, stdin: bytes | None = None) -> subprocess.CompletedProcess:
        # Through ssh the arguments become one remote shell line: quote them (names have spaces and parentheses).
        remote = self.prefix and self.prefix[0] == "ssh"
        argv = [shlex.quote(a) for a in args] if remote else list(args)
        return subprocess.run(self.prefix + argv, input=stdin, capture_output=True, timeout=120)

    def exists(self, path: str) -> bool:
        """A folder lists (exit 0), or a file downloads."""
        return self.run("fs", "ls", str(self.vault), path).returncode == 0

    def ls(self, path: str) -> list[str] | None:
        r = self.run("fs", "ls", str(self.vault), path)
        if r.returncode != 0:
            return None
        out = r.stdout.decode()
        names = []
        for line in out.splitlines()[2:]:
            parts = re.split(r"\s{2,}", line.strip())
            if len(parts) >= 4:
                names.append(parts[-1].rstrip("/"))
        return sorted(names)

    def get(self, path: str) -> bytes | None:
        r = self.run("fs", "get", str(self.vault), path)
        return r.stdout if r.returncode == 0 else None

    def put(self, path: str, data: bytes) -> bool:
        return self.run("fs", "put", str(self.vault), "-", path, "--overwrite", stdin=data).returncode == 0


    def sha256(self, path: str) -> str | None:
        """`vh fs get` streamed into a hash: multi-GiB files never sit in memory."""
        argv = self.prefix + ([shlex.quote(a) for a in ("fs", "get", str(self.vault), path)]
                              if self.prefix and self.prefix[0] == "ssh" else ["fs", "get", str(self.vault), path])
        digest = hashlib.sha256()
        with subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as proc:
            assert proc.stdout
            while chunk := proc.stdout.read(8 << 20):
                digest.update(chunk)
        return digest.hexdigest() if proc.returncode == 0 else None


AGENT = False  # --agent: the background agent signals, not this script


def signal(domain: str) -> None:
    if AGENT:
        return
    subprocess.run([str(APP), "--developer", "signal", domain], capture_output=True, timeout=60)


def shell(command: str) -> bool:
    return subprocess.run(command, shell=True, capture_output=True, timeout=300).returncode == 0


def file_sha256(path: Path, limit: int | None = None, offset: int = 0) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        f.seek(offset)
        left = limit
        while left is None or left > 0:
            chunk = f.read(8 << 20 if left is None else min(8 << 20, left))
            if not chunk:
                break
            digest.update(chunk)
            if left is not None:
                left -= len(chunk)
    return digest.hexdigest()


def wait(what, timeout: float = 90, every: float = 1.5, domain: str | None = None):
    deadline = time.monotonic() + timeout
    while True:
        value = what()
        if value or time.monotonic() > deadline:
            return value
        if domain:
            signal(domain)
        time.sleep(every)


def local_ls(path: Path) -> list[str]:
    return sorted(p.name for p in path.iterdir() if p.name != ".Trash")


def pattern(n: int, a: int, b: int, m: int) -> bytes:
    return bytes((i * a + b) % m for i in range(n))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--domain", required=True)
    ap.add_argument("--vault", type=int, required=True)
    ap.add_argument("--vh", required=True)
    ap.add_argument("--app", help="the Vaulthalla.app whose extension serves the domain")
    ap.add_argument("--agent", action="store_true", help="Release build: the background agent signals")
    ap.add_argument("--large", type=float, metavar="GIB", help="round-trip a file this many GiB through Finder")
    ap.add_argument("--restart-cmd", help="restarts the node, during the large read-back")
    ap.add_argument("--stop-cmd", help="stops the node (with --start-cmd: an offline edit)")
    ap.add_argument("--start-cmd", help="starts the node again")
    ap.add_argument("--revoke-cmd", help="revokes this Mac on the node; destructive, runs last (needs --agent)")
    args = ap.parse_args()
    global APP, AGENT
    if args.app:
        APP = Path(args.app) / "Contents/MacOS/Vaulthalla"
    AGENT = args.agent
    if args.revoke_cmd and not args.agent:
        ap.error("--revoke-cmd needs --agent: the agent is what removes the domain")
    if args.restart_cmd and not args.large:
        ap.error("--restart-cmd needs --large: the restart lands during the large read-back")
    if bool(args.stop_cmd) != bool(args.start_cmd):
        ap.error("--stop-cmd and --start-cmd go together")
    root, node, domain = Path(args.root), Node(args.vh, args.vault), args.domain
    tag = str(int(time.time()))

    # The app's executable also runs as the agent (`Vaulthalla --agent`): only an instance without it is the app.
    procs = subprocess.run(["pgrep", "-fl", "Contents/MacOS/Vaulthalla"], capture_output=True).stdout.decode()
    app = [line for line in procs.splitlines() if "--agent" not in line and "--developer" not in line]
    step("Desktop app not running", not app, "; ".join(app) or "only the extension and the agent")
    if AGENT:
        agent = [line for line in procs.splitlines() if "--agent" in line]
        step("background agent running (desktop#5)", bool(agent), "; ".join(agent) or
             "not running: show a vault in Finder from Desktop once, and check Login Items")

    # 1. Listings equal `vh fs ls` as the same account (Lookup-filtered by the server).
    signal(domain)
    server_root = node.ls("/")
    step("ls / equals vh fs ls /", wait(lambda: local_ls(root) == server_root, 60) is True,
         f"local {local_ls(root)} server {server_root}")
    step("ls /docs equals vh fs ls /docs", local_ls(root / "docs") == node.ls("/docs"),
         f"local {local_ls(root / 'docs')} server {node.ls('/docs')}")

    # 2. Bytes: whole files and a partial read.
    hello = (root / "hello.txt").read_bytes()
    step("cat hello.txt equals vh fs get", hello == node.get("/hello.txt"), f"{len(hello)} bytes")
    blob = (root / "docs/blob.bin").read_bytes()
    step("docs/blob.bin equals the seeded pattern", blob == pattern(65536, 7, 3, 256), f"{len(blob)} bytes")
    dd = subprocess.run(["dd", f"if={root / 'big.bin'}", "bs=1m", "skip=20", "count=1"], capture_output=True)
    expected = pattern(48 * 1024 * 1024, 13, 5, 251)[20 * 1024 * 1024:21 * 1024 * 1024]
    step("dd 1 MiB at 20 MiB of big.bin equals the pattern", dd.stdout == expected,
         hashlib.sha256(dd.stdout).hexdigest()[:16])
    du = int(subprocess.run(["du", "-k", str(root / "big.bin")], capture_output=True).stdout.split()[0])
    step("only the range is on disk", du < 8 * 1024, f"{du} KiB of 49152")

    # 3. An edit reaches the server.
    edited = f"Edited in Finder {tag}.\n".encode()
    (root / "hello.txt").write_bytes(edited)
    step("edit hello.txt: vh fs get shows the new bytes", wait(lambda: node.get("/hello.txt") == edited) is True)

    # 4. A concurrent server edit: the local edit becomes a conflict copy; neither is lost.
    server_edit = f"Edited on the server {tag}.\n".encode()
    mac_edit = f"Edited on the Mac {tag}, after the server.\n".encode()
    step("server-side edit (vh fs put)", node.put("/hello.txt", server_edit))
    before = set(local_ls(root))
    (root / "hello.txt").write_bytes(mac_edit)

    # The copy is found by name in Finder (signalled), then read on the server: `vh fs ls` of a folder holding a long
    # name with a multi-byte character fails server-side (the CLI table cuts UTF-8 by bytes), so it isn't the oracle.
    def conflict_copies():
        names = [n for n in local_ls(root) if n.startswith("hello (conflict from ") and n not in before]
        return [n for n in names if node.get("/" + n) == mac_edit] or None
    copies = wait(conflict_copies, domain=domain)
    step("the Mac's edit is a conflict copy on the server, and it appears in Finder", bool(copies), f"{copies}")
    step("the server's edit stays hello.txt", node.get("/hello.txt") == server_edit)
    step("the local hello.txt comes back to the server's version",
         wait(lambda: (root / "hello.txt").read_bytes() == server_edit, 60, domain=domain) is True)

    # 5. create, mkdir, rename, move, delete; the deleted file is recoverable.
    created = f"created {tag}\n".encode()
    (root / f"new-{tag}.txt").write_bytes(created)
    step("create: the file is on the server", wait(lambda: node.get(f"/new-{tag}.txt") == created) is True)
    (root / f"dir-{tag}").mkdir()
    step("mkdir: the folder is on the server", wait(lambda: node.ls(f"/dir-{tag}") == []) is True)
    (root / f"new-{tag}.txt").rename(root / f"renamed-{tag}.txt")
    step("rename: the server has the new name",
         wait(lambda: node.get(f"/renamed-{tag}.txt") == created and node.get(f"/new-{tag}.txt") is None) is True)
    (root / f"renamed-{tag}.txt").rename(root / f"dir-{tag}" / f"renamed-{tag}.txt")
    step("move: the file is in the folder on the server",
         wait(lambda: node.ls(f"/dir-{tag}") == [f"renamed-{tag}.txt"] and node.get(f"/renamed-{tag}.txt") is None) is True)
    step("move kept the bytes", node.get(f"/dir-{tag}/renamed-{tag}.txt") == created)
    (root / f"dir-{tag}" / f"renamed-{tag}.txt").unlink()
    step("delete: the file is gone on the server", wait(lambda: node.ls(f"/dir-{tag}") == []) is True)
    rec = node.run("recovery", "list", str(node.vault), f"/dir-{tag}/renamed-{tag}.txt", "--json")
    points = json.loads(rec.stdout or b"[]") if rec.returncode == 0 else []
    deleted = [p for p in points if p.get("restorable")]
    step("the deleted file has a recovery point (recovery.list)", bool(deleted),
         ", ".join(f"{p['id']} ({p.get('reason')})" for p in points))
    if deleted:
        done = node.run("recovery", "restore", deleted[0]["id"], "--yes")
        step("recovery.restore brings it back with its bytes",
             done.returncode == 0 and node.get(f"/dir-{tag}/renamed-{tag}.txt") == created,
             done.stdout.decode().strip().splitlines()[-1] if done.stdout else done.stderr.decode()[:200])

    # Tidy: the conflict copies go through Finder too (a delete each), so the root lists with `vh fs ls` again.
    for name in copies or []:
        (root / name).unlink()
    if copies:
        step("conflict copies deleted through Finder", wait(lambda: all(node.get("/" + n) is None for n in copies)) is True)

    # 6. Freshness with the app quit: the agent signals, nothing here does (desktop#5).
    if AGENT:
        fresh = f"fresh-{tag}.txt"
        step("server-side create (vh fs put)", node.put("/" + fresh, b"from the server\n"))
        if step("it appears in Finder within the agent's interval", wait(lambda: fresh in local_ls(root), 180) is True):
            (root / fresh).unlink()  # `vh` has no delete: tidy through Finder

    # 7. A large file through Finder and back; a node restart during the read (desktop#9).
    if args.large:
        size = int(args.large * (1 << 30))
        large = root / f"large-{tag}.bin"
        block = os.urandom(8 << 20)
        with large.open("wb") as f:
            for i in range(0, size, len(block)):
                f.write(block[: min(len(block), size - i)])
        local = file_sha256(large)
        step(f"large write: {args.large:g} GiB reaches the server intact",
             wait(lambda: node.sha256(f"/{large.name}") == local, 1800, every=20) is True, local[:16])
        evicted = subprocess.run(["fileproviderctl", "evict", str(large)], capture_output=True)
        step("evict the local copy (fileproviderctl evict)", evicted.returncode == 0,
             evicted.stderr.decode().strip()[:200])
        restarted: list[bool] = []
        if args.restart_cmd:
            import threading
            threading.Timer(2.0, lambda: restarted.append(shell(args.restart_cmd))).start()
        step("large read-back is intact" + (" across a node restart" if args.restart_cmd else ""),
             file_sha256(large) == local)
        if args.restart_cmd:
            step("the restart command ran", restarted == [True])
        tail = max(0, size - (3 << 20))
        step("partial read near the end matches", file_sha256(large, 1 << 20, tail) ==
             hashlib.sha256((block * 2)[tail % len(block): tail % len(block) + (1 << 20)]).hexdigest())
        large.unlink()
        step("large file deleted through Finder", wait(lambda: node.get(f"/{large.name}") is None, 120) is True)

    # 8. An edit made while the node is down reconciles on reconnect, without overwriting the server (desktop#9).
    if args.stop_cmd:
        offline = f"offline-{tag}.txt"
        server_side, mac_side = b"server, before the outage\n", b"Mac, during the outage\n"
        (root / offline).write_bytes(b"base\n")
        step("offline: base file on the server", wait(lambda: node.get("/" + offline) == b"base\n") is True)
        step("offline: server edits it (vh fs put)", node.put("/" + offline, server_side))
        step("offline: node stopped", shell(args.stop_cmd))
        (root / offline).write_bytes(mac_side)
        time.sleep(10)
        step("offline: node started", shell(args.start_cmd))
        def reconciled():
            names = [n for n in local_ls(root) if n.startswith("offline-") and "(conflict from " in n]
            return [n for n in names if node.get("/" + n) == mac_side] or None
        offline_copies = wait(reconciled, 300, every=5, domain=domain)
        step("offline: the Mac's edit is a conflict copy after reconnect", bool(offline_copies), f"{offline_copies}")
        step("offline: the server's edit stays", node.get("/" + offline) == server_side)
        for name in [offline] + (offline_copies or []):
            (root / name).unlink()

    # 9. Revocation fails closed: the agent removes the domain (desktop#5). Destructive: pair again afterwards.
    if args.revoke_cmd:
        step("revoke this Mac on the node", shell(args.revoke_cmd))
        step("the agent removes the domain from Finder", wait(lambda: not root.exists(), 240, every=5) is True,
             str(root))

    print(f"{sum(results)}/{len(results)} passed", flush=True)
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
