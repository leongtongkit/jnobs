#!/usr/bin/env python3
"""Tail sniff.log and print interpreted Turn Up events.

Reads the hex-dump lines produced by sniff.py, walks the byte stream,
emits one line per logical event. Knob sweeps are coalesced.

Usage: python3 parse.py [path-to-sniff.log]
"""
import sys, time, re, os

LOG = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "sniff.log")
HEX_RE = re.compile(r"\[\s*([\d.]+)s\]\s*\(\s*\d+\)\s+([0-9a-f ]+?)\s+\|")

class Parser:
    def __init__(self):
        self.buf = bytearray()
        self.pending = None  # (kid, start_val, last_val, start_t, last_t)
        self.FLUSH = 0.15

    def flush_pending(self, force=False, now=None):
        if not self.pending: return
        k, s, e, st, et = self.pending
        if not force and now is not None and (now - et) < self.FLUSH:
            return
        d = "CW" if e > s else "CCW" if e < s else "noop"
        print(f"[{st:7.3f}s] knob {k} {d:3s} {s:4d} → {e:4d} (Δ{e-s:+d}, {et-st:.2f}s)", flush=True)
        self.pending = None

    def feed(self, bytes_, t):
        self.buf.extend(bytes_)
        while True:
            i = self.buf.find(0xFE)
            if i < 0:
                self.buf.clear(); return
            if i > 0: del self.buf[:i]
            j = self.buf.find(0xFF, 1)
            if j < 0: return
            frame = bytes(self.buf[:j+1])
            del self.buf[:j+1]
            self.dispatch(frame, t)

    def dispatch(self, frame, t):
        if frame == b"\xfe\x02\xff":
            return  # heartbeat — suppress
        if len(frame) == 6 and frame[1] == 0x03:
            kid = frame[2]; val = (frame[3] << 8) | frame[4]
            if self.pending and self.pending[0] == kid:
                k, s, e, st, et = self.pending
                self.pending = (k, s, val, st, t)
            else:
                self.flush_pending(force=True)
                self.pending = (kid, val, val, t, t)
            return
        if len(frame) == 4 and frame[1] == 0x06:
            self.flush_pending(force=True)
            print(f"[{t:7.3f}s] BUTTON {frame[2]} PRESS", flush=True); return
        if len(frame) == 4 and frame[1] == 0x07:
            self.flush_pending(force=True)
            print(f"[{t:7.3f}s] BUTTON {frame[2]} RELEASE", flush=True); return
        self.flush_pending(force=True)
        hx = " ".join(f"{b:02x}" for b in frame)
        print(f"[{t:7.3f}s] UNKNOWN ({len(frame)}): {hx}", flush=True)

def tail(path):
    while not os.path.exists(path):
        time.sleep(0.1)
    f = open(path, "r")
    f.seek(0, 2)  # tail-from-end
    while True:
        line = f.readline()
        if not line:
            time.sleep(0.05); continue
        yield line.rstrip("\n")

def main():
    p = Parser()
    print(f"# parsing {LOG}", flush=True)
    for line in tail(LOG):
        m = HEX_RE.search(line)
        if not m: continue
        t = float(m.group(1))
        bs = bytes.fromhex(m.group(2).replace(" ", ""))
        p.feed(bs, t)
        p.flush_pending(now=time.time() if False else t)

if __name__ == "__main__":
    main()
