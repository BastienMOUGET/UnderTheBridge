#!/usr/bin/env python3
"""Test bout en bout d'amalgame-bridge en mode --selftest.

Lance `bridge --selftest` (pile lwIP sur lien factice, IP 10.255.0.1,
serveur echo TCP :7), puis joue des scénarios SOCKS5 depuis l'hôte :

  application (ce script) ── SOCKS5 127.0.0.1 ──► bridge ── lwIP ──► echo lwIP

Aucun privilège ni réseau requis. Usage : selftest_e2e.py <chemin/bridge>
"""
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time

BRIDGE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "build", "bridge")
PORT = 11080
ECHO = "10.255.0.1"
failures = 0


def check(name, cond, detail=""):
    global failures
    if cond:
        print(f"[PASS] {name}")
    else:
        failures += 1
        print(f"[FAIL] {name} {detail}")


def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            break
        buf += c
    return buf


def socks_open(dst, port, methods=b"\x00", auth=None):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    s.sendall(b"\x05" + bytes([len(methods)]) + methods)
    sel = recv_exact(s, 2)
    if auth and sel == b"\x05\x02":
        u, p = auth
        s.sendall(b"\x01" + bytes([len(u)]) + u + bytes([len(p)]) + p)
        recv_exact(s, 2)
    if isinstance(dst, str) and dst.replace(".", "").isdigit():
        addr = b"\x01" + socket.inet_aton(dst)
    else:
        addr = b"\x03" + bytes([len(dst)]) + dst.encode()
    s.sendall(b"\x05\x01\x00" + addr + struct.pack(">H", port))
    rep = recv_exact(s, 10)
    return s, rep


def roundtrip(payload, dst=ECHO):
    s, rep = socks_open(dst, 7)
    if len(rep) < 2 or rep[1] != 0:
        return None, rep
    s.sendall(payload)
    s.shutdown(socket.SHUT_WR)
    got = b""
    while True:
        c = s.recv(65536)
        if not c:
            break
        got += c
    s.close()
    return got, rep


def concurrent(n):
    socks_list = []
    err = ""
    try:
        for i in range(n):
            s, rep = socks_open(ECHO, 7)
            socks_list.append((s, rep))
        ok = 0
        for i, (s, rep) in enumerate(socks_list):
            msg = f"session {i}".encode()
            if rep[1] == 0:
                s.sendall(msg)
                if recv_exact(s, len(msg)) == msg:
                    ok += 1
                elif not err:
                    err = f"(écho manquant dès la session {i})"
    except OSError as e:
        ok, err = 0, f"({type(e).__name__} après {len(socks_list)} ouvertures : {e})"
    for s, _ in socks_list:
        s.close()
    time.sleep(0.2)
    return ok, err


def main():
    # Sortie du bridge dans un fichier, PAS dans un tube : un tube non lu
    # se remplit (≈4 Ko sous Windows) et bloque le bridge sur fprintf.
    logf = tempfile.TemporaryFile()
    proc = subprocess.Popen([BRIDGE, "--selftest", "--port", str(PORT)],
                            stdout=logf, stderr=subprocess.STDOUT)
    try:
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", PORT), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)

        got, rep = roundtrip(b"bonjour bridge")
        check("connect + echo court", got == b"bonjour bridge", repr(got))
        check("réponse SOCKS : BND.ADDR = IP de la pile",
              rep[4:8] == socket.inet_aton(ECHO), rep.hex())

        big = os.urandom(4 * 1024 * 1024)
        t0 = time.time()
        got, _ = roundtrip(big)
        dt = time.time() - t0
        check(f"echo 4 Mio intègre ({len(big) / dt / 1e6:.1f} Mo/s)", got == big,
              f"reçu {len(got) if got else 0} octets")

        got, _ = roundtrip(b"via nom", dst="10.255.0.1")
        check("ATYP domaine avec IP littérale", got == b"via nom", repr(got))

        s, rep = socks_open(ECHO, 9)
        check("port fermé → REP 0x05 (connexion refusée)", len(rep) > 1 and rep[1] == 5, rep.hex())
        s.close()

        s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
        s.sendall(b"\x05\x01\x00")
        recv_exact(s, 2)
        s.sendall(b"\x05\x02\x00\x01" + socket.inet_aton(ECHO) + struct.pack(">H", 7))
        rep = recv_exact(s, 10)
        check("BIND → REP 0x07 (non supporté)", len(rep) > 1 and rep[1] == 7, rep.hex())
        s.close()

        s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
        s.sendall(b"\x05\x01\x02")       # seulement user/pass, non configuré
        check("méthode non acceptable → 0xFF", recv_exact(s, 2) == b"\x05\xff")
        s.close()

        # HTTP CONNECT sur le même port (clients sans SOCKS : Claude Code, npm…)
        def http_connect(target, method="CONNECT"):
            c = socket.create_connection(("127.0.0.1", PORT), timeout=10)
            c.sendall(f"{method} {target} HTTP/1.1\r\nHost: {target}\r\n\r\n".encode())
            head = b""
            while b"\r\n\r\n" not in head:
                ch = c.recv(1)
                if not ch:
                    break
                head += ch
            return c, head.split(b"\r\n", 1)[0].decode(errors="replace")

        c, status = http_connect(f"{ECHO}:7")
        payload = os.urandom(1024 * 1024)
        ok = status.startswith("HTTP/1.1 200")
        if ok:
            c.sendall(payload)
            c.shutdown(socket.SHUT_WR)
            got = b""
            while True:
                ch = c.recv(65536)
                if not ch:
                    break
                got += ch
            ok = got == payload
        c.close()
        check("HTTP CONNECT : tunnel echo 1 Mio", ok, status)

        c, status = http_connect(f"{ECHO}:9")
        check("HTTP CONNECT : port fermé → 502", status.startswith("HTTP/1.1 502"), status)
        c.close()
        c, status = http_connect(f"http://{ECHO}:7/", method="GET")
        check("HTTP : GET → 405 (tunnel uniquement)", status.startswith("HTTP/1.1 405"), status)
        c.close()
        c, status = http_connect("pas-de-port-valide:99999")
        check("HTTP CONNECT : cible invalide → 400", status.startswith("HTTP/1.1 400"), status)
        c.close()

        # Sessions concurrentes, par paliers (repère un éventuel seuil).
        for n in (5, 10, 20, 40, 60, 64, 70):
            ok, err = concurrent(n)
            check(f"{n} sessions simultanées", ok == n, f"{ok}/{n} {err}")
            if ok != n:
                break

        # UDP ASSOCIATE : la pile n'a pas de serveur UDP ; on vérifie la négociation.
        s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
        s.sendall(b"\x05\x01\x00")
        recv_exact(s, 2)
        s.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
        rep = recv_exact(s, 10)
        uport = struct.unpack(">H", rep[8:10])[0] if len(rep) == 10 else 0
        check("UDP ASSOCIATE → port relais local", len(rep) == 10 and rep[1] == 0 and uport > 0, rep.hex())
        s.close()
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        logf.seek(0)
        out = logf.read()
        logf.close()
        if os.name == "nt":
            # Windows : terminate() = TerminateProcess, pas de signal à intercepter.
            print("[SKIP] arrêt propre sur SIGTERM (pas de SIGTERM sous Windows)")
        else:
            check("arrêt propre sur SIGTERM", proc.returncode == 0, f"code {proc.returncode}")
        if failures:
            print("── journal du bridge ──")
            print(out.decode(errors="replace")[-4000:])
    print(f"\n{'OK' if failures == 0 else 'ÉCHEC'} — {failures} échec(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
