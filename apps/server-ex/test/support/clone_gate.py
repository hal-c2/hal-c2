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
import os
import select
import shutil
import socket
import sys

# Only stdin, stdout and stderr: an inherited end of its own stdout pipe would keep
# it from seeing git go.
os.closerange(3, os.sysconf("SC_OPEN_MAX"))

port, token = int(sys.argv[1]), sys.argv[2]
if token == "@cwd":
    token = os.path.basename(os.getcwd())
conn = socket.create_connection(("127.0.0.1", port))
conn.sendall((token + "\n").encode())

# git gone: nothing reads stdout any more (POLLERR), or, as a transport behind
# `git remote-ext`, which outlives git, stdin closes (POLLHUP; git sends nothing
# before the gate's answer). A smudge filter's stdin closes after the file's content.
poll = select.poll()
poll.register(conn, select.POLLIN)
poll.register(sys.stdout.fileno(), 0)
transport = len(sys.argv) > 3
if transport:
    poll.register(sys.stdin.fileno(), 0)
if any(fd != conn.fileno() for fd, _ in poll.poll()):
    sys.exit(1)

verdict = conn.makefile("r").readline().strip()

if verdict != "ok":
    sys.stderr.write("fatal: %s\n" % (verdict or "the gate closed"))
    sys.exit(1)

if transport:
    service, repository = sys.argv[3], sys.argv[4]
    os.execvp(service, [service, repository])
else:
    shutil.copyfileobj(sys.stdin.buffer, sys.stdout.buffer)
