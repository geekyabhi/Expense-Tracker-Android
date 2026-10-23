import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../services/expense_repository.dart';
import '../../services/notion_settings.dart';
import '../../services/watcher_channel.dart';
import 'settings_ui.dart';

/// Folder: the expenses database (token, database id) and the sync mode.
class NotionSettingsPage extends StatefulWidget {
  const NotionSettingsPage({super.key, required this.api, this.repo});
  final ApiService api;

  /// When given, switching to a different database also refreshes the expenses
  /// on the phone. Without it only the connection changes.
  final ExpenseRepository? repo;

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
  bool _resultOk = false;

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

  /// Same database whatever the spelling (link, dashes, case).
  static String _dbKey(String id) => NotionSettings.normalizeDatabaseId(id)
      .replaceAll('-', '')
      .toLowerCase();

  Future<void> _saveAndTest() async {
    setState(() {
      _checking = true;
      _result = null;
      _resultOk = false;
    });
    final before = widget.api.settings.databaseId; // the database in use so far
    // Saving can fail (storage problem). That must not stop the test, and the
    // spinner must always stop, so both are guarded.
    String? saveProblem;
    String result;
    try {
      try {
        await _save();
      } catch (e) {
        saveProblem = '$e';
      }
      result = widget.api.settings.isConfigured
          ? await widget.api.checkDatabase()
          : 'Enter both the token and the database ID.';

      // A different database that tests fine: the expenses on the phone belong
      // to the old one, so they have to be dealt with. Never on a failed test
      // (a typo must not wipe anything), and never for a first-time setup or a
      // token-only change.
      final switched = before.trim().isNotEmpty &&
          _dbKey(before) != _dbKey(widget.api.settings.databaseId);
      if (result.contains('look right') && switched && widget.repo != null) {
        // Show the test result and stop the spinner while the question is open.
        if (mounted) {
          setState(() {
            _checking = false;
            _result = result;
          });
        }
        final note = await _switchDatabase();
        if (note != null) result = '$result $note';
      }
    } catch (e) {
      result = 'Something went wrong: $e';
    }
    if (saveProblem != null) {
      result = '$result Could not save these settings on the phone, so they '
          'will be lost when the app closes ($saveProblem).';
    }
    if (!mounted) return;
    setState(() {
      _checking = false;
      _result = result;
      _resultOk = saveProblem == null && result.contains('look right');
    });
  }

  /// Asks what to do with the expenses of the old database, does it, and loads
  /// the new database. Returns a sentence for the result line (null = nothing).
  Future<String?> _switchDatabase() async {
    final repo = widget.repo!;
    final uploaded =
        repo.expenses.where((e) => e.synced && e.remoteId != null).length;
    final others = repo.expenses.length - uploaded;

    var replace = true; // nothing on the phone: nothing to lose
    if (repo.expenses.isNotEmpty) {
      final choice = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Switch to the new database?'),
          content: Text(
            'You changed to a different Notion database, but the expenses on '
            'this phone belong to the old one.\n\n'
            '• $uploaded already uploaded to the old database\n'
            '• $others not uploaded, or edited since\n\n'
            'Replace: remove the $uploaded uploaded ones (they stay safe in the '
            'old database), keep the $others others so you can push them to the '
            'new one, and load the new database.\n\n'
            'Keep all: remove nothing. Every expense stays and can be pushed to '
            'the new database; the new database is loaded too.',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep all')),
            FilledButton(
                style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 20)),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Replace')),
          ],
        ),
      );
      if (choice == null) return null;
      replace = choice;
    }
    if (mounted) setState(() => _checking = true); // loading the new database

    final r = await repo.switchDatabase(replace: replace);
    final loaded = r.imported.error != null
        ? 'could not load the new database (${r.imported.error})'
        : 'loaded ${r.imported.added} from the new database';
    return 'Switched: removed ${r.removed}, kept ${r.detached} to push to the '
        'new database, $loaded.';
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
                          color: _resultOk ? Colors.green : scheme.error)),
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
