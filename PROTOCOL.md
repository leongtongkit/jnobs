# Turn Up Volume Mixer — Serial Protocol

Clean-room reverse-engineered from USB CDC-ACM traffic observation on 2026-05-20. Frame formats and behaviors below were inferred by exercising the device (knob turns, button presses, host pings) and parsing the resulting byte streams in `probe/`. Verified live against device ID `137430839`.

## Device

- USB vendor / product: `0x04D9 / 0x0060` (Holtek)
- Enumerates as `AppleUSBCDCCompositeDevice` → `/dev/cu.usbmodem*` on macOS
- Baud: `115200` (technically ignored by USB CDC, but the host software sets it)
- 5 knobs, 5 buttons, 3 RGB LEDs per knob (the "fan")

## Framing

All messages: `0xFE  TYPE  [payload]  0xFF`. Both directions use the same framing.

- `MESSAGE_START_BYTE = 0xFE` (`254`)
- `MESSAGE_END_BYTE = 0xFF` (`255`)
- Payload bytes are raw — no escaping. Frame length is fixed per TYPE.

## Messages — Device → Host

| TYPE | Total bytes | Name | Payload | Notes |
|---|---|---|---|---|
| `0x02` | 3 | Health/Heartbeat | (none) | Emitted autonomously every ~500 ms after connect |
| `0x03` | 6 | Knob Position | `KK HH LL` | `KK` = knob ID 0..4, `HH·256 + LL` = 10-bit ADC (0..1023). Emitted on every change (delta ≈ 11 per detent click) |
| `0x04` | 13 | Knob Batch | `H0 L0 H1 L1 H2 L2 H3 L3 H4 L4` | Initial state of all 5 knobs. Sent once in response to host ping |
| `0x06` | 4 | Button Press | `BB` | `BB` = button ID 0..4. Emitted on key-down |
| `0x07` | 4 | Button Release | `BB` | Emitted on key-up |
| `0x08` | 7 | Device ID | `ID3 ID2 ID1 ID0` | uint32 big-endian. Sent once after host ping |

## Messages — Host → Device

### `0x01` — Ping (3 bytes)

`fe 01 ff`

Sent on connect. Device responds with one `fe 08 ID3 ID2 ID1 ID0 ff` (device ID) and one `fe 04 ... ff` (knob batch), then continuous heartbeats.

### `0x05` — Set Lights (48 bytes)

`fe 05 [45 bytes RGB] ff`

Sets every LED on the device in a single shot. Payload is **5 knobs × 3 LEDs × RGB**, in this exact order:

```
fe 05
  K0R0 K0G0 K0B0   K0R1 K0G1 K0B1   K0R2 K0G2 K0B2     ← knob 0 (3 fan LEDs)
  K1R0 K1G0 K1B0   K1R1 K1G1 K1B1   K1R2 K1G2 K1B2     ← knob 1
  K2…                                                  ← knob 2
  K3…                                                  ← knob 3
  K4R0 K4G0 K4B0   K4R1 K4G1 K4B1   K4R2 K4G2 K4B2     ← knob 4
ff
```

Each color byte is 0..255 (no gamma applied by the device — host-side responsibility). The LEDs are perceptually non-linear, so a host-side 8-bit gamma LUT (we use a standard 2.2 curve) is applied before sending to keep low intensities visible.

The LEDs are completely host-driven: with no host commands they stay dark.

## Connect Sequence

1. Open `/dev/cu.usbmodem*` at 115200 baud, 8N1, no flow control.
2. Send `fe 01 ff`.
3. Read until you see `fe 04 …` (BATCH) — this is the handshake-complete signal. We treat 5 s with no batch as a failed handshake and reconnect.
4. Optionally read `fe 08 …` for the device ID.
5. Begin listening for KNOB / BUTTON / HEARTBEAT events.
6. Send `fe 05 …` whenever LED state should change.
7. If `fe 02 ff` heartbeat is silent for >10 s, the device is gone — reconnect.

## Knob Value Conversion

Raw 10-bit ADC values normalize to `0..100`:

```
percent = raw / 10.23     // 10.23 = 1023 / 100
if raw > 1000: percent = 100   // clamp top — gives a dead-zone at the top of the pot's mechanical travel
```

Observed in practice: the pot doesn't reliably reach 1023 on all units, so the >1000 clamp avoids a frustrating top-of-travel gap.

## Our defaults

Mint-green `(0, 220, 70)` LEDs, knob 0 = master volume, buttons 0–2 = prev/play/next. These are independently chosen defaults for the Jnobs macOS app (see `~/Library/Application Support/Jnobs/config.json`), arrived at by ergonomics, not derived from any other software.
