import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/services/local_db.dart';

/// In-memory stand-in for the sqflite database.
class FakeDb implements LocalDb {
  final Map<String, Expense> rows = {};

  @override
  Future<void> insert(Expense e) async => rows[e.id] = e;

  @override
  Future<void> markSynced(String id, {String? remoteId}) async =>
      rows[id] = rows[id]!.copyWith(synced: true, remoteId: remoteId);

  @override
  Future<List<Expense>> all() async =>
      rows.values.toList()..sort((a, b) => b.date.compareTo(a.date));

  @override
  Future<List<Expense>> pending() async =>
      rows.values.where((e) => !e.synced).toList();

  @override
  Future<void> setProcessed(String id, bool processed) async =>
      rows[id] = rows[id]!.copyWith(processed: processed);

  @override
  Future<void> delete(String id) async => rows.remove(id);

  final Set<String> tombstones = {};

  @override
  Future<List<String>> pendingDeletes() async => tombstones.toList();

  @override
  Future<void> addPendingDelete(String remoteId) async =>
      tombstones.add(remoteId);

  @override
  Future<void> removePendingDelete(String remoteId) async =>
      tombstones.remove(remoteId);
}
