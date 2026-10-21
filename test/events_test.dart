import 'dart:convert';

import 'package:expense_tracker/models/app_event.dart';
import 'package:expense_tracker/screens/settings_screen.dart';
import 'package:expense_tracker/services/api_service.dart';
import 'package:expense_tracker/services/events_api.dart';
import 'package:expense_tracker/services/events_service.dart';
import 'package:expense_tracker/services/events_settings.dart';
import 'package:expense_tracker/services/notion_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppEvent _event(DateTime date, [String repeats = '']) => AppEvent(
    id: 'e', name: 'n', title: 't', subtitle: 's', date: date, repeats: repeats);

Map<String, dynamic> _page(String id,
        {String name = 'Anniversary',
        String title = 'Happy Anniversary!',
        String subtitle = 'Sub',
        String? date = '2026-10-28',
        String? repeats = 'Yearly',
        String? type = 'Anniversary'}) =>
    {
      'id': id,
      'properties': {
        'Name': {
          'title': [
            {'plain_text': name}
          ]
        },
        'Title': {
          'rich_text': title.isEmpty
              ? []
              : [
                  {'plain_text': title}
                ]
        },
        'Subtitle': {
          'rich_text': [
            {'plain_text': subtitle}
          ]
        },
        'Date': {'date': date == null ? null : {'start': date}},
        'Repeats': {'select': repeats == null ? null : {'name': repeats}},
        'Type': {'select': type == null ? null : {'name': type}},
      },
    };

EventsApi _api(Future<http.Response> Function(http.Request) h) => EventsApi(
      settings: EventsSettings(token: 'ev-token', databaseId: 'ev-db'),
      client: MockClient(h),
      pageGap: Duration.zero,
    );

void main() {
  group('when an event happens', () {
    test('a one-off event happens only on its date', () {
      final e = _event(DateTime(2026, 10, 28));
      expect(e.occursOn(DateTime(2026, 10, 28, 15, 30)), isTrue);
      expect(e.occursOn(DateTime(2026, 10, 27)), isFalse);
      expect(e.occursOn(DateTime(2026, 10, 29)), isFalse);
      expect(e.occursOn(DateTime(2027, 10, 28)), isFalse);
    });

    test('yearly repeats on the same day every year, never before the start', () {
      final e = _event(DateTime(2026, 10, 28), 'Yearly');
      expect(e.occursOn(DateTime(2027, 10, 28)), isTrue);
      expect(e.occursOn(DateTime(2031, 10, 28)), isTrue);
      expect(e.occursOn(DateTime(2027, 10, 27)), isFalse);
      expect(e.occursOn(DateTime(2025, 10, 28)), isFalse);
    });

    test('a 29 February event falls on 28 February in other years', () {
      final e = _event(DateTime(2024, 2, 29), 'Yearly');
      expect(e.occursOn(DateTime(2028, 2, 29)), isTrue);
      expect(e.occursOn(DateTime(2027, 2, 28)), isTrue);
      expect(e.occursOn(DateTime(2028, 2, 28)), isFalse); // leap year: the 29th
    });

    test('monthly repeats on the same day, shortened in short months', () {
      final e = _event(DateTime(2026, 1, 31), 'Monthly');
      expect(e.occursOn(DateTime(2026, 3, 31)), isTrue);
      expect(e.occursOn(DateTime(2026, 4, 30)), isTrue); // April has 30 days
      expect(e.occursOn(DateTime(2027, 2, 28)), isTrue);
      expect(e.occursOn(DateTime(2026, 4, 29)), isFalse);
    });

    test('weekly and daily', () {
      final w = _event(DateTime(2026, 10, 28), 'Weekly');
      expect(w.occursOn(DateTime(2026, 11, 4)), isTrue);
      expect(w.occursOn(DateTime(2026, 11, 5)), isFalse);
      final d = _event(DateTime(2026, 10, 28), 'Daily');
      expect(d.occursOn(DateTime(2026, 12, 1)), isTrue);
      expect(d.occursOn(DateTime(2026, 10, 27)), isFalse);
    });

    test('an unknown Repeats value means it does not repeat', () {
      final e = _event(DateTime(2026, 10, 28), 'Sometimes');
      expect(e.occursOn(DateTime(2027, 10, 28)), isFalse);
    });
  });

  group('reading events from Notion', () {
    test('queries the events database sorted by Date, with its own token',
        () async {
      late http.Request req;
      final api = _api((r) async {
        req = r;
        return http.Response(
            jsonEncode({'results': [_page('p1')], 'has_more': false}), 200);
      });

      final events = await api.fetchAll();

      expect(req.method, 'POST');
      expect(req.url.toString(), 'https://api.notion.com/v1/databases/ev-db/query');
      expect(req.headers['Authorization'], 'Bearer ev-token');
      expect(req.headers['Notion-Version'], '2022-06-28');
      expect(jsonDecode(req.body), {
        'sorts': [
          {'property': 'Date', 'direction': 'ascending'}
        ],
        'page_size': 100,
      });
      expect(events.single.title, 'Happy Anniversary!');
      expect(events.single.subtitle, 'Sub');
    });

    test('the Title and Subtitle columns become the popup text', () {
      final e = EventsApi.eventFromPage(_page('p1',
          title: 'Happy Anniversary!', subtitle: 'So much ❤️'))!;
      expect(e.title, 'Happy Anniversary!');
      expect(e.subtitle, 'So much ❤️');
      expect(e.name, 'Anniversary');
      expect(e.type, 'Anniversary');
      expect(e.repeats, 'Yearly');
      expect(e.date, DateTime(2026, 10, 28));
    });

    test('an empty Title falls back to the row Name', () {
      final e = EventsApi.eventFromPage(_page('p', title: '', name: 'Dad birthday'))!;
      expect(e.title, 'Dad birthday');
    });

    test('rows without a date or without any title are skipped', () {
      expect(EventsApi.eventFromPage(_page('p', date: null)), isNull);
      expect(EventsApi.eventFromPage(_page('p', title: '', name: '')), isNull);
    });

    test('follows pagination', () async {
      final bodies = <Map<String, dynamic>>[];
      final api = _api((r) async {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        bodies.add(body);
        return body['start_cursor'] == null
            ? http.Response(
                jsonEncode({
                  'results': [_page('p1')],
                  'has_more': true,
                  'next_cursor': 'c1'
                }),
                200)
            : http.Response(
                jsonEncode({'results': [_page('p2')], 'has_more': false}), 200);
      });
      final events = await api.fetchAll();
      expect(events.map((e) => e.id), ['p1', 'p2']);
      expect(bodies[1]['start_cursor'], 'c1');
    });

    test('401 is a rejection, 503 and network errors are offline', () async {
      expect(
          () => _api((r) async => http.Response('{"message":"API token is invalid."}', 401))
              .fetchAll(),
          throwsA(isA<ApiRejected>()));
      expect(() => _api((r) async => http.Response('{}', 503)).fetchAll(),
          throwsA(isA<ApiOffline>()));
      expect(
          () => _api((r) async => throw http.ClientException('offline')).fetchAll(),
          throwsA(isA<ApiOffline>()));
    });
  });

  group('test connection', () {
    Map<String, dynamic> db({List<String> missing = const []}) => {
          'title': [
            {'plain_text': 'Events'}
          ],
          'properties': {
            for (final e in {
              'Title': 'rich_text',
              'Subtitle': 'rich_text',
              'Date': 'date',
              'Repeats': 'select',
              'Type': 'select',
              'Name': 'title',
            }.entries)
              if (!missing.contains(e.key)) e.key: {'type': e.value}
          }
        };

    test('all good, with the number of events', () async {
      final api = _api((r) async => r.method == 'GET'
          ? http.Response(jsonEncode(db()), 200)
          : http.Response(jsonEncode({'results': [_page('a'), _page('b')], 'has_more': false}), 200));
      final msg = await api.checkConnection();
      expect(msg, contains('look right'));
      expect(msg, contains('2 events found'));
    });

    test('names the missing column', () async {
      final api = _api((r) async =>
          http.Response(jsonEncode(db(missing: ['Subtitle'])), 200));
      final msg = await api.checkConnection();
      expect(msg, contains('missing column "Subtitle"'));
      expect(msg, isNot(contains('look right')));
    });

    test('bad token and unshared database give clear messages', () async {
      expect(await _api((r) async => http.Response('{}', 401)).checkConnection(),
          contains('token is invalid'));
      expect(await _api((r) async => http.Response('{}', 404)).checkConnection(),
          contains('not found'));
    });
  });

  group('Settings: separate events credentials', () {
    testWidgets('the events token is used for events, never the expenses one',
        (t) async {
      SharedPreferences.setMockInitialValues({});
      t.view.physicalSize = const Size(800, 4000);
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
      addTearDown(() => t.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));

      final requests = <http.Request>[];
      final events = EventsApi(
        settings: EventsSettings(),
        pageGap: Duration.zero,
        client: MockClient((r) async {
          requests.add(r);
          return r.method == 'GET'
              ? http.Response(
                  jsonEncode({
                    'title': [
                      {'plain_text': 'Events'}
                    ],
                    'properties': {
                      'Title': {'type': 'rich_text'},
                      'Subtitle': {'type': 'rich_text'},
                      'Date': {'type': 'date'},
                    }
                  }),
                  200)
              : http.Response('{"results":[],"has_more":false}', 200);
        }),
      );
      final expenses = ApiService(
          settings: NotionSettings(token: 'expenses-token', databaseId: 'expenses-db'));

      await t.pumpWidget(
          MaterialApp(
          home: SettingsScreen(api: expenses, events: EventsService(api: events))));
      await t.pumpAndSettle();

      Finder field(String label) => find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == label);

      // The expenses credentials live in their own folder.
      await t.tap(find.text('Expenses & Notion'));
      await t.pumpAndSettle();
      expect(t.widget<TextField>(field('Notion Bearer token')).controller!.text,
          'expenses-token');
      expect(field('Events Bearer token'), findsNothing);
      await t.pageBack();
      await t.pumpAndSettle();

      // The events ones are in another: separate fields, empty to start with.
      await t.tap(find.text('Events'));
      await t.pumpAndSettle();
      expect(field('Events Bearer token'), findsOneWidget);
      expect(field('Events database ID'), findsOneWidget);
      expect(field('Notion Bearer token'), findsNothing);
      expect(t.widget<TextField>(field('Events Bearer token')).controller!.text, '');

      await t.enterText(field('Events Bearer token'), 'Bearer ev-secret');
      await t.enterText(field('Events database ID'),
          'https://www.notion.so/Events-0123456789abcdef0123456789abcdef?v=1');
      await t.tap(find.text('Save & test events'));
      await t.pumpAndSettle();

      expect(requests, isNotEmpty);
      for (final r in requests) {
        expect(r.headers['Authorization'], 'Bearer ev-secret');
        expect(r.url.path, contains('0123456789abcdef0123456789abcdef'));
      }
      expect(events.settings.token, 'ev-secret'); // "Bearer " stripped
      expect(find.textContaining('look right'), findsOneWidget);
      expect(find.textContaining('No events found in the database'), findsOneWidget);
      // The expenses credentials were not touched.
      expect(expenses.settings.token, 'expenses-token');
      expect(expenses.settings.databaseId, 'expenses-db');
    });
  });
}
