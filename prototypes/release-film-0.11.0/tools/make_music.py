"""Original 30 s upbeat bed for the msgblast 0.11 vertical cut. 120 BPM, C major, I-V-vi-IV.
Writes public/audio/music.wav. Pure numpy synthesis, no samples."""
import numpy as np, wave, sys
SR = 48000
DUR = 30.0
BPM = 120
BEAT = 60 / BPM
N = int(SR * DUR)
out = np.zeros((N, 2))
rng = np.random.default_rng(11)

def add(sig, t, pan=0.0, gain=1.0):
    i = int(t * SR)
    if i >= N: return
    sig = sig[: N - i] * gain
    out[i:i + len(sig), 0] += sig * (1 - max(0, pan))
    out[i:i + len(sig), 1] += sig * (1 + min(0, pan))

def env(n, a=0.005, d=0.2, s=0.0, r=0.05, hold=None):
    t = np.arange(n) / SR
    e = np.minimum(1, t / a) if a > 0 else np.ones(n)
    dec = s + (1 - s) * np.exp(-np.maximum(0, t - a) / d)
    e = e * dec
    if hold is not None:
        rel = np.clip((t - hold) / r, 0, 1)
        e *= (1 - rel)
    return e

def kick():
    n = int(0.35 * SR); t = np.arange(n) / SR
    f = 50 + 120 * np.exp(-t * 30)
    ph = 2 * np.pi * np.cumsum(f) / SR
    return np.sin(ph) * np.exp(-t * 9) * 1.0 + np.tanh(np.sin(ph) * 3) * np.exp(-t * 25) * 0.2

def clap():
    n = int(0.25 * SR); t = np.arange(n) / SR
    nz = rng.standard_normal(n)
    # band-ish: difference filter
    nz = np.convolve(nz, [1, 0, -1], 'same')
    e = np.exp(-t * 22) + 0.6 * np.exp(-((t - 0.012) % 0.012) * 300) * (t < 0.036)
    return nz * e * 0.35

def hat(open_=False):
    n = int((0.18 if open_ else 0.05) * SR); t = np.arange(n) / SR
    nz = rng.standard_normal(n); nz = nz - np.convolve(nz, np.ones(4) / 4, 'same')
    return nz * np.exp(-t * (18 if open_ else 80)) * 0.22

def note_freq(m): return 440 * 2 ** ((m - 69) / 12)

def saw(f, n, detune=0.0):
    t = np.arange(n) / SR
    s = 0
    for d in (-detune, 0, detune):
        s = s + 2 * ((t * f * (1 + d)) % 1) - 1
    return s / 3

def lowpass(x, cutoff):
    a = np.exp(-2 * np.pi * cutoff / SR)
    y = np.zeros_like(x); acc = 0.0
    for i in range(len(x)):
        acc = (1 - a) * x[i] + a * acc; y[i] = acc
    return y

def bass(m, dur):
    n = int(dur * SR); f = note_freq(m)
    t = np.arange(n) / SR
    s = np.sin(2 * np.pi * f * t) + 0.35 * np.sign(np.sin(2 * np.pi * f * t)) * 0.5
    return lowpass(s, 600) * env(n, 0.004, 0.25, 0.6, 0.03, hold=dur - 0.03) * 0.55

def stab(ms, dur, cutoff=2200):
    n = int(dur * SR)
    s = sum(saw(note_freq(m), n, 0.006) for m in ms) / len(ms)
    return lowpass(s, cutoff) * env(n, 0.003, 0.12, 0.25, 0.04, hold=dur - 0.04) * 0.5

def pad(ms, dur, cutoff=1200):
    n = int(dur * SR)
    s = sum(saw(note_freq(m), n, 0.01) for m in ms) / len(ms)
    t = np.arange(n) / SR
    e = np.minimum(1, t / 0.3) * np.minimum(1, (dur - t) / 0.3)
    return lowpass(s, cutoff) * e * 0.28

def pluck(m, dur=0.22):
    n = int(dur * SR); t = np.arange(n) / SR; f = note_freq(m)
    s = np.sin(2 * np.pi * f * t + 1.5 * np.exp(-t * 20) * np.sin(2 * np.pi * f * 2 * t))
    return s * np.exp(-t * 14) * 0.28

def riser(dur):
    n = int(dur * SR); t = np.arange(n) / SR
    nz = rng.standard_normal(n)
    nz = nz - np.convolve(nz, np.ones(8) / 8, 'same')
    return nz * (t / dur) ** 2 * 0.25

# chords per bar (2 s): C G Am F, voiced around middle C
CH = [[60, 64, 67, 72], [59, 62, 67, 71], [57, 60, 64, 69], [57, 60, 65, 69]]
ROOT = [36, 43, 45, 41]
bars = int(DUR / (4 * BEAT))

DROP1, BREAK, DROP2, END = 2.0, 22.0, 23.0, 28.0
for b in range(bars):
    t0 = b * 4 * BEAT
    ci = b % 4
    # pad everywhere, brighter in drops
    in_drop = (DROP1 <= t0 < BREAK) or (DROP2 <= t0 < END)
    add(pad(CH[ci], 4 * BEAT, 1800 if in_drop else 900), t0, gain=1.0 if in_drop else 1.3)
    for beat in range(4):
        tb = t0 + beat * BEAT
        # arpeggio plucks on 8ths everywhere except the very end
        if tb < END:
            for k in range(2):
                m = CH[ci][(beat * 2 + k) % 4] + 12
                add(pluck(m), tb + k * BEAT / 2, pan=(-0.4 if k else 0.4), gain=0.9 if in_drop else 0.7)
        beat_drop = (DROP1 <= tb < BREAK) or (DROP2 <= tb < END)
        if not beat_drop:
            continue
        add(kick(), tb, gain=0.95)
        if beat in (1, 3):
            add(clap(), tb, gain=0.9)
        add(hat(), tb + BEAT / 2, pan=0.3)
        add(hat(), tb + BEAT / 4, pan=-0.3, gain=0.4)
        add(hat(), tb + 3 * BEAT / 4, pan=-0.3, gain=0.4)
        # bass: offbeat pumping 8ths
        add(bass(ROOT[ci], BEAT / 2 - 0.02), tb + BEAT / 2)
        add(bass(ROOT[ci] + 12, BEAT / 4), tb + 0.0, gain=0.4)
        # stabs on the "and" of 2 and on 4
        if beat in (1, 3):
            add(stab([m + 12 for m in CH[ci][:3]], BEAT / 2.5), tb + (BEAT / 2 if beat == 1 else 0), gain=0.5)

# risers into each drop
add(riser(DROP1 - 0.2), 0.2, gain=0.45)
add(riser(1.0), DROP2 - 1.0, gain=0.55)
# final hit and ring out
add(kick(), END, gain=1.1)
add(clap(), END, gain=0.8)
add(pad(CH[0] + [79], 2.0, 2400), END, gain=1.4)
add(bass(36, 1.6), END, gain=1.0)
add(pluck(84, 1.5), END, gain=1.0)

# gentle master: soft clip, normalize, fade out tail
out = np.tanh(out * 1.4)
out /= np.max(np.abs(out)) + 1e-9
out *= 0.89
fade = int(0.6 * SR)
out[-fade:] *= np.linspace(1, 0, fade)[:, None]

path = sys.argv[1] if len(sys.argv) > 1 else 'public/audio/music.wav'
with wave.open(path, 'wb') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes((out * 32767).astype('<i2').tobytes())
print('wrote', path)
