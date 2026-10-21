import 'package:expense_tracker/screens/settings_screen.dart';
import 'package:expense_tracker/services/api_service.dart';
import 'package:expense_tracker/services/events_api.dart';
import 'package:expense_tracker/services/events_service.dart';
import 'package:expense_tracker/services/events_settings.dart';
import 'package:expense_tracker/services/notion_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for the Android side of the "expense_tracker/watcher" channel.
class FakeAndroid {
  bool bubble = false;
  bool watcher = false;
  bool usage = true;
  bool overlay = true;
  bool battery = true;
  Set<String> watched = {};

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'getInstalledApps':
        return [
          {'name': 'GPay', 'package': 'com.gpay', 'icon': null},
          {'name': 'Swiggy', 'package': 'com.swiggy', 'icon': null},
        ];
      case 'getWatched':
        return watched.toList();
      case 'setWatched':
        watched = (call.arguments['packages'] as List).cast<String>().toSet();
        return null;
      case 'permissionStatus':
        return {'usage': usage, 'overlay': overlay, 'battery': battery};
      case 'isEnabled':
        return watcher;
      case 'setEnabled':
        watcher = call.arguments['enabled'] as bool;
        return null;
      case 'isBubbleEnabled':
        return bubble;
      case 'setBubbleEnabled':
        bubble = call.arguments['enabled'] as bool;
        return null;
      default:
        return null;
    }
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late FakeAndroid android;
  late ApiService api;
  late EventsService events;

  Future<void> open(WidgetTester t,
      {bool notion = false, bool eventsOn = false, int gap = 240}) async {
    t.view.physicalSize = const Size(800, 3000);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    const channel = MethodChannel('expense_tracker/watcher');
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, android.handle);
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    api = ApiService(
        settings: notion
            ? NotionSettings(token: 't', databaseId: 'd')
            : NotionSettings());
    events = EventsService(
        api: EventsApi(
            settings: eventsOn
                ? EventsSettings(token: 't', databaseId: 'd', gapMinutes: gap)
                : EventsSettings()));
    await t.pumpWidget(MaterialApp(home: SettingsScreen(api: api, events: events)));
    await t.pumpAndSettle();
  }

  Finder folder(String title) => find.widgetWithText(ListTile, title);

  /// The status line of a folder on the main list.
  String summaryOf(WidgetTester t, String title) {
    final tile = t.widget<ListTile>(folder(title));
    return (tile.subtitle as Text).data!;
  }

  setUp(() => android = FakeAndroid());

  testWidgets('the main list has the five folders', (t) async {
    await open(t);
    for (final name in [
      'Expenses & Notion',
      'Events',
      'Floating button',
      'Close-an-app popup',
      'Permissions',
    ]) {
      expect(folder(name), findsOneWidget, reason: name);
    }
    // Nothing from inside the folders is on the main list.
    expect(find.text('Notion Bearer token'), findsNothing);
    expect(find.text('Show event popups'), findsNothing);
    expect(find.widgetWithText(SwitchListTile, 'Floating + button'), findsNothing);
  });

  testWidgets('each folder shows a one-line status', (t) async {
    await open(t);
    expect(summaryOf(t, 'Expenses & Notion'), 'Not set up');
    expect(summaryOf(t, 'Events'), 'Not set up');
    expect(summaryOf(t, 'Floating button'), 'Off');
    expect(summaryOf(t, 'Close-an-app popup'), 'Off');
    expect(summaryOf(t, 'Permissions'), '3 of 3 granted');
  });

  testWidgets('the status reflects the real settings', (t) async {
    android
      ..bubble = true
      ..watcher = true
      ..watched = {'com.gpay', 'com.swiggy'}
      ..overlay = false;
    await open(t, notion: true, eventsOn: true, gap: 240);
    expect(summaryOf(t, 'Expenses & Notion'), 'Connected · Auto sync');
    expect(summaryOf(t, 'Events'), 'Popups on · gap: 4 hours');
    expect(summaryOf(t, 'Floating button'), 'On');
    expect(summaryOf(t, 'Close-an-app popup'), 'On · 2 apps');
    expect(summaryOf(t, 'Permissions'), '2 of 3 granted');
  });

  testWidgets('"Every time I open the app" reads naturally in the status',
      (t) async {
    await open(t, eventsOn: true, gap: 0);
    expect(summaryOf(t, 'Events'), 'Popups on · gap: every time I open the app');
  });

  testWidgets('each folder opens its own page', (t) async {
    await open(t);

    Future<void> visit(String name, void Function() check) async {
      await t.tap(folder(name));
      await t.pumpAndSettle();
      check();
      await t.pageBack();
      await t.pumpAndSettle();
      expect(folder(name), findsOneWidget); // back on the main list
    }

    await visit('Expenses & Notion', () {
      expect(find.text('Notion Bearer token'), findsOneWidget);
      expect(find.text('Save & test connection'), findsOneWidget);
      expect(find.text('Auto'), findsOneWidget);
      expect(find.text('Manual'), findsOneWidget);
    });
    await visit('Events', () {
      expect(find.text('Events Bearer token'), findsOneWidget);
      expect(find.text('Save & test events'), findsOneWidget);
      expect(find.text('Show event popups'), findsOneWidget);
      expect(find.text('Preview an event popup'), findsOneWidget);
    });
    await visit('Floating button', () {
      expect(find.widgetWithText(SwitchListTile, 'Floating + button'), findsOneWidget);
    });
    await visit('Close-an-app popup', () {
      expect(find.text('Ask for an expense when I close an app'), findsOneWidget);
      expect(find.text('Preview the popup'), findsOneWidget);
      expect(find.text('GPay'), findsOneWidget);
      expect(find.text('Swiggy'), findsOneWidget);
    });
    await visit('Permissions', () {
      expect(find.text('Usage access'), findsOneWidget);
      expect(find.text('Display over other apps'), findsOneWidget);
      expect(find.text('Unrestricted battery'), findsOneWidget);
    });
  });

  testWidgets('the status updates when you come back from a folder', (t) async {
    await open(t, notion: true);
    expect(summaryOf(t, 'Floating button'), 'Off');
    expect(summaryOf(t, 'Expenses & Notion'), 'Connected · Auto sync');

    // Turn the floating button on.
    await t.tap(folder('Floating button'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(SwitchListTile, 'Floating + button'));
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();
    expect(summaryOf(t, 'Floating button'), 'On');

    // Switch sync to Manual.
    await t.tap(folder('Expenses & Notion'));
    await t.pumpAndSettle();
    await t.tap(find.text('Manual'));
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();
    expect(summaryOf(t, 'Expenses & Notion'), 'Connected · Manual sync');
  });

  testWidgets('picking an app in its folder updates the count', (t) async {
    android.watcher = true;
    await open(t);
    expect(summaryOf(t, 'Close-an-app popup'), 'On · 0 apps');

    await t.tap(folder('Close-an-app popup'));
    await t.pumpAndSettle();
    await t.tap(find.text('GPay'));
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();
    expect(summaryOf(t, 'Close-an-app popup'), 'On · 1 app');
  });
}
