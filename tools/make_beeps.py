#!/usr/bin/env python3
"""Generate the warning sounds in assets/sounds/ (standard library only)."""
import math
import struct
import wave
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "assets" / "sounds"
RATE = 44_100


def tone(path, freq, seconds, amplitude, harmonics=1, pulses=1, pause=0.0):
    """pulses beeps of `seconds` each, `pause` s apart, peaking at
    `amplitude` (fraction of full scale)."""
    n = int(RATE * seconds)
    fade = int(RATE * 0.01)
    samples = []
    for k_pulse in range(pulses):
        if k_pulse:
            samples += [0.0] * int(RATE * pause)
        for i in range(n):
            t = i / RATE
            # Odd harmonics make a harsher, more noticeable sound.
            s = sum(math.sin(2 * math.pi * freq * k * t) / k for k in range(1, 2 * harmonics, 2))
            samples.append(min(1.0, i / fade, (n - i) / fade) * s)
    scale = amplitude / max(abs(s) for s in samples)
    frames = b"".join(struct.pack("<h", int(32767 * scale * s)) for s in samples)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(frames)


OUT.mkdir(parents=True, exist_ok=True)
# Alarm 1: double beep near 900 Hz (where phone speakers are loudest), peaking
# at 60% of full scale so it stays well below alarm 2.
tone(OUT / "beep_low.wav", 880, 0.25, 0.6, harmonics=3, pulses=2, pause=0.12)
tone(OUT / "beep_loud.wav", 1000, 1.20, 0.848, harmonics=3)
print("wrote", *sorted(p.name for p in OUT.iterdir()))

# MP3 copies are what the app writes to /sdcard/MountainRoads as 1.mp3 / 2.mp3
# (needs the `lame` encoder: brew install lame).
import shutil
import subprocess

if shutil.which("lame"):
    for name in ("beep_low", "beep_loud"):
        subprocess.run(["lame", "--quiet", "-b", "128", str(OUT / f"{name}.wav"), str(OUT / f"{name}.mp3")], check=True)
    print("wrote", *sorted(p.name for p in OUT.iterdir()))
