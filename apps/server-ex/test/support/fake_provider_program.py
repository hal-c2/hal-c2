#!/usr/bin/env python3
"""A provider CLI for the programs a node leaves behind (node-startup.feature).

It exits when its input closes, unless --keep-working, when it goes on as `claude -p`
does mid-turn. --ignore-term also ignores SIGTERM, as a program deep in a turn may.
"""
import signal
import sys
import time

if "--ignore-term" in sys.argv:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)

sys.stdin.read()

if "--keep-working" in sys.argv:
    time.sleep(3600)
