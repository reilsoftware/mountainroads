#!/bin/sh
# Build the Android release and copy it to dist/MountainRoad.apk.
set -e
cd "$(dirname "$0")/.."
flutter build apk --release
mkdir -p dist
cp build/app/outputs/flutter-apk/app-release.apk dist/MountainRoad.apk
echo "dist/MountainRoad.apk"
