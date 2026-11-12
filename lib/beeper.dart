import 'dart:math';

import 'package:audioplayers/audioplayers.dart';

import 'config.dart';
import 'road.dart';

/// Plays the warning sounds. Driven from GPS updates (about once a second)
/// rather than timers, so it keeps working while the app is in the
/// background: the location service is what keeps the app alive there.
class Beeper {
  /// Silence between the end of one beep and the start of the next.
  static const gap = Duration(seconds: 5);

  final _low = AudioPlayer();
  final _loud = AudioPlayer();
  Source _lowSrc = AssetSource('sounds/beep_low.wav');
  Source _loudSrc = AssetSource('sounds/beep_loud.wav');
  // Sound lengths, so the gap is measured from the end of a (possibly long,
  // user-supplied) sound.
  Duration _lowLen = Duration.zero;
  // Red alarms to pick from: the loud beep (or 2.mp3), plus the
  // randomAlarmSounds when "Random alarm" is on.
  List<(Source, Duration)> _loudChoices = [];
  Duration _lastLen = Duration.zero; // length of the sound played last
  final _random = Random();
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  SpeedStatus _prev = SpeedStatus.ok;

  /// [lowPath] / [loudPath]: user sound files (1.mp3 / 2.mp3) replacing
  /// the built-in beeps.
  Future<void> init({String? lowPath, String? loudPath, bool randomAlarm = false}) async {
    _lowSrc = lowPath != null ? DeviceFileSource(lowPath) : AssetSource('sounds/beep_low.wav');
    _loudSrc = loudPath != null ? DeviceFileSource(loudPath) : AssetSource('sounds/beep_loud.wav');
    // Alarm usage on Android: uses the alarm volume and is not muted with
    // media. Playback category on iOS: plays with the silent switch on and
    // ducks music instead of stopping it.
    final ctx = AudioContext(
      android: const AudioContextAndroid(
        usageType: AndroidUsageType.alarm,
        contentType: AndroidContentType.sonification,
        audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        stayAwake: true,
      ),
      iOS: AudioContextIOS(
        category: AVAudioSessionCategory.playback,
        options: const {AVAudioSessionOptions.duckOthers},
      ),
    );
    await AudioPlayer.global.setAudioContext(ctx);
    for (final p in [_low, _loud]) {
      await p.setAudioContext(ctx);
      await p.setReleaseMode(ReleaseMode.stop);
    }
    await _low.setSource(_lowSrc);
    _lowLen = await _low.getDuration() ?? Duration.zero;
    _loudChoices = [];
    for (final src in [_loudSrc, if (randomAlarm) ...randomAlarmSounds.map(AssetSource.new)]) {
      try {
        await _loud.setSource(src);
        _loudChoices.add((src, await _loud.getDuration() ?? Duration.zero));
      } catch (_) {
        // An unreadable sound is skipped; the loud beep is always first.
      }
    }
    if (_loudChoices.isEmpty) _loudChoices.add((_loudSrc, const Duration(seconds: 2)));
  }

  void update(SpeedStatus status) {
    final now = DateTime.now();
    final escalated = status.index > _prev.index;
    _prev = status;
    switch (status) {
      case SpeedStatus.ok:
        return;
      case SpeedStatus.warn:
        if (escalated || now.difference(_last) >= _lastLen + gap) {
          _last = now;
          playLow();
        }
      case SpeedStatus.danger:
        if (escalated || now.difference(_last) >= _lastLen + gap) {
          _last = now;
          playLoud(random: true);
        }
    }
  }

  Future<void> playLow() async {
    _lastLen = _lowLen;
    await _low.stop();
    await _low.play(_lowSrc, volume: 1.0);
  }

  /// The loud alarm, or with [random] one picked from all the red alarms.
  Future<void> playLoud({bool random = false}) async {
    final (src, len) = random ? _loudChoices[_random.nextInt(_loudChoices.length)] : _loudChoices.first;
    _lastLen = len;
    await _loud.stop();
    await _loud.play(src, volume: 1.0);
  }
}
