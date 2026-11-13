import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'config.dart';

bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

const _channel = MethodChannel('mountain_roads/settings');

/// Opens an Android settings page (see MainActivity.openSettings); app info on iOS.
Future<void> _openPage(String page) async {
  if (!_isAndroid) {
    await openAppSettings();
    return;
  }
  await _channel.invokeMethod<bool>('openSettings', {'page': page});
}

/// One line in the permissions list: its status, how to switch it on, and
/// which Android settings page tapping its name opens.
class _Item {
  final String title;
  final String detail;
  final bool required;
  final Future<bool> Function() check;
  final Future<void> Function() enable;
  final String page;
  final String action;

  const _Item(
    this.title,
    this.detail, {
    required this.check,
    required this.enable,
    required this.page,
    this.required = true,
    this.action = 'Allow',
  });

  factory _Item.permission(String title, String detail, Permission p, String page, {bool required = true}) => _Item(
    title,
    detail,
    required: required,
    page: page,
    check: () => p.isGranted,
    enable: () async {
      if ((await p.request()).isPermanentlyDenied) await _openPage(page);
    },
  );
}

final _items = [
  _Item(
    'Location switched on',
    'The phone\'s main Location switch (quick settings).',
    page: 'location',
    action: 'Turn on',
    check: Geolocator.isLocationServiceEnabled,
    enable: () => _openPage('location'),
  ),
  _Item.permission('Location', 'Needed to measure your speed.', Permission.locationWhenInUse, 'app'),
  _Item.permission(
    'Location all the time',
    'Keeps watching speed after a restart and with the app closed.',
    Permission.locationAlways,
    'app',
  ),
  _Item.permission(
    'Notifications',
    'Shows the "Mountain Roads" status while it runs.',
    Permission.notification,
    'notifications',
  ),
  if (_isAndroid)
    _Item.permission(
      'Battery: unrestricted',
      'Stops Android from putting the app to sleep.',
      Permission.ignoreBatteryOptimizations,
      'battery',
    ),
  if (_isAndroid)
    _Item(
      'Google Location Accuracy (optional)',
      'Faster, battery-friendly location using Wi-Fi and mobile networks. Without it the app uses GPS only.',
      required: false,
      page: 'googleAccuracy',
      action: 'Turn on',
      check: () async => await _channel.invokeMethod<bool>('googleAccuracy') ?? false,
      enable: () => _channel.invokeMethod<bool>('enableGoogleAccuracy'),
    ),
  if (_isAndroid)
    _Item.permission(
      'SD card access (optional)',
      'Lets you change sounds, warning delay, Ruta 41 and colours with files in $configDir.',
      Permission.manageExternalStorage,
      'allFiles',
      required: false,
    ),
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  final Map<_Item, bool> _on = {};
  AppConfig _config = const AppConfig();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // Back from the system settings page.
    if (s == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    for (final item in _items) {
      try {
        _on[item] = await item.check();
      } catch (_) {
        _on[item] = false;
      }
    }
    final config = await AppConfig.load(); // also creates the folder's files
    if (_isAndroid && config.folderAvailable != _config.folderAvailable) {
      FlutterBackgroundService().invoke('reload');
    }
    if (mounted) setState(() => _config = config);
  }

  Future<void> _enable(_Item item) async {
    await item.enable();
    await _refresh();
    // A new location source (e.g. Google accuracy) helps the tracker too.
    if (_isAndroid) FlutterBackgroundService().invoke('reload');
  }

  void _reload() {
    if (_isAndroid) FlutterBackgroundService().invoke('reload');
    _refresh();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings reloaded')));
  }

  @override
  Widget build(BuildContext context) {
    final c = _config;
    String sound(String? path, String fallback) => path == null ? fallback : path.split('/').last;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: OutlinedButton.icon(
              onPressed: () => _showReadMe(context),
              icon: const Icon(Icons.article_outlined),
              label: const Text('Read ReadMe'),
            ),
          ),
          const _Header('Permissions'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'The required permissions let your phone stay in your pocket and still alarm you if you '
              'are going too fast. When you are not on the Mountain Roads the app is in a sleep-like '
              'mode: GPS off, checking your rough position only every 20 seconds.',
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text('Tap a name to open its Android settings page.', style: TextStyle(fontSize: 13)),
          ),
          for (final item in _items)
            ListTile(
              leading: Icon(
                Icons.circle,
                color: _on[item] == true
                    ? Colors.green
                    : item.required
                    ? Colors.red
                    : Colors.grey,
              ),
              title: Text(item.title, style: const TextStyle(decoration: TextDecoration.underline)),
              subtitle: Text(item.detail),
              onTap: () => _openPage(item.page),
              trailing: _on[item] == true
                  ? Text(item.action == 'Allow' ? 'Allowed' : 'On', style: const TextStyle(color: Colors.green))
                  : TextButton(onPressed: () => _enable(item), child: Text(item.action)),
            ),
          const _Header('Alarm'),
          CheckboxListTile(
            title: const Text('Random alarm'),
            subtitle: const Text(
              'Each alarm picks a sound at random: yellow from the beep and 2 fun sounds, red from the loud beep and 3.',
            ),
            value: c.randomAlarm,
            onChanged: (on) async {
              await saveRandomAlarm(on ?? false);
              if (_isAndroid) FlutterBackgroundService().invoke('reload');
              await _refresh();
            },
          ),
          const _Header('Debug'),
          CheckboxListTile(
            title: const Text('Debug mode'),
            subtitle: const Text('Speed limit panel becomes buttons for recording speed signs.'),
            value: c.debugMode,
            onChanged: (on) async {
              if (on == true) await _showDebugNotice(context, folderAvailable: c.folderAvailable);
              await saveDebugMode(on ?? false);
              await _refresh();
            },
          ),
          if (_isAndroid) ...[
            const _Header('Settings folder: $configDir'),
            if (!c.folderAvailable)
              const ListTile(
                leading: Icon(Icons.folder_off),
                title: Text('Not available'),
                subtitle: Text('Allow SD card access to create the folder and its ReadMe.txt.'),
              )
            else ...[
              _Info('Alarms start', '${c.thresholds.description} (${c.thresholds.fileName})'),
              _Info('Yellow alarm sound', sound(c.lowSoundPath, 'built-in beep')),
              _Info('Red alarm sound', sound(c.loudSoundPath, 'built-in beep')),
              _Info(
                'Warning delay',
                c.alarmDelaySeconds == 0 ? 'beep immediately' : '${c.alarmDelaySeconds} s over the limit',
              ),
              _Info('Speed alarm starts at', c.ruta41 ? 'La Serena airport (ruta41_on.txt)' : 'Control Puerta'),
              _Info('Colours', c.colors == null ? 'standard' : 'ColorBlind.txt'),
              _Info('Recorded signs', '${c.signs.length}'),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reload settings folder'),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;

  const _Header(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}

class _Info extends StatelessWidget {
  final String label;
  final String value;

  const _Info(this.label, this.value);

  @override
  Widget build(BuildContext context) => ListTile(dense: true, title: Text(label), trailing: Text(value));
}

Future<void> _showDebugNotice(BuildContext context, {required bool folderAvailable}) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('Debug mode'),
    content: Text(
      'Debug files will be written to your SD card but no other information sharing is enabled.'
      '${folderAvailable ? '' : '\n\nAllow SD card access first, or nothing can be saved.'}',
    ),
    actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
  ),
);

/// Full-screen ReadMe with an X to close. Always the copy built into the app.
void _showReadMe(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => Dialog.fullscreen(
    child: Scaffold(
      appBar: AppBar(
        title: const Text('ReadMe'),
        leading: IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: const SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: SelectableText(readMeText, style: TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.4)),
      ),
    ),
  ),
);
