import 'dart:convert';

import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/screens/settings_screen.dart';
import 'package:expense_tracker/services/api_service.dart';
import 'package:expense_tracker/services/expense_repository.dart';
import 'package:expense_tracker/services/notion_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

Expense _e(String id,
        {String? remote, bool synced = false, bool processed = false, String title = ''}) =>
    Expense(
      id: id,
      title: title.isEmpty ? 'Expense $id' : title,
      amount: 5,
      category: 'Other',
      date: DateTime(2026, 10, 1),
      synced: synced,
      processed: processed,
      remoteId: remote,
    );

Map<String, dynamic> _page(String id, String title) => {
      'id': id,
      'properties': {
        'Expense': {
          'title': [
            {'plain_text': title}
          ]
        },
        'Amount': {'number': 9},
        'Date': {
          'date': {'start': '2026-10-20'}
        },
        'Category': {
          'multi_select': [
            {'name': 'Food'}
          ]
        },
        'Source': {'multi_select': []},
        'Mode': {'multi_select': []},
        'Processed': {'checkbox': false},
      },
    };

http.Response _dbOk() => http.Response(
    jsonEncode({
      'title': [
        {'plain_text': 'New database'}
      ],
      'properties': {
        'Expense': {'type': 'title'},
        'Amount': {'type': 'number'},
        'Date': {'type': 'date'},
        'Category': {'type': 'multi_select'},
        'Source': {'type': 'multi_select'},
        'Mode': {'type': 'multi_select'},
        'Processed': {'type': 'checkbox'},
      }
    }),
    200);

class Env {
  Env({String token = 'old-token', String db = 'old-db', bool dbHealthy = true}) {
    api = ApiService(
      settings: NotionSettings(token: token, databaseId: db),
      pageGap: Duration.zero,
      client: MockClient((r) async {
        calls.add(r);
        if (r.method == 'GET') {
          return dbHealthy ? _dbOk() : http.Response('{}', 404);
        }
        if (r.url.path.endsWith('/query')) {
          return http.Response(
              jsonEncode({
                'results': [_page('new-1', 'From new db'), _page('new-2', 'Also new')],
                'has_more': false,
              }),
              200);
        }
        return http.Response('{"id":"x"}', 200);
      }),
    );
    repo = ExpenseRepository(db: store, api: api, pushGap: Duration.zero);
  }
  final store = FakeDb();
  final calls = <http.Request>[];
  late final ApiService api;
  late final ExpenseRepository repo;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // The mix of expenses a phone could hold when the connection is switched.
  void seed(FakeDb db) {
    db.rows['safe1'] = _e('safe1', remote: 'old-page-1', synced: true, processed: true);
    db.rows['safe2'] = _e('safe2', remote: 'old-page-2', synced: true);
    db.rows['never'] = _e('never'); // never pushed
    db.rows['edited'] = _e('edited', remote: 'old-page-3'); // pushed, then edited
    db.tombstones.add('old-page-9'); // a deletion waiting for the old database
  }

  group('switchDatabase (the logic)', () {
    test('Replace: uploaded ones go, unpushed work stays and is detached, new loads',
        () async {
      final env = Env();
      seed(env.store);
      await env.repo.reload();

      final r = await env.repo.switchDatabase(replace: true);

      // The two safely-uploaded expenses are removed from the phone.
      expect(env.store.rows.containsKey('safe1'), isFalse);
      expect(env.store.rows.containsKey('safe2'), isFalse);
      expect(r.removed, 2);
      // Unpushed work is never lost, and no longer points at the old database.
      for (final id in ['never', 'edited']) {
        final e = env.store.rows[id]!;
        expect(e.synced, isFalse, reason: id);
        expect(e.remoteId, isNull, reason: id);
      }
      expect(r.detached, 1); // only 'edited' needed detaching; 'never' was clean
      // Waiting deletions belonged to the old database: dropped.
      expect(env.store.tombstones, isEmpty);
      // The new database was loaded.
      expect(r.imported.added, 2);
      expect(env.store.rows.values.map((e) => e.title),
          containsAll(['From new db', 'Also new']));
      // 2 kept + 2 new
      expect(env.store.rows.length, 4);
      expect(env.repo.expenses.length, 4);
    });

    test('Keep all: nothing is removed, all are detached, new loads', () async {
      final env = Env();
      seed(env.store);
      await env.repo.reload();

      final r = await env.repo.switchDatabase(replace: false);

      expect(r.removed, 0);
      for (final id in ['safe1', 'safe2', 'never', 'edited']) {
        expect(env.store.rows.containsKey(id), isTrue, reason: id);
        final e = env.store.rows[id]!;
        expect(e.synced, isFalse, reason: id);
        expect(e.remoteId, isNull, reason: id);
        expect(e.processed, isFalse, reason: id); // was the old database's state
      }
      expect(r.detached, 3); // safe1, safe2, edited
      expect(env.store.tombstones, isEmpty);
      expect(env.store.rows.length, 4 + 2);
    });

    test('an empty phone just loads the new database', () async {
      final env = Env();
      final r = await env.repo.switchDatabase(replace: true);
      expect(r.removed, 0);
      expect(r.detached, 0);
      expect(env.store.rows.length, 2);
    });

    test('a kept expense can be pushed to the new database as a fresh page',
        () async {
      final env = Env();
      env.store.rows['edited'] = _e('edited', remote: 'old-page-3');
      await env.repo.reload();
      await env.repo.switchDatabase(replace: true);

      env.calls.clear();
      final r = await env.repo.push(env.store.rows['edited']!);
      expect(r.ok, isTrue);
      // A create (POST /pages), not an update of a page from the old database.
      expect(env.calls.single.method, 'POST');
      expect(env.calls.single.url.path, '/v1/pages');
    });
  });

  group('Settings: switching the connection', () {
    Future<void> open(WidgetTester t, Env env) async {
      t.view.physicalSize = const Size(800, 3000);
      t.view.devicePixelRatio = 2.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      const channel = MethodChannel('expense_tracker/watcher');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
        switch (c.method) {
          case 'getInstalledApps':
          case 'getWatched':
            return <Object?>[];
          case 'permissionStatus':
            return {'usage': true, 'overlay': true, 'battery': true};
          case 'isEnabled':
          case 'isBubbleEnabled':
            return false;
          default:
            return null;
        }
      });
      addTearDown(() =>
          t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      await t.pumpWidget(MaterialApp(
          home: SettingsScreen(api: env.api, repo: env.repo)));
      await t.pumpAndSettle();
      await t.tap(find.text('Expenses & Notion'));
      await t.pumpAndSettle();
    }

    Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label);

    Future<void> saveWith(WidgetTester t, {String? token, String? db}) async {
      if (token != null) await t.enterText(field('Notion Bearer token'), token);
      if (db != null) await t.enterText(field('Expenses database ID'), db);
      await t.tap(find.text('Save & test connection'));
      await t.pumpAndSettle();
    }

    testWidgets('a new database asks, and Replace refreshes the list', (t) async {
      final env = Env();
      seed(env.store);
      await env.repo.reload();
      await open(t, env);

      await saveWith(t, db: 'new-db');

      expect(find.text('Switch to the new database?'), findsOneWidget);
      expect(find.textContaining('2 already uploaded'), findsOneWidget);
      expect(find.textContaining('2 not uploaded'), findsOneWidget);

      await t.tap(find.widgetWithText(FilledButton, 'Replace'));
      await t.pumpAndSettle();

      expect(find.text('Switch to the new database?'), findsNothing);
      expect(env.repo.expenses.map((e) => e.title),
          containsAll(['From new db', 'Also new']));
      expect(env.store.rows.containsKey('safe1'), isFalse);
      expect(env.store.rows.containsKey('never'), isTrue);
      expect(find.textContaining('Switched: removed 2'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('Keep all removes nothing', (t) async {
      final env = Env();
      seed(env.store);
      await env.repo.reload();
      await open(t, env);
      await saveWith(t, db: 'new-db');

      await t.tap(find.widgetWithText(TextButton, 'Keep all'));
      await t.pumpAndSettle();

      expect(env.store.rows.containsKey('safe1'), isTrue);
      expect(env.store.rows.containsKey('safe2'), isTrue);
      expect(env.store.rows['safe1']!.remoteId, isNull);
      expect(find.textContaining('Switched: removed 0'), findsOneWidget);
    });

    testWidgets('with nothing on the phone it just loads, without asking',
        (t) async {
      final env = Env();
      await open(t, env);
      await saveWith(t, db: 'new-db');

      expect(find.text('Switch to the new database?'), findsNothing);
      expect(env.repo.expenses.length, 2);
    });

    testWidgets('a failed test never touches the expenses (typo protection)',
        (t) async {
      final env = Env(dbHealthy: false);
      seed(env.store);
      await env.repo.reload();
      await open(t, env);

      await saveWith(t, db: 'typo-db');

      expect(find.text('Switch to the new database?'), findsNothing);
      expect(env.store.rows.keys,
          containsAll(['safe1', 'safe2', 'never', 'edited']));
      expect(env.store.rows.length, 4);
    });

    testWidgets('only the token changed: nothing happens to the expenses',
        (t) async {
      final env = Env();
      seed(env.store);
      await env.repo.reload();
      await open(t, env);

      await saveWith(t, token: 'another-token');

      expect(find.text('Switch to the new database?'), findsNothing);
      expect(env.store.rows.length, 4);
      expect(env.store.rows['safe1']!.remoteId, 'old-page-1');
    });

    testWidgets('the same database written differently is not a switch',
        (t) async {
      final env = Env(db: '0123456789abcdef0123456789abcdef');
      seed(env.store);
      await env.repo.reload();
      await open(t, env);

      // A link and dashes around the very same database id.
      await saveWith(t,
          db: 'https://www.notion.so/Expenses-01234567-89AB-cdef-0123-456789abcdef?v=1');

      expect(find.text('Switch to the new database?'), findsNothing);
      expect(env.store.rows.length, 4);
    });

    testWidgets('the first time you set it up there is no switch', (t) async {
      final env = Env(token: '', db: '');
      seed(env.store);
      await env.repo.reload();
      await open(t, env);

      await saveWith(t, token: 'tok', db: 'first-db');

      expect(find.text('Switch to the new database?'), findsNothing);
      expect(env.store.rows['safe1']!.remoteId, 'old-page-1');
    });
  });
}
