import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../services/notion_settings.dart';
import '../../services/watcher_channel.dart';
import 'settings_ui.dart';

/// Folder: the expenses database (token, database id) and the sync mode.
class NotionSettingsPage extends StatefulWidget {
  const NotionSettingsPage({super.key, required this.api});
  final ApiService api;

  @override
  State<NotionSettingsPage> createState() => _NotionSettingsPageState();
}

class _NotionSettingsPageState extends State<NotionSettingsPage> {
  late final _token = TextEditingController(text: widget.api.settings.token);
  late final _dbId =
      TextEditingController(text: widget.api.settings.databaseId);
  bool _showToken = false;
  bool _checking = false;
  String? _result;

  @override
  void dispose() {
    _token.dispose();
    _dbId.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final s = widget.api.settings;
    // Accept a token pasted together with the "Bearer " prefix.
    s.token = _token.text
        .trim()
        .replaceFirst(RegExp(r'^bearer\s+', caseSensitive: false), '');
    _token.text = s.token;
    s.databaseId = NotionSettings.normalizeDatabaseId(_dbId.text);
    _dbId.text = s.databaseId;
    await _persist();
  }

  /// Saves the settings and hands them to the native popup.
  Future<void> _persist() async {
    final s = widget.api.settings;
    await s.save();
    if (WatcherChannel.supported) {
      try {
        await WatcherChannel.setNotion(s.token, s.databaseId, s.autoSync);
      } catch (_) {}
    }
  }

  Future<void> _setAutoSync(bool auto) async {
    setState(() => widget.api.settings.autoSync = auto);
    await _persist();
  }

  Future<void> _saveAndTest() async {
    setState(() {
      _checking = true;
      _result = null;
    });
    await _save();
    final result = widget.api.settings.isConfigured
        ? await widget.api.checkDatabase()
        : 'Enter both the token and the database ID.';
    if (!mounted) return;
    setState(() {
      _checking = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auto = widget.api.settings.autoSync;
    return SettingsPage(
      title: 'Expenses & Notion',
      children: [
        const SettingsLabel('Notion'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _token,
                  obscureText: !_showToken,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Notion Bearer token',
                    hintText: 'Paste your token here',
                    suffixIcon: IconButton(
                      icon: Icon(
                          _showToken ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _showToken = !_showToken),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _dbId,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Expenses database ID',
                    hintText: 'Paste the database ID (or its link)',
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: _checking ? null : _saveAndTest,
                  icon: _checking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.check),
                  label: const Text('Save & test connection'),
                ),
                if (_result != null) ...[
                  const SizedBox(height: 12),
                  Text(_result!,
                      style: TextStyle(
                          color: _result!.contains('look right')
                              ? Colors.green
                              : scheme.error)),
                ],
                const SizedBox(height: 8),
                Text(
                  'Stored on this phone only. The database must be shared with '
                  'your Notion connection.',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        const SettingsLabel('Sync mode'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                          value: true,
                          icon: Icon(Icons.sync),
                          label: Text('Auto')),
                      ButtonSegment(
                          value: false,
                          icon: Icon(Icons.touch_app_outlined),
                          label: Text('Manual')),
                    ],
                    selected: {auto},
                    onSelectionChanged: (v) => _setAutoSync(v.first),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  auto
                      ? 'New expenses are pushed to Notion right after you save '
                          'them. If you are offline or Notion fails, they stay on '
                          'this phone until you push them yourself.'
                      : 'Expenses are only saved on this phone. Nothing is sent '
                          'until you select expenses and tap Push.',
                  style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
