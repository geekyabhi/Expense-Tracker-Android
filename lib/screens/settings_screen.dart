import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/events_api.dart';
import '../services/events_service.dart';
import '../services/events_settings.dart';
import '../services/watcher_channel.dart';
import 'settings/app_watcher_page.dart';
import 'settings/events_page.dart';
import 'settings/floating_button_page.dart';
import 'settings/notion_page.dart';
import 'settings/permissions_page.dart';

/// The settings home: a short list of folders. Each folder opens its own page
/// and shows a one-line status.
class SettingsScreen extends StatefulWidget {
  SettingsScreen({super.key, required this.api, EventsService? events})
      : events = events ??
            EventsService(api: EventsApi(settings: EventsSettings()));
  final ApiService api;
  final EventsService events;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final AppLifecycleListener _lifecycle;

  // Android-side status for the summaries (null until loaded).
  bool _bubble = false;
  bool _watcher = false;
  int _watched = 0;
  PermissionStatus? _perms;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _loadStatus);
    _loadStatus();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    if (!WatcherChannel.supported) return;
    try {
      final results = await Future.wait([
        WatcherChannel.isBubbleEnabled(),
        WatcherChannel.isEnabled(),
        WatcherChannel.watched(),
        WatcherChannel.permissions(),
      ]);
      if (!mounted) return;
      setState(() {
        _bubble = results[0] as bool;
        _watcher = results[1] as bool;
        _watched = (results[2] as Set<String>).length;
        _perms = results[3] as PermissionStatus;
      });
    } catch (_) {}
  }

  /// Opens a folder, then refreshes the summaries when coming back.
  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (!mounted) return;
    setState(() {}); // credentials and switches may have changed
    _loadStatus();
  }

  // ----------------------------------------------------------- summaries

  String get _notionSummary {
    final s = widget.api.settings;
    if (!s.isConfigured) return 'Not set up';
    return 'Connected · ${s.autoSync ? 'Auto sync' : 'Manual sync'}';
  }

  String get _eventsSummary {
    final s = widget.events.settings;
    if (!s.isConfigured) return 'Not set up';
    if (!s.popupEnabled) return 'Popups off';
    final gap = kEventGapChoices
        .firstWhere((c) => c.$1 == s.gapMinutes,
            orElse: () => (s.gapMinutes, '${s.gapMinutes} min'))
        .$2;
    return 'Popups on · gap: ${gap[0].toLowerCase()}${gap.substring(1)}';
  }

  String get _bubbleSummary =>
      !WatcherChannel.supported ? 'Android only' : (_bubble ? 'On' : 'Off');

  String get _watcherSummary {
    if (!WatcherChannel.supported) return 'Android only';
    if (!_watcher) return 'Off';
    return 'On · $_watched app${_watched == 1 ? '' : 's'}';
  }

  String get _permissionsSummary {
    final p = _perms;
    if (!WatcherChannel.supported) return 'Android only';
    if (p == null) return 'Checking…';
    final granted = [p.usage, p.overlay, p.battery].where((g) => g).length;
    return '$granted of 3 granted';
  }

  // ----------------------------------------------------------- UI

  Widget _folder({
    required IconData icon,
    required String title,
    required String summary,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          onTap: onTap,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          leading: CircleAvatar(
            backgroundColor: scheme.primaryContainer,
            child: Icon(icon, color: scheme.primary),
          ),
          title: Text(title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          subtitle: Text(summary),
          trailing: const Icon(Icons.chevron_right),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _folder(
            icon: Icons.account_balance_wallet_outlined,
            title: 'Expenses & Notion',
            summary: _notionSummary,
            onTap: () => _open(NotionSettingsPage(api: widget.api)),
          ),
          _folder(
            icon: Icons.event_outlined,
            title: 'Events',
            summary: _eventsSummary,
            onTap: () => _open(EventsSettingsPage(events: widget.events)),
          ),
          _folder(
            icon: Icons.add_circle_outline,
            title: 'Floating button',
            summary: _bubbleSummary,
            onTap: () => _open(const FloatingButtonPage()),
          ),
          _folder(
            icon: Icons.touch_app_outlined,
            title: 'Close-an-app popup',
            summary: _watcherSummary,
            onTap: () => _open(const AppWatcherPage()),
          ),
          _folder(
            icon: Icons.shield_outlined,
            title: 'Permissions',
            summary: _permissionsSummary,
            onTap: () => _open(const PermissionsPage()),
          ),
        ],
      ),
    );
  }
}
