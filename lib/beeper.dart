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
  // Sounds to pick from, with their lengths so the gap is measured from the
  // end of a (possibly long, user-supplied) sound. The first is the beep
  // (or 1.mp3 / 2.mp3); the random sounds follow when "Random alarm" is on.
  List<(Source, Duration)> _lowChoices = [];
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
    _lowChoices = await _choices(_low, _lowSrc, randomAlarm ? randomLowAlarmSounds : const []);
    _loudChoices = await _choices(_loud, _loudSrc, randomAlarm ? randomLoudAlarmSounds : const []);
  }

  static Future<List<(Source, Duration)>> _choices(AudioPlayer player, Source main, List<String> extra) async {
    final out = <(Source, Duration)>[];
    for (final src in [main, ...extra.map(AssetSource.new)]) {
      try {
        await player.setSource(src);
        out.add((src, await player.getDuration() ?? Duration.zero));
      } catch (_) {
        // An unreadable sound is skipped.
      }
    }
    return out.isEmpty ? [(main, const Duration(seconds: 2))] : out;
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
          playLow(random: true);
        }
      case SpeedStatus.danger:
        if (escalated || now.difference(_last) >= _lastLen + gap) {
          _last = now;
          playLoud(random: true);
        }
    }
  }

  /// Alarm 1 (yellow); with [random], picked from all the yellow alarms.
  Future<void> playLow({bool random = false}) => _play(_low, _lowChoices, random);

  /// Alarm 2 (red); with [random], picked from all the red alarms.
  Future<void> playLoud({bool random = false}) => _play(_loud, _loudChoices, random);

  Future<void> _play(AudioPlayer player, List<(Source, Duration)> choices, bool random) async {
    if (choices.isEmpty) return;
    final (src, len) = random ? choices[_random.nextInt(choices.length)] : choices.first;
    _lastLen = len;
    await player.stop();
    await player.play(src, volume: 1.0);
  }
}
