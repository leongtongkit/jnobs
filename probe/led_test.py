#!/usr/bin/env python3
"""LED verification test — builds correctly-sized colorMessage frames."""
import os, sys, termios, time, select

PORT = "/dev/cu.usbmodem00001"

def color_frame(knob_colors):
    """knob_colors: list of 5 tuples of (R,G,B) — applied identically to all 3 LEDs of each knob."""
    assert len(knob_colors) == 5
    frame = bytearray([0xFE, 0x05])
    for r, g, b in knob_colors:
        for _ in range(3):  # 3 LEDs per knob
            frame += bytes([r, g, b])
    frame.append(0xFF)
    assert len(frame) == 48, f"got {len(frame)} bytes"
    return bytes(frame)

OFF = (0, 0, 0)
RED = (0xFF, 0, 0); GREEN = (0, 0xFF, 0); BLUE = (0, 0, 0xFF)
WHITE = (0xFF, 0xFF, 0xFF); YELLOW = (0xFF, 0xFF, 0); CYAN = (0, 0xFF, 0xFF)
MAGENTA = (0xFF, 0, 0xFF)

tests = [
    ("knob 0 RED",         [RED, OFF, OFF, OFF, OFF]),
    ("knob 1 GREEN",       [OFF, GREEN, OFF, OFF, OFF]),
    ("knob 2 BLUE",        [OFF, OFF, BLUE, OFF, OFF]),
    ("knob 3 WHITE",       [OFF, OFF, OFF, WHITE, OFF]),
    ("knob 4 YELLOW",      [OFF, OFF, OFF, OFF, YELLOW]),
    ("ALL cyan",           [CYAN]*5),
    ("rainbow",            [RED, YELLOW, GREEN, CYAN, MAGENTA]),
    ("ALL off",            [OFF]*5),
]

def configure(fd):
    a = termios.tcgetattr(fd)
    a[0]=0; a[1]=0; a[3]=0
    a[2] = (a[2] & ~termios.CSIZE) | termios.CS8 | termios.CREAD | termios.CLOCAL
    a[2] &= ~termios.PARENB & ~termios.CSTOPB
    a[6][termios.VMIN]=0; a[6][termios.VTIME]=0
    a[4]=termios.B115200; a[5]=termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, a)

def main():
    fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    configure(fd)
    print(f"# {PORT} opened. Sending {len(tests)} LED frames.", flush=True)
    for label, colors in tests:
        f = color_frame(colors)
        os.write(fd, f)
        print(f">>> {label:20s}  ({len(f)}B)  {f.hex(' ')}", flush=True)
        time.sleep(2.0)
    os.close(fd)
    print("# done.")

if __name__ == "__main__":
    main()
