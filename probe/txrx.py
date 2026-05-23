#!/usr/bin/env python3
"""Interactive TX/RX probe for Turn Up.

Reads candidate frames from stdin (one hex string per line, spaces ignored)
and sends them to /dev/cu.usbmodem00001. Continuously prints all RX bytes
(non-heartbeat) to stderr with timestamps.

Usage:
    python3 txrx.py < frames.txt
or interactively:
    python3 txrx.py
    > fe 03 00 03 ff ff
    > fe 04 00 03 ff ff
"""
import os, sys, termios, time, select, threading

PORT = "/dev/cu.usbmodem00001"

def configure(fd):
    a = termios.tcgetattr(fd)
    a[0]=0; a[1]=0; a[3]=0
    a[2] = (a[2] & ~termios.CSIZE) | termios.CS8 | termios.CREAD | termios.CLOCAL
    a[2] &= ~termios.PARENB & ~termios.CSTOPB
    a[6][termios.VMIN]=0; a[6][termios.VTIME]=0
    a[4]=termios.B115200; a[5]=termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, a)

fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
configure(fd)

rx_buf = bytearray()
t0 = time.time()
stop = threading.Event()

def parse_print(frame, t):
    if frame == b"\xfe\x02\xff":
        return  # suppress heartbeat
    hx = " ".join(f"{b:02x}" for b in frame)
    if len(frame) == 6 and frame[1] == 0x03:
        kid = frame[2]; val = (frame[3]<<8)|frame[4]
        print(f"  <-- [{t:7.3f}s] KNOB {kid} pos={val}  ({hx})", file=sys.stderr, flush=True)
    elif len(frame) == 4 and frame[1] in (0x06, 0x07):
        kind = "PRESS" if frame[1] == 0x06 else "RELEASE"
        print(f"  <-- [{t:7.3f}s] BTN {frame[2]} {kind}  ({hx})", file=sys.stderr, flush=True)
    else:
        print(f"  <-- [{t:7.3f}s] FRAME ({len(frame)}): {hx}", file=sys.stderr, flush=True)

def rx_loop():
    while not stop.is_set():
        r,_,_ = select.select([fd], [], [], 0.05)
        if r:
            try: chunk = os.read(fd, 256)
            except BlockingIOError: chunk = b""
            if chunk:
                rx_buf.extend(chunk)
                while True:
                    i = rx_buf.find(0xFE)
                    if i < 0:
                        rx_buf.clear(); break
                    if i > 0: del rx_buf[:i]
                    j = rx_buf.find(0xFF, 1)
                    if j < 0: break
                    frame = bytes(rx_buf[:j+1])
                    del rx_buf[:j+1]
                    parse_print(frame, time.time() - t0)

threading.Thread(target=rx_loop, daemon=True).start()

print(f"# {PORT} opened RDWR. paste hex frames (one per line). EOF to exit.", file=sys.stderr, flush=True)
try:
    for line in sys.stdin:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            data = bytes.fromhex(line.replace(" ", ""))
        except ValueError as e:
            print(f"# parse error: {e}", file=sys.stderr, flush=True); continue
        hx = " ".join(f"{b:02x}" for b in data)
        print(f"--> [{time.time()-t0:7.3f}s] TX ({len(data)}): {hx}", file=sys.stderr, flush=True)
        os.write(fd, data)
        time.sleep(1.5)  # let device react / report
finally:
    stop.set()
    time.sleep(0.1)
    os.close(fd)
