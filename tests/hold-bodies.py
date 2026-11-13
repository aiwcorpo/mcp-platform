# Opens connections to the TLS server that each send all of a request body but the last bytes and then wait, as a slow client
# does. Prints how many connections nginx answered (refused) while they waited.
# Usage: hold-bodies.py <connections> <content-length> <bytes sent> <seconds to hold>
import socket
import ssl
import sys
import time

count, length, sent, hold = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
conns = []
for _ in range(count):
    s = ctx.wrap_socket(socket.create_connection(("mcp.test", 8443)), server_hostname="mcp.test")
    s.sendall(f"POST /mcp HTTP/1.1\r\nHost: mcp.test\r\nContent-Type: application/json\r\n"
              f"Content-Length: {length}\r\n\r\n".encode())
    s.sendall(b"x" * sent)
    conns.append(s)
time.sleep(hold)
answers = []
for s in conns:
    s.setblocking(False)
    try:
        first = s.recv(64)
        if first:
            answers.append(first.split(b"\r\n")[0].decode())
    except (ssl.SSLWantReadError, BlockingIOError):
        pass
print(f"held={count - len(answers)} answered={len(answers)} {' | '.join(sorted(set(answers)))}", flush=True)
