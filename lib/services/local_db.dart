import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/expense.dart';

class LocalDb {
  LocalDb._();
  static final LocalDb instance = LocalDb._();

  Database? _db;

  Future<Database> get _database async => _db ??= await _open();

  Future<Database> _open() async {
    final path = join(await getDatabasesPath(), 'expenses.db');
    return openDatabase(
      path,
      version: 3,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE expenses(
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            amount REAL NOT NULL,
            category TEXT NOT NULL,
            date TEXT NOT NULL,
            note TEXT,
            source TEXT NOT NULL DEFAULT '',
            mode TEXT NOT NULL DEFAULT '',
            synced INTEGER NOT NULL DEFAULT 0,
            remote_id TEXT,
            processed INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute(
            'CREATE TABLE pending_deletes(remote_id TEXT PRIMARY KEY)');
      },
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) {
          await db.execute(
              "ALTER TABLE expenses ADD COLUMN source TEXT NOT NULL DEFAULT ''");
          await db.execute(
              "ALTER TABLE expenses ADD COLUMN mode TEXT NOT NULL DEFAULT ''");
          await db.execute('ALTER TABLE expenses ADD COLUMN remote_id TEXT');
          // Earlier "uploads" went to a placeholder API, not Notion.
          await db.execute('UPDATE expenses SET synced = 0');
        }
        if (oldVersion < 3) {
          await db.execute(
              'ALTER TABLE expenses ADD COLUMN processed INTEGER NOT NULL DEFAULT 0');
          await db.execute(
              'CREATE TABLE IF NOT EXISTS pending_deletes(remote_id TEXT PRIMARY KEY)');
        }
      },
    );
  }

  Future<void> insert(Expense e) async {
    final db = await _database;
    await db.insert('expenses', e.toDb(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> markSynced(String id, {String? remoteId}) async {
    final db = await _database;
    await db.update(
      'expenses',
      {'synced': 1, if (remoteId != null) 'remote_id': remoteId},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> setProcessed(String id, bool processed) async {
    final db = await _database;
    await db.update('expenses', {'processed': processed ? 1 : 0},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> delete(String id) async {
    final db = await _database;
    await db.delete('expenses', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Expense>> all() async {
    final db = await _database;
    final rows = await db.query('expenses', orderBy: 'date DESC');
    return rows.map(Expense.fromDb).toList();
  }

  Future<List<Expense>> pending() async {
    final db = await _database;
    final rows = await db.query('expenses',
        where: 'synced = 0', orderBy: 'date ASC');
    return rows.map(Expense.fromDb).toList();
  }

  /// Notion pages whose expense was deleted here but not yet archived there.
  Future<List<String>> pendingDeletes() async {
    final db = await _database;
    final rows = await db.query('pending_deletes');
    return rows.map((r) => r['remote_id'] as String).toList();
  }

  Future<void> addPendingDelete(String remoteId) async {
    final db = await _database;
    await db.insert('pending_deletes', {'remote_id': remoteId},
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> removePendingDelete(String remoteId) async {
    final db = await _database;
    await db.delete('pending_deletes',
        where: 'remote_id = ?', whereArgs: [remoteId]);
  }
}
