import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../models/expense.dart';
import 'api_service.dart';
import 'local_db.dart';
import 'options_store.dart';
import 'sync_settings.dart';

enum PushStatus { ok, offline, rejected, busy, signedOut }

class PushResult {
  const PushResult(this.status, [this.detail]);
  final PushStatus status;
  final String? detail;
  bool get ok => status == PushStatus.ok;

  String get message => switch (status) {
        PushStatus.ok => 'Uploaded',
        PushStatus.offline => 'No connection, or the server is busy. Try again.',
        PushStatus.rejected => detail ?? 'Rejected by the server',
        PushStatus.busy => 'Already uploading',
        PushStatus.signedOut => 'Your session expired. Sign in again.',
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
  final int added; // new expenses brought in from the server
  final int updated; // existing expenses changed to match an edit made elsewhere
  final int removed; // expenses removed because they were deleted on the server
  final int missing; // gone from the server but kept on the phone
  final int refreshed; // existing expenses whose Processed flag changed
  final int known; // server expenses that were already on the phone
  final int total; // expenses the server returned
  final String? error;
}

class DeleteSummary {
  const DeleteSummary({this.removed = 0, this.archived = 0, this.queued = 0});
  final int removed; // expenses removed from the phone
  final int archived; // expenses deleted on the server right now
  final int queued; // server deletions still waiting (manual mode, or offline)
}

class BulkSummary {
  const BulkSummary(this.uploaded, this.failed);
  final int uploaded;
  final int failed;
}

/// Everything is saved on the device first. Right after a save, in Auto mode, the
/// app pushes it to the server ([autoPush]); if that isn't possible (offline,
/// signed out, rejected) the expense stays on the device until pushed manually.
class ExpenseRepository extends ChangeNotifier {
  ExpenseRepository({
    LocalDb? db,
    required ApiService api,
    required this.sync,
    OptionsStore? options,
    this.pushGap = const Duration(milliseconds: 100),
  })  : _db = db ?? LocalDb.instance,
        _api = api,
        options = options ?? OptionsStore.memory();

  final LocalDb _db;
  final ApiService _api;

  /// Auto or Manual pushing.
  final SyncSettings sync;

  /// Pause between calls when looping over several expenses.
  final Duration pushGap;

  ApiService get api => _api;
  bool get signedIn => _api.session.isSignedIn;

  /// The user's saved categories, modes and sources.
  final OptionsStore options;
  AppLifecycleListener? _lifecycle;

  List<Expense> expenses = [];

  /// Ids of expenses with an upload in flight (drives per-row spinners).
  final Set<String> pushing = {};

  /// True while a bulk push is looping.
  bool bulkPushing = false;

  /// True while "Sync from server" is running.
  bool importing = false;

  /// Expenses deleted here that the server hasn't been told about yet.
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

  /// Called right after a save. Pushes if sync is set to Auto and you are signed
  /// in; returns null when nothing was attempted. A failed push leaves the
  /// expense on the device, to be pushed manually later.
  Future<PushResult?> autoPush(Expense e) async {
    if (!sync.autoSync || !signedIn) return null;
    final r = await push(e);
    // The server is reachable, so also finish any deletions that were waiting.
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
      return PushResult(PushStatus.rejected, 'Server: ${err.message}');
    } on SessionExpired {
      return const PushResult(PushStatus.signedOut);
    } finally {
      pushing.remove(e.id);
      await reload();
    }
  }

  /// Bulk push: loops over [selected], one API call each, and keeps going when
  /// one fails so a single bad row doesn't block the rest. Stops if the session
  /// has ended, since every further call would fail the same way.
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
        if (r.status == PushStatus.signedOut) break;
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

  // ------------------------------------------------------------ account change

  /// Removes everything on the phone that belongs to the previous account:
  /// expenses, waiting deletions and the custom pick-lists. Used when someone
  /// else signs in, and the first time anyone signs in to the server.
  Future<void> wipeLocal() async {
    await _db.clearAll();
    await options.reset();
    await reload();
  }

  // ------------------------------------------------------------------ delete

  /// Removes expenses from the phone. Ones the server has are queued for
  /// deleting there too, which happens right away in Auto mode and otherwise
  /// waits for [applyPendingDeletes] (the banner's Apply button).
  Future<DeleteSummary> deleteExpenses(Iterable<Expense> list) async {
    var removed = 0;
    for (final e in list.toList()) {
      await _db.delete(e.id);
      if (e.remoteId != null) await _db.addPendingDelete(e.remoteId!);
      removed++;
    }
    await reload();
    var archived = 0;
    if (sync.autoSync && signedIn) archived = await applyPendingDeletes();
    return DeleteSummary(
        removed: removed, archived: archived, queued: pendingDeletes);
  }

  /// Deletes every queued expense on the server. Returns how many succeeded.
  Future<int> applyPendingDeletes() async {
    if (!signedIn) return 0;
    var done = 0;
    var first = true;
    for (final id in await _db.pendingDeletes()) {
      if (!first) await Future<void>.delayed(pushGap);
      first = false;
      try {
        final r = await _api.remove(id);
        if (r.ok) {
          await _db.removePendingDelete(id);
          done++;
        }
      } on ApiRejected catch (err) {
        debugPrint('$err'); // stays queued
      } on SessionExpired {
        break;
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

  /// Does the phone's copy already match the server's? (Seconds aren't compared.)
  static bool _sameAsServer(Expense local, Expense server) =>
      local.title.trim() == server.title.trim() &&
      local.amount == server.amount &&
      local.category == server.category &&
      local.mode == server.mode &&
      local.source == server.source &&
      local.note == server.note &&
      _sameMinute(local.date, server.date);

  /// "Sync from server": makes the phone match the server.
  ///
  /// * expenses the phone doesn't have are added;
  /// * an expense that is safely in sync (uploaded, not edited here since) is
  ///   updated to match edits made elsewhere (the website), and its Processed
  ///   flag refreshed;
  /// * an expense that was deleted on the server is removed from the phone (see
  ///   [confirmRemoval]);
  /// * an expense never pushed, or edited on the phone since its push, is never
  ///   changed or removed (only its Processed flag is refreshed).
  ///
  /// [confirmRemoval] is asked with the expenses that are gone from the server.
  /// Without it nothing is ever removed. Nothing is removed either when the
  /// server returns no expenses at all. An expense that is kept although the
  /// server doesn't have it is marked "not uploaded" (no server link), so it can
  /// be pushed again. Expenses whose deletion is pending are skipped, so they
  /// don't come back.
  Future<ImportSummary> refreshFromServer({
    Future<bool> Function(List<Expense> missing)? confirmRemoval,
  }) async {
    if (importing) return const ImportSummary();
    importing = true;
    notifyListeners();
    try {
      final fromServer = await _api.listAll(); // complete, or it throws
      final local = await _db.all();
      final byRemote = {
        for (final e in local)
          if (e.remoteId != null) _norm(e.remoteId!): e
      };
      final queuedDeletes = (await _db.pendingDeletes()).map(_norm).toSet();

      var added = 0, updated = 0, refreshed = 0, known = 0;
      final seen = <String>{};
      for (final parsed in fromServer) {
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
        if (existing.synced && !_sameAsServer(existing, parsed)) {
          // Safely in sync here, so the edit made elsewhere wins.
          await _db.insert(existing.copyWith(
            title: parsed.title,
            amount: parsed.amount,
            category: parsed.category,
            date: parsed.date,
            source: parsed.source,
            mode: parsed.mode,
            note: parsed.note,
            processed: parsed.processed,
          ));
          updated++;
        } else if (existing.processed != parsed.processed) {
          await _db.setProcessed(existing.id, parsed.processed);
          refreshed++;
        }
      }

      // Uploaded and unchanged here, yet the server no longer has it: deleted.
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
        if (fromServer.isNotEmpty && confirmRemoval != null) {
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
        } else if (fromServer.isEmpty || confirmRemoval != null) {
          // Kept, but the server doesn't have them. Stop calling them "uploaded"
          // (and drop the link), so they can be pushed again as new expenses.
          // Without a way to ask, they are left exactly as they were.
          for (final e in missing) {
            await _db.insert(e.copyWith(
                synced: false, processed: false, clearRemoteId: true));
          }
        }
      }

      await _mergeServerOptions();
      return ImportSummary(
        added: added,
        updated: updated,
        removed: removed,
        missing: missing.length - removed,
        refreshed: refreshed,
        known: known,
        total: fromServer.length,
      );
    } on ApiRejected catch (err) {
      return ImportSummary(error: 'Server: ${err.message}');
    } on ApiOffline {
      return const ImportSummary(
          error: 'No connection, or the server is busy. Try again.');
    } on SessionExpired {
      return const ImportSummary(error: 'Your session expired. Sign in again.');
    } catch (e) {
      // Anything unexpected (a reply that can't be read...) must still end in a
      // message instead of a button that silently does nothing.
      return ImportSummary(error: 'Could not read the expenses from the server ($e)');
    } finally {
      importing = false;
      await reload();
    }
  }

  /// Offers the account's own categories, modes and sources in the form.
  Future<void> _mergeServerOptions() async {
    try {
      final o = await _api.options();
      await options.mergeFromServer(
          categories: o.categories, modes: o.modes, sources: o.sources);
    } catch (_) {} // the lists are a convenience; never fail a refresh over them
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }
}
