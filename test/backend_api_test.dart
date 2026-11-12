import 'dart:convert';

import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

Expense _exp({
  String id = 'a',
  String title = 'Chai',
  double amount = 20,
  String category = 'Food',
  String source = '',
  String mode = 'Direct',
  String note = '',
  DateTime? date,
  String? remote,
}) =>
    Expense(
      id: id,
      title: title,
      amount: amount,
      category: category,
      source: source,
      mode: mode,
      note: note,
      date: date ?? DateTime(2026, 11, 9, 10, 0),
      remoteId: remote,
    );

void main() {
  late Harness h;
  late ApiService api;
  setUp(() async {
    h = await Harness.create();
    api = h.repo.api;
  });

  group('create', () {
    test('POSTs the expense with the bearer token and returns the server id', () async {
      final r = await api.upload(_exp(source: 'HDFC', mode: 'UPI', note: 'with Sam'));

      expect(r.ok, isTrue);
      final req = h.backend.callsTo('/create/').single;
      expect(req.method, 'POST');
      expect(req.url.toString(), 'https://server.test/api/expenses/create/');
      expect(req.headers['Authorization'], 'Bearer ${h.session.token}');
      expect(req.headers['Content-Type'], contains('application/json'));
      expect(jsonDecode(req.body), {
        'name': 'Chai',
        'amount': 20.0,
        'date': ApiService.isoWithOffset(DateTime(2026, 11, 9, 10, 0)),
        'categories': ['Food'],
        'source': 'HDFC',
        'mode': 'UPI',
        'comment': 'with Sam',
      });
      // The server really has it, under this account, and gave us its id.
      expect(h.backend.count(h.user.id), 1);
      expect(r.pageId, h.backend.ids(h.user.id).single.toString());
      expect(h.backend.row(h.user.id, int.parse(r.pageId!))!['comment'], 'with Sam');
    });

    test('the date carries the time and the UTC offset', () {
      final s = ApiService.isoWithOffset(DateTime(2026, 11, 9, 9, 5));
      expect(s, startsWith('2026-11-09T09:05:00'));
      expect(s, matches(RegExp(r'[+-]\d{2}:\d{2}$')));
      expect(DateTime.parse(s).isAtSameMomentAs(DateTime(2026, 11, 9, 9, 5)), isTrue);
    });

    test('several categories are kept as a comma-separated label and sent as a list',
        () async {
      await api.upload(_exp(category: 'Food, Travel'));
      final body = jsonDecode(h.backend.callsTo('/create/').single.body);
      expect(body['categories'], ['Food', 'Travel']);
      expect(ApiService.splitList(' a , ,b,, c '), ['a', 'b', 'c']);
    });

    test('a 4xx the server explains is a rejection with its own message', () async {
      expect(
        () => api.upload(_exp(title: '')),
        throwsA(isA<ApiRejected>().having((e) => e.message, 'message', 'Name is required')),
      );
    });

    test('a created expense without an id in the reply is not guessed at', () async {
      final odd = ApiService(
        session: h.session,
        client: MockClient((r) async => http.Response('{"ok": true}', 201)),
      );
      expect(() => odd.upload(_exp()), throwsA(isA<ApiRejected>()));
    });
  });

  group('update', () {
    test('an expense with a server id is PATCHed, not created again', () async {
      final first = await api.upload(_exp());
      h.backend.calls.clear();

      final r = await api.upload(_exp(title: 'Chai (edited)', amount: 25, remote: first.pageId));

      expect(r.ok, isTrue);
      expect(r.pageId, first.pageId);
      final req = h.backend.calls.single;
      expect(req.method, 'PATCH');
      expect(req.url.path, '/api/expenses/${first.pageId}/update/');
      expect(h.backend.count(h.user.id), 1);
      expect(h.backend.row(h.user.id, int.parse(first.pageId!))!['title'], 'Chai (edited)');
    });

    test('an expense that was deleted on the server is created again', () async {
      final first = await api.upload(_exp());
      h.backend.removeExpense(h.user.id, int.parse(first.pageId!));
      h.backend.calls.clear();

      final r = await api.upload(_exp(remote: first.pageId));

      expect(r.ok, isTrue);
      expect(r.pageId, isNot(first.pageId)); // a new server id
      expect(h.backend.calls.map((c) => c.method), ['PATCH', 'POST']);
      expect(h.backend.count(h.user.id), 1);
    });
  });

  group('delete', () {
    test('DELETEs by id', () async {
      final id = h.backend.addExpense(h.user.id);
      final r = await api.remove('$id');
      expect(r.ok, isTrue);
      final req = h.backend.calls.single;
      expect(req.method, 'DELETE');
      expect(req.url.path, '/api/expenses/$id/delete/');
      expect(h.backend.count(h.user.id), 0);
    });

    test('one that is already gone counts as done', () async {
      expect((await api.remove('999')).ok, isTrue);
    });
  });

  group('when things go wrong', () {
    test('no connection or a busy server: failed, safe to retry', () async {
      h.backend.offline = true;
      expect((await api.upload(_exp())).ok, isFalse);
      expect((await api.remove('1')).ok, isFalse);
      h.backend.offline = false;
      for (final code in [429, 500, 502, 503]) {
        h.backend.failNextWith = code;
        expect((await api.upload(_exp())).ok, isFalse, reason: '$code');
      }
    });

    test('a 401 ends the session and says so', () async {
      h.backend.expireAllTokens();
      await expectLater(api.upload(_exp()), throwsA(isA<SessionExpired>()));
      expect(h.session.isSignedIn, isFalse);
      expect(h.session.notice, contains('expired'));
      // The expense was not lost: the caller keeps it; nothing was created.
      expect(h.backend.count(h.user.id), 0);
    });

    test('signed out: no request is even made', () async {
      await h.session.signOut();
      await expectLater(api.upload(_exp()), throwsA(isA<SessionExpired>()));
      await expectLater(api.listAll(), throwsA(isA<SessionExpired>()));
      expect(h.backend.calls, isEmpty);
    });

    test('a 401 while reading ends the session too', () async {
      h.backend.expireAllTokens();
      await expectLater(api.listAll(), throwsA(isA<SessionExpired>()));
      expect(h.session.isSignedIn, isFalse);
    });
  });

  group('reading', () {
    test('asks for everything, newest first, fresh', () async {
      await api.listAll();
      final req = h.backend.callsTo('/list/').single;
      expect(req.method, 'GET');
      expect(req.url.queryParameters, {'all': '1', 'sort': 'date_desc', 'force': '1'});
      expect(req.headers['Authorization'], 'Bearer ${h.session.token}');
    });

    test('only the signed-in account\'s expenses come back', () async {
      final other = h.backend.addAccount(email: 'other@example.com');
      h.backend.addExpense(other.id, title: 'Not mine');
      h.backend.addExpense(h.user.id, title: 'Mine');
      final list = await api.listAll();
      expect(list.map((e) => e.title), ['Mine']);
    });

    test('a server entry becomes an expense, field by field', () async {
      h.backend.addExpense(h.user.id,
          title: 'Dinner out',
          amount: 450,
          date: '2026-10-02T20:15:00+05:30',
          categories: ['Food', 'Travel'],
          sources: ['HDFC', 'Cash'],
          mode: 'GPay',
          comment: 'team dinner',
          processed: true);
      final e = (await api.listAll()).single;

      expect(e.title, 'Dinner out');
      expect(e.amount, 450.0);
      expect(e.category, 'Food, Travel'); // all of them, so an edit never drops one
      expect(e.source, 'HDFC'); // the first source, as the server shows it
      expect(e.mode, 'GPay');
      expect(e.note, 'team dinner');
      expect(e.processed, isTrue);
      expect(e.synced, isTrue);
      expect(e.remoteId, h.backend.ids(h.user.id).single.toString());
      expect(e.date.isAtSameMomentAs(DateTime.parse('2026-10-02T20:15:00+05:30')), isTrue);
      expect(e.date.isUtc, isFalse);
    });

    test('missing values get sensible defaults', () async {
      h.backend.addExpense(h.user.id,
          title: '', categories: [], mode: '', date: '2026-10-05', amount: 3);
      final e = (await api.listAll()).single;
      expect(e.title, '(untitled)');
      expect(e.category, 'Other');
      expect(e.mode, kDefaultMode);
      expect(e.source, '');
      expect(e.date, DateTime(2026, 10, 5));
    });

    test('a 5xx or no connection while reading is "offline"', () async {
      h.backend.offline = true;
      await expectLater(api.listAll(), throwsA(isA<ApiOffline>()));
      h.backend.offline = false;
      h.backend.failNextWith = 503;
      await expectLater(api.listAll(), throwsA(isA<ApiOffline>()));
    });

    test('a 4xx while reading is a rejection with the server\'s message', () async {
      final bad = ApiService(
        session: h.session,
        client: MockClient((r) async => http.Response('{"error":"Invalid period"}', 400)),
      );
      await expectLater(bad.listAll(),
          throwsA(isA<ApiRejected>().having((e) => e.message, 'message', 'Invalid period')));
    });
  });

  group('pick-lists', () {
    test('reads the account\'s categories, modes and sources', () async {
      h.backend.addAccount(); // another account, whose lists must not leak
      await api.upload(_exp(category: 'Food', source: 'HDFC', mode: 'UPI'));
      final o = await api.options();
      expect(o.categories, ['Food']);
      expect(o.sources, ['HDFC']);
      expect(o.modes, ['UPI']);
    });

    test('adds one', () async {
      await api.addOption('categories', 'Groceries');
      final req = h.backend.callsTo('/options/categories/').single;
      expect(req.method, 'POST');
      expect(jsonDecode(req.body), {'name': 'Groceries'});
      expect(h.backend.pickList(h.user.id, 'categories'), ['Groceries']);
    });
  });
}
