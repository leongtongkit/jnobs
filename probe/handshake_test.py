#!/usr/bin/env python3
"""Send the handshake ping (fe 01 ff) and capture the device's response —
expect fe 04 [batch] ff and fe 08 [device id] ff (see PROTOCOL.md)."""
import os, termios, time, select

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

# clear buffer first
time.sleep(0.2)
while True:
    r,_,_ = select.select([fd], [], [], 0.05)
    if not r: break
    os.read(fd, 256)

print("# sending fe 01 ff (handshake ping)")
os.write(fd, bytes([0xFE, 0x01, 0xFF]))

t0 = time.time()
buf = bytearray()
while time.time() - t0 < 2.0:
    r,_,_ = select.select([fd], [], [], 0.05)
    if r:
        chunk = os.read(fd, 256)
        if chunk: buf.extend(chunk)

# parse frames
i = 0
while i < len(buf):
    if buf[i] != 0xFE:
        i += 1; continue
    # try each known type
    types_lengths = {0x02: 3, 0x03: 6, 0x04: 13, 0x06: 4, 0x07: 4, 0x08: 7}
    if i + 1 < len(buf) and buf[i+1] in types_lengths:
        L = types_lengths[buf[i+1]]
        if i + L <= len(buf) and buf[i+L-1] == 0xFF:
            f = bytes(buf[i:i+L])
            tname = {0x02:"HEARTBEAT", 0x03:"KNOB", 0x04:"BATCH", 0x06:"BTN_PRESS",
                     0x07:"BTN_REL", 0x08:"DEVICE_ID"}[buf[i+1]]
            if buf[i+1] == 0x04:
                vals = [(f[2+k*2]<<8)|f[3+k*2] for k in range(5)]
                print(f"  {tname:11s} {f.hex(' ')}  -> knob_init={vals}")
            elif buf[i+1] == 0x08:
                did = (f[2]<<24)|(f[3]<<16)|(f[4]<<8)|f[5]
                print(f"  {tname:11s} {f.hex(' ')}  -> device_id={did}")
            else:
                print(f"  {tname:11s} {f.hex(' ')}")
            i += L
            continue
    i += 1

os.close(fd)
