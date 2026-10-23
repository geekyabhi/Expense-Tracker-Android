import 'dart:convert';

import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/screens/home_screen.dart';
import 'package:expense_tracker/services/api_service.dart';
import 'package:expense_tracker/services/expense_repository.dart';
import 'package:expense_tracker/services/options_store.dart';
import 'fakes.dart';
import 'package:expense_tracker/services/notion_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Expense _e(String id, String title, double amount, int day) => Expense(
      id: id,
      title: title,
      amount: amount,
      category: 'Other',
      date: DateTime(2026, 10, day, 12),
    );

void main() {
  late FakeDb db;
  late List<http.Request> calls;
  late ExpenseRepository repo;
  var online = true;
  var queryBody = '{"results":[],"has_more":false}';

  Future<void> pumpHome(WidgetTester t, {bool autoSync = true}) async {
    online = true;
    queryBody = '{"results":[],"has_more":false}';
    db = FakeDb()
      ..rows['a'] = _e('a', 'Lunch', 12.5, 3)
      ..rows['b'] = _e('b', 'Taxi', 40, 2)
      ..rows['c'] = _e('c', 'Coffee', 3, 1);
    calls = [];
    repo = ExpenseRepository(
      db: db,
      pushGap: Duration.zero,
      api: ApiService(
        pageGap: Duration.zero,
        settings: NotionSettings(
            token: 'secret', databaseId: 'dbid', autoSync: autoSync),
        client: MockClient((req) async {
          if (!online) throw http.ClientException('offline');
          calls.add(req);
          if (req.url.path.endsWith('/query')) {
            return http.Response(queryBody, 200);
          }
          return http.Response('{"id":"page-${calls.length}"}', 200);
        }),
      ),
    );
    await repo.reload();
    await t.pumpWidget(MaterialApp(home: HomeScreen(repo: repo)));
    await t.pumpAndSettle();
  }

  testWidgets('tapping an expense opens it for editing and saves changes',
      (t) async {
    // Tall phone-like screen so the whole form (and Save) is on screen.
    t.view.physicalSize = const Size(800, 2400);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await pumpHome(t);

    await t.tap(find.text('Taxi'));
    await t.pumpAndSettle();

    expect(find.text('Edit expense'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Taxi'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '40'), findsOneWidget);

    await t.enterText(find.widgetWithText(TextFormField, 'Taxi'), 'Cab');
    await t.tap(find.text('Save changes'));
    await t.pumpAndSettle();

    expect(find.text('Cab'), findsOneWidget);
    expect(db.rows['b']!.title, 'Cab');
    // Online: the edit is pushed straight away.
    expect(calls.length, 1);
    expect(db.rows['b']!.synced, isTrue);
    expect(find.text('Saved and uploaded to Notion'), findsOneWidget);
  });

  testWidgets('nothing is uploaded until expenses are selected and pushed',
      (t) async {
    await pumpHome(t);
    expect(calls, isEmpty);

    // Long-press selects the first one; tap adds another.
    await t.longPress(find.text('Lunch'));
    await t.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await t.tap(find.text('Coffee'));
    await t.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await t.tap(find.text('Push'));
    await t.pumpAndSettle();

    expect(calls.length, 2);
    expect(db.rows['a']!.synced, isTrue);
    expect(db.rows['c']!.synced, isTrue);
    expect(db.rows['b']!.synced, isFalse);
    expect(db.rows['a']!.remoteId, isNotNull);
    expect(find.text('Expenses'), findsOneWidget); // left selection mode
  });

  testWidgets('select all pushes every expense', (t) async {
    await pumpHome(t);
    await t.tap(find.byTooltip('Select expenses to push'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Select all'));
    await t.pumpAndSettle();
    expect(find.text('3 selected'), findsOneWidget);
    await t.tap(find.text('Push'));
    await t.pumpAndSettle();
    expect(calls.length, 3);
  });

  Future<void> addExpenseViaForm(WidgetTester t) async {
    t.view.physicalSize = const Size(800, 2400);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.tap(find.byType(FloatingActionButton));
    await t.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await t.enterText(fields.at(0), 'Dinner'); // expense name
    await t.enterText(fields.at(1), '99'); // price
    await t.tap(find.text('Save expense'));
    await t.pumpAndSettle();
  }

  testWidgets('new expense is pushed straight away when online', (t) async {
    await pumpHome(t);
    await addExpenseViaForm(t);

    final row = db.rows.values.firstWhere((e) => e.title == 'Dinner');
    expect(calls.length, 1);
    expect(row.synced, isTrue);
    expect(row.remoteId, isNotNull);
    expect(find.text('Saved and uploaded to Notion'), findsOneWidget);
  });

  testWidgets('offline: saved on the device and left for a manual push',
      (t) async {
    await pumpHome(t);
    online = false;
    await addExpenseViaForm(t);

    final row = db.rows.values.firstWhere((e) => e.title == 'Dinner');
    expect(calls, isEmpty);
    expect(row.synced, isFalse);
    expect(find.text('Dinner'), findsOneWidget);
    expect(find.textContaining('push it later'), findsOneWidget);

    // Back online: the manual push uploads it.
    online = true;
    await t.tap(find.byTooltip('Select expenses to push'));
    await t.pumpAndSettle();
    await t.tap(find.text('Dinner'));
    await t.pumpAndSettle();
    await t.tap(find.text('Push'));
    await t.pumpAndSettle();
    expect(calls.length, 1);
    expect(db.rows[row.id]!.synced, isTrue);
  });

  testWidgets('mode defaults to Direct and is what gets pushed', (t) async {
    await pumpHome(t);
    await addExpenseViaForm(t);

    final row = db.rows.values.firstWhere((e) => e.title == 'Dinner');
    expect(row.mode, 'Direct');
    final body = jsonDecode(calls.single.body) as Map<String, dynamic>;
    expect(body['properties']['Mode'], {
      'multi_select': [
        {'name': 'Direct'}
      ]
    });
  });

  testWidgets('an expense created by an app shows that app as its mode',
      (t) async {
    t.view.physicalSize = const Size(800, 2400);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await pumpHome(t);
    db.rows['a'] = db.rows['a']!.copyWith(mode: 'GPay');
    await repo.reload();
    await t.pumpAndSettle();

    // Visible on the list card...
    expect(find.textContaining('GPay'), findsOneWidget);

    // ...and inside the expense details.
    await t.tap(find.text('Lunch'));
    await t.pumpAndSettle();
    final chip = t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'GPay'));
    expect(chip.selected, isTrue);
    expect(find.text('Paid with'), findsNothing);
  });

  testWidgets('manual sync mode: saving never uploads', (t) async {
    await pumpHome(t, autoSync: false);
    await addExpenseViaForm(t);

    final row = db.rows.values.firstWhere((e) => e.title == 'Dinner');
    expect(calls, isEmpty);
    expect(row.synced, isFalse);
    expect(find.text('Saved on device'), findsOneWidget);
  });

  testWidgets('processed rows are green, unprocessed rows are red', (t) async {
    await pumpHome(t);
    db.rows['a'] = db.rows['a']!.copyWith(processed: true);
    await repo.reload();
    await t.pumpAndSettle();

    Color cardColor(String title) => t
        .widget<Card>(find.ancestor(
            of: find.text(title), matching: find.byType(Card)).first)
        .color!;

    final green = cardColor('Lunch'); // processed
    final red = cardColor('Taxi'); // not processed
    expect(green.g, greaterThan(green.r));
    expect(red.r, greaterThan(red.g));
    expect(find.text('Processed'), findsOneWidget);
    expect(find.text('Unprocessed'), findsNWidgets(2));
  });

  testWidgets('Sync from Notion brings in new expenses', (t) async {
    await pumpHome(t);
    queryBody = jsonEncode({
      'results': [
        {
          'id': 'notion-1',
          'properties': {
            'Expense': {
              'title': [
                {'plain_text': 'Chai'}
              ]
            },
            'Amount': {'number': 15},
            'Date': {
              'date': {'start': '2026-10-05'}
            },
            'Processed': {'checkbox': true},
          },
        }
      ],
      'has_more': false,
    });
    expect(find.text('Chai'), findsNothing);

    await t.tap(find.byTooltip('Sync from Notion'));
    await t.pumpAndSettle();

    expect(find.text('Chai'), findsOneWidget);
    expect(find.text('Added 1.'), findsOneWidget);
  });

  testWidgets('delete from the edit screen asks, then removes and archives',
      (t) async {
    t.view.physicalSize = const Size(800, 2400);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await pumpHome(t);
    db.rows['a'] = db.rows['a']!.copyWith(remoteId: 'page-a', synced: true);
    await repo.reload();
    await t.pumpAndSettle();

    await t.tap(find.text('Lunch'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Delete expense'));
    await t.pumpAndSettle();
    expect(find.textContaining('archived in Notion'), findsOneWidget);

    // Cancel keeps it.
    await t.tap(find.widgetWithText(TextButton, 'Cancel'));
    await t.pumpAndSettle();
    expect(db.rows.containsKey('a'), isTrue);

    await t.tap(find.byTooltip('Delete expense'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(TextButton, 'Delete'));
    await t.pumpAndSettle();

    expect(db.rows.containsKey('a'), isFalse);
    expect(find.text('Lunch'), findsNothing);
    expect(calls.single.url.path, '/v1/pages/page-a');
    expect(find.textContaining('Deleted 1 expense'), findsOneWidget);
  });

  testWidgets('bulk delete from selection mode', (t) async {
    await pumpHome(t);
    await t.longPress(find.text('Lunch'));
    await t.pumpAndSettle();
    await t.tap(find.text('Taxi'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Delete selected'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(TextButton, 'Delete'));
    await t.pumpAndSettle();

    expect(db.rows.keys, ['c']);
    expect(find.text('Lunch'), findsNothing);
    expect(find.text('Taxi'), findsNothing);
    expect(find.text('Coffee'), findsOneWidget);
  });

  testWidgets('manual mode: deleted expense shows an Apply banner',
      (t) async {
    await pumpHome(t, autoSync: false);
    db.rows['a'] = db.rows['a']!.copyWith(remoteId: 'page-a', synced: true);
    await repo.reload();
    await t.pumpAndSettle();

    await t.longPress(find.text('Lunch'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Delete selected'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(TextButton, 'Delete'));
    await t.pumpAndSettle();

    expect(calls, isEmpty);
    expect(find.textContaining('not archived in Notion yet'), findsOneWidget);

    await t.tap(find.text('Apply'));
    await t.pumpAndSettle();

    expect(calls.single.url.path, '/v1/pages/page-a');
    expect(find.textContaining('not archived in Notion yet'), findsNothing);
  });

  // ------------------------------------------------- form: order and options

  testWidgets('form fields are in the requested order', (t) async {
    t.view.physicalSize = const Size(800, 3000);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await pumpHome(t);
    await t.tap(find.byType(FloatingActionButton));
    await t.pumpAndSettle();

    double y(String label) => t.getTopLeft(find.text(label)).dy;
    final order = [
      'Expense name',
      'Price',
      'Date & time',
      'Category',
      'Mode',
      'Source',
      'Note (optional)',
    ];
    for (var i = 0; i < order.length - 1; i++) {
      expect(y(order[i]), lessThan(y(order[i + 1])),
          reason: '${order[i]} should be above ${order[i + 1]}');
    }
  });

  Future<void> addOption(WidgetTester t, int newChipIndex, String name) async {
    await t.tap(find.widgetWithText(ActionChip, 'New').at(newChipIndex));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).last, name);
    await t.tap(find.widgetWithText(TextButton, 'Add'));
    await t.pumpAndSettle();
  }

  testWidgets('create a new category, mode and source and use them',
      (t) async {
    t.view.physicalSize = const Size(800, 3000);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await pumpHome(t);
    await t.tap(find.byType(FloatingActionButton));
    await t.pumpAndSettle();

    await addOption(t, 0, 'Groceries'); // category
    await addOption(t, 1, 'Cash'); // mode
    await addOption(t, 2, 'SBI'); // source

    // The new ones are selected right away.
    for (final name in ['Groceries', 'Cash', 'SBI']) {
      expect(t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, name)).selected,
          isTrue,
          reason: name);
    }

    final fields = find.byType(TextFormField);
    await t.enterText(fields.at(0), 'Veggies');
    await t.enterText(fields.at(1), '120');
    await t.tap(find.text('Save expense'));
    await t.pumpAndSettle();

    final row = db.rows.values.firstWhere((e) => e.title == 'Veggies');
    expect(row.category, 'Groceries');
    expect(row.mode, 'Cash');
    expect(row.source, 'SBI');

    // ...and they are what gets sent to Notion.
    final props = jsonDecode(calls.single.body)['properties'];
    expect(props['Category']['multi_select'][0]['name'], 'Groceries');
    expect(props['Mode']['multi_select'][0]['name'], 'Cash');
    expect(props['Source']['multi_select'][0]['name'], 'SBI');

    // Saved for next time.
    expect(repo.options.categories, contains('Groceries'));
    expect(repo.options.modes, contains('Cash'));
    expect(repo.options.sources, contains('SBI'));
  });

  testWidgets('a new option is offered the next time the form opens',
      (t) async {
    t.view.physicalSize = const Size(800, 3000);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await pumpHome(t);
    await repo.options.add(OptionKind.source, 'HDFC');

    await t.tap(find.byType(FloatingActionButton));
    await t.pumpAndSettle();

    expect(find.widgetWithText(ChoiceChip, 'HDFC'), findsOneWidget);
    // Nothing selected by default for the optional source.
    expect(
        t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'HDFC')).selected,
        isFalse);
    // Mode defaults to Direct.
    expect(
        t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Direct')).selected,
        isTrue);
  });

  testWidgets('hold a chip to remove an unused option; used ones are kept',
      (t) async {
    t.view.physicalSize = const Size(800, 3000);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await pumpHome(t);
    await repo.options.add(OptionKind.source, 'OldBank');
    await t.tap(find.byType(FloatingActionButton));
    await t.pumpAndSettle();

    // Unused: removed after confirming.
    await t.longPress(find.widgetWithText(ChoiceChip, 'OldBank'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(TextButton, 'Remove'));
    await t.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'OldBank'), findsNothing);
    expect(repo.options.sources, isNot(contains('OldBank')));

    // "Other" is used by the existing expenses: refused, still there.
    await t.longPress(find.widgetWithText(ChoiceChip, 'Other'));
    await t.pumpAndSettle();
    expect(find.textContaining('Can’t remove'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Other'), findsOneWidget);

    // The default mode can never be removed.
    await t.longPress(find.widgetWithText(ChoiceChip, 'Direct'));
    await t.pumpAndSettle();
    expect(find.textContaining('default mode'), findsOneWidget);
  });

  testWidgets('refresh asks before removing expenses deleted in Notion',
      (t) async {
    await pumpHome(t);
    // 'a' is on the phone and was uploaded; Notion no longer has it.
    db.rows['a'] = db.rows['a']!.copyWith(remoteId: 'page-a', synced: true);
    await repo.reload();
    await t.pumpAndSettle();
    queryBody = jsonEncode({
      'results': [
        {
          'id': 'page-other',
          'properties': {
            'Expense': {
              'title': [
                {'plain_text': 'Something else'}
              ]
            },
            'Amount': {'number': 7},
            'Date': {
              'date': {'start': '2026-10-05'}
            },
          },
        }
      ],
      'has_more': false,
    });

    await t.tap(find.byTooltip('Sync from Notion'));
    await t.pumpAndSettle();
    expect(find.textContaining('deleted in Notion'), findsOneWidget);
    expect(find.textContaining('Lunch'), findsWidgets); // named in the question

    // Keep it on the phone first: it stays, and stops saying "uploaded".
    await t.tap(find.widgetWithText(TextButton, 'Keep on phone'));
    await t.pumpAndSettle();
    expect(db.rows.containsKey('a'), isTrue);
    expect(db.rows['a']!.synced, isFalse);
    expect(db.rows['a']!.remoteId, isNull);
    expect(find.textContaining('kept on the phone and marked not uploaded'),
        findsOneWidget);
    expect(find.text('On device'), findsWidgets);

    // Pretend it was uploaded again and then deleted in Notion; this time remove it.
    db.rows['a'] = db.rows['a']!.copyWith(remoteId: 'page-a', synced: true);
    await repo.reload();
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Sync from Notion'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(TextButton, 'Remove'));
    await t.pumpAndSettle();
    expect(db.rows.containsKey('a'), isFalse);
    expect(find.textContaining('removed 1 deleted in Notion'), findsOneWidget);
  });
}
