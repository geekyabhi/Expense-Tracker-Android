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
  group('read: Sync from Notion (makes the phone match Notion)', () {
    test('adds new rows, updates edited ones, refreshes Processed',
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
      expect(r.updated, 1); // 'a' was edited in Notion
      expect(r.total, 3);
      expect(env.db.rows.length, 2);
      // Existing, safely-in-sync expense: follows the edit made in Notion.
      expect(env.db.rows['a']!.title, 'CHANGED IN NOTION');
      expect(env.db.rows['a']!.amount, 5);
      expect(env.db.rows['a']!.processed, isTrue);
      expect(env.db.rows['a']!.synced, isTrue);
      expect(env.db.rows['a']!.remoteId, '11111111-1111-1111-1111-111111111111');
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

    test('a reply it cannot read still ends in a message', () async {
      // 200 OK but not JSON (for example a Wi-Fi login page).
      final env = Env(handler: (r) async => http.Response('<html>login</html>', 200));
      final r = await env.repo.importFromNotion();
      expect(r.error, isNotNull);
      expect(r.error, contains('Could not read the Notion database'));
      expect(env.repo.importing, isFalse);
    });

    test('a reply of the wrong shape still ends in a message', () async {
      final env = Env(handler: (r) async => http.Response('{"unexpected": true}', 200));
      final r = await env.repo.importFromNotion();
      expect(r.error, contains('Could not read the Notion database'));
    });

    test('it counts the rows that were already on the phone', () async {
      final env = Env(
        handler: (r) async => http.Response(
            jsonEncode({
              'results': [_page('p1', 'One'), _page('p2', 'Two')],
              'has_more': false,
            }),
            200),
      );
      await env.repo.importFromNotion();
      final again = await env.repo.importFromNotion();
      expect(again.added, 0);
      expect(again.known, 2);
      expect(again.total, 2);
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

  group('refresh: edits and deletions made in Notion', () {
    // A full Notion page for an expense, with every column set.
    Map<String, dynamic> notionRow(String id,
            {String title = 'Lunch',
            num amount = 12,
            String category = 'Food',
            String? mode,
            String? source,
            String date = '2026-10-01T12:00:00+05:30',
            bool processed = false}) =>
        {
          'id': id,
          'properties': {
            'Expense': {
              'title': [
                {'plain_text': title}
              ]
            },
            'Amount': {'number': amount},
            'Date': {
              'date': {'start': date}
            },
            'Category': {
              'multi_select': [
                {'name': category}
              ]
            },
            'Source': {
              'multi_select': source == null
                  ? []
                  : [
                      {'name': source}
                    ]
            },
            'Mode': {
              'multi_select': mode == null
                  ? []
                  : [
                      {'name': mode}
                    ]
            },
            'Processed': {'checkbox': processed},
          },
        };

    Env envWith(List<Map<String, dynamic>> rows) => Env(
        handler: (r) async =>
            http.Response(jsonEncode({'results': rows, 'has_more': false}), 200));

    Expense synced(String id, String remote,
            {String title = 'Lunch',
            double amount = 12,
            String category = 'Food',
            DateTime? date}) =>
        Expense(
          id: id,
          title: title,
          amount: amount,
          category: category,
          date: date ?? DateTime.parse('2026-10-01T12:00:00+05:30').toLocal(),
          synced: true,
          remoteId: remote,
        );

    test('an edit made in Notion is copied to the phone (every column)', () async {
      final env = envWith([
        notionRow('p1',
            title: 'Dinner out',
            amount: 450,
            category: 'Bills',
            mode: 'GPay',
            source: 'HDFC',
            date: '2026-10-02T20:15:00+05:30',
            processed: true),
      ]);
      env.db.rows['a'] = synced('a', 'p1');
      await env.repo.reload();

      final r = await env.repo.importFromNotion();

      final e = env.db.rows['a']!;
      expect(r.updated, 1);
      expect(e.title, 'Dinner out');
      expect(e.amount, 450);
      expect(e.category, 'Bills');
      expect(e.mode, 'GPay');
      expect(e.source, 'HDFC');
      expect(e.date, DateTime.parse('2026-10-02T20:15:00+05:30').toLocal());
      expect(e.processed, isTrue);
      expect(e.id, 'a'); // the same expense, not a new one
      expect(env.repo.expenses.single.title, 'Dinner out'); // the list shows it
    });

    test('the note is kept: it does not exist in Notion', () async {
      final env = envWith([notionRow('p1', amount: 99)]);
      env.db.rows['a'] = synced('a', 'p1').copyWith(note: 'my own note');
      await env.repo.reload();
      await env.repo.importFromNotion();
      expect(env.db.rows['a']!.amount, 99);
      expect(env.db.rows['a']!.note, 'my own note');
    });

    test('an unchanged expense is not counted as updated (no spurious edits)',
        () async {
      // Same minute, different seconds: still the same.
      final env = envWith([notionRow('p1', date: '2026-10-01T12:00:00+05:30')]);
      env.db.rows['a'] = synced('a', 'p1',
          date: DateTime.parse('2026-10-01T12:00:41.123+05:30').toLocal());
      await env.repo.reload();
      final r = await env.repo.importFromNotion();
      expect(r.updated, 0);
      expect(r.known, 1);
    });

    test('an expense edited on the phone and not yet pushed is never overwritten',
        () async {
      final env = envWith([notionRow('p1', title: 'Old title in Notion', processed: true)]);
      env.db.rows['a'] =
          synced('a', 'p1', title: 'My new title').copyWith(synced: false);
      await env.repo.reload();

      final r = await env.repo.importFromNotion();

      expect(env.db.rows['a']!.title, 'My new title');
      expect(env.db.rows['a']!.synced, isFalse);
      expect(r.updated, 0);
      // Only Processed (owned by Notion) is refreshed.
      expect(env.db.rows['a']!.processed, isTrue);
    });

    group('deleted in Notion', () {
      Env deletedSetup({
        bool keepRowOne = true,
      }) {
        final env = envWith(keepRowOne ? [notionRow('p1')] : [notionRow('other')]);
        env.db.rows['kept'] = synced('kept', 'p1');
        env.db.rows['gone'] = synced('gone', 'p2', title: 'Deleted in Notion');
        env.db.rows['never'] = Expense(
            id: 'never',
            title: 'Never pushed',
            amount: 1,
            category: 'Other',
            date: DateTime(2026, 10, 1));
        env.db.rows['edited'] = synced('edited', 'p3', title: 'Edited here')
            .copyWith(synced: false);
        return env;
      }

      test('it asks first, with the expenses that are gone', () async {
        final env = deletedSetup();
        await env.repo.reload();
        List<Expense>? asked;
        await env.repo.importFromNotion(confirmRemoval: (m) async {
          asked = m;
          return false;
        });
        // Only the uploaded-and-unchanged one that is missing from Notion.
        expect(asked!.map((e) => e.id), ['gone']);
      });

      test('confirmed: removed from the phone, everything else stays', () async {
        final env = deletedSetup();
        await env.repo.reload();
        final r = await env.repo.importFromNotion(confirmRemoval: (_) async => true);

        expect(r.removed, 1);
        expect(r.missing, 0);
        expect(env.db.rows.containsKey('gone'), isFalse);
        expect(env.db.rows.containsKey('kept'), isTrue);
        // Never pushed, and edited-since-push, are not in Notion's list but are
        // never removed.
        expect(env.db.rows.containsKey('never'), isTrue);
        expect(env.db.rows.containsKey('edited'), isTrue);
        expect(env.repo.expenses.map((e) => e.id), isNot(contains('gone')));
      });

      test('declined: kept, but no longer called "uploaded"', () async {
        final env = deletedSetup();
        await env.repo.reload();
        final r = await env.repo.importFromNotion(confirmRemoval: (_) async => false);
        expect(r.removed, 0);
        expect(r.missing, 1);
        final e = env.db.rows['gone']!;
        expect(e.title, 'Deleted in Notion'); // still there
        expect(e.synced, isFalse); // shown as "On device" now
        expect(e.remoteId, isNull); // no link to a page that isn't there
        // Only that one was touched.
        expect(env.db.rows['kept']!.synced, isTrue);
        expect(env.db.rows['kept']!.remoteId, 'p1');
      });

      test('a kept expense can then be pushed as a new page', () async {
        final env = deletedSetup();
        await env.repo.reload();
        await env.repo.importFromNotion(confirmRemoval: (_) async => false);

        env.calls.clear();
        final r = await env.repo.push(env.db.rows['gone']!);
        expect(r.ok, isTrue);
        expect(env.calls.single.method, 'POST'); // create, not an update
        expect(env.calls.single.url.path, '/v1/pages');
      });

      test('without a way to ask, nothing is removed or changed', () async {
        final env = deletedSetup();
        await env.repo.reload();
        final r = await env.repo.importFromNotion();
        expect(r.removed, 0);
        expect(env.db.rows.containsKey('gone'), isTrue);
        expect(env.db.rows['gone']!.synced, isTrue);
        expect(env.db.rows['gone']!.remoteId, 'p2');
      });

      test('Notion returning no rows never removes anything, but is not "uploaded"',
          () async {
        // More likely a wrong or brand-new database than every expense being
        // deleted, so nothing is removed. But none of these are in this database,
        // so they must not claim to be uploaded.
        final env = envWith([]);
        env.db.rows['a'] = synced('a', 'p1');
        env.db.rows['b'] = synced('b', 'p2');
        await env.repo.reload();
        var asked = false;
        final r = await env.repo.importFromNotion(confirmRemoval: (_) async {
          asked = true;
          return true;
        });
        expect(asked, isFalse);
        expect(r.removed, 0);
        expect(env.db.rows.length, 2);
        for (final e in env.db.rows.values) {
          expect(e.synced, isFalse, reason: e.id);
          expect(e.remoteId, isNull, reason: e.id);
        }
        expect(env.repo.expenses.every((e) => !e.synced), isTrue);
      });

      test('a failed fetch never removes anything', () async {
        final env = Env(handler: (r) async => throw http.ClientException('offline'));
        env.db.rows['a'] = synced('a', 'p1');
        await env.repo.reload();
        final r = await env.repo.importFromNotion(confirmRemoval: (_) async => true);
        expect(r.error, isNotNull);
        expect(env.db.rows.containsKey('a'), isTrue);
      });

      test('removing the right ones even when ids are spelled differently',
          () async {
        final env = envWith([notionRow('11111111111111111111111111111111')]);
        env.db.rows['same'] = synced('same', '11111111-1111-1111-1111-111111111111');
        await env.repo.reload();
        final r = await env.repo.importFromNotion(confirmRemoval: (_) async => true);
        expect(r.removed, 0); // dashes/case are not a difference
        expect(env.db.rows.containsKey('same'), isTrue);
      });
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
