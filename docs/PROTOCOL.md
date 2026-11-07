# SlidePod BLE protocol v1

The firmware advertises as **`SlidePod`** with one primary service. All multi-byte fields
are little-endian. The source of truth is `lib/slidepod_core/src/protocol.h`, and
`pio test -e native` checks the byte layouts.

| | UUID | Properties |
|---|---|---|
| Service | `5d1e0000-7c3a-4b8e-9f21-6a0c2e4b7d90` | |
| State | `5d1e0001-7c3a-4b8e-9f21-6a0c2e4b7d90` | read, notify (50 Hz) |
| Calibration | `5d1e0002-7c3a-4b8e-9f21-6a0c2e4b7d90` | read, write |
| Control | `5d1e0003-7c3a-4b8e-9f21-6a0c2e4b7d90` | write |

The firmware asks for a 7.5–15 ms connection interval. Every packet fits the default
20-byte ATT payload, so no MTU exchange is needed.

## State (15 bytes, notify)

| Offset | Type | Field | Scale |
|---|---|---|---|
| 0 | u8 | protocol version | `1` |
| 1 | u8 | flags | see below |
| 2 | u16 | distance | mm (Kalman-filtered ToF) |
| 4 | u16 | slide position | value / 256 → 1.0 = 1st … 7.0 = 7th (continuous) |
| 6 | u16 | pitch | value / 10 → Hz, 0 = none |
| 8 | i8 | cents | vs nearest equal-tempered note, + = sharp |
| 9 | u8 | note | MIDI number (58 = B♭3) |
| 10 | u8 | partial | 1 = pedal |
| 11 | u8 | confidence | value / 255 |
| 12 | i16 | correction | value / 256 → positions; ideal − current, + = move the slide **out** |
| 14 | u8 | battery | % |

Flags:

| Bit | Meaning |
|---|---|
| 0 | slide valid: ToF reading is fresh and in range. Otherwise ignore distance and position. |
| 1 | pitch valid |
| 2 | note valid: note, partial, cents and correction are meaningful (needs bits 0 and 1) |
| 3 | reachable: the in-tune spot for this note on this partial lies on the slide (about 0.7 to 7.5) |
| 4 | USB power present |
| 5 | calibrated: user calibration is stored (otherwise defaults) |

**Correction** is how the partial model makes up for out-of-tune harmonics. Two examples
on a B♭ tenor:
- D4 in 1st position is the 5th partial, about 14 cents flat. The in-tune spot is about
  0.86, *inside* 1st, so the correction comes out at about −0.14.
- F4 in 1st is the 6th partial and almost exactly in tune, so the correction is about 0.

## Calibration (10 bytes, read / write)

| Offset | Type | Field |
|---|---|---|
| 0 | u8 | protocol version `1` |
| 1 | f32 | `d1_mm`: sensor reading in 1st position |
| 5 | f32 | `tube_mm`: effective tube length in 1st (B♭ tenor ≈ 2750) |
| 9 | u8 | `open_midi`: pedal in 1st position (B♭1 = 34, E♭ alto = 39) |

A write takes effect at once and is saved to flash. The app can keep per-horn profiles
and write one when a student picks their instrument. The firmware rejects values outside
d1 0–500 mm, tube 1200–4500 mm, open note MIDI 20–50.

Slide model: `position = 1 + 12·log2(1 + 2·(distance − d1) / tube)`

## Control (write)

| Bytes | Action |
|---|---|
| `01` | Capture **1st position**: store the current distance as d1 |
| `02 k` | Capture **position k** (2–7): solve the tube length from the current distance. Use 6. |
| `03` | Reset calibration to defaults |
| `04 m` | Set the open (pedal) note to MIDI m |

Calibration flow in the app:
1. Prompt "slide in 1st" and write `01`.
2. Prompt "slide to 6th" and write `02 06`.
3. Read back the calibration characteristic to confirm.
