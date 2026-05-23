#!/usr/bin/env python3
"""Turn Up serial protocol sniffer — stdlib only.

Opens /dev/cu.usbmodem00001, configures sane terminal mode, and logs every
incoming byte with timestamp, hex, and ASCII printable form. Each line is
either a single byte burst (gap > 50ms since previous) or a continuation.
"""
import os
import sys
import termios
import time
import select

PORT = sys.argv[1] if len(sys.argv) > 1 else "/dev/cu.usbmodem00001"
BAUD = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
GAP_MS = 50  # bytes within this window are one logical packet

BAUD_MAP = {
    9600: termios.B9600, 19200: termios.B19200, 38400: termios.B38400,
    57600: termios.B57600, 115200: termios.B115200, 230400: termios.B230400,
}

def configure(fd, baud):
    attrs = termios.tcgetattr(fd)
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = attrs
    # raw mode
    iflag = 0
    oflag = 0
    lflag = 0
    cflag = (cflag & ~termios.CSIZE) | termios.CS8 | termios.CREAD | termios.CLOCAL
    cflag &= ~termios.PARENB
    cflag &= ~termios.CSTOPB
    cflag &= ~termios.CRTSCTS if hasattr(termios, "CRTSCTS") else cflag
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 0
    b = BAUD_MAP.get(baud, termios.B115200)
    termios.tcsetattr(fd, termios.TCSANOW, [iflag, oflag, cflag, lflag, b, b, cc])

def main():
    fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    configure(fd, BAUD)
    print(f"# listening on {PORT} @ {BAUD} — interact with the device. Ctrl-C to stop.", flush=True)
    buf = bytearray()
    last_byte_t = 0.0
    t0 = time.time()
    try:
        while True:
            r, _, _ = select.select([fd], [], [], 0.02)
            if r:
                try:
                    chunk = os.read(fd, 256)
                except BlockingIOError:
                    chunk = b""
                if chunk:
                    now = time.time()
                    if buf and (now - last_byte_t) * 1000 > GAP_MS:
                        flush(buf, last_byte_t - t0)
                        buf.clear()
                    buf.extend(chunk)
                    last_byte_t = now
            else:
                if buf and (time.time() - last_byte_t) * 1000 > GAP_MS:
                    flush(buf, last_byte_t - t0)
                    buf.clear()
    except KeyboardInterrupt:
        if buf:
            flush(buf, last_byte_t - t0)
        print("\n# stopped.")
    finally:
        os.close(fd)

def flush(buf, t):
    hexs = " ".join(f"{b:02x}" for b in buf)
    asci = "".join((chr(b) if 32 <= b < 127 else ".") for b in buf)
    print(f"[{t:7.3f}s] ({len(buf):3d}) {hexs}   |{asci}|", flush=True)

if __name__ == "__main__":
    main()
