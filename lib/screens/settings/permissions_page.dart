import 'package:flutter/material.dart';

import '../../services/watcher_channel.dart';
import 'settings_ui.dart';

/// Folder: the Android permissions the overlay features need.
class PermissionsPage extends StatefulWidget {
  const PermissionsPage({super.key});

  @override
  State<PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends State<PermissionsPage> {
  late final AppLifecycleListener _lifecycle;
  PermissionStatus? _perms;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Coming back from the system settings pages: re-check what was granted.
    _lifecycle = AppLifecycleListener(onResume: _load);
    _load();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!onAndroid) {
      setState(() => _loading = false);
      return;
    }
    try {
      final p = await WatcherChannel.permissions();
      if (mounted) {
        setState(() {
          _perms = p;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _perms;
    return SettingsPage(
      title: 'Permissions',
      children: [
        const SizedBox(height: 12),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (p == null)
          const Padding(padding: EdgeInsets.all(8), child: Text(androidOnly))
        else
          Card(
            child: Column(children: [
              PermissionTile(
                title: 'Usage access',
                why: 'Lets the app see which app is open',
                granted: p.usage,
                onGrant: WatcherChannel.openUsageSettings,
              ),
              PermissionTile(
                title: 'Display over other apps',
                why: 'Needed for the popup and the floating button',
                granted: p.overlay,
                onGrant: WatcherChannel.openOverlaySettings,
              ),
              PermissionTile(
                title: 'Unrestricted battery',
                why: 'Stops Samsung from killing the background service',
                granted: p.battery,
                onGrant: WatcherChannel.requestIgnoreBattery,
              ),
            ]),
          ),
      ],
    );
  }
}
