import 'package:expense_tracker/screens/auth_gate.dart';
import 'package:expense_tracker/services/events_api.dart';
import 'package:expense_tracker/services/events_service.dart';
import 'package:expense_tracker/services/events_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

EventsService noEvents() =>
    EventsService(api: EventsApi(settings: EventsSettings()));

/// A tall phone-like screen, so whole forms (and their Save button) are visible.
void tallScreen(WidgetTester t, {double height = 3000}) {
  t.view.physicalSize = Size(800, height);
  t.view.devicePixelRatio = 2.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
}

/// Answers the Android side of the app's channel (no phone in a test).
void fakeAndroid(WidgetTester t, {bool overlay = true}) {
  const channel = MethodChannel('expense_tracker/watcher');
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
    switch (c.method) {
      case 'getInstalledApps':
      case 'getWatched':
        return <Object?>[];
      case 'permissionStatus':
        return {'usage': true, 'overlay': overlay, 'battery': true};
      case 'isEnabled':
      case 'isBubbleEnabled':
        return false;
      default:
        return null;
    }
  });
  addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
}

/// The whole app as a person meets it: the front door, then the screens.
Future<void> pumpApp(WidgetTester t, Harness h,
    {EventsService? events, bool tall = false}) async {
  if (tall) tallScreen(t);
  fakeAndroid(t);
  await t.pumpWidget(MaterialApp(
    key: UniqueKey(),
    home: AuthGate(account: h.account, repo: h.repo, events: events ?? noEvents()),
  ));
  await t.pumpAndSettle();
}
