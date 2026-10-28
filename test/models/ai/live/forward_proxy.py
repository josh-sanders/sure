# Minimal logging forward proxy for the spike: plain HTTP (absolute URI) and
# CONNECT tunnels. Loopback only. Logs one line per request to argv[2].
import socket, sys, threading, select
PORT, LOG = int(sys.argv[1]), sys.argv[2]
lock = threading.Lock()
def log(line):
    with lock, open(LOG, "a") as f: f.write(line + "\n")
def pipe(a, b):
    socks = [a, b]
    try:
        while True:
            r, _, _ = select.select(socks, [], [], 120)
            if not r: return
            for s in r:
                data = s.recv(65536)
                if not data: return
                (b if s is a else a).sendall(data)
    except OSError: return
def handle(client):
    try:
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = client.recv(65536)
            if not chunk: return
            head += chunk
        line = head.split(b"\r\n", 1)[0].decode()
        method, target, _ = line.split(" ", 2)
        log(f"{method} {target}")
        if method == "CONNECT":
            host, port = target.rsplit(":", 1)
            upstream = socket.create_connection((host, int(port)), timeout=30)
            client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            pipe(client, upstream)
        else:
            from urllib.parse import urlsplit
            u = urlsplit(target)
            upstream = socket.create_connection((u.hostname, u.port or 80), timeout=300)
            path = (u.path or "/") + (("?" + u.query) if u.query else "")
            rest = head.split(b"\r\n", 1)[1]
            upstream.sendall(f"{method} {path} HTTP/1.1\r\n".encode() + rest)
            pipe(client, upstream)
    except Exception as e:
        log(f"ERR {e}")
    finally:
        client.close()
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", PORT)); srv.listen(32)
while True:
    c, _ = srv.accept(); threading.Thread(target=handle, args=(c,), daemon=True).start()
