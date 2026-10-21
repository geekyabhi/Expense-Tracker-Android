import 'package:expense_tracker/screens/settings_screen.dart';
import 'package:expense_tracker/services/api_service.dart';
import 'package:expense_tracker/services/notion_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the Android side of the "expense_tracker/watcher" channel.
class FakeAndroid {
  FakeAndroid({this.overlay = true});
  bool overlay;
  bool bubble = false;
  final calls = <MethodCall>[];

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'getInstalledApps':
      case 'getWatched':
        return <Object?>[];
      case 'permissionStatus':
        return {'usage': true, 'overlay': overlay, 'battery': true};
      case 'isEnabled':
        return false;
      case 'isBubbleEnabled':
        return bubble;
      case 'setBubbleEnabled':
        if (call.arguments['enabled'] == true && !overlay) {
          throw PlatformException(code: 'overlay');
        }
        bubble = call.arguments['enabled'] as bool;
        return null;
      default:
        return null;
    }
  }
}

void main() {
  Future<void> open(WidgetTester t, FakeAndroid android) async {
    t.view.physicalSize = const Size(800, 7000);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('expense_tracker/watcher'), android.handle);
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('expense_tracker/watcher'), null));
    await t.pumpWidget(MaterialApp(
        home: SettingsScreen(api: ApiService(settings: NotionSettings()))));
    await t.pumpAndSettle();
    await t.tap(find.text('Floating button')); // open the folder
    await t.pumpAndSettle();
  }

  Finder bubbleSwitch() =>
      find.widgetWithText(SwitchListTile, 'Floating + button');

  testWidgets('the floating button can be turned on and off', (t) async {
    final android = FakeAndroid();
    await open(t, android);
    expect(t.widget<SwitchListTile>(bubbleSwitch()).value, isFalse);

    await t.tap(bubbleSwitch());
    await t.pumpAndSettle();
    expect(t.widget<SwitchListTile>(bubbleSwitch()).value, isTrue);
    expect(android.bubble, isTrue);

    await t.tap(bubbleSwitch());
    await t.pumpAndSettle();
    expect(t.widget<SwitchListTile>(bubbleSwitch()).value, isFalse);
    expect(android.bubble, isFalse);
  });

  testWidgets('it starts switched on if it was left on', (t) async {
    final android = FakeAndroid()..bubble = true;
    await open(t, android);
    expect(t.widget<SwitchListTile>(bubbleSwitch()).value, isTrue);
  });

  testWidgets('without the overlay permission it asks for it instead',
      (t) async {
    final android = FakeAndroid(overlay: false);
    await open(t, android);

    await t.tap(bubbleSwitch());
    await t.pumpAndSettle();

    expect(t.widget<SwitchListTile>(bubbleSwitch()).value, isFalse);
    expect(android.calls.where((c) => c.method == 'setBubbleEnabled'), isEmpty);
    expect(find.textContaining('Display over other apps'), findsWidgets);
    expect(find.text('Grant'), findsWidgets);
  });
}
