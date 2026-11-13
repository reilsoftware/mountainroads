#!/bin/sh
# Peak-normalise the Random alarm sounds to match the built-in beeps:
# alarm 1 sounds peak at 60% (-4.4 dB, like 1.mp3), alarm 2 sounds at 85%
# (-1.4 dB, like 2.mp3). Usage: tools/normalize_random.sh <folder of originals>
set -e
SRC=${1:?folder with the original mp3s}
OUT=$(dirname "$0")/../assets/sounds/random
norm() { # file target_dB
  peak=$(ffmpeg -hide_banner -i "$SRC/$1" -af volumedetect -f null - 2>&1 | sed -n 's/.*max_volume: \(-*[0-9.]*\) dB/\1/p')
  gain=$(echo "$2 - ($peak)" | bc)
  ffmpeg -hide_banner -loglevel error -y -i "$SRC/$1" -af "volume=${gain}dB,alimiter=limit=1:level=false" -c:a libmp3lame -q:a 2 "$OUT/$1"
  echo "$1: peak $peak dB, gain $gain dB"
}
norm mein-leben.mp3 -4.4
norm fallout-sirene.mp3 -4.4
norm r2d2_scream_converted.mp3 -1.4
norm red-siren-alert.mp3 -1.4
norm firebat-slow-down.mp3 -1.4
