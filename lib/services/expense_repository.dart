import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../models/expense.dart';
import 'api_service.dart';
import 'local_db.dart';
import 'options_store.dart';

enum PushStatus { ok, offline, rejected, busy }

class PushResult {
  const PushResult(this.status, [this.detail]);
  final PushStatus status;
  final String? detail;
  bool get ok => status == PushStatus.ok;

  String get message => switch (status) {
        PushStatus.ok => 'Uploaded',
        PushStatus.offline => 'No connection, or Notion is busy. Try again.',
        PushStatus.rejected => detail ?? 'Rejected by server',
        PushStatus.busy => 'Already uploading',
      };
}

class ImportSummary {
  const ImportSummary({this.added = 0, this.refreshed = 0, this.total = 0, this.error});
  final int added; // new expenses brought in from Notion
  final int refreshed; // existing expenses whose Processed flag changed
  final int total; // pages Notion returned
  final String? error;
}

class DeleteSummary {
  const DeleteSummary({this.removed = 0, this.archived = 0, this.queued = 0});
  final int removed; // expenses removed from the phone
  final int archived; // Notion pages archived right now
  final int queued; // archives still waiting (manual mode, or offline)
}

class BulkSummary {
  const BulkSummary(this.uploaded, this.failed);
  final int uploaded;
  final int failed;
}

/// Everything is saved on the device first. Right after a save the app tries to
/// push it to Notion ([autoPush]); if that isn't possible (offline, not set up,
/// rejected) the expense simply stays on the device until pushed manually.
class ExpenseRepository extends ChangeNotifier {
  ExpenseRepository({
    LocalDb? db,
    required ApiService api,
    OptionsStore? options,
    this.pushGap = const Duration(milliseconds: 350),
  })  : _db = db ?? LocalDb.instance,
        _api = api,
        options = options ?? OptionsStore.memory();

  final LocalDb _db;
  final ApiService _api;

  /// Pause between calls in a bulk push (Notion allows ~3 requests/second).
  final Duration pushGap;

  ApiService get api => _api;

  /// The user's saved categories, modes and sources.
  final OptionsStore options;
  AppLifecycleListener? _lifecycle;

  List<Expense> expenses = [];

  /// Ids of expenses with an upload in flight (drives per-row spinners).
  final Set<String> pushing = {};

  /// True while a bulk push is looping.
  bool bulkPushing = false;

  /// True while "Sync from Notion" is running.
  bool importing = false;

  /// Expenses deleted here whose Notion page isn't archived yet.
  int pendingDeletes = 0;

  Future<void> init() async {
    expenses = await _db.all();
    notifyListeners();
    // Expenses can also be added by the native popup while the app is closed.
    _lifecycle = AppLifecycleListener(onResume: reload);
  }

  Future<Expense> add({
    required String title,
    required double amount,
    required String category,
    required DateTime date,
    String note = '',
    String source = '',
    String mode = kDefaultMode,
  }) async {
    final e = Expense(
      id: const Uuid().v4(),
      title: title,
      amount: amount,
      category: category,
      date: date,
      note: note,
      source: source,
      mode: mode,
    );
    await _db.insert(e);
    await reload();
    return e;
  }

  /// Saves edits locally. The row is flagged as not uploaded because the
  /// server's copy (if any) is now stale.
  Future<Expense> update(Expense edited) async {
    final stored = edited.copyWith(synced: false);
    await _db.insert(stored); // insert = replace by id
    await reload();
    return stored;
  }

  /// Called right after a save. Pushes if sync is set to Auto and Notion is set
  /// up; returns null when nothing was attempted. A failed push leaves the
  /// expense on the device, to be pushed manually later.
  Future<PushResult?> autoPush(Expense e) async {
    if (!_api.settings.autoSync || !_api.settings.isConfigured) return null;
    final r = await push(e);
    // Notion is reachable, so also finish any archives that were waiting.
    if (r.ok && pendingDeletes > 0) await applyPendingDeletes();
    return r;
  }

  /// Uploads one expense.
  Future<PushResult> push(Expense e) async {
    if (!pushing.add(e.id)) return const PushResult(PushStatus.busy);
    notifyListeners();
    try {
      final r = await _api.upload(e);
      if (r.ok) {
        await _db.markSynced(e.id, remoteId: r.pageId);
        return const PushResult(PushStatus.ok);
      }
      return const PushResult(PushStatus.offline);
    } on ApiRejected catch (err) {
      debugPrint('$err');
      return PushResult(PushStatus.rejected, 'Notion: ${err.message}');
    } finally {
      pushing.remove(e.id);
      await reload();
    }
  }

  /// Bulk push: loops over [selected], one API call each, and keeps going when
  /// one fails so a single bad row doesn't block the rest.
  Future<BulkSummary> pushMany(Iterable<Expense> selected) async {
    if (bulkPushing) return const BulkSummary(0, 0);
    bulkPushing = true;
    notifyListeners();
    var uploaded = 0, failed = 0;
    try {
      var first = true;
      for (final e in selected.toList()) {
        if (!first) await Future<void>.delayed(pushGap);
        first = false;
        final r = await push(e);
        if (r.ok) {
          uploaded++;
        } else if (r.status != PushStatus.busy) {
          failed++;
        }
      }
    } finally {
      bulkPushing = false;
      notifyListeners();
    }
    return BulkSummary(uploaded, failed);
  }

  Future<void> reload() async {
    expenses = await _db.all();
    pendingDeletes = (await _db.pendingDeletes()).length;
    notifyListeners();
  }

  // ------------------------------------------------------------------ delete

  /// Removes expenses from the phone. Ones that exist in Notion are queued for
  /// archiving, which happens right away in Auto mode and otherwise waits for
  /// [applyPendingDeletes] (the banner's Apply button).
  Future<DeleteSummary> deleteExpenses(Iterable<Expense> list) async {
    var removed = 0;
    for (final e in list.toList()) {
      await _db.delete(e.id);
      if (e.remoteId != null) await _db.addPendingDelete(e.remoteId!);
      removed++;
    }
    await reload();
    var archived = 0;
    if (_api.settings.autoSync && _api.settings.isConfigured) {
      archived = await applyPendingDeletes();
    }
    return DeleteSummary(
        removed: removed, archived: archived, queued: pendingDeletes);
  }

  /// Archives every queued Notion page. Returns how many succeeded.
  Future<int> applyPendingDeletes() async {
    if (!_api.settings.isConfigured) return 0;
    var done = 0;
    var first = true;
    for (final pageId in await _db.pendingDeletes()) {
      if (!first) await Future<void>.delayed(pushGap);
      first = false;
      try {
        final r = await _api.archive(pageId);
        if (r.ok) {
          await _db.removePendingDelete(pageId);
          done++;
        }
      } on ApiRejected catch (err) {
        debugPrint('$err'); // stays queued
      }
    }
    await reload();
    return done;
  }

  // -------------------------------------------------------------------- read

  static String _norm(String id) => id.replaceAll('-', '').toLowerCase();

  /// "Sync from Notion". Import only: brings in Notion rows the phone doesn't
  /// have and never changes the ones it does, with one exception: the
  /// read-only Processed flag, which is refreshed so the row colour is right.
  /// Pages whose expense was deleted here (archive pending) are skipped so they
  /// don't come back.
  Future<ImportSummary> importFromNotion() async {
    if (importing) return const ImportSummary();
    importing = true;
    notifyListeners();
    try {
      final pages = await _api.queryAllPages();
      final byRemote = {
        for (final e in await _db.all())
          if (e.remoteId != null) _norm(e.remoteId!): e
      };
      final queuedDeletes =
          (await _db.pendingDeletes()).map(_norm).toSet();

      var added = 0, refreshed = 0;
      for (final page in pages) {
        final parsed = ApiService.expenseFromPage(page);
        if (parsed == null) continue;
        final key = _norm(parsed.remoteId!);
        if (queuedDeletes.contains(key)) continue;
        final existing = byRemote[key];
        if (existing == null) {
          await _db.insert(parsed);
          byRemote[key] = parsed;
          added++;
        } else if (existing.processed != parsed.processed) {
          await _db.setProcessed(existing.id, parsed.processed);
          refreshed++;
        }
      }
      return ImportSummary(added: added, refreshed: refreshed, total: pages.length);
    } on ApiRejected catch (err) {
      return ImportSummary(error: 'Notion: ${err.message}');
    } on ApiOffline {
      return const ImportSummary(
          error: 'No connection, or Notion is busy. Try again.');
    } finally {
      importing = false;
      await reload();
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }
}
