import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'config.dart';
import 'patterns.dart';
import 'road.dart';
import 'service.dart';
import 'settings.dart';
import 'tracker.dart';

bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

void main() => runApp(const MountainRoadsApp());

class MountainRoadsApp extends StatelessWidget {
  const MountainRoadsApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Mountain Roads',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
    home: const SpeedScreen(),
  );
}

class SpeedScreen extends StatefulWidget {
  const SpeedScreen({super.key});

  @override
  State<SpeedScreen> createState() => _SpeedScreenState();
}

class _SpeedScreenState extends State<SpeedScreen> with WidgetsBindingObserver {
  TrackerState _state = const TrackerState();
  StreamSubscription<Map<String, dynamic>?>? _serviceSub;
  Tracker? _localTracker; // iOS: tracking runs inside the app
  AppConfig _config = const AppConfig();
  String? _permissionProblem;
  bool _needsAlways = false;
  bool _signDown = false; // debug mode: direction of the signs being recorded

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _setup();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _serviceSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // Coming back from Settings may have changed permissions.
    if (s == AppLifecycleState.resumed) _setup();
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) _setVisible(false);
  }

  /// Tells the tracker whether the speed is on screen (full GPS) or not.
  void _setVisible(bool on) =>
      _isAndroid ? FlutterBackgroundService().invoke('visible', {'on': on}) : _localTracker?.setVisible(on);

  Future<void> _setup() async {
    await Permission.notification.request();
    if (!await Permission.locationWhenInUse.request().isGranted) {
      return setState(() => _permissionProblem = 'Location permission is needed to show your speed.');
    }
    // "Allow all the time" lets tracking restart after a reboot.
    final always = await Permission.locationAlways.request().isGranted;
    if (_isAndroid) await Permission.ignoreBatteryOptimizations.request();
    _config = await AppConfig.load();
    setState(() {
      _permissionProblem = null;
      _needsAlways = !always;
    });

    if (_isAndroid) {
      await startTrackingService(startOnBoot: always);
      final service = FlutterBackgroundService();
      _serviceSub ??= service.on('state').listen((m) {
        if (m == null || !mounted) return;
        final s = TrackerState.fromMap(m);
        // The service may have started (or restarted) after we said the
        // app is on screen.
        if (s.sleeping && WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) _setVisible(true);
        setState(() => _state = s);
      });
      service.invoke('getState');
    } else if (_localTracker == null) {
      _localTracker = Tracker((s) {
        if (mounted) setState(() => _state = s);
      });
      await _localTracker!.start();
    }
    _setVisible(true);
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
    // Files or SD card access may have changed.
    final config = await AppConfig.load();
    _isAndroid ? FlutterBackgroundService().invoke('reload') : await _localTracker?.reload();
    if (mounted) {
      setState(() {
        if (config.debugMode && !_config.debugMode) _signDown = false; // up by default
        _config = config;
      });
    }
  }

  /// Debug mode: save a sign at the current position and use it at once.
  Future<void> _recordSign(int limit) async {
    final s = _state, messenger = ScaffoldMessenger.of(context);
    void say(String text) => messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
    if (s.lat == null || s.lon == null) return say('No GPS position yet');
    try {
      recordSign(limit, down: _signDown, lat: s.lat!, lon: s.lon!);
    } on FileSystemException {
      return say('Could not save: allow SD card access in Settings');
    }
    say('Saved ${limit}_${_signDown ? 'down' : 'up'}.txt  ${s.lat!.toStringAsFixed(5)}, ${s.lon!.toStringAsFixed(5)}');
    final config = await AppConfig.load();
    if (mounted) setState(() => _config = config);
    if (_isAndroid) {
      FlutterBackgroundService().invoke('reload');
    } else {
      await _localTracker?.reload();
    }
  }

  void _testSound() => _isAndroid ? FlutterBackgroundService().invoke('testSound') : _localTracker?.testSound();

  @override
  Widget build(BuildContext context) {
    final s = _state;
    final speed = _Panel(
      title: 'Your Speed',
      unit: 'km/h',
      child: Text(
        s.speedKmh == null ? '--' : s.speedKmh!.round().toString(),
        style: const TextStyle(fontSize: 200, fontWeight: FontWeight.bold, color: Colors.white, height: 1),
      ),
    );
    final limit = _config.debugMode
        ? _SignPad(
            limit: s.hasFix && s.onRoad ? s.limitKmh!.round().toString() : (s.hasFix ? 'X' : '--'),
            down: _signDown,
            onDirection: (down) => setState(() => _signDown = down),
            onSign: _recordSign,
          )
        : _Panel(
            title: 'Speed Limit',
            unit: s.onRoad ? 'km/h' : '',
            child: !s.hasFix
                ? const Text('--', style: TextStyle(fontSize: 200, color: Colors.white70, height: 1))
                : s.onRoad
                ? _LimitSign(limit: s.limitKmh!)
                // Not on the mountain roads: no limit to show.
                : const Text(
                    'X',
                    style: TextStyle(fontSize: 200, fontWeight: FontWeight.bold, color: Colors.white70, height: 1),
                  ),
          );
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;

    final panels = portrait
        ? Column(
            children: [
              Expanded(child: speed),
              const SizedBox(height: 24),
              Expanded(child: limit),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: speed),
              const SizedBox(width: 24),
              Expanded(child: limit),
            ],
          );

    return Scaffold(
      floatingActionButton: FloatingActionButton.small(
        tooltip: 'Settings',
        onPressed: _openSettings,
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        child: const Icon(Icons.settings),
      ),
      body: AlertBackground(
        status: s.status,
        colors: _config.colors ?? defaultColors,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Row(
                  children: [
                    const Text('Mountain Roads', style: TextStyle(fontSize: 18, color: Colors.white70)),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Test sounds',
                      icon: const Icon(Icons.volume_up, color: Colors.white70),
                      onPressed: _testSound,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Expanded(
                  // Dark backing keeps the numbers readable over the patterns.
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: s.status == SpeedStatus.ok ? Colors.transparent : Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: panels,
                  ),
                ),
                const SizedBox(height: 16),
                _statusLine(s),
                if (_permissionProblem != null || _needsAlways) ...[
                  const SizedBox(height: 12),
                  Text(
                    _permissionProblem ?? 'Set Location to "Allow all the time" so speed is watched after a restart.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, color: Colors.white),
                  ),
                  TextButton(onPressed: openAppSettings, child: const Text('Open settings')),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusLine(TrackerState s) {
    const style = TextStyle(fontSize: 22, color: Colors.white);
    if (s.error != null) return Text(s.error!, textAlign: TextAlign.center, style: style);
    if (!s.hasFix) return const Text('Waiting for GPS…', style: TextStyle(fontSize: 22, color: Colors.white70));
    if (s.onRoad) return const SizedBox.shrink();
    return Column(
      children: [Text('Mountain road ${formatDistance(s.distanceM!)} away', textAlign: TextAlign.center, style: style)],
    );
  }
}

/// Debug mode: a 3x4 grid in place of the speed limit. Top row: the current
/// limit and the up / down direction; below, one button per sign limit.
class _SignPad extends StatelessWidget {
  final String limit;
  final bool down;
  final ValueChanged<bool> onDirection;
  final ValueChanged<int> onSign;

  const _SignPad({required this.limit, required this.down, required this.onDirection, required this.onSign});

  static const _limits = [20, 30, 40, 50, 60, 70, 80, 90, 100];

  Widget _cell(Widget child, {VoidCallback? onTap, bool selected = false}) => Expanded(
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: Material(
        color: selected ? Colors.white : Colors.black54,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: FittedBox(
                child: DefaultTextStyle(
                  style: TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.bold,
                    color: selected ? Colors.black : Colors.white,
                  ),
                  child: IconTheme(
                    data: IconThemeData(size: 56, color: selected ? Colors.black : Colors.white),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: Row(
          children: [
            _cell(
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('limit', style: TextStyle(fontSize: 18, fontWeight: FontWeight.normal)),
                  Text(limit),
                ],
              ),
            ),
            _cell(const Icon(Icons.arrow_upward), selected: !down, onTap: () => onDirection(false)),
            _cell(const Icon(Icons.arrow_downward), selected: down, onTap: () => onDirection(true)),
          ],
        ),
      ),
      for (var r = 0; r < 3; r++)
        Expanded(
          child: Row(
            children: [for (final l in _limits.skip(r * 3).take(3)) _cell(Text('$l'), onTap: () => onSign(l))],
          ),
        ),
    ],
  );
}

/// A titled panel whose main value scales to fill the space.
class _Panel extends StatelessWidget {
  final String title;
  final String unit;
  final Widget child;

  const _Panel({required this.title, required this.unit, required this.child});

  @override
  Widget build(BuildContext context) => Column(
    children: [
      FittedBox(
        child: Text(
          title,
          style: const TextStyle(fontSize: 34, color: Colors.white, fontWeight: FontWeight.w500),
        ),
      ),
      const SizedBox(height: 12),
      Expanded(child: FittedBox(child: child)),
      const SizedBox(height: 8),
      // Keep the unit row even when empty so both panels line up.
      Text(unit.isEmpty ? ' ' : unit, style: const TextStyle(fontSize: 28, color: Colors.white70)),
    ],
  );
}

class _LimitSign extends StatelessWidget {
  final double limit;

  const _LimitSign({required this.limit});

  @override
  Widget build(BuildContext context) => Container(
    width: 220,
    height: 220,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: Colors.white,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.red.shade700, width: 24),
    ),
    child: Text(
      limit.round().toString(),
      style: const TextStyle(fontSize: 96, fontWeight: FontWeight.bold, color: Colors.black),
    ),
  );
}
