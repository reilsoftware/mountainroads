#!/usr/bin/env python3
"""Generate the warning sounds in assets/sounds/ (standard library only)."""
import math
import struct
import wave
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "assets" / "sounds"
RATE = 44_100


def tone(path, freq, seconds, amplitude, harmonics=1, pulses=1, pause=0.0):
    """pulses beeps of `seconds` each, `pause` s apart."""
    n = int(RATE * seconds)
    fade = int(RATE * 0.01)
    frames = bytearray()
    for k_pulse in range(pulses):
        if k_pulse:
            frames += b"\0\0" * int(RATE * pause)
        for i in range(n):
            t = i / RATE
            # Odd harmonics make a harsher, more noticeable sound.
            s = sum(math.sin(2 * math.pi * freq * k * t) / k for k in range(1, 2 * harmonics, 2))
            env = min(1.0, i / fade, (n - i) / fade)
            frames += struct.pack("<h", max(-32767, min(32767, int(32767 * amplitude * env * s / 1.1))))
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(frames)


OUT.mkdir(parents=True, exist_ok=True)
# Alarm 1: full volume double beep near 900 Hz, where phone speakers are loudest.
tone(OUT / "beep_low.wav", 880, 0.25, 1.0, harmonics=3, pulses=2, pause=0.12)
tone(OUT / "beep_loud.wav", 1000, 1.20, 1.0, harmonics=3)
print("wrote", *sorted(p.name for p in OUT.iterdir()))

# MP3 copies are what the app writes to /sdcard/MountainRoads as 1.mp3 / 2.mp3
# (needs the `lame` encoder: brew install lame).
import shutil
import subprocess

if shutil.which("lame"):
    for name in ("beep_low", "beep_loud"):
        subprocess.run(["lame", "--quiet", "-b", "128", str(OUT / f"{name}.wav"), str(OUT / f"{name}.mp3")], check=True)
    print("wrote", *sorted(p.name for p in OUT.iterdir()))
