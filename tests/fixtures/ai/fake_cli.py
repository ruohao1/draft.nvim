"""Provider-free native-terminal fixture; records input without interpreting it."""

import json
import os
import signal
import sys
import termios
import tty


def main():
    # The caller owns a private fixture directory. Never read provider state.
    descriptor = os.open(sys.argv[1], os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)

    def event(kind, **data):
        os.write(descriptor, (json.dumps({"event": kind, **data}) + "\n").encode())

    def stopped(number, _frame):
        event("signal", number=number)
        raise SystemExit(0)

    previous = termios.tcgetattr(sys.stdin.fileno())
    try:
        signal.signal(signal.SIGHUP, stopped)
        signal.signal(signal.SIGTERM, stopped)
        tty.setraw(sys.stdin.fileno())
        event("ready")
        os.write(sys.stdout.fileno(), b"FAKE CLI READY (no provider)\r\n")
        while True:
            data = os.read(sys.stdin.fileno(), 2048)
            if not data:
                break
            event("input", hex=data.hex())
            os.write(sys.stdout.fileno(), b"INPUT: " + data + b"\r\n")
    finally:
        termios.tcsetattr(sys.stdin.fileno(), termios.TCSANOW, previous)
        os.close(descriptor)


if __name__ == "__main__":
    main()
