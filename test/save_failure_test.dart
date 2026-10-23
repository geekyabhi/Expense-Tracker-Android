import 'dart:convert';

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

/// Storage that always fails, like the shrunk release build did
/// (NoSuchMethodError from the shared_preferences plugin).
class BrokenNotionSettings extends NotionSettings {
  BrokenNotionSettings({super.token, super.databaseId});
  @override
  Future<void> save() async => throw PlatformException(code: 'NoSuchMethodError');
}

class BrokenEventsSettings extends EventsSettings {
  BrokenEventsSettings({super.token, super.databaseId});
  @override
  Future<void> save() async => throw PlatformException(code: 'NoSuchMethodError');
}

http.Response _dbOk() => http.Response(
    jsonEncode({
      'title': [
        {'plain_text': 'My database'}
      ],
      'properties': {
        'Expense': {'type': 'title'},
        'Amount': {'type': 'number'},
        'Date': {'type': 'date'},
        'Category': {'type': 'multi_select'},
        'Source': {'type': 'multi_select'},
        'Mode': {'type': 'multi_select'},
        'Processed': {'type': 'checkbox'},
        'Title': {'type': 'rich_text'},
        'Subtitle': {'type': 'rich_text'},
      }
    }),
    200);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> open(WidgetTester t, ApiService api, EventsService events) async {
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
    await t.pumpWidget(MaterialApp(home: SettingsScreen(api: api, events: events)));
    await t.pumpAndSettle();
  }

  Finder field(String label) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == label);

  testWidgets(
      'expenses: if saving fails, the test still runs, the spinner stops and you are told',
      (t) async {
    final calls = <http.Request>[];
    final api = ApiService(
      settings: BrokenNotionSettings(),
      client: MockClient((r) async {
        calls.add(r);
        return _dbOk();
      }),
    );
    await open(t, api, EventsService(api: EventsApi(settings: EventsSettings())));

    await t.tap(find.text('Expenses & Notion'));
    await t.pumpAndSettle();
    await t.enterText(field('Notion Bearer token'), 'tok');
    await t.enterText(field('Expenses database ID'), 'db');
    await t.tap(find.text('Save & test connection'));
    await t.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'spinner must stop');
    expect(calls, isNotEmpty, reason: 'the connection is still tested');
    expect(find.textContaining('Could not save these settings on the phone'),
        findsOneWidget);
    expect(find.textContaining('look right'), findsOneWidget);
    // Shown as a problem (not the green success colour).
    final text = t.widget<Text>(find.textContaining('Could not save these settings'));
    expect(text.style!.color, isNot(Colors.green));
  });

  testWidgets('expenses: when saving works there is no warning', (t) async {
    final api = ApiService(
      settings: NotionSettings(),
      client: MockClient((r) async => _dbOk()),
    );
    await open(t, api, EventsService(api: EventsApi(settings: EventsSettings())));
    await t.tap(find.text('Expenses & Notion'));
    await t.pumpAndSettle();
    await t.enterText(field('Notion Bearer token'), 'tok');
    await t.enterText(field('Expenses database ID'), 'db');
    await t.tap(find.text('Save & test connection'));
    await t.pumpAndSettle();

    expect(find.textContaining('Could not save'), findsNothing);
    expect(find.textContaining('look right'), findsOneWidget);
    final text = t.widget<Text>(find.textContaining('look right'));
    expect(text.style!.color, Colors.green);
  });

  testWidgets('events: if saving fails, the spinner stops and you are told',
      (t) async {
    final eventsApi = EventsApi(
      settings: BrokenEventsSettings(),
      pageGap: Duration.zero,
      client: MockClient((r) async => r.method == 'GET'
          ? _dbOk()
          : http.Response('{"results":[],"has_more":false}', 200)),
    );
    await open(t, ApiService(settings: NotionSettings()), EventsService(api: eventsApi));

    await t.tap(find.text('Events'));
    await t.pumpAndSettle();
    await t.enterText(field('Events Bearer token'), 'tok');
    await t.enterText(field('Events database ID'), 'db');
    await t.tap(find.text('Save & test events'));
    await t.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Could not save these settings on the phone'),
        findsOneWidget);
    expect(find.textContaining('look right'), findsOneWidget);
  });

  testWidgets('a crash anywhere in the test still stops the spinner', (t) async {
    final api = ApiService(
      settings: NotionSettings(),
      client: MockClient((r) async => throw StateError('boom')),
    );
    await open(t, api, EventsService(api: EventsApi(settings: EventsSettings())));
    await t.tap(find.text('Expenses & Notion'));
    await t.pumpAndSettle();
    await t.enterText(field('Notion Bearer token'), 'tok');
    await t.enterText(field('Expenses database ID'), 'db');
    await t.tap(find.text('Save & test connection'));
    await t.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Could not reach Notion'), findsOneWidget);
  });
}
