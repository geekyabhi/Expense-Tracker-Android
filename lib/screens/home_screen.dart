import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/expense.dart';
import '../services/events_api.dart';
import '../services/events_service.dart';
import '../services/events_settings.dart';
import '../services/expense_repository.dart';
import '../services/options_store.dart';
import '../utils/format.dart';
import 'event_dialog.dart';
import 'settings_screen.dart';

/// Asks before deleting; the text depends on what will happen in Notion.
Future<bool> confirmDelete(
    BuildContext context, ExpenseRepository repo, List<Expense> list) async {
  final inNotion = list.where((e) => e.remoteId != null).length;
  final auto = repo.api.settings.autoSync && repo.api.settings.isConfigured;
  final what = list.length == 1 ? '“${list.first.title}”' : '${list.length} expenses';
  final extra = inNotion == 0
      ? 'It was never pushed to Notion, so only the copy on this phone is removed.'
      : auto
          ? 'It will also be archived in Notion (recoverable from Notion’s trash).'
          : 'Its Notion page will be archived when you tap Apply on the '
              'Expenses screen.';
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Delete $what?'),
      content: Text(extra),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        TextButton(
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete')),
      ],
    ),
  );
  return ok ?? false;
}

String deleteMessage(DeleteSummary r) {
  final b = StringBuffer(
      'Deleted ${r.removed} expense${r.removed == 1 ? '' : 's'}');
  if (r.archived > 0) b.write(' and archived in Notion');
  if (r.queued > 0) {
    b.write('. ${r.queued} archive${r.queued == 1 ? '' : 's'} waiting in '
        'Notion, tap Apply');
  }
  return b.toString();
}

class HomeScreen extends StatefulWidget {
  HomeScreen({super.key, required this.repo, EventsService? events})
      : events = events ??
            EventsService(api: EventsApi(settings: EventsSettings()));
  final ExpenseRepository repo;
  final EventsService events;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  ExpenseRepository get repo => widget.repo;

  bool _checkingEvents = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Opening the app: show today's events (after the first frame is up).
    WidgetsBinding.instance.addPostFrameCallback((_) => _showDueEvents());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the app counts as opening it.
    if (state == AppLifecycleState.resumed) _showDueEvents();
  }

  /// Pops up one of today's events, respecting the minimum gap set in
  /// Settings. The time is recorded as the popup appears, so closing the app
  /// without dismissing it still starts the gap.
  Future<void> _showDueEvents() async {
    if (_checkingEvents) return;
    _checkingEvents = true;
    try {
      final event = await widget.events.nextDue();
      if (event == null || !mounted) return;
      await widget.events.markShown(event);
      if (!mounted) return;
      await showEventDialog(context, event);
    } finally {
      _checkingEvents = false;
    }
  }

  bool _selecting = false;
  final Set<String> _selected = {};

  void _startSelecting([String? firstId]) => setState(() {
        _selecting = true;
        _selected
          ..clear()
          ..addAll([if (firstId != null) firstId]);
      });

  void _stopSelecting() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  void _toggle(String id) => setState(() {
        if (!_selected.remove(id)) _selected.add(id);
      });

  void _toggleAll() => setState(() {
        if (_selected.length == repo.expenses.length) {
          _selected.clear();
        } else {
          _selected
            ..clear()
            ..addAll(repo.expenses.map((e) => e.id));
        }
      });

  /// True when Notion is set up; otherwise says so, with a way to Settings.
  bool _notionReady() {
    if (repo.api.settings.isConfigured) return true;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Add your Notion token and database ID first'),
      action: SnackBarAction(
        label: 'Settings',
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => SettingsScreen(api: repo.api, events: widget.events, repo: repo))),
      ),
    ));
    return false;
  }

  /// Asks before removing expenses that were deleted in Notion: the phone's
  /// copy would then be the only copy.
  Future<bool> _confirmRemoval(List<Expense> missing) async {
    if (!mounted) return false;
    final n = missing.length;
    final shown = missing.take(5).map((e) => '• ${e.title}').join('\n');
    final more = n > 5 ? '\n…and ${n - 5} more' : '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$n expense${n == 1 ? ' was' : 's were'} deleted in Notion'),
        content: Text(
          '$shown$more\n\nRemove ${n == 1 ? 'it' : 'them'} from this phone too? '
          'This phone would no longer have ${n == 1 ? 'it' : 'them'} anywhere. '
          'Notion keeps deleted pages in its trash for a while.\n\n'
          'If you keep ${n == 1 ? 'it' : 'them'}, ${n == 1 ? 'it is' : 'they are'} '
          'marked as not uploaded, so you can push ${n == 1 ? 'it' : 'them'} to '
          'Notion again.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep on phone')),
          TextButton(
              style: TextButton.styleFrom(
                  foregroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _syncFromNotion() async {
    if (!_notionReady()) return;
    final messenger = ScaffoldMessenger.of(context);
    final r = await repo.importFromNotion(confirmRemoval: _confirmRemoval);
    if (!mounted) return;
    final parts = [
      if (r.added > 0) 'Added ${r.added}',
      if (r.updated > 0) 'updated ${r.updated} from Notion edits',
      if (r.removed > 0) 'removed ${r.removed} deleted in Notion',
      if (r.refreshed > 0) 'updated ${r.refreshed} processed status',
    ];
    var text = r.error ??
        (parts.isEmpty
            ? 'Already matches Notion (${r.total} expense${r.total == 1 ? '' : 's'}).'
            : '${parts.join(', ')}.');
    if (r.error == null && r.missing > 0) {
      text += ' ${r.missing} not in Notion, kept on the phone and marked not '
          'uploaded.';
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 6),
      ));
  }

  Future<void> _applyDeletes() async {
    if (!_notionReady()) return;
    final messenger = ScaffoldMessenger.of(context);
    final left = repo.pendingDeletes;
    final done = await repo.applyPendingDeletes();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(done == left
            ? 'Archived $done in Notion'
            : 'Archived $done of $left. Try again when you are online.'),
      ));
  }

  Future<void> _deleteSelected() async {
    final messenger = ScaffoldMessenger.of(context);
    final chosen =
        repo.expenses.where((e) => _selected.contains(e.id)).toList();
    if (chosen.isEmpty) return;
    if (!await confirmDelete(context, repo, chosen)) return;
    final r = await repo.deleteExpenses(chosen);
    if (!mounted) return;
    _stopSelecting();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(deleteMessage(r))));
  }

  Future<void> _pushSelected() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!_notionReady()) return;
    final chosen = repo.expenses.where((e) => _selected.contains(e.id));
    final r = await repo.pushMany(chosen);
    if (!mounted) return;
    _stopSelecting();
    messenger.showSnackBar(SnackBar(
      content: Text(r.failed == 0
          ? 'Uploaded ${r.uploaded} expense(s)'
          : 'Uploaded ${r.uploaded}, failed ${r.failed}.'),
    ));
  }

  void _open(Expense? e) => Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ExpenseFormScreen(repo: repo, existing: e)));

  Widget _status(Expense e) {
    final scheme = Theme.of(context).colorScheme;
    if (repo.pushing.contains(e.id)) {
      return const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2));
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(e.synced ? Icons.cloud_done : Icons.cloud_off,
            size: 14, color: e.synced ? Colors.green : Colors.orange),
        const SizedBox(width: 4),
        Text(e.synced ? 'Uploaded' : 'On device',
            style: TextStyle(
                fontSize: 11,
                color: e.synced ? scheme.onSurfaceVariant : Colors.orange)),
      ],
    );
  }

  Widget _processedLabel(Expense e) => Text(
        e.processed ? 'Processed' : 'Unprocessed',
        style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: e.processed ? Colors.green.shade700 : Colors.red.shade700),
      );

  PreferredSizeWidget _appBar() {
    if (_selecting) {
      return AppBar(
        leading: IconButton(
            tooltip: 'Cancel selection',
            icon: const Icon(Icons.close),
            onPressed: _stopSelecting),
        title: Text('${_selected.length} selected'),
        actions: [
          IconButton(
              tooltip: 'Select all',
              icon: const Icon(Icons.select_all),
              onPressed: _toggleAll),
          IconButton(
              tooltip: 'Delete selected',
              icon: const Icon(Icons.delete_outline),
              onPressed: _selected.isEmpty ? null : _deleteSelected),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 16)),
              onPressed: _selected.isEmpty || repo.bulkPushing
                  ? null
                  : _pushSelected,
              icon: repo.bulkPushing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_upload, size: 18),
              label: const Text('Push'),
            ),
          ),
        ],
      );
    }
    return AppBar(
      title: const Text('Expenses'),
      actions: [
        IconButton(
          tooltip: 'Sync from Notion',
          icon: repo.importing
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.cloud_download_outlined),
          onPressed: repo.importing ? null : _syncFromNotion,
        ),
        if (repo.expenses.isNotEmpty)
          IconButton(
              tooltip: 'Select expenses to push',
              icon: const Icon(Icons.checklist),
              onPressed: _startSelecting),
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
              builder: (_) => SettingsScreen(api: repo.api, events: widget.events, repo: repo))),
        ),
      ],
    );
  }

  Widget _summary() {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final month = repo.expenses
        .where((e) => e.date.year == now.year && e.date.month == now.month);
    final total = month.fold<double>(0, (sum, e) => sum + e.amount);
    final notUploaded = repo.expenses.where((e) => !e.synced).length;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          colors: [scheme.primary, scheme.tertiary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${DateFormat.MMMM().format(now)} spending',
              style: TextStyle(
                  color: scheme.onPrimary.withValues(alpha: 0.85),
                  fontSize: 14)),
          const SizedBox(height: 6),
          Text(money(total),
              style: TextStyle(
                  color: scheme.onPrimary,
                  fontSize: 34,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Text(
            '${repo.expenses.length} expense${repo.expenses.length == 1 ? '' : 's'}'
            '  •  $notUploaded not uploaded',
            style: TextStyle(color: scheme.onPrimary.withValues(alpha: 0.85)),
          ),
        ],
      ),
    );
  }

  Widget _dayHeader(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Text(label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700)),
      );

  Widget _card(Expense e) {
    final style = categoryStyle(e.category);
    final isSel = _selected.contains(e.id);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        // Green = processed in Notion, red = not processed yet.
        color: Color.alphaBlend(
          (e.processed ? Colors.green : Colors.red).withValues(alpha: 0.14),
          scheme.surfaceContainerLow,
        ),
        shape: isSel
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(color: scheme.primary, width: 2))
            : null,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _selecting ? _toggle(e.id) : _open(e),
          onLongPress: _selecting ? null : () => _startSelecting(e.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                if (_selecting)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Checkbox(
                        value: isSel, onChanged: (_) => _toggle(e.id)),
                  )
                else
                  CircleAvatar(
                    backgroundColor: style.color.withValues(alpha: 0.15),
                    child: Icon(style.icon, color: style.color, size: 22),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(
                        [
                          e.category,
                          DateFormat.jm().format(e.date),
                          if (e.source.isNotEmpty) e.source,
                          if (e.mode.isNotEmpty) e.mode,
                        ].join(' • '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: scheme.onSurfaceVariant, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(money(e.amount),
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    _status(e),
                    const SizedBox(height: 2),
                    _processedLabel(e),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Summary card, then expenses grouped under day headings.
  List<Widget> _listItems() {
    final items = <Widget>[_summary(), if (repo.pendingDeletes > 0) _pendingBanner()];
    String? lastDay;
    for (final e in repo.expenses) {
      final label = dayLabel(e.date);
      if (label != lastDay) {
        items.add(_dayHeader(label));
        lastDay = label;
      }
      items.add(_card(e));
    }
    return items;
  }

  Widget _pendingBanner() => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Row(
              children: [
                const Icon(Icons.delete_sweep_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${repo.pendingDeletes} deleted expense'
                    '${repo.pendingDeletes == 1 ? '' : 's'} not archived in Notion yet',
                  ),
                ),
                TextButton(onPressed: _applyDeletes, child: const Text('Apply')),
              ],
            ),
          ),
        ),
      );

  Widget _empty() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.receipt_long, size: 72, color: scheme.outline),
            const SizedBox(height: 16),
            const Text('No expenses yet',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text('Tap “Add expense” to log your first one.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: repo,
      builder: (context, _) => PopScope(
        canPop: !_selecting,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _stopSelecting();
        },
        child: Scaffold(
          appBar: _appBar(),
          body: RefreshIndicator(
            onRefresh: _syncFromNotion,
            child: repo.expenses.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      SizedBox(
                        height: MediaQuery.of(context).size.height * 0.6,
                        child: _empty(),
                      ),
                    ],
                  )
                : Builder(builder: (_) {
                    final items = _listItems();
                    return ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                      itemCount: items.length,
                      itemBuilder: (_, i) => items[i],
                    );
                  }),
          ),
          floatingActionButton: _selecting
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => _open(null),
                  icon: const Icon(Icons.add),
                  label: const Text('Add expense'),
                ),
        ),
      ),
    );
  }
}

/// Adds a new expense, or edits [existing] when given.
class ExpenseFormScreen extends StatefulWidget {
  const ExpenseFormScreen({super.key, required this.repo, this.existing});
  final ExpenseRepository repo;
  final Expense? existing;

  @override
  State<ExpenseFormScreen> createState() => _ExpenseFormScreenState();
}

class _ExpenseFormScreenState extends State<ExpenseFormScreen> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.existing?.title);
  late final _amount = TextEditingController(
      text: widget.existing == null
          ? null
          : plainAmount(widget.existing!.amount));
  late final _note = TextEditingController(text: widget.existing?.note);
  late String _category = widget.existing?.category ??
      (widget.repo.options.categories.isEmpty
          ? 'Other'
          : widget.repo.options.categories.first);
  late String _mode = widget.existing?.mode ?? kDefaultMode;
  late String _source = widget.existing?.source ?? '';
  late DateTime _date = widget.existing?.date ?? DateTime.now();
  bool _saving = false;

  bool get _editing => widget.existing != null;

  ExpenseRepository get _repo => widget.repo;

  @override
  void dispose() {
    _title.dispose();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ options

  String _valueOf(OptionKind kind, Expense e) => switch (kind) {
        OptionKind.category => e.category,
        OptionKind.mode => e.mode,
        OptionKind.source => e.source,
      };

  /// Saved options first, then anything already used by an expense (popup app
  /// names, rows imported from Notion...), then the current selection.
  List<String> _choices(OptionKind kind, String selected) {
    final seen = <String>{};
    final out = <String>[];
    void add(String v) {
      final t = v.trim();
      if (t.isNotEmpty && seen.add(t.toLowerCase())) out.add(t);
    }

    _repo.options.listOf(kind).forEach(add);
    for (final e in _repo.expenses) {
      add(_valueOf(kind, e));
    }
    add(selected);
    return out;
  }

  Future<void> _newOption(OptionKind kind, void Function(String) pick) async {
    final name = await showDialog<String>(
        context: context, builder: (_) => _NewOptionDialog(kind: kind));
    if (name == null) return;
    final stored = await _repo.options.add(kind, name);
    if (stored.isNotEmpty && mounted) setState(() => pick(stored));
  }

  Future<void> _removeOption(OptionKind kind, String name) async {
    final messenger = ScaffoldMessenger.of(context);
    void say(String text) => messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));

    if (kind == OptionKind.mode && name == kDefaultMode) {
      return say('“$kDefaultMode” is the default mode and can’t be removed');
    }
    final used = _repo.expenses
        .where((e) => _valueOf(kind, e).toLowerCase() == name.toLowerCase())
        .length;
    if (used > 0) {
      return say('Can’t remove “$name”: $used expense${used == 1 ? '' : 's'} use it');
    }
    if (!_repo.options.contains(kind, name)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove “$name”?'),
        content: Text('It will no longer be offered as a ${kind.label}. '
            'Existing expenses are not affected.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              style: TextButton.styleFrom(
                  foregroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) {
      await _repo.options.remove(kind, name);
      if (mounted) setState(() {});
    }
  }

  /// One row of choice chips plus a "New" chip. Tap the selected chip again to
  /// clear it; hold a chip to remove it from your list.
  Widget _chips(OptionKind kind, String selected, void Function(String) pick) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final c in _choices(kind, selected))
          GestureDetector(
            onLongPress: () => _removeOption(kind, c),
            child: ChoiceChip(
              avatar: kind == OptionKind.category
                  ? Icon(categoryStyle(c).icon,
                      size: 18,
                      color: selected == c ? null : categoryStyle(c).color)
                  : null,
              label: Text(c),
              selected: selected == c,
              onSelected: (on) => setState(() => pick(on ? c : '')),
            ),
          ),
        ActionChip(
          avatar: const Icon(Icons.add, size: 18),
          label: const Text('New'),
          onPressed: () => _newOption(kind, pick),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ actions

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_date),
    );
    if (t == null) return;
    setState(() => _date = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final title = _title.text.trim();
    final amount = double.parse(_amount.text);
    final note = _note.text.trim();
    final mode = _mode.trim().isEmpty ? kDefaultMode : _mode.trim();
    final repo = _repo;
    final messenger = ScaffoldMessenger.of(context);
    final saved = _editing
        ? await repo.update(widget.existing!.copyWith(
            title: title,
            amount: amount,
            category: _category,
            date: _date,
            note: note,
            source: _source,
            mode: mode,
          ))
        : await repo.add(
            title: title,
            amount: amount,
            category: _category,
            date: _date,
            note: note,
            source: _source,
            mode: mode,
          );
    if (!mounted) return;
    Navigator.of(context).pop();
    // Upload in the background so a slow network never blocks the screen.
    unawaited(_pushInBackground(repo, messenger, saved));
  }

  Future<void> _delete() async {
    final repo = _repo;
    final messenger = ScaffoldMessenger.of(context);
    final e = widget.existing!;
    if (!await confirmDelete(context, repo, [e])) return;
    final r = await repo.deleteExpenses([e]);
    if (!mounted) return;
    Navigator.of(context).pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(deleteMessage(r))));
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(text,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700)),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Edit expense' : 'Add expense'),
        actions: [
          if (_editing)
            IconButton(
              tooltip: 'Delete expense',
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            if (_editing)
              Align(
                alignment: Alignment.centerLeft,
                child: Chip(
                  avatar: Icon(
                    widget.existing!.processed
                        ? Icons.check_circle
                        : Icons.pending_outlined,
                    color: widget.existing!.processed
                        ? Colors.green
                        : Colors.red,
                  ),
                  label: Text(widget.existing!.processed
                      ? 'Processed in Notion'
                      : 'Not processed yet'),
                ),
              ),

            // 1. Expense name
            _label('Expense name'),
            TextFormField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  hintText: 'e.g. Lunch', prefixIcon: Icon(Icons.edit_outlined)),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),

            // 2. Price
            _label('Price'),
            TextFormField(
              controller: _amount,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
              decoration: InputDecoration(
                prefixText: '$kCurrency ',
                prefixStyle: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    color: scheme.primary),
                hintText: '0',
                contentPadding: const EdgeInsets.symmetric(vertical: 16),
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              validator: (v) {
                final n = double.tryParse(v ?? '');
                return (n == null || n <= 0) ? 'Enter a valid price' : null;
              },
            ),

            // 3. Date & time
            _label('Date & time'),
            Material(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                onTap: _pickDate,
                leading: const Icon(Icons.event),
                title: Text(DateFormat.yMMMd().add_jm().format(_date)),
                trailing: const Icon(Icons.chevron_right),
              ),
            ),

            // 4. Category (required)
            _label('Category'),
            _chips(OptionKind.category, _category, (v) {
              if (v.isNotEmpty) _category = v; // a category is always chosen
            }),

            // 5. Mode ("Direct" unless set)
            _label('Mode'),
            _chips(OptionKind.mode, _mode,
                (v) => _mode = v.isEmpty ? kDefaultMode : v),

            // 6. Source (optional)
            _label('Source'),
            _chips(OptionKind.source, _source, (v) => _source = v),

            // 7. Note
            _label('Note (optional)'),
            TextFormField(
              controller: _note,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration:
                  const InputDecoration(hintText: 'Anything worth remembering'),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap New to add your own category, mode or source. Hold a chip '
              'to remove it from your list.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5))
                : Text(_editing ? 'Save changes' : 'Save expense'),
          ),
        ),
      ),
    );
  }
}

/// Asks for the name of a new category / mode / source.
class _NewOptionDialog extends StatefulWidget {
  const _NewOptionDialog({required this.kind});
  final OptionKind kind;

  @override
  State<_NewOptionDialog> createState() => _NewOptionDialogState();
}

class _NewOptionDialogState extends State<_NewOptionDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _name.text.trim();
    if (v.isNotEmpty) Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('New ${widget.kind.label}'),
      content: TextField(
        controller: _name,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(hintText: 'Name of the ${widget.kind.label}'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        TextButton(onPressed: _submit, child: const Text('Add')),
      ],
    );
  }
}

/// Right after a save: push if possible, then say what happened.
Future<void> _pushInBackground(ExpenseRepository repo,
    ScaffoldMessengerState messenger, Expense saved) async {
  final r = await repo.autoPush(saved);
  final text = switch (r?.status) {
    null => 'Saved on device',
    PushStatus.ok => 'Saved and uploaded to Notion',
    PushStatus.offline => 'Saved on device. No connection, push it later.',
    PushStatus.rejected => 'Saved on device. ${r!.message}',
    PushStatus.busy => 'Saved on device',
  };
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}
