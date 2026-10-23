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
  const ImportSummary(
      {this.added = 0,
      this.updated = 0,
      this.removed = 0,
      this.missing = 0,
      this.refreshed = 0,
      this.known = 0,
      this.total = 0,
      this.error});
  final int added; // new expenses brought in from Notion
  final int updated; // existing expenses changed to match an edit made in Notion
  final int removed; // expenses removed because they were deleted in Notion
  final int missing; // gone from Notion but kept on the phone (declined/skipped)
  final int refreshed; // existing expenses whose Processed flag changed
  final int known; // Notion rows that were already on the phone
  final int total; // pages Notion returned
  final String? error;
}

class DeleteSummary {
  const DeleteSummary({this.removed = 0, this.archived = 0, this.queued = 0});
  final int removed; // expenses removed from the phone
  final int archived; // Notion pages archived right now
  final int queued; // archives still waiting (manual mode, or offline)
}

class SwitchSummary {
  const SwitchSummary({this.removed = 0, this.detached = 0, required this.imported});
  final int removed; // expenses of the old database taken off this phone
  final int detached; // expenses kept, no longer linked to the old database
  final ImportSummary imported; // what the new database brought in
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

  // ------------------------------------------------- switching databases

  /// Called when the expenses database was changed to a different one. The
  /// expenses on the phone are still linked to pages of the old database, so
  /// they are dealt with, then the new database is loaded.
  ///
  /// [replace] true: expenses already uploaded to the old database (and not
  /// edited since) are removed from the phone, because they are safe there.
  /// false: nothing is removed.
  /// Either way, an expense that is NOT safely in the old database (never
  /// pushed, or edited after its push) is kept, and every kept expense is
  /// detached from the old database (no Notion link, marked not uploaded) so it
  /// can be pushed to the new one. Waiting deletions for the old database are
  /// dropped, since they point at pages that belong to it.
  Future<SwitchSummary> switchDatabase({required bool replace}) async {
    var removed = 0, detached = 0;
    for (final e in await _db.all()) {
      final safeInOld = e.synced && e.remoteId != null;
      if (replace && safeInOld) {
        await _db.delete(e.id);
        removed++;
      } else if (e.synced || e.remoteId != null || e.processed) {
        await _db.insert(e.copyWith(
            synced: false, processed: false, clearRemoteId: true));
        detached++;
      }
    }
    for (final pageId in await _db.pendingDeletes()) {
      await _db.removePendingDelete(pageId);
    }
    await reload();
    final imported = await importFromNotion();
    return SwitchSummary(removed: removed, detached: detached, imported: imported);
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

  static bool _sameMinute(DateTime a, DateTime b) =>
      a.year == b.year &&
      a.month == b.month &&
      a.day == b.day &&
      a.hour == b.hour &&
      a.minute == b.minute;

  /// Does the phone's copy already match what Notion has? (The note isn't in
  /// Notion, and seconds aren't compared.)
  static bool _sameAsNotion(Expense local, Expense notion) =>
      local.title.trim() == notion.title.trim() &&
      local.amount == notion.amount &&
      local.category == notion.category &&
      local.mode == notion.mode &&
      local.source == notion.source &&
      _sameMinute(local.date, notion.date);

  /// "Sync from Notion": makes the phone match Notion.
  ///
  /// * rows the phone doesn't have are added;
  /// * an expense that is safely in sync (uploaded, not edited here since) is
  ///   updated to match edits made in Notion, and its Processed flag refreshed;
  /// * an expense that was deleted/archived in Notion is removed from the phone
  ///   (see [confirmRemoval]);
  /// * an expense never pushed, or edited on the phone since its push, is never
  ///   changed or removed (only its Processed flag is refreshed).
  ///
  /// [confirmRemoval] is asked with the expenses that are gone from Notion.
  /// Without it nothing is ever removed. Nothing is removed either when Notion
  /// returns no rows at all, since that is more likely a wrong database than
  /// every expense being deleted. An expense that is kept although it is not in
  /// Notion is marked "not uploaded" (no Notion link), so it can be pushed
  /// again. Pages whose deletion is pending are skipped, so they don't come back.
  Future<ImportSummary> importFromNotion({
    Future<bool> Function(List<Expense> missing)? confirmRemoval,
  }) async {
    if (importing) return const ImportSummary();
    importing = true;
    notifyListeners();
    try {
      final pages = await _api.queryAllPages(); // complete, or it throws
      final local = await _db.all();
      final byRemote = {
        for (final e in local)
          if (e.remoteId != null) _norm(e.remoteId!): e
      };
      final queuedDeletes = (await _db.pendingDeletes()).map(_norm).toSet();

      var added = 0, updated = 0, refreshed = 0, known = 0;
      final seen = <String>{};
      for (final page in pages) {
        final parsed = ApiService.expenseFromPage(page);
        if (parsed == null) continue;
        final key = _norm(parsed.remoteId!);
        seen.add(key);
        if (queuedDeletes.contains(key)) continue;
        final existing = byRemote[key];
        if (existing == null) {
          await _db.insert(parsed);
          byRemote[key] = parsed;
          added++;
          continue;
        }
        known++;
        if (existing.synced && !_sameAsNotion(existing, parsed)) {
          // Safely in sync here, so the edit made in Notion wins.
          await _db.insert(existing.copyWith(
            title: parsed.title,
            amount: parsed.amount,
            category: parsed.category,
            date: parsed.date,
            source: parsed.source,
            mode: parsed.mode,
            processed: parsed.processed,
          ));
          updated++;
        } else if (existing.processed != parsed.processed) {
          await _db.setProcessed(existing.id, parsed.processed);
          refreshed++;
        }
      }

      // Uploaded and unchanged here, yet no longer in Notion: deleted there.
      final missing = [
        for (final e in local)
          if (e.remoteId != null &&
              e.synced &&
              !seen.contains(_norm(e.remoteId!)))
            e
      ];
      var removed = 0;
      if (missing.isNotEmpty) {
        var remove = false;
        if (pages.isNotEmpty && confirmRemoval != null) {
          // Fetching is done: don't keep spinning behind the question.
          importing = false;
          notifyListeners();
          remove = await confirmRemoval(missing);
        }
        if (remove) {
          for (final e in missing) {
            await _db.delete(e.id);
            removed++;
          }
        } else if (pages.isEmpty || confirmRemoval != null) {
          // Kept, but they are not in this Notion database. Stop calling them
          // "uploaded" (and drop the link to a page that isn't here), so they can
          // be pushed again as new pages. Without a way to ask, they are left
          // exactly as they were.
          for (final e in missing) {
            await _db.insert(e.copyWith(
                synced: false, processed: false, clearRemoteId: true));
          }
        }
      }

      return ImportSummary(
        added: added,
        updated: updated,
        removed: removed,
        missing: missing.length - removed,
        refreshed: refreshed,
        known: known,
        total: pages.length,
      );
    } on ApiRejected catch (err) {
      return ImportSummary(error: 'Notion: ${err.message}');
    } on ApiOffline {
      return const ImportSummary(
          error: 'No connection, or Notion is busy. Try again.');
    } catch (e) {
      // Anything unexpected (a reply that can't be read...) must still end in a
      // message instead of a button that silently does nothing.
      return ImportSummary(error: 'Could not read the Notion database ($e)');
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
