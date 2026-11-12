import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'road.dart';

/// User-editable settings folder on Android (needs "All files access").
const configDir = '/sdcard/MountainRoads';

/// Okabe–Ito colours (Wong, Nature Methods 2011), distinguishable with the
/// common forms of colour blindness: blue, yellow, vermillion.
const colorBlindDefaults = '#0072B2,#F0E442,#D55E00';

const _soundExts = ['mp3', 'wav', 'm4a', 'ogg'];

/// Size of the quieter alarm 1 of the first test builds: a 1.mp3 of exactly
/// this size is that old default and is replaced by the louder one.
const _oldDefaultLowMp3Bytes = 5850;

/// Sounds the "Random alarm" setting mixes in with the loud alarm.
const randomAlarmSounds = [
  'sounds/random/mein-leben.mp3',
  'sounds/random/r2d2_scream_converted.mp3',
  'sounds/random/fallout-sirene.mp3',
  'sounds/random/red-siren-alert.mp3',
  'sounds/random/firebat-slow-down.mp3',
];

const _randomAlarmKey = 'randomAlarm';

/// The "Random alarm" switch in Settings (kept in the app, not the folder).
Future<bool> loadRandomAlarm() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload(); // may have been changed by the other isolate
  return prefs.getBool(_randomAlarmKey) ?? false;
}

Future<void> saveRandomAlarm(bool on) async => (await SharedPreferences.getInstance()).setBool(_randomAlarmKey, on);

/// The ReadMe shown in Settings and written to the folder. Settings always
/// shows this built-in copy, never the file on the SD card.
const readMeText =
    '''Mountain Roads settings folder
===============================

The app reads these files when it starts (and when you tap "Reload" in
Settings). Delete a file to go back to the default.

1.mp3   Sound for "more than 10% over the limit" (yellow). Replace it with
        your own sound. 1.wav, 1.m4a or 1.ogg also work.
2.mp3   Sound for "more than 20% over the limit" (red). Same rules as 1.mp3.

0SecondsWarning.txt   Beep as soon as you are over the limit.
        Rename it to 10SecondsWarning.txt or 20SecondsWarning.txt to beep
        only after you have been over the limit for 10 or 20 seconds.
        The screen still changes straight away.

ruta41_off.txt   The speed alarm starts at Control Puerta.
        Rename it to ruta41_on.txt (or ruta41.txt) to start the alarm at
        La Serena airport and cover Ruta 41 to Control Puerta. Contents do
        not matter.

1020percent.txt   When the alarms start. The first two digits are the
        yellow alarm, the last two the red alarm. Rename it to change them:
          1020percent.txt  over 10% / over 20% of the limit (default)
          1530percent.txt  over 15% / over 30%
          0510percent.txt  over 5% / over 10%
          1020.txt         over 10 km/h / over 20 km/h
          0510.txt, 0515.txt, ...  km/h over the limit, same pattern

SpeedZones.png         Map of the speed limits from Control Puerta.
SpeedZones_Ruta41.png  Map including Ruta 41 from La Serena airport.
        (Both are rewritten by the app; changes to them are not kept.)

ColorBlind.txt   If this file exists, its first line sets the three screen
        colours as hex codes: normal,over-10%,over-20%
        For example: $colorBlindDefaults
        An empty file is filled with colour-blind-friendly defaults.

Random alarm   A switch in Settings (off by default). When on, the red
        alarm is picked at random from the loud beep (or your 2.mp3) and
        five fun sounds built into the app.

Privacy
-------
This application is developed solely to assist the driver in maintaining
proper speed. This application will never send data to the internet and
never record, transmit or share any information with anyone.
(The Android app does not even have permission to use the internet. Your
position and speed are only kept in memory while it runs.)

The required permissions are used so your phone can stay in your pocket
and still alarm you if you are going too fast. When you are not on the
Mountain Roads the app is in a sleep-like mode (GPS off, rough position
checked every 20 seconds).
''';

class AppConfig {
  final String? lowSoundPath;
  final String? loudSoundPath;
  final int alarmDelaySeconds;
  final bool ruta41;
  final Thresholds thresholds;
  final bool randomAlarm;

  /// Normal, warn and danger colours from ColorBlind.txt, if present.
  final List<Color>? colors;
  final bool folderAvailable;

  const AppConfig({
    this.lowSoundPath,
    this.loudSoundPath,
    this.alarmDelaySeconds = 0,
    this.ruta41 = false,
    this.thresholds = Thresholds.standard,
    this.randomAlarm = false,
    this.colors,
    this.folderAvailable = false,
  });

  /// Reads the settings folder, creating the default files first. Without
  /// storage access (or off Android) this returns the built-in defaults.
  static Future<AppConfig> load() async {
    final random = await loadRandomAlarm().catchError((_) => false);
    if (defaultTargetPlatform != TargetPlatform.android) return AppConfig(randomAlarm: random);
    try {
      final dir = Directory(configDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      await _writeDefaults();
      return AppConfig(
        lowSoundPath: _find('1'),
        loudSoundPath: _find('2'),
        alarmDelaySeconds: _exists('20SecondsWarning.txt')
            ? 20
            : _exists('10SecondsWarning.txt')
            ? 10
            : 0,
        ruta41: _exists('ruta41.txt') || _exists('ruta41_on.txt'),
        thresholds: _readThresholds(),
        randomAlarm: random,
        colors: _readColors(),
        folderAvailable: true,
      );
    } on FileSystemException {
      return AppConfig(randomAlarm: random);
    }
  }

  static bool _exists(String name) => File('$configDir/$name').existsSync();

  /// From a file like 1530percent.txt or 0510.txt. If there are several, one
  /// other than the default 1020percent.txt wins.
  static Thresholds _readThresholds() {
    final found = <Thresholds>[];
    for (final f in Directory(configDir).listSync().whereType<File>()) {
      final t = Thresholds.fromFileName(f.uri.pathSegments.last);
      if (t != null) found.add(t);
    }
    found.sort((a, b) => a.fileName.compareTo(b.fileName));
    return found.firstWhere((t) => t.fileName != Thresholds.standard.fileName, orElse: () => Thresholds.standard);
  }

  static String? _find(String base) {
    for (final ext in _soundExts) {
      if (_exists('$base.$ext')) return '$configDir/$base.$ext';
    }
    return null;
  }

  static Future<void> _writeDefaults() async {
    File('$configDir/ReadMe.txt').writeAsStringSync(readMeText);
    // App-owned files: refreshed every start so they match this version.
    for (final (asset, name) in [
      ('docs/speed_zones.png', 'SpeedZones.png'),
      ('docs/speed_zones_ruta41.png', 'SpeedZones_Ruta41.png'),
    ]) {
      final bytes = await rootBundle.load(asset);
      File('$configDir/$name').writeAsBytesSync(bytes.buffer.asUint8List());
    }
    final oldLow = File('$configDir/1.mp3');
    if (oldLow.existsSync() && oldLow.lengthSync() == _oldDefaultLowMp3Bytes) oldLow.deleteSync();
    for (final (base, asset) in [('1', 'beep_low'), ('2', 'beep_loud')]) {
      if (_find(base) == null) {
        final bytes = await rootBundle.load('assets/sounds/$asset.mp3');
        File('$configDir/$base.mp3').writeAsBytesSync(bytes.buffer.asUint8List());
      }
    }
    if (!['0', '10', '20'].any((n) => _exists('${n}SecondsWarning.txt'))) {
      File('$configDir/0SecondsWarning.txt').writeAsStringSync('');
    }
    if (!['ruta41.txt', 'ruta41_on.txt', 'ruta41_off.txt'].any(_exists)) {
      File('$configDir/ruta41_off.txt').writeAsStringSync('');
    }
    final dir = Directory(configDir).listSync().map((f) => f.uri.pathSegments.last);
    if (!dir.any((n) => Thresholds.fromFileName(n) != null)) {
      File('$configDir/${Thresholds.standard.fileName}').writeAsStringSync('');
    }
    final cb = File('$configDir/ColorBlind.txt');
    if (cb.existsSync() && cb.readAsStringSync().trim().isEmpty) {
      cb.writeAsStringSync('$colorBlindDefaults\n');
    }
  }

  static List<Color>? _readColors() {
    final f = File('$configDir/ColorBlind.txt');
    if (!f.existsSync()) return null;
    final line = f.readAsLinesSync().map((l) => l.trim()).firstWhere((l) => l.contains(','), orElse: () => '');
    final colors = parseColors(line);
    return colors ?? parseColors(colorBlindDefaults);
  }
}

/// "#0072B2,#F0E442,#D55E00" -> three colours, or null if malformed.
List<Color>? parseColors(String line) {
  final parts = line.split(',').map((p) => p.trim().replaceFirst('#', '')).toList();
  if (parts.length < 3) return null;
  final out = <Color>[];
  for (final p in parts.take(3)) {
    final v = int.tryParse(p.length == 6 ? 'FF$p' : p, radix: 16);
    if (v == null || (p.length != 6 && p.length != 8)) return null;
    out.add(Color(v));
  }
  return out;
}
