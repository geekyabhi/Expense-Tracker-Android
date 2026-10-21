import 'dart:convert';

import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/services/api_service.dart';
import 'package:expense_tracker/services/expense_repository.dart';
import 'package:expense_tracker/services/notion_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

Map<String, dynamic> _page(String id, String title, {bool processed = false}) => {
      'id': id,
      'properties': {
        'Expense': {
          'title': [
            {'plain_text': title}
          ]
        },
        'Amount': {'number': 5},
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
        'Processed': {'checkbox': processed},
      },
    };

Expense _local(String id, {String? remoteId, bool processed = false}) => Expense(
      id: id,
      title: 'Local $id',
      amount: 1,
      category: 'Other',
      date: DateTime(2026, 10, 1),
      synced: remoteId != null,
      processed: processed,
      remoteId: remoteId,
    );

class Env {
  Env({bool autoSync = true, Future<http.Response> Function(http.Request)? handler}) {
    repo = ExpenseRepository(
      db: db,
      pushGap: Duration.zero,
      api: ApiService(
        settings: NotionSettings(
            token: 't', databaseId: 'db', autoSync: autoSync),
        pageGap: Duration.zero,
        client: MockClient((r) async {
          calls.add(r);
          return handler != null ? await handler(r) : http.Response("{}", 200);
        }),
      ),
    );
  }
  final db = FakeDb();
  final calls = <http.Request>[];
  late final ExpenseRepository repo;
}

void main() {
  group('read: Sync from Notion (import only)', () {
    test('adds new rows, keeps existing ones, refreshes only Processed',
        () async {
      final env = Env(
        handler: (r) async => http.Response(
            jsonEncode({
              'results': [
                // Same page as local 'a', written without dashes this time.
                _page('11111111111111111111111111111111', 'CHANGED IN NOTION',
                    processed: true),
                _page('22222222-2222-2222-2222-222222222222', 'Chai'),
                // Deleted here, archive still pending: must not come back.
                _page('33333333-3333-3333-3333-333333333333', 'Ghost'),
              ],
              'has_more': false,
            }),
            200),
      );
      env.db.rows['a'] =
          _local('a', remoteId: '11111111-1111-1111-1111-111111111111');
      env.db.tombstones.add('33333333-3333-3333-3333-333333333333');
      await env.repo.reload();

      final r = await env.repo.importFromNotion();

      expect(r.error, isNull);
      expect(r.added, 1);
      expect(r.refreshed, 1);
      expect(r.total, 3);
      expect(env.db.rows.length, 2);
      // Existing expense: title untouched, Processed refreshed.
      expect(env.db.rows['a']!.title, 'Local a');
      expect(env.db.rows['a']!.processed, isTrue);
      // New one came in synced, with its Notion id.
      final chai = env.db.rows.values.firstWhere((e) => e.title == 'Chai');
      expect(chai.synced, isTrue);
      expect(chai.remoteId, '22222222-2222-2222-2222-222222222222');
      expect(chai.date, DateTime(2026, 10, 20));
      expect(env.db.rows.values.any((e) => e.title == 'Ghost'), isFalse);
    });

    test('running it twice does not duplicate anything', () async {
      final env = Env(
        handler: (r) async => http.Response(
            jsonEncode({
              'results': [_page('p1', 'One'), _page('p2', 'Two')],
              'has_more': false,
            }),
            200),
      );
      await env.repo.importFromNotion();
      final second = await env.repo.importFromNotion();
      expect(env.db.rows.length, 2);
      expect(second.added, 0);
      expect(second.refreshed, 0);
    });

    test('errors come back as a message, not an exception', () async {
      var env = Env(
          handler: (r) async =>
              http.Response('{"message":"API token is invalid."}', 401));
      expect((await env.repo.importFromNotion()).error, contains('invalid'));

      env = Env(handler: (r) async => throw http.ClientException('offline'));
      expect((await env.repo.importFromNotion()).error,
          contains('No connection'));
      expect(env.repo.importing, isFalse);
    });
  });

  group('delete = archive in Notion, following the sync mode', () {
    test('Auto: removed here and archived right away', () async {
      final env = Env();
      env.db.rows['a'] = _local('a', remoteId: 'page-a');
      await env.repo.reload();

      final r = await env.repo.deleteExpenses([env.db.rows['a']!]);

      expect(env.db.rows, isEmpty);
      expect(env.db.tombstones, isEmpty);
      expect(r.removed, 1);
      expect(r.archived, 1);
      expect(r.queued, 0);
      expect(env.calls.single.method, 'PATCH');
      expect(env.calls.single.url.path, '/v1/pages/page-a');
      expect(jsonDecode(env.calls.single.body), {'archived': true});
    });

    test('Manual: removed here, archive waits until Apply', () async {
      final env = Env(autoSync: false);
      env.db.rows['a'] = _local('a', remoteId: 'page-a');
      await env.repo.reload();

      final r = await env.repo.deleteExpenses([env.db.rows['a']!]);

      expect(env.calls, isEmpty, reason: 'Manual mode must not call Notion');
      expect(env.db.rows, isEmpty);
      expect(env.db.tombstones, {'page-a'});
      expect(env.repo.pendingDeletes, 1);
      expect(r.queued, 1);

      final done = await env.repo.applyPendingDeletes();

      expect(done, 1);
      expect(env.calls.single.url.path, '/v1/pages/page-a');
      expect(env.db.tombstones, isEmpty);
      expect(env.repo.pendingDeletes, 0);
    });

    test('an expense that was never pushed is only removed locally', () async {
      final env = Env();
      env.db.rows['a'] = _local('a');
      await env.repo.reload();

      final r = await env.repo.deleteExpenses([env.db.rows['a']!]);

      expect(env.db.rows, isEmpty);
      expect(env.db.tombstones, isEmpty);
      expect(env.calls, isEmpty);
      expect(r.archived, 0);
    });

    test('offline: the archive stays queued and can be retried', () async {
      var online = false;
      final env = Env(
          handler: (r) async => online
              ? http.Response('{}', 200)
              : throw http.ClientException('offline'));
      env.db.rows['a'] = _local('a', remoteId: 'page-a');
      await env.repo.reload();

      final r = await env.repo.deleteExpenses([env.db.rows['a']!]);
      expect(r.archived, 0);
      expect(r.queued, 1);
      expect(env.db.tombstones, {'page-a'});

      online = true;
      expect(await env.repo.applyPendingDeletes(), 1);
      expect(env.db.tombstones, isEmpty);
    });

    test('several at once are archived one call each', () async {
      final env = Env();
      env.db.rows['a'] = _local('a', remoteId: 'page-a');
      env.db.rows['b'] = _local('b', remoteId: 'page-b');
      env.db.rows['c'] = _local('c');
      await env.repo.reload();

      final r = await env.repo.deleteExpenses(env.db.rows.values);

      expect(r.removed, 3);
      expect(r.archived, 2);
      expect(env.calls.map((c) => c.url.path).toSet(),
          {'/v1/pages/page-a', '/v1/pages/page-b'});
    });
  });

  group('update = PATCH on the same page', () {
    test('editing a pushed expense updates its page, not a new one', () async {
      final env = Env(
          handler: (r) async => http.Response('{"id":"page-a"}', 200));
      env.db.rows['a'] = _local('a', remoteId: 'page-a');
      await env.repo.reload();

      final stored =
          await env.repo.update(env.db.rows['a']!.copyWith(title: 'Edited'));
      final res = await env.repo.autoPush(stored);

      expect(res!.ok, isTrue);
      expect(env.calls.single.method, 'PATCH');
      expect(env.calls.single.url.path, '/v1/pages/page-a');
      final props = jsonDecode(env.calls.single.body)['properties'];
      expect(props['Expense']['title'][0]['text']['content'], 'Edited');
      expect(props.containsKey('Processed'), isFalse);
    });
  });
}
