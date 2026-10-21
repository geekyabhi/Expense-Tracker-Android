import 'dart:convert';

import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/services/api_service.dart';
import 'package:expense_tracker/services/notion_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _coffee = Expense(
  id: 'x',
  title: 'Coffee',
  amount: 250,
  category: 'Food',
  date: DateTime(2026, 10, 23, 9, 30),
  source: 'HDFC',
  mode: 'UPI',
);

ApiService _api(Future<http.Response> Function(http.Request) h) => ApiService(
      settings: NotionSettings(token: 'tok', databaseId: 'db123'),
      client: MockClient(h),
      pageGap: Duration.zero,
    );

Map<String, dynamic> _page(String id, String title,
        {bool? processed, double amount = 10, String date = '2026-10-20'}) =>
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
            {'name': 'Food'}
          ]
        },
        'Source': {
          'multi_select': [
            {'name': 'HDFC'}
          ]
        },
        'Mode': {
          'multi_select': [
            {'name': 'UPI'}
          ]
        },
        if (processed != null) 'Processed': {'checkbox': processed},
      },
    };

void main() {
  test('creating a page sends the same request as the curl', () async {
    late http.Request req;
    final api = _api((r) async {
      req = r;
      return http.Response('{"id":"page-1"}', 200);
    });

    final res = await api.upload(_coffee);

    expect(res.ok, isTrue);
    expect(res.pageId, 'page-1');
    expect(req.method, 'POST');
    expect(req.url.toString(), 'https://api.notion.com/v1/pages');
    expect(req.headers['Authorization'], 'Bearer tok');
    expect(req.headers['Notion-Version'], '2022-06-28');
    expect(req.headers['Content-Type'], contains('application/json'));
    expect(jsonDecode(req.body), {
      'parent': {'database_id': 'db123'},
      'properties': {
        'Expense': {
          'title': [
            {
              'text': {'content': 'Coffee'}
            }
          ]
        },
        'Amount': {'number': 250},
        'Date': {
          'date': {'start': ApiService.notionDate(_coffee.date)}
        },
        'Category': {
          'multi_select': [
            {'name': 'Food'}
          ]
        },
        'Source': {
          'multi_select': [
            {'name': 'HDFC'}
          ]
        },
        'Mode': {
          'multi_select': [
            {'name': 'UPI'}
          ]
        },
      },
    });
  });

  test('date is sent with time and UTC offset', () {
    final d = DateTime(2026, 10, 23, 9, 5);
    final out = ApiService.notionDate(d);
    expect(out, startsWith('2026-10-23T09:05:00'));
    expect(out, matches(RegExp(r'[+-]\d{2}:\d{2}$')));
    // Parses back to the same instant as the phone's local time.
    expect(DateTime.parse(out).isAtSameMomentAs(d), isTrue);
  });

  test('an expense already in Notion is updated, not duplicated', () async {
    late http.Request req;
    final api = _api((r) async {
      req = r;
      return http.Response('{"id":"page-1"}', 200);
    });

    final res = await api.upload(_coffee.copyWith(remoteId: 'page-1'));

    expect(res.ok, isTrue);
    expect(req.method, 'PATCH');
    expect(req.url.toString(), 'https://api.notion.com/v1/pages/page-1');
    expect(jsonDecode(req.body).containsKey('parent'), isFalse);
  });

  test('empty source/mode send empty lists so edits can clear them', () async {
    late http.Request req;
    final api = _api((r) async {
      req = r;
      return http.Response('{"id":"p"}', 200);
    });
    await api.upload(_coffee.copyWith(source: '', mode: ''));
    final props = jsonDecode(req.body)['properties'];
    expect(props['Source'], {'multi_select': []});
    expect(props['Mode'], {'multi_select': []});
  });

  test('commas are stripped from tags (Notion rejects them)', () async {
    late http.Request req;
    final api = _api((r) async {
      req = r;
      return http.Response('{"id":"p"}', 200);
    });
    await api.upload(_coffee.copyWith(source: 'HDFC, Savings'));
    expect(jsonDecode(req.body)['properties']['Source']['multi_select'][0]['name'],
        'HDFC  Savings');
  });

  test('a 400 surfaces Notion\'s message', () async {
    final api = _api((r) async => http.Response(
        '{"object":"error","message":"Source is expected to be select."}', 400));
    expect(
      () => api.upload(_coffee),
      throwsA(isA<ApiRejected>()
          .having((e) => e.message, 'message', contains('Source'))),
    );
  });

  test('409 and 5xx are retryable failures, not rejections', () async {
    for (final code in [409, 500, 503]) {
      final api = _api((r) async => http.Response('{}', code));
      expect((await api.upload(_coffee)).ok, isFalse, reason: '$code');
    }
  });

  test('network errors are retryable failures', () async {
    final api = _api((r) async => throw http.ClientException('offline'));
    expect((await api.upload(_coffee)).ok, isFalse);
  });

  test('database id can be pasted as a URL', () {
    expect(
      NotionSettings.normalizeDatabaseId(
          'https://www.notion.so/ws/Expenses-0123456789abcdef0123456789abcdef?v=ffffffffffffffffffffffffffffffff'),
      '0123456789abcdef0123456789abcdef',
    );
    expect(
      NotionSettings.normalizeDatabaseId('01234567-89ab-cdef-0123-456789abcdef'),
      '0123456789abcdef0123456789abcdef',
    );
  });

  // ------------------------------------------------------------------ delete

  test('delete archives the page', () async {
    late http.Request req;
    final api = _api((r) async {
      req = r;
      return http.Response('{}', 200);
    });
    final res = await api.archive('page-1');
    expect(res.ok, isTrue);
    expect(req.method, 'PATCH');
    expect(req.url.toString(), 'https://api.notion.com/v1/pages/page-1');
    expect(jsonDecode(req.body), {'archived': true});
    expect(req.headers['Authorization'], 'Bearer tok');
  });

  test('archiving a page that is already gone counts as done', () async {
    expect((await _api((r) async => http.Response('{}', 404)).archive('p')).ok,
        isTrue);
    expect(
        (await _api((r) async => http.Response(
                    '{"message":"Can\'t edit block that is archived."}', 400))
                .archive('p'))
            .ok,
        isTrue);
  });

  test('archive: offline/5xx retry later, other 4xx are rejections', () async {
    expect((await _api((r) async => http.Response('{}', 503)).archive('p')).ok,
        isFalse);
    expect(
        (await _api((r) async => throw http.ClientException('offline'))
                .archive('p'))
            .ok,
        isFalse);
    expect(() => _api((r) async => http.Response('{"message":"nope"}', 401)).archive('p'),
        throwsA(isA<ApiRejected>()));
  });

  // -------------------------------------------------------------------- read

  test('reading follows pagination until has_more is false', () async {
    final bodies = <Map<String, dynamic>>[];
    final api = _api((r) async {
      expect(r.method, 'POST');
      expect(r.url.toString(), 'https://api.notion.com/v1/databases/db123/query');
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      bodies.add(body);
      if (body['start_cursor'] == null) {
        return http.Response(
            jsonEncode({
              'results': [_page('p1', 'One'), _page('p2', 'Two')],
              'has_more': true,
              'next_cursor': 'cursor-1',
            }),
            200);
      }
      return http.Response(
          jsonEncode({
            'results': [_page('p3', 'Three')],
            'has_more': false,
            'next_cursor': null,
          }),
          200);
    });

    final pages = await api.queryAllPages();

    expect(pages.map((p) => p['id']), ['p1', 'p2', 'p3']);
    expect(bodies.length, 2);
    expect(bodies[0], {'page_size': 100});
    expect(bodies[1], {'page_size': 100, 'start_cursor': 'cursor-1'});
  });

  test('reading: 401 is a rejection, 503 and network errors are offline',
      () async {
    expect(
        () => _api((r) async => http.Response('{"message":"API token is invalid."}', 401))
            .queryAllPages(),
        throwsA(isA<ApiRejected>()
            .having((e) => e.message, 'message', contains('invalid'))));
    expect(() => _api((r) async => http.Response('{}', 503)).queryAllPages(),
        throwsA(isA<ApiOffline>()));
    expect(
        () => _api((r) async => throw http.ClientException('offline'))
            .queryAllPages(),
        throwsA(isA<ApiOffline>()));
  });

  test('a Notion page becomes an expense', () {
    final e = ApiService.expenseFromPage(
        _page('page-9', 'Coffee', processed: true, amount: 250))!;
    expect(e.title, 'Coffee');
    expect(e.amount, 250);
    expect(e.category, 'Food');
    expect(e.source, 'HDFC');
    expect(e.mode, 'UPI');
    expect(e.processed, isTrue);
    expect(e.synced, isTrue);
    expect(e.remoteId, 'page-9');
    expect(e.date, DateTime(2026, 10, 20));
  });

  test('page dates with a UTC offset come back as the same instant', () {
    final e = ApiService.expenseFromPage(
        _page('p', 'x', date: '2026-10-23T09:30:00+05:30'))!;
    expect(e.date.isAtSameMomentAs(DateTime.parse('2026-10-23T09:30:00+05:30')),
        isTrue);
    expect(e.date.isUtc, isFalse);
  });

  test('missing columns fall back to defaults', () {
    final e = ApiService.expenseFromPage({
      'id': 'bare',
      'properties': <String, dynamic>{},
    })!;
    expect(e.title, '(untitled)');
    expect(e.amount, 0);
    expect(e.category, 'Other');
    expect(e.mode, 'Direct');
    expect(e.source, '');
    expect(e.processed, isFalse);
  });
}
