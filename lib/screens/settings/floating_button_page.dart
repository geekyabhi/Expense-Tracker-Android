import 'package:flutter/material.dart';

import '../../services/watcher_channel.dart';
import 'settings_ui.dart';

/// Folder: the floating + button.
class FloatingButtonPage extends StatefulWidget {
  const FloatingButtonPage({super.key});

  @override
  State<FloatingButtonPage> createState() => _FloatingButtonPageState();
}

class _FloatingButtonPageState extends State<FloatingButtonPage> {
  late final AppLifecycleListener _lifecycle;
  bool _bubble = false;
  bool _overlay = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Back from the system permission page: re-check what was granted.
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
      final bubble = await WatcherChannel.isBubbleEnabled();
      final perms = await WatcherChannel.permissions();
      if (!mounted) return;
      setState(() {
        _bubble = bubble;
        _overlay = perms.overlay;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle(bool on) async {
    if (on && !_overlay) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Allow “Display over other apps” first'),
          action: SnackBarAction(
              label: 'Grant', onPressed: WatcherChannel.openOverlaySettings),
        ));
      return;
    }
    try {
      await WatcherChannel.setBubbleEnabled(on);
      if (mounted) setState(() => _bubble = on);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Allow “Display over other apps” first')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SettingsPage(
      title: 'Floating button',
      children: [
        const SizedBox(height: 12),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (!onAndroid)
          const Padding(padding: EdgeInsets.all(8), child: Text(androidOnly))
        else ...[
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.add_circle_outline),
              title: const Text('Floating + button',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text(
                  'A small + on top of every app. Tap it to add an expense, '
                  'drag it anywhere.'),
              value: _bubble,
              onChanged: _toggle,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _overlay
                ? 'The permission it needs ("Display over other apps") is granted.'
                : 'It needs the "Display over other apps" permission. Grant it '
                    'in the Permissions folder, or when asked here.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}
