# probe/ — clean-room protocol derivation

These scripts are how the Turn Up serial protocol (`../PROTOCOL.md`) was
derived. They are not part of the shipping application; they are evidence
of methodology.

## Methodology

1. **Capture.** `sniff.py` opens the device's `/dev/cu.usbmodem*` serial
   node and dumps every byte it sees, with timestamps, to `sniff.log`.
   No protocol assumptions — just bytes in, bytes out.
2. **Interpret.** `parse.py` tails the log, walks the byte stream, and
   emits one line per logical event under a hypothesised framing
   (`0xFE TYPE [payload] 0xFF`). Frame boundaries and TYPE payloads
   were inferred by exercising the device — turn each knob slowly,
   press each button in isolation — and observing what bytes correlate
   with each physical action.
3. **Verify.** `txrx.py` sends candidate command frames back to the
   device and watches the response. `led_test.py` toggles LEDs by
   sending hypothesised LED-update frames and confirming visually.
   `handshake_test.py` probes the device's startup handshake.
4. **Document.** Confirmed facts are written to `../PROTOCOL.md`.

## Provenance guarantee

The protocol facts in `../PROTOCOL.md` were derived **only** from byte
streams observed flowing to and from the physical device. No vendor
binaries, installers, drivers, or third-party decompiler output were
inspected, referenced, or used at any point in this project's history.
The procedure above is reproducible from a Turn Up mixer + a USB cable
+ these scripts.

## tap_probe.swift

Separate concern from the serial protocol: this is a self-contained Swift
program that validates macOS's public Core Audio process-tap API
(`CATapDescription` / `AudioHardwareCreateProcessTap` /
`AudioHardwareCreateAggregateDevice`). It was the feasibility check for
Jnobs's per-app audio engine — capture a known test tone from a target
process, route it through an aggregate device with gain applied, confirm
the level at the output. Apple's public API, no third-party code.
