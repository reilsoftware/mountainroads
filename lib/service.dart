import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import 'tracker.dart';

/// Android: configure and start the always-on tracking service.
///
/// [startOnBoot] should only be true once location is allowed "all the
/// time"; Android refuses a location service started at boot otherwise.
Future<void> startTrackingService({required bool startOnBoot}) async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onServiceStart,
      autoStart: true,
      autoStartOnBoot: startOnBoot,
      isForegroundMode: true,
      initialNotificationTitle: 'Mountain Roads',
      initialNotificationContent: 'Starting…',
      foregroundServiceTypes: [AndroidForegroundType.location],
    ),
    // iOS runs the tracker inside the app instead (see main.dart).
    iosConfiguration: IosConfiguration(autoStart: false),
  );
  if (!await service.isRunning()) await service.startService();
}

/// Entry point of the background service's own Dart isolate. It keeps
/// running when the app is closed or swiped away, and restarts on boot.
@pragma('vm:entry-point')
void onServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();

  String? lastSummary;
  final tracker = Tracker((s) {
    service.invoke('state', s.toMap());
    if (service is AndroidServiceInstance && s.summary != lastSummary) {
      lastSummary = s.summary;
      service.setForegroundNotificationInfo(title: 'Mountain Roads', content: s.summary);
    }
  });
  service.on('getState').listen((_) => service.invoke('state', tracker.state.toMap()));
  service.on('testSound').listen((_) => tracker.testSound());
  // The app's screen is showing: keep full GPS so speed always shows.
  service.on('visible').listen((m) => tracker.setVisible(m?['on'] == true));
  // Settings changed (e.g. storage access granted or files edited).
  service.on('reload').listen((_) async {
    await tracker.reload();
    service.invoke('state', tracker.state.toMap());
  });
  await tracker.start();
}
