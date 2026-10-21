import 'package:flutter/material.dart';

import '../../models/app_event.dart';
import '../../services/events_service.dart';
import '../../services/events_settings.dart';
import '../../services/notion_settings.dart';
import '../event_dialog.dart';
import 'settings_ui.dart';

/// Folder: the events database (its own token and id), the popup switch and
/// the minimum gap between popups.
class EventsSettingsPage extends StatefulWidget {
  const EventsSettingsPage({super.key, required this.events});
  final EventsService events;

  @override
  State<EventsSettingsPage> createState() => _EventsSettingsPageState();
}

class _EventsSettingsPageState extends State<EventsSettingsPage> {
  late final _token = TextEditingController(text: widget.events.settings.token);
  late final _db =
      TextEditingController(text: widget.events.settings.databaseId);
  bool _showToken = false;
  bool _checking = false;
  String? _result;

  @override
  void dispose() {
    _token.dispose();
    _db.dispose();
    super.dispose();
  }

  Future<void> _saveAndTest() async {
    setState(() {
      _checking = true;
      _result = null;
    });
    final s = widget.events.settings;
    s.token = _token.text
        .trim()
        .replaceFirst(RegExp(r'^bearer\s+', caseSensitive: false), '');
    _token.text = s.token;
    s.databaseId = NotionSettings.normalizeDatabaseId(_db.text);
    _db.text = s.databaseId;
    try {
      await s.save();
    } catch (_) {}
    await widget.events.clearCache(); // the credentials may have changed
    var result = s.isConfigured
        ? await widget.events.api.checkConnection()
        : 'Enter both the events token and the events database ID.';
    if (result.contains('look right')) {
      // Say plainly what is on today and what comes next.
      result = '$result ${await widget.events.todaySummary()}';
    }
    if (!mounted) return;
    setState(() {
      _checking = false;
      _result = result;
    });
  }

  Future<void> _savePrefs() async {
    try {
      await widget.events.settings.save();
    } catch (_) {}
  }

  /// Shows the popup now: the next real event if there is one, else a sample.
  Future<void> _preview() async {
    final events = await widget.events.loadEvents();
    if (!mounted) return;
    final sample = AppEvent(
      id: 'preview',
      name: 'Preview',
      title: 'Your event title',
      subtitle: 'Your subtitle shows here.',
      date: DateTime.now(),
      type: 'Preview',
    );
    await showEventDialog(context, events.isNotEmpty ? events.first : sample);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = widget.events.settings;
    return SettingsPage(
      title: 'Events',
      children: [
        const SettingsLabel('Events (Notion)'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'A separate Notion database with the events to show: Title, '
                  'Subtitle and Date. It has its own token and ID.',
                  style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _token,
                  obscureText: !_showToken,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Events Bearer token',
                    hintText: 'Paste the events token here',
                    suffixIcon: IconButton(
                      icon: Icon(
                          _showToken ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _showToken = !_showToken),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _db,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Events database ID',
                    hintText: 'Paste the events database ID (or link)',
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
                      : const Icon(Icons.event_available),
                  label: const Text('Save & test events'),
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
                Text(widget.events.lastCheckText,
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                Text(
                  'Stored on this phone only. Share the events database with '
                  'its own Notion connection.',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        const SettingsLabel('Popups'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Show event popups'),
                  subtitle: const Text(
                      'When I open the app, pop up today\'s events.'),
                  value: settings.popupEnabled,
                  onChanged: (v) {
                    setState(() => settings.popupEnabled = v);
                    _savePrefs();
                  },
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<int>(
                  isExpanded: true,
                  initialValue: settings.gapMinutes,
                  decoration: const InputDecoration(
                      labelText: 'Minimum gap between popups'),
                  items: [
                    for (final (minutes, label) in kEventGapChoices)
                      DropdownMenuItem(value: minutes, child: Text(label)),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => settings.gapMinutes = v);
                    _savePrefs();
                  },
                ),
                const SizedBox(height: 4),
                Text(
                  'Only one event is shown at a time. The next popup waits at '
                  'least this long after the last one.',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _preview,
                    icon: const Icon(Icons.visibility_outlined),
                    label: const Text('Preview an event popup'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
