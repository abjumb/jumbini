"""Chiptune audio synthesis for Jumbini desktop-pet dog game.

Generates 11 WAV files: 22050 Hz, mono, 8-bit unsigned PCM.
Uses only numpy and stdlib wave.
"""
import wave
import numpy as np

SR = 22050
OUT = "/home/claude/jumbini-audio"

rng = np.random.default_rng(42)


def t(dur):
    return np.arange(int(SR * dur)) / SR


def square(freq_arr, tt):
    phase = 2 * np.pi * np.cumsum(freq_arr) / SR
    return np.sign(np.sin(phase))


def saw(freq_arr, tt):
    phase = np.cumsum(freq_arr) / SR
    return 2.0 * (phase % 1.0) - 1.0


def sine(freq_arr, tt):
    phase = 2 * np.pi * np.cumsum(freq_arr) / SR
    return np.sin(phase)


def env_ar(n, attack_s=0.005, release_s=0.02):
    """Linear attack/release envelope to avoid clicks."""
    e = np.ones(n)
    a = max(1, int(attack_s * SR))
    r = max(1, int(release_s * SR))
    a = min(a, n)
    r = min(r, n)
    e[:a] = np.linspace(0, 1, a)
    e[-r:] *= np.linspace(1, 0, r)
    return e


def decay_env(n, power=3.0):
    return np.linspace(1, 0, n) ** power


def lowpass(x, alpha=0.1):
    """Simple one-pole low-pass."""
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc += alpha * (v - acc)
        y[i] = acc
    return y


def write_wav(name, x, peak=0.8):
    x = np.asarray(x, dtype=np.float64)
    m = np.max(np.abs(x))
    if m > 0:
        x = x * (peak / m)
    # quantize to 8-bit unsigned PCM
    q = np.clip(np.round(x * 127.0 + 128.0), 0, 255).astype(np.uint8)
    path = f"{OUT}/{name}"
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(1)
        w.setframerate(SR)
        w.writeframes(q.tobytes())
    print(f"wrote {name}: {len(q)} frames, {1000*len(q)/SR:.1f} ms")


# ---------- 1. barks ----------
def make_bark(base_scale, seed):
    r = np.random.default_rng(seed)
    burst_dur = 0.080
    gap = 0.030
    parts = []
    for i in range(2):
        tt = t(burst_dur)
        n = len(tt)
        f0 = 800 * base_scale * (1.0 + 0.03 * i)
        f1 = 350 * base_scale
        freq = f0 + (f1 - f0) * (tt / burst_dur)
        sig = square(freq, tt)
        noise = r.standard_normal(n) * 0.18
        burst = (sig + noise) * env_ar(n, 0.003, 0.025) * decay_env(n, 1.2)
        parts.append(burst)
        if i == 0:
            parts.append(np.zeros(int(gap * SR)))
    return np.concatenate(parts)


write_wav("bark1.wav", make_bark(1.00, 1))   # base pitch
write_wav("bark2.wav", make_bark(1.15, 2))   # +15%
write_wav("bark3.wav", make_bark(0.87, 3))   # -13%

# ---------- 2. growl ----------
dur = 0.55
tt = t(dur)
n = len(tt)
freq = np.full(n, 80.0) + 5.0 * np.sin(2 * np.pi * 1.5 * tt)  # slight pitch drift
sig = saw(freq, tt)
tremolo = 0.65 + 0.35 * np.sin(2 * np.pi * 8.0 * tt)
noise = lowpass(rng.standard_normal(n), alpha=0.08) * 1.2
growl = (sig + noise) * tremolo * env_ar(n, 0.03, 0.08)
write_wav("growl.wav", growl)

# ---------- 3. yip ----------
dur = 0.15
tt = t(dur)
n = len(tt)
# rise 600 -> 1200 over first 60%, fall to 800 over rest
rise_n = int(n * 0.6)
freq = np.empty(n)
freq[:rise_n] = np.linspace(600, 1200, rise_n)
freq[rise_n:] = np.linspace(1200, 800, n - rise_n)
yip = square(freq, tt) * env_ar(n, 0.004, 0.03) * decay_env(n, 0.7)
write_wav("yip.wav", yip)

# ---------- 4. whine ----------
dur = 0.40
tt = t(dur)
n = len(tt)
base = np.linspace(900, 400, n)
vib = 12.0 * np.sin(2 * np.pi * 6.0 * tt)  # slight vibrato
whine = sine(base + vib, tt) * env_ar(n, 0.02, 0.06)
write_wav("whine.wav", whine)

# ---------- 5. squeak ----------
sq1_dur = 0.20
tt = t(sq1_dur)
n = len(tt)
f = 1800 + 250 * np.sin(2 * np.pi * 35.0 * tt)  # strong fast vibrato
sq1 = sine(f, tt) * env_ar(n, 0.002, 0.04)  # quick attack
gap = np.zeros(int(0.04 * SR))
sq2_dur = 0.10
tt2 = t(sq2_dur)
n2 = len(tt2)
f2 = 1200 + 180 * np.sin(2 * np.pi * 30.0 * tt2)
sq2 = sine(f2, tt2) * env_ar(n2, 0.003, 0.03) * 0.7
write_wav("squeak.wav", np.concatenate([sq1, gap, sq2]))

# ---------- 6. grunt ----------
dur = 0.20
tt = t(dur)
n = len(tt)
bn = lowpass(rng.standard_normal(n), alpha=0.25)  # band-limited-ish noise
bn = bn - lowpass(bn, alpha=0.02)                 # remove lowest rumble -> band-limited
sq = square(np.full(n, 120.0), tt) * 0.8
grunt = (bn * 1.4 + sq) * env_ar(n, 0.008, 0.05) * decay_env(n, 0.8)
write_wav("grunt.wav", grunt)

# ---------- 7. chime ----------
notes = [523.25, 659.25, 783.99]  # C5 E5 G5
note_dur = 0.12
parts = []
for f0 in notes:
    tt = t(note_dur)
    nn = len(tt)
    tone = square(np.full(nn, f0), tt) * env_ar(nn, 0.003, 0.02) * decay_env(nn, 1.5)
    parts.append(tone)
# small release tail on last note already handled by envelope
write_wav("chime.wav", np.concatenate(parts))

# ---------- 8. shutter ----------
click_dur = 0.015
gap = 0.060
c1 = rng.standard_normal(int(click_dur * SR))
c1 *= env_ar(len(c1), 0.001, 0.005)
c2 = rng.standard_normal(int(click_dur * SR)) * 0.5
c2 *= env_ar(len(c2), 0.001, 0.005)
silence = np.zeros(int(gap * SR))
write_wav("shutter.wav", np.concatenate([c1, silence, c2]))

print("done")
