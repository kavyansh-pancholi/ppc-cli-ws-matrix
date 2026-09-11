#!/usr/bin/env python3
"""Logging forward-proxy. Records every CONNECT target host, then tunnels
the bytes through untouched (no TLS interception, no CA needed)."""
import socket, threading, sys, os

LOG = os.environ.get('PROXY_LOG', '/tmp/egress.log')
PORT = int(os.environ.get('PROXY_PORT', '8899'))
_lock = threading.Lock()

def record(host):
    with _lock:
        with open(LOG, 'a') as f:
            f.write(host + '\n')

def pipe(a, b):
    try:
        while True:
            data = a.recv(65536)
            if not data: break
            b.sendall(data)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try: s.shutdown(socket.SHUT_RDWR)
            except OSError: pass

def handle(client):
    try:
        req = b''
        while b'\r\n\r\n' not in req:
            chunk = client.recv(4096)
            if not chunk: return
            req += chunk
        line = req.split(b'\r\n')[0].decode('latin-1')
        parts = line.split()
        if len(parts) < 2 or parts[0].upper() != 'CONNECT':
            record('NON-CONNECT ' + line[:80]); client.close(); return
        hostport = parts[1]
        host = hostport.rsplit(':', 1)[0]
        port = int(hostport.rsplit(':', 1)[1]) if ':' in hostport else 443
        record(host)
        try:
            upstream = socket.create_connection((host, port), timeout=20)
        except OSError as e:
            client.sendall(b'HTTP/1.1 502 Bad Gateway\r\n\r\n'); client.close(); return
        client.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')
        threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
        pipe(upstream, client)
    except Exception:
        try: client.close()
        except OSError: pass

def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('127.0.0.1', PORT)); srv.listen(128)
    print(f'proxy listening on 127.0.0.1:{PORT}, logging to {LOG}', flush=True)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()

main()
