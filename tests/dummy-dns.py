# DNS server for the name resolution tests: answers an A query for one of the given names with the given address and NXDOMAIN
# for anything else, and prints every query. It stands in for a resolver outside Docker that knows a name it should not.
# Usage: dummy-dns.py <address> <name>...
import socket
import struct
import sys

address, names = sys.argv[1], {n.lower() for n in sys.argv[2:]}
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("0.0.0.0", 53))
while True:
    query, peer = sock.recvfrom(512)
    tid = struct.unpack(">H", query[:2])[0]
    pos, labels = 12, []
    while query[pos]:
        labels.append(query[pos + 1:pos + 1 + query[pos]].decode())
        pos += 1 + query[pos]
    qtype = struct.unpack(">H", query[pos + 1:pos + 3])[0]
    question = query[12:pos + 5]
    name = ".".join(labels).lower()
    print(f"QUERY {name} type={qtype}", flush=True)
    if name in names and qtype == 1:
        reply = struct.pack(">HHHHHH", tid, 0x8180, 1, 1, 0, 0) + question
        reply += struct.pack(">HHHLH", 0xC00C, 1, 1, 60, 4) + socket.inet_aton(address)
    else:
        reply = struct.pack(">HHHHHH", tid, 0x8183, 1, 0, 0, 0) + question
    sock.sendto(reply, peer)
