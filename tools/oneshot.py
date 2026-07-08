#!/usr/bin/env python3
# One-shot TCP file server. Binds, accepts ONE connection, sends file, exits.
import socket, sys, os
src_ip, port, path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((src_ip, port))
s.listen(1)
c, addr = s.accept()
sys.stderr.write("conn from %s, sending %s (%d bytes)\n" % (addr, path, os.path.getsize(path)))
with open(path, 'rb') as f:
    while True:
        d = f.read(65536)
        if not d: break
        c.sendall(d)
c.shutdown(socket.SHUT_WR)
sent = os.path.getsize(path)
sys.stderr.write("done, %d bytes\n" % sent)
c.close(); s.close()
