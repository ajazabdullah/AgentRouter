#!/usr/bin/env python3
"""Disposable raw terminal receiver; never interprets or executes received bytes."""
import hashlib
import json
import os
import select
import sys
import termios
import tty

fd = sys.stdin.fileno()
previous = termios.tcgetattr(fd)
try:
    tty.setraw(fd)
    os.write(sys.stdout.fileno(), b'\x1b[?2004hREADY\r\n')
    data = b''
    while b'\x1b[201~' not in data:
        data += os.read(fd, 4096)
    # Include any unwanted trailing Enter or additional bytes in the verification.
    while select.select([fd], [], [], 0.3)[0]:
        data += os.read(fd, 4096)
    with open(sys.argv[1], 'w') as result:
        json.dump({'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}, result)
    while True:
        select.select([], [], [], 60)
finally:
    os.write(sys.stdout.fileno(), b'\x1b[?2004l')
    termios.tcsetattr(fd, termios.TCSANOW, previous)
