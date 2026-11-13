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

final _sdItem = _Item.permission(
  'SD card access (optional)',
  'Lets the app use the settings folder $configDir: your own sounds, alarm levels, colours, and debug files.',
  Permission.manageExternalStorage,
  'allFiles',
  required: false,
);

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
  if (_isAndroid) _sdItem,
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// Keeps permission states and the config fresh (also after coming back
/// from an Android settings page). Shared by all the settings pages.
mixin _Live<T extends StatefulWidget> on State<T>, WidgetsBindingObserver {
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
    if (_isAndroid && config.folderAvailable != _config.folderAvailable) _reloadService();
    if (mounted) setState(() => _config = config);
  }

  Future<void> _enable(_Item item) async {
    await item.enable();
    await _refresh();
    // A new location source (e.g. Google accuracy) helps the tracker too.
    _reloadService();
  }

  Widget _row(_Item item) => ListTile(
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
  );
}

void _reloadService() {
  if (_isAndroid) FlutterBackgroundService().invoke('reload');
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver, _Live {
  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final c = _config;
    final missing = _items.where((i) => i.required && _on[i] == false).length;
    String onOff(bool on) => on ? 'on' : 'off';
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _MenuTile(
            Icons.verified_user_outlined,
            'Permissions',
            _on.isEmpty
                ? ' '
                : missing == 0
                ? 'All required permissions allowed'
                : '$missing required ${missing == 1 ? 'permission needs' : 'permissions need'} attention',
            warn: missing > 0,
            onTap: () => _open(const _PermissionsPage()),
          ),
          _MenuTile(
            Icons.toggle_on_outlined,
            'Toggles',
            'Random sounds ${onOff(c.randomAlarm)} · Ruta 41 alarms ${onOff(c.ruta41)} · '
                'Recinto alarms ${onOff(c.recinto)}',
            onTap: () => _open(const _TogglesPage()),
          ),
          _MenuTile(
            Icons.bug_report_outlined,
            'Debug mode',
            c.debugMode ? 'On: recording speed signs' : 'Off',
            onTap: () => _open(const _DebugPage()),
          ),
          _MenuTile(
            Icons.sd_card_outlined,
            'SD Card / Settings Folder',
            !_isAndroid
                ? 'ReadMe (the settings folder is Android only)'
                : c.folderAvailable
                ? '$configDir · ReadMe'
                : 'Not allowed yet · ReadMe',
            onTap: () => _open(const _FolderPage()),
          ),
        ],
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final bool warn;
  final VoidCallback onTap;

  const _MenuTile(this.icon, this.title, this.subtitle, {required this.onTap, this.warn = false});

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, color: warn ? Colors.red : null),
    title: Text(title),
    subtitle: Text(subtitle, style: warn ? const TextStyle(color: Colors.red) : null),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}

class _PermissionsPage extends StatefulWidget {
  const _PermissionsPage();

  @override
  State<_PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends State<_PermissionsPage> with WidgetsBindingObserver, _Live {
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Permissions')),
    body: ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        const _Text(
          'The required permissions let your phone stay in your pocket and still alarm you if you '
          'are going too fast. When you are not on the Mountain Roads the app is in a sleep-like '
          'mode: GPS off, checking your rough position only every 20 seconds.',
        ),
        if (_isAndroid) const _Text('Tap a name to open its Android settings page.', small: true),
        for (final item in _items) _row(item),
      ],
    ),
  );
}

class _TogglesPage extends StatefulWidget {
  const _TogglesPage();

  @override
  State<_TogglesPage> createState() => _TogglesPageState();
}

class _TogglesPageState extends State<_TogglesPage> with WidgetsBindingObserver, _Live {
  Future<void> _set(Future<void> Function() save) async {
    await save();
    _reloadService();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final c = _config;
    return Scaffold(
      appBar: AppBar(title: const Text('Toggles')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          SwitchListTile(
            title: const Text('Random sounds'),
            subtitle: const Text(
              'Each alarm picks a sound at random: yellow from the beep and 2 fun sounds, '
              'red from the loud beep and 3. Default off.',
            ),
            value: c.randomAlarm,
            onChanged: (on) => _set(() => saveRandomAlarm(on)),
          ),
          SwitchListTile(
            title: const Text('Ruta 41 alarms'),
            subtitle: const Text(
              'Also watch Ruta 41 from La Serena airport to Control Puerta (zones A–M). Default off.',
            ),
            value: c.ruta41,
            onChanged: (on) => _set(() => saveToggle(ruta41Toggle, on)),
          ),
          SwitchListTile(
            title: const Text('Recinto alarms'),
            subtitle: const Text(
              'Alarms on the AURA roads from Control Puerta to Tololo, Pachón and Rubin. '
              'When off, speed, limit and colours still show but there is no sound. Default on.',
            ),
            value: c.recinto,
            onChanged: (on) => _set(() => saveToggle(recintoToggle, on)),
          ),
          if (_isAndroid && c.folderAvailable)
            const _Text(
              'Ruta 41 and Recinto are also saved in the settings folder as ruta41_on/off.txt and '
              'recinto_on/off.txt, so renaming those files works too.',
              small: true,
            ),
        ],
      ),
    );
  }
}

class _DebugPage extends StatefulWidget {
  const _DebugPage();

  @override
  State<_DebugPage> createState() => _DebugPageState();
}

class _DebugPageState extends State<_DebugPage> with WidgetsBindingObserver, _Live {
  @override
  Widget build(BuildContext context) {
    final c = _config;
    return Scaffold(
      appBar: AppBar(title: const Text('Debug mode')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Card(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            color: Theme.of(context).colorScheme.errorContainer,
            child: const ListTile(
              leading: Icon(Icons.warning_amber),
              title: Text(
                'Debug files will be written to your SD card but no other information sharing is enabled.',
              ),
            ),
          ),
          SwitchListTile(
            title: const Text('Debug mode'),
            subtitle: const Text('Default off.'),
            value: c.debugMode,
            onChanged: (on) async {
              if (on) await _showDebugNotice(context, folderAvailable: c.folderAvailable);
              await saveDebugMode(on);
              await _refresh();
            },
          ),
          const _Header('How it works'),
          const _Text(
            'The speed limit panel on the main screen becomes a grid of buttons:\n'
            '• top row: the current limit, then ↑ (driving up the mountain, the default) and ↓ (down).\n'
            '• 20 to 100: tap the number on a speed sign as you pass it.\n\n'
            'Each tap adds the current GPS position to a file in $configDir, for example '
            '60_up.txt or 40_down.txt (one "lat,lon" line per sign). From each sign on, in its direction, '
            'its limit replaces the built-in one until the next zone change or sign. These files stay on '
            'the SD card only; edit or delete them there to fix mistakes.',
          ),
          if (_isAndroid) ...[
            const _Header('Needs SD card access'),
            const _Text('Signs can only be saved if the app is allowed to use the SD card:'),
            _row(_sdItem),
            if (c.folderAvailable) _Info('Recorded signs', '${c.signs.length}'),
          ] else
            const _Text('On iPhone there is no SD card, so signs cannot be saved.'),
        ],
      ),
    );
  }
}

class _FolderPage extends StatefulWidget {
  const _FolderPage();

  @override
  State<_FolderPage> createState() => _FolderPageState();
}

class _FolderPageState extends State<_FolderPage> with WidgetsBindingObserver, _Live {
  void _reload() {
    _reloadService();
    _refresh();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings reloaded')));
  }

  @override
  Widget build(BuildContext context) {
    final c = _config;
    String sound(String? path, String fallback) => path == null ? fallback : path.split('/').last;
    String onOff(bool on) => on ? 'on' : 'off';
    return Scaffold(
      appBar: AppBar(title: const Text('SD Card / Settings Folder')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: FilledButton.tonalIcon(
              onPressed: () => _showReadMe(context),
              icon: const Icon(Icons.article_outlined),
              label: const Text('Read ReadMe'),
            ),
          ),
          if (!_isAndroid)
            const _Text(
              'The settings folder is Android only. On iPhone the app uses the built-in sounds, '
              'alarms at 10% / 20% over, and standard colours.',
            )
          else ...[
            _row(_sdItem),
            _Header('Folder: $configDir'),
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
                c.alarmDelaySeconds == 0
                    ? 'immediately (0SecondsWarning.txt)'
                    : '${c.alarmDelaySeconds} s (${c.alarmDelaySeconds}SecondsWarning.txt)',
              ),
              _Info('Ruta 41 alarms', '${onOff(c.ruta41)} (ruta41_${onOff(c.ruta41)}.txt)'),
              _Info('Recinto alarms', '${onOff(c.recinto)} (recinto_${onOff(c.recinto)}.txt)'),
              _Info('Colours', c.colors == null ? 'standard' : 'ColorBlind.txt'),
              _Info('Recorded signs', '${c.signs.length}'),
              const _Info('Maps', 'SpeedZones.png, SpeedZones_Ruta41.png'),
              const _Text('Edit or rename the files on the SD card (see ReadMe), then tap Reload.', small: true),
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

class _Text extends StatelessWidget {
  final String text;
  final bool small;

  const _Text(this.text, {this.small = false});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: Text(text, style: small ? const TextStyle(fontSize: 13) : null),
  );
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
