#!/usr/bin/env python3
# Holds a real `git clone` at one point until the test says how it goes on.
#
#   As an ext:: transport, it holds the fetch:
#     ext::python3 clone_gate.py PORT TOKEN %S /path/to/bare.git
#   As a smudge filter (filter.<name>.smudge), it holds the checkout of a file:
#     python3 clone_gate.py PORT TOKEN
#   where a TOKEN of @cwd is the name of the folder being checked out.
#
# It connects to the test on 127.0.0.1:PORT, sends TOKEN and a newline, and reads one
# line back: "ok" goes on (runs git's upload pack on the repository, or passes the
# file through), anything else fails with that line as git's error. The test closing
# the connection fails the gate. Like any helper git starts, the gate ends once git
# is gone (the end of its stdout git reads closes), so a killed git is reported.
#
# "hold" first instead has a held gate outlive the git it holds, as a helper git
# started that has not exited yet: once git is gone the gate says "gone" and waits
# for the test to close the connection. It keeps the descriptors 3 and 4 it got from
# git (Exile's, as it runs git), so until then git's exit is not reported, and it
# leaves git's process group, so killing that does not end it.
import os
import select
import shutil
import socket
import sys

# Only stdin, stdout, stderr and Exile's two: an inherited end of its own stdout
# pipe would keep it from seeing git go.
os.closerange(5, os.sysconf("SC_OPEN_MAX"))

port, token = int(sys.argv[1]), sys.argv[2]
if token == "@cwd":
    token = os.path.basename(os.getcwd())
conn = socket.create_connection(("127.0.0.1", port))
conn.sendall((token + "\n").encode())


def line():
    # Unbuffered, so a line the test sent next is still there for poll to see.
    got = b""
    while not got.endswith(b"\n"):
        byte = conn.recv(1)
        if not byte:
            break
        got += byte
    return got.decode().strip()


# git gone: nothing reads stdout any more (POLLERR), or, as a transport behind
# `git remote-ext`, which outlives git, stdin closes (POLLHUP; git sends nothing
# before the gate's answer). A smudge filter's stdin closes after the file's content.
poll = select.poll()
poll.register(conn, select.POLLIN)
poll.register(sys.stdout.fileno(), 0)
transport = len(sys.argv) > 3
if transport:
    poll.register(sys.stdin.fileno(), 0)

hold = False
while True:
    if any(fd != conn.fileno() for fd, _ in poll.poll()):
        if hold:
            conn.sendall(b"gone\n")
            line()
        sys.exit(1)
    verdict = line()
    if verdict != "hold":
        break
    # Out of git's process group, which a stopped clone is killed with, as a
    # helper that went off on its own.
    os.setsid()
    hold = True

if verdict != "ok":
    sys.stderr.write("fatal: %s\n" % (verdict or "the gate closed"))
    sys.exit(1)

if transport:
    service, repository = sys.argv[3], sys.argv[4]
    os.closerange(3, 5)
    os.execvp(service, [service, repository])
else:
    shutil.copyfileobj(sys.stdin.buffer, sys.stdout.buffer)
