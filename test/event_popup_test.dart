import 'dart:convert';

import 'package:expense_tracker/models/app_event.dart';
import 'package:expense_tracker/screens/home_screen.dart';
import 'package:expense_tracker/screens/settings_screen.dart';
import 'package:expense_tracker/services/api_service.dart';
import 'package:expense_tracker/services/events_api.dart';
import 'package:expense_tracker/services/events_service.dart';
import 'package:expense_tracker/services/events_settings.dart';
import 'package:expense_tracker/services/expense_repository.dart';
import 'package:expense_tracker/services/notion_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

Map<String, dynamic> _page(String id,
        {String title = 'Happy Anniversary!',
        String subtitle = 'So much love',
        String date = '2026-10-28',
        String? repeats = 'Yearly'}) =>
    {
      'id': id,
      'properties': {
        'Name': {
          'title': [
            {'plain_text': 'Anniversary'}
          ]
        },
        'Title': {
          'rich_text': [
            {'plain_text': title}
          ]
        },
        'Subtitle': {
          'rich_text': [
            {'plain_text': subtitle}
          ]
        },
        'Date': {
          'date': {'start': date}
        },
        'Repeats': {'select': repeats == null ? null : {'name': repeats}},
        'Type': {
          'select': {'name': 'Anniversary'}
        },
      },
    };

/// A service wired to a fake Notion and a clock the test controls.
class Setup {
  Setup({
    List<Map<String, dynamic>>? pages,
    int gap = 240,
    bool enabled = true,
    bool configured = true,
  }) : pages = pages ?? [_page('p1')] {
    now = DateTime(2026, 10, 28, 9, 0);
    service = EventsService(
      clock: () => now,
      api: EventsApi(
        pageGap: Duration.zero,
        settings: EventsSettings(
          token: configured ? 'ev-token' : '',
          databaseId: configured ? 'ev-db' : '',
          popupEnabled: enabled,
          gapMinutes: gap,
        ),
        client: MockClient((r) async {
          calls++;
          if (offline) throw http.ClientException('offline');
          return http.Response(
              jsonEncode({'results': this.pages, 'has_more': false}), 200);
        }),
      ),
    );
  }

  final List<Map<String, dynamic>> pages;
  late final EventsService service;
  late DateTime now;
  int calls = 0;
  bool offline = false;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('which event is shown', () {
    test('an event is shown on its day and not on other days', () async {
      final s = Setup();
      expect((await s.service.nextDue())?.title, 'Happy Anniversary!');

      s.now = DateTime(2026, 10, 27, 9);
      expect(await s.service.nextDue(), isNull);
    });

    test('a yearly event is shown again next year', () async {
      final s = Setup();
      s.now = DateTime(2027, 10, 28, 9);
      expect(await s.service.nextDue(), isNotNull);
    });

    test('the minimum gap holds the next popup back until it has passed',
        () async {
      final s = Setup(gap: 240); // 4 hours
      await s.service.markShown((await s.service.nextDue())!);

      expect(await s.service.nextDue(), isNull); // right away

      s.now = DateTime(2026, 10, 28, 12, 59); // 3 h 59 m later
      expect(await s.service.nextDue(), isNull);

      s.now = DateTime(2026, 10, 28, 13, 0); // exactly 4 h
      expect(await s.service.nextDue(), isNotNull);
    });

    test('a gap of 0 shows it every time', () async {
      final s = Setup(gap: 0);
      await s.service.markShown((await s.service.nextDue())!);
      expect(await s.service.nextDue(), isNotNull);
    });

    test('the gap is kept on the phone, so it survives a restart', () async {
      final s = Setup(gap: 240);
      await s.service.markShown((await s.service.nextDue())!);

      final again = Setup(gap: 240); // brand new service, same stored data
      expect(await again.service.nextDue(), isNull);
    });

    test('switched off, or not set up: nothing shows and Notion is not called',
        () async {
      final off = Setup(enabled: false);
      expect(await off.service.nextDue(), isNull);
      expect(off.calls, 0);

      final unset = Setup(configured: false);
      expect(await unset.service.nextDue(), isNull);
      expect(unset.calls, 0);
    });

    test('Notion is asked every time the app opens', () async {
      final s = Setup(gap: 0);
      await s.service.nextDue();
      await s.service.nextDue();
      await s.service.nextDue();
      expect(s.calls, 3);
    });

    test('a change made in Notion is seen on the very next check', () async {
      // Not today when the app first looks...
      final s = Setup(gap: 0, pages: [_page('p1', date: '2026-10-29', repeats: null)]);
      expect(await s.service.nextDue(), isNull);

      // ...then the event is moved to today in Notion. No settings visit needed.
      s.pages[0] = _page('p1', date: '2026-10-28', repeats: null);
      expect((await s.service.nextDue())?.title, 'Happy Anniversary!');
    });

    test('offline: the last events are used from the cache', () async {
      final s = Setup(gap: 0);
      expect(await s.service.nextDue(), isNotNull); // fills the cache

      s.offline = true;
      s.now = DateTime(2026, 10, 28, 15); // cache is stale, so it tries Notion
      expect(await s.service.nextDue(), isNotNull);
      expect(s.calls, 2);
    });

    test('offline with nothing cached shows nothing, without crashing',
        () async {
      final s = Setup()..offline = true;
      expect(await s.service.nextDue(), isNull);
    });
  });

  group('what Settings tells you', () {
    test('no event today: says when the next one is', () async {
      final s = Setup(pages: [_page('p1', date: '2026-10-28')]);
      s.now = DateTime(2026, 10, 21, 22, 30);
      final text = await s.service.todaySummary();
      expect(text, contains('No event today'));
      expect(text, contains('Happy Anniversary!'));
      expect(text, contains('Oct 28, 2026'));
      expect(text, contains('in 7 days'));
    });

    test('an event today: says so', () async {
      final s = Setup();
      final text = await s.service.todaySummary();
      expect(text, startsWith('Today: 1 event'));
      expect(text, contains('Happy Anniversary!'));
    });

    test('a yearly event with its date in the past: next is next year',
        () async {
      final s = Setup(pages: [_page('p1', date: '2026-10-28')]);
      s.now = DateTime(2026, 10, 29, 9);
      expect(await s.service.todaySummary(), contains('Oct 28, 2027'));
    });

    test('an empty database is reported as such', () async {
      final s = Setup(pages: []);
      expect(await s.service.todaySummary(), 'No events found in the database.');
    });

    test('always asks Notion afresh', () async {
      final s = Setup();
      await s.service.todaySummary();
      await s.service.todaySummary();
      expect(s.calls, 2);
    });
  });

  group('there is no time-based reuse of Notion\'s answer', () {
    test('even checks seconds apart each ask Notion', () async {
      final s = Setup(gap: 0);
      await s.service.nextDue();
      s.now = s.now.add(const Duration(seconds: 2));
      await s.service.nextDue();
      s.now = s.now.add(const Duration(seconds: 2));
      await s.service.nextDue();
      expect(s.calls, 3);
    });

    test('an event moved to today is shown on the very next check, however soon',
        () async {
      final s = Setup(gap: 0, pages: [_page('p1', date: '2026-10-29', repeats: null)]);
      expect(await s.service.nextDue(), isNull);

      s.now = s.now.add(const Duration(seconds: 1));
      s.pages[0] = _page('p1', date: '2026-10-28', repeats: null);
      expect(await s.service.nextDue(), isNotNull);
    });

    test('and an event moved away from today stops showing right away',
        () async {
      final s = Setup(gap: 0);
      expect(await s.service.nextDue(), isNotNull);

      s.now = s.now.add(const Duration(seconds: 1));
      s.pages[0] = _page('p1', date: '2026-10-29', repeats: null);
      expect(await s.service.nextDue(), isNull);
    });
  });

  group('what the app reports about the last check', () {
    test('before any check', () {
      final s = Setup();
      expect(s.service.lastCheckText, contains('Not checked yet'));
    });

    test('a successful check says it asked Notion', () async {
      final s = Setup();
      await s.service.nextDue();
      expect(s.service.lastCheckFromNotion, isTrue);
      expect(s.service.lastCheckText, contains('asked Notion'));
    });

    test('a failed check says so and that the saved copy was used', () async {
      final s = Setup();
      await s.service.nextDue(); // saves a copy
      s.offline = true;
      await s.service.nextDue();
      expect(s.service.lastCheckFromNotion, isFalse);
      expect(s.service.lastCheckText, contains('could not reach Notion'));
      expect(s.service.lastCheckText, contains('saved copy'));
    });
  });

  group('several events on the same day: one at a time', () {
    List<Map<String, dynamic>> two() => [
          _page('p1', title: 'First'),
          _page('p2', title: 'Second'),
          _page('p3', title: 'Not today', date: '2026-12-25', repeats: null),
        ];

    test('only one event is returned, never a list', () async {
      final s = Setup(pages: two());
      final e = await s.service.nextDue();
      expect(e, isA<AppEvent>());
      expect(e!.title, 'First'); // Notion order to start with
    });

    test('they take turns, never-shown first, then the one shown longest ago',
        () async {
      final s = Setup(pages: two(), gap: 0);

      final first = (await s.service.nextDue())!;
      expect(first.title, 'First');
      s.now = s.now.add(const Duration(minutes: 1));
      await s.service.markShown(first);

      s.now = s.now.add(const Duration(minutes: 1));
      final second = (await s.service.nextDue())!;
      expect(second.title, 'Second');
      await s.service.markShown(second);

      s.now = s.now.add(const Duration(minutes: 1));
      expect((await s.service.nextDue())!.title, 'First'); // back to the start
    });

    test('the gap is between popups, not per event', () async {
      final s = Setup(pages: two(), gap: 240);
      await s.service.markShown((await s.service.nextDue())!); // First

      // "Second" has never been shown, but a popup just appeared: wait.
      s.now = DateTime(2026, 10, 28, 10, 0);
      expect(await s.service.nextDue(), isNull);

      s.now = DateTime(2026, 10, 28, 13, 0);
      expect((await s.service.nextDue())!.title, 'Second');
    });

    test('events on other days never take a turn', () async {
      final s = Setup(pages: two(), gap: 0);
      for (var i = 0; i < 6; i++) {
        final e = (await s.service.nextDue())!;
        expect(e.title, isNot('Not today'));
        s.now = s.now.add(const Duration(minutes: 1));
        await s.service.markShown(e);
      }
    });
  });

  group('the popup in the app', () {
    ExpenseRepository repo() =>
        ExpenseRepository(db: FakeDb(), api: ApiService(settings: NotionSettings()));

    testWidgets('opening the app shows the Title and Subtitle from Notion',
        (t) async {
      final s = Setup();
      await t.pumpWidget(MaterialApp(home: HomeScreen(repo: repo(), events: s.service)));
      await t.pumpAndSettle();

      expect(find.text('Happy Anniversary!'), findsOneWidget);
      expect(find.text('So much love'), findsOneWidget);
      expect(find.text('Anniversary'), findsOneWidget); // the Type chip

      await t.tap(find.text('Close'));
      await t.pumpAndSettle();
      expect(find.text('Happy Anniversary!'), findsNothing);
    });

    testWidgets('no popup when nothing is on today', (t) async {
      final s = Setup(pages: [_page('p1', date: '2026-12-25', repeats: null)]);
      await t.pumpWidget(MaterialApp(home: HomeScreen(repo: repo(), events: s.service)));
      await t.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('coming back to the app respects the minimum gap', (t) async {
      final s = Setup(gap: 60); // 1 hour
      await t.pumpWidget(MaterialApp(home: HomeScreen(repo: repo(), events: s.service)));
      await t.pumpAndSettle();
      expect(find.text('Happy Anniversary!'), findsOneWidget);
      await t.tap(find.text('Close'));
      await t.pumpAndSettle();

      Future<void> reopenApp() async {
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await t.pump();
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await t.pumpAndSettle();
      }

      s.now = DateTime(2026, 10, 28, 9, 30); // only 30 minutes later
      await reopenApp();
      expect(find.text('Happy Anniversary!'), findsNothing);

      s.now = DateTime(2026, 10, 28, 10, 5); // past the 1 hour gap
      await reopenApp();
      expect(find.text('Happy Anniversary!'), findsOneWidget);
    });

    testWidgets('several events today: one popup, the next after the gap',
        (t) async {
      final s = Setup(pages: [
        _page('p1', title: 'First'),
        _page('p2', title: 'Second'),
      ], gap: 60);
      await t.pumpWidget(MaterialApp(home: HomeScreen(repo: repo(), events: s.service)));
      await t.pumpAndSettle();

      // Only one of them, even though both are today.
      expect(find.text('First'), findsOneWidget);
      expect(find.text('Second'), findsNothing);
      await t.tap(find.text('Close'));
      await t.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);

      Future<void> reopenApp() async {
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await t.pump();
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await t.pumpAndSettle();
      }

      s.now = DateTime(2026, 10, 28, 9, 30); // inside the gap
      await reopenApp();
      expect(find.byType(Dialog), findsNothing);

      s.now = DateTime(2026, 10, 28, 10, 5); // gap over: the other one
      await reopenApp();
      expect(find.text('Second'), findsOneWidget);
      expect(find.text('First'), findsNothing);
    });
  });

  group('Settings: popup controls', () {
    Future<void> openSettings(WidgetTester t, Setup s) async {
      t.view.physicalSize = const Size(800, 5000);
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
          key: UniqueKey(), // a fresh app each time, not the previous page
          home: SettingsScreen(
              api: ApiService(settings: NotionSettings()), events: s.service)));
      await t.pumpAndSettle();
      await t.tap(find.text('Events')); // open the folder
      await t.pumpAndSettle();
    }

    testWidgets('the switch and the gap are saved', (t) async {
      final s = Setup(gap: 240);
      await openSettings(t, s);

      await t.tap(find.widgetWithText(SwitchListTile, 'Show event popups'));
      await t.pumpAndSettle();
      expect(s.service.settings.popupEnabled, isFalse);

      await t.tap(find.byType(DropdownButtonFormField<int>));
      await t.pumpAndSettle();
      await t.tap(find.text('1 hour').last);
      await t.pumpAndSettle();
      expect(s.service.settings.gapMinutes, 60);

      // Stored on the device.
      final stored = await EventsSettings.load();
      expect(stored.popupEnabled, isFalse);
      expect(stored.gapMinutes, 60);
    });

    testWidgets('preview shows the next real event, or a sample', (t) async {
      final real = Setup();
      await openSettings(t, real);
      await t.tap(find.text('Preview an event popup'));
      await t.pumpAndSettle();
      expect(find.text('Happy Anniversary!'), findsOneWidget);
      await t.tap(find.text('Close'));
      await t.pumpAndSettle();

      final none = Setup(configured: false);
      await openSettings(t, none);
      await t.tap(find.text('Preview an event popup'));
      await t.pumpAndSettle();
      expect(find.text('Your event title'), findsOneWidget);
    });
  });
}
