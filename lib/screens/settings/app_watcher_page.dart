import 'package:flutter/material.dart';

import '../../services/watcher_channel.dart';
import 'settings_ui.dart';

/// Folder: ask for an expense when a chosen app is closed, and which apps.
class AppWatcherPage extends StatefulWidget {
  const AppWatcherPage({super.key});

  @override
  State<AppWatcherPage> createState() => _AppWatcherPageState();
}

class _AppWatcherPageState extends State<AppWatcherPage> {
  late final AppLifecycleListener _lifecycle;
  final _search = TextEditingController();

  List<InstalledApp> _apps = [];
  Set<String> _selected = {};
  PermissionStatus _perms =
      const PermissionStatus(usage: false, overlay: false, battery: false);
  bool _enabled = false;
  bool _loading = true;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _refreshPerms);
    _load();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!onAndroid) {
      setState(() {
        _loading = false;
        _error = androidOnly;
      });
      return;
    }
    try {
      final results = await Future.wait([
        WatcherChannel.installedApps(),
        WatcherChannel.watched(),
        WatcherChannel.permissions(),
        WatcherChannel.isEnabled(),
      ]);
      if (!mounted) return;
      setState(() {
        _apps = results[0] as List<InstalledApp>;
        _selected = results[1] as Set<String>;
        _perms = results[2] as PermissionStatus;
        _enabled = results[3] as bool;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load apps: $e';
      });
    }
  }

  Future<void> _refreshPerms() async {
    if (!onAndroid) return;
    try {
      final p = await WatcherChannel.permissions();
      if (mounted) setState(() => _perms = p);
    } catch (_) {}
  }

  Future<void> _toggle(bool on) async {
    if (on && !(_perms.usage && _perms.overlay)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Grant Usage access and Display over other apps first '
              '(Permissions folder)')));
      return;
    }
    await WatcherChannel.setEnabled(on);
    setState(() => _enabled = on);
  }

  Future<void> _preview() async {
    try {
      await WatcherChannel.previewPopup();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Grant “Display over other apps” first')));
    }
  }

  Future<void> _pick(String pkg, bool on) async {
    setState(() => on ? _selected.add(pkg) : _selected.remove(pkg));
    await WatcherChannel.setWatched(_selected);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _error != null) {
      return SettingsPage(
        title: 'Close-an-app popup',
        children: [
          const SizedBox(height: 24),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else
            Padding(padding: const EdgeInsets.all(8), child: Text(_error!)),
        ],
      );
    }

    final q = _query.toLowerCase();
    final shown = _apps.where((a) => a.name.toLowerCase().contains(q)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Close-an-app popup')),
      body: ListView.builder(
        itemCount: shown.length + 1,
        itemBuilder: (_, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Card(
                    child: SwitchListTile(
                      title: const Text('Ask for an expense when I close an app',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(_selected.isEmpty
                          ? 'Pick at least one app below'
                          : '${_selected.length} app(s) selected'),
                      value: _enabled,
                      onChanged: _toggle,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.visibility_outlined),
                      title: const Text('Preview the popup'),
                      subtitle: const Text('See it now. Nothing is saved.'),
                      trailing: const Icon(Icons.play_arrow_rounded),
                      onTap: _preview,
                    ),
                  ),
                  const SettingsLabel('Apps to watch'),
                  TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search apps',
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          }
          final a = shown[i - 1];
          return CheckboxListTile(
            value: _selected.contains(a.package),
            onChanged: (v) => _pick(a.package, v ?? false),
            secondary: a.icon == null
                ? const Icon(Icons.android)
                : Image.memory(a.icon!, width: 40, height: 40),
            title: Text(a.name),
          );
        },
      ),
    );
  }
}
