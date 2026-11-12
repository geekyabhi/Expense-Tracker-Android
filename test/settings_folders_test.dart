import 'package:expense_tracker/screens/settings_screen.dart';
import 'package:expense_tracker/services/events_api.dart';
import 'package:expense_tracker/services/events_service.dart';
import 'package:expense_tracker/services/events_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

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
  late Harness h;
  late EventsService events;

  Future<void> open(WidgetTester t,
      {bool signedIn = false, bool manual = false, bool eventsOn = false, int gap = 240}) async {
    t.view.physicalSize = const Size(800, 3000);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    const channel = MethodChannel('expense_tracker/watcher');
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, android.handle);
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    h = await Harness.create(signedIn: signedIn, autoSync: !manual);
    events = EventsService(
        api: EventsApi(
            settings: eventsOn
                ? EventsSettings(token: 't', databaseId: 'd', gapMinutes: gap)
                : EventsSettings()));
    await t.pumpWidget(MaterialApp(home: SettingsScreen(account: h.account, repo: h.repo, events: events)));
    await t.pumpAndSettle();
  }

  Finder folder(String title) => find.widgetWithText(ListTile, title);

  /// The status line of a folder on the main list.
  String summaryOf(WidgetTester t, String title) {
    final tile = t.widget<ListTile>(folder(title));
    return (tile.subtitle as Text).data!;
  }

  setUp(() => android = FakeAndroid());

  testWidgets('the main list has the four folders, and no Events', (t) async {
    await open(t);
    expect(folder('Events'), findsNothing);
    for (final name in [
      'Account & sync',
      'Floating button',
      'Close-an-app popup',
      'Permissions',
    ]) {
      expect(folder(name), findsOneWidget, reason: name);
    }
    // Nothing from inside the folders is on the main list.
    expect(find.text('Sign out of all devices'), findsNothing);
    expect(find.text('Show event popups'), findsNothing);
    expect(find.widgetWithText(SwitchListTile, 'Floating + button'), findsNothing);
  });

  testWidgets('each folder shows a one-line status', (t) async {
    await open(t);
    expect(summaryOf(t, 'Account & sync'), 'Not signed in');
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
    await open(t, signedIn: true, eventsOn: true, gap: 240);
    expect(summaryOf(t, 'Account & sync'), 'user@example.com · Auto sync');
    expect(summaryOf(t, 'Floating button'), 'On');
    expect(summaryOf(t, 'Close-an-app popup'), 'On · 2 apps');
    expect(summaryOf(t, 'Permissions'), '2 of 3 granted');
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

    await visit('Account & sync', () {
      expect(find.text('Sign out of all devices'), findsOneWidget);
      expect(find.text('Sign out'), findsWidgets);
      expect(find.text('Auto'), findsOneWidget);
      expect(find.text('Manual'), findsOneWidget);
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
    await open(t, signedIn: true);
    expect(summaryOf(t, 'Floating button'), 'Off');
    expect(summaryOf(t, 'Account & sync'), 'user@example.com · Auto sync');

    // Turn the floating button on.
    await t.tap(folder('Floating button'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(SwitchListTile, 'Floating + button'));
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();
    expect(summaryOf(t, 'Floating button'), 'On');

    // Switch sync to Manual.
    await t.tap(folder('Account & sync'));
    await t.pumpAndSettle();
    await t.tap(find.text('Manual'));
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();
    expect(summaryOf(t, 'Account & sync'), 'user@example.com · Manual sync');
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
