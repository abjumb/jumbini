#!/usr/bin/env python3
"""Generate Jumbini's tiny 8-bit sound effects (pure stdlib, no deps).

"borf": a ~200ms square-wave yip with a fast pitch drop — a small dog
telling off the Dock. Quiet by design; he lives on your desktop all day.

Outputs 16-bit mono WAVs into Sources/Jumbini/Resources/audio/.
"""
import os
import struct
import wave

RATE = 44100

# ---------------------------------------------------------------- synthesis


def square(phase, duty=0.5):
    """Naive square oscillator: +1 for the duty part of the cycle, else -1."""
    return 1.0 if (phase % 1.0) < duty else -1.0


def envelope(t, duration, attack=0.008, release=0.06):
    """Linear attack, flat middle, linear release — no clicks at the ends."""
    if t < attack:
        return t / attack
    if t > duration - release:
        return max(0.0, (duration - t) / release)
    return 1.0


def borf(duration=0.2, f_start=660.0, f_end=180.0, duty=0.42, volume=0.16):
    """The bark: a square wave whose pitch drops fast (exponential glide),
    which reads as "borf!" rather than a beep. Quiet-ish (volume 0..1)."""
    samples = []
    phase = 0.0
    n = int(duration * RATE)
    for i in range(n):
        t = i / RATE
        # Exponential pitch drop: most of the fall happens up front.
        freq = f_start * (f_end / f_start) ** (t / duration)
        phase += freq / RATE
        s = square(phase, duty) * envelope(t, duration) * volume
        # 8-bit crunch: quantize amplitude to 256 levels before the 16-bit write.
        s = round(s * 127) / 127
        samples.append(s)
    return samples


# ---------------------------------------------------------------- output


def write_wav(path, samples):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)  # 16-bit
        w.setframerate(RATE)
        frames = b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples
        )
        w.writeframes(frames)
    print(f"wrote {path} ({len(samples) / RATE * 1000:.0f}ms)")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, "..", "Sources", "Jumbini", "Resources", "audio")
    write_wav(os.path.join(out, "borf.wav"), borf())
    write_wav(os.path.join(out, "squeak.wav"), squeak())


# ---------------------------------------------------------------- squeaky toy


def squeak_tone(duration, f_start, f_end, duty=0.22, volume=0.11):
    """One chirp: a thin (low duty) square gliding LINEARLY up in pitch —
    the sound of air forced through a rubber toy's reed, not a bark."""
    samples = []
    phase = 0.0
    for i in range(int(duration * RATE)):
        t = i / RATE
        freq = f_start + (f_end - f_start) * (t / duration)
        phase += freq / RATE
        s = square(phase, duty) * envelope(t, duration, attack=0.006, release=0.03) * volume
        samples.append(round(s * 127) / 127)
    return samples


def squeak():
    """The rubber chicken: EEK-eek, ~230ms. Two rising chirps, the second
    shorter, lower and quieter — the toy re-inflating after the first bite.
    Deliberately quieter than the bark; he does this a lot."""
    return (
        squeak_tone(0.11, 1150, 1750)
        + [0.0] * int(0.04 * RATE)
        + squeak_tone(0.08, 980, 1300, volume=0.075)
    )


if __name__ == "__main__":
    main()
