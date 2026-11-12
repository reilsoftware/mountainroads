import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import 'beeper.dart';
import 'config.dart';
import 'road.dart';

/// Further than this from the mountain roads, location is checked rarely and
/// coarsely to save battery.
const double sleepDistanceM = 1000;

/// In sleep mode, how often to check position. At 100 km/h a car covers
/// ~550 m in 20 s, so it wakes well before reaching the road.
const Duration sleepInterval = Duration(seconds: 20);

class TrackerState {
  final double? speedKmh;
  final double? distanceM;
  final double? limitKmh;
  final bool onRoad;
  final SpeedStatus status;
  final bool sleeping;
  final String? error;

  const TrackerState({
    this.speedKmh,
    this.distanceM,
    this.limitKmh,
    this.onRoad = false,
    this.status = SpeedStatus.ok,
    this.sleeping = false,
    this.error,
  });

  bool get hasFix => distanceM != null;

  Map<String, dynamic> toMap() => {
    'speedKmh': speedKmh,
    'distanceM': distanceM,
    'limitKmh': limitKmh,
    'onRoad': onRoad,
    'status': status.index,
    'sleeping': sleeping,
    'error': error,
  };

  factory TrackerState.fromMap(Map<String, dynamic> m) => TrackerState(
    speedKmh: (m['speedKmh'] as num?)?.toDouble(),
    distanceM: (m['distanceM'] as num?)?.toDouble(),
    limitKmh: (m['limitKmh'] as num?)?.toDouble(),
    onRoad: m['onRoad'] == true,
    status: SpeedStatus.values[(m['status'] as int?) ?? 0],
    sleeping: m['sleeping'] == true,
    error: m['error'] as String?,
  );

  /// One line for the Android notification (no speed, so it changes rarely).
  String get summary {
    if (error != null) return error!;
    if (!hasFix) return 'Waiting for GPS…';
    if (onRoad) return 'On the mountain road · limit ${limitKmh!.round()} km/h';
    return 'Mountain road ${formatDistance(distanceM!)} away${sleeping ? ' · low power' : ''}';
  }
}

String formatDistance(double m) => m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(m < 10000 ? 1 : 0)} km';

/// Watches position, matches it to the mountain roads and beeps when
/// speeding. Runs in the Android background service, or in the app on iOS.
class Tracker {
  final void Function(TrackerState) onState;
  final _beeper = Beeper();
  Road? _road;
  StreamSubscription<Position>? _sub;
  bool? _sleeping;
  AppConfig config = const AppConfig();
  DateTime? _overSince; // when the driver went over the limit
  bool _waitingForLocation = false;
  bool _forceLocationManager = false; // set if the fused provider refuses
  bool _visible = false; // app on screen: always full GPS so speed shows
  Position? _lastPos; // for speed when the fix has none
  TrackerState state = const TrackerState();

  Tracker(this.onState);

  Future<void> start() async {
    try {
      await reload();
      // Start awake so the first fix is quick; the first fix picks the mode.
      await _listen(sleeping: false);
    } catch (e) {
      _emit(TrackerState(error: '$e'));
    }
  }

  /// Re-read /sdcard/MountainRoads (sounds, warning delay, ruta41.txt).
  Future<void> reload() async {
    config = await AppConfig.load();
    _road = Road.fromJson(await rootBundle.loadString('assets/road.json'), optional: {if (config.ruta41) 'ruta41'});
    await _beeper.init(lowPath: config.lowSoundPath, loudPath: config.loudSoundPath, randomAlarm: config.randomAlarm);
    _sleeping = null; // re-pick the GPS mode on the next fix
    if (_sub != null) {
      // Google Location Accuracy may have been turned on: try the fused
      // provider again (it falls back to GPS by itself if still refused).
      _forceLocationManager = false;
      Future(() => _listen(sleeping: false));
    }
  }

  /// The app is on screen (or not). On screen, GPS stays at full rate
  /// even far from the mountain roads, so the speed always shows.
  void setVisible(bool visible) {
    if (visible == _visible) return;
    _visible = visible;
    if (_sub != null && visible && _sleeping == true) Future(() => _listen(sleeping: false));
    // Going off screen: the next fix picks low power again if far away.
    if (!visible) _sleeping = null;
  }

  Future<void> testSound() async {
    await _beeper.playLow();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await _beeper.playLoud();
  }

  /// (Re)open the position stream. Must not run inside a position event:
  /// geolocator caches its stream until the old one is fully cancelled, and
  /// a cancel during event delivery is deferred, so new settings would be
  /// ignored. Callers schedule it with [Future] and it awaits the cancel.
  Future<void> _listen({required bool sleeping}) async {
    _sleeping = sleeping;
    final old = _sub;
    _sub = null;
    await old?.cancel();
    _sub = Geolocator.getPositionStream(locationSettings: _settings(sleeping)).listen(_onPosition, onError: _onError);
  }

  /// The position stream ends on errors such as Location being switched off.
  /// Show why, then restart as soon as Location is back on (checked on every
  /// service change, and every 15 s in case a change is missed).
  void _onError(Object e) {
    if (e is LocationServiceDisabledException && !_forceLocationManager) {
      // Google's fused provider also reports this when Location is on but its
      // accuracy setting ("Google Location Accuracy") is off. Fall back to
      // Android's own GPS, which doesn't need that setting.
      Geolocator.isLocationServiceEnabled().then((on) {
        if (!on) return _waitForLocation(e);
        _forceLocationManager = true;
        Future(() => _listen(sleeping: _sleeping ?? false));
      });
      return;
    }
    _waitForLocation(e);
  }

  void _waitForLocation(Object e) {
    _emit(
      TrackerState(
        error: e is LocationServiceDisabledException ? 'Location is off. Turn on Location in quick settings.' : '$e',
      ),
    );
    if (_waitingForLocation) return;
    _waitingForLocation = true;
    StreamSubscription<ServiceStatus>? statusSub;
    Timer? poll;
    Future<void> retry() async {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      await statusSub?.cancel();
      poll?.cancel();
      _waitingForLocation = false;
      _emit(const TrackerState());
      await _listen(sleeping: false);
    }

    statusSub = Geolocator.getServiceStatusStream().listen((_) => retry());
    poll = Timer.periodic(const Duration(seconds: 15), (_) => retry());
  }

  LocationSettings _settings(bool sleeping) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      // The background service is already a foreground service, so no
      // foregroundNotificationConfig here.
      return sleeping
          ? AndroidSettings(
              accuracy: LocationAccuracy.medium,
              intervalDuration: sleepInterval,
              forceLocationManager: _forceLocationManager,
            )
          : AndroidSettings(
              accuracy: LocationAccuracy.bestForNavigation,
              intervalDuration: const Duration(seconds: 1),
              forceLocationManager: _forceLocationManager,
            );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: sleeping ? LocationAccuracy.medium : LocationAccuracy.bestForNavigation,
        distanceFilter: sleeping ? 200 : 0,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      );
    }
    return const LocationSettings(accuracy: LocationAccuracy.best);
  }

  void _onPosition(Position p) {
    final speed = _speedKmh(p);
    final match = _road!.match(p.latitude, p.longitude);
    final status = speed != null && match.onRoad ? classify(speed, match.limitKmh, config.thresholds) : SpeedStatus.ok;
    // The screen changes straight away; the sound waits until the driver has
    // been over the limit for the configured delay (10/20SecondsWarning.txt).
    final now = DateTime.now();
    if (status == SpeedStatus.ok) {
      _overSince = null;
    } else {
      _overSince ??= now;
    }
    final overFor = _overSince == null ? Duration.zero : now.difference(_overSince!);
    _beeper.update(overFor.inSeconds >= config.alarmDelaySeconds ? status : SpeedStatus.ok);
    final sleep = match.distanceM > sleepDistanceM && !_visible;
    if (sleep != _sleeping) {
      _sleeping = sleep;
      Future(() => _listen(sleeping: sleep));
    }
    _emit(
      TrackerState(
        speedKmh: speed,
        distanceM: match.distanceM,
        limitKmh: match.limitKmh,
        onRoad: match.onRoad,
        status: status,
        sleeping: sleep,
      ),
    );
  }

  /// GPS speed, or (when the fix has none, e.g. a network fix) the distance
  /// from the previous fix over the time between them.
  double? _speedKmh(Position p) {
    final prev = _lastPos;
    _lastPos = p;
    if (p.speed >= 0 && (p.speedAccuracy <= 0 || p.speedAccuracy < 10)) return p.speed * 3.6;
    if (prev == null) return p.speed >= 0 ? p.speed * 3.6 : null;
    final secs = p.timestamp.difference(prev.timestamp).inMilliseconds / 1000;
    if (secs <= 0 || secs > 60) return p.speed >= 0 ? p.speed * 3.6 : null;
    final m = Geolocator.distanceBetween(prev.latitude, prev.longitude, p.latitude, p.longitude);
    // Ignore jitter smaller than the two fixes' accuracy.
    if (m < p.accuracy + prev.accuracy) return 0;
    return m / secs * 3.6;
  }

  void _emit(TrackerState s) {
    state = s;
    onState(s);
  }
}
