import 'dart:convert';

import 'package:expense_tracker/services/options_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'ui_helpers.dart';

/// Three expenses that exist only on the phone.
Future<void> seedLocal(Harness h) async {
  h.db.rows['a'] = h.local('a', title: 'Lunch', amount: 12.5, date: DateTime(2026, 10, 3, 12));
  h.db.rows['b'] = h.local('b', title: 'Taxi', amount: 40, date: DateTime(2026, 10, 2, 12));
  h.db.rows['c'] = h.local('c', title: 'Coffee', amount: 3, date: DateTime(2026, 10, 1, 12));
  await h.repo.reload();
}

Map<String, dynamic> lastBody(Harness h, String path) =>
    jsonDecode(h.backend.callsTo(path).last.body) as Map<String, dynamic>;

/// Fills the add form: name first, then the price.
Future<void> fillForm(WidgetTester t, {String name = 'Dinner', String price = '99'}) async {
  final fields = find.byType(TextFormField);
  await t.enterText(fields.at(0), name);
  await t.enterText(fields.at(1), price);
}

void main() {
  group('opening and editing an expense', () {
    testWidgets('tapping opens it with its values, and saved edits go to the server',
        (t) async {
      final h = await Harness.create();
      await seedLocal(h);
      await pumpApp(t, h, tall: true);

      await t.tap(find.text('Taxi'));
      await t.pumpAndSettle();
      expect(find.text('Edit expense'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Taxi'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '40'), findsOneWidget);

      await t.enterText(find.widgetWithText(TextFormField, 'Taxi'), 'Cab');
      await t.tap(find.text('Save changes'));
      await t.pumpAndSettle();

      expect(find.text('Cab'), findsOneWidget);
      expect(h.db.rows['b']!.title, 'Cab');
      expect(h.db.rows['b']!.synced, isTrue); // Auto: pushed
      expect(h.backend.count(h.user.id), 1);
      expect(find.text('Saved and uploaded'), findsOneWidget);
    });

    testWidgets('an expense made by an app shows that app as its mode, in the list and inside',
        (t) async {
      final h = await Harness.create();
      await seedLocal(h);
      h.db.rows['a'] = h.db.rows['a']!.copyWith(mode: 'GPay');
      await h.repo.reload();
      await pumpApp(t, h, tall: true);

      expect(find.textContaining('GPay'), findsOneWidget);
      await t.tap(find.text('Lunch'));
      await t.pumpAndSettle();
      expect(t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'GPay')).selected, isTrue);
    });
  });

  group('selecting and pushing', () {
    testWidgets('long-press and tap select; Push uploads only those', (t) async {
      final h = await Harness.create(autoSync: false);
      await seedLocal(h);
      await pumpApp(t, h);
      expect(h.backend.calls, isEmpty); // Manual: nothing is sent by itself

      await t.longPress(find.text('Lunch'));
      await t.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      await t.tap(find.text('Coffee'));
      await t.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      await t.tap(find.text('Push'));
      await t.pumpAndSettle();

      expect(h.backend.count(h.user.id), 2);
      expect(h.db.rows['a']!.synced, isTrue);
      expect(h.db.rows['c']!.synced, isTrue);
      expect(h.db.rows['b']!.synced, isFalse);
      expect(h.db.rows['a']!.remoteId, isNotNull);
      expect(find.text('Expenses'), findsOneWidget); // back out of selection mode
    });

    testWidgets('select all pushes everything', (t) async {
      final h = await Harness.create(autoSync: false);
      await seedLocal(h);
      await pumpApp(t, h);
      await t.tap(find.byTooltip('Select expenses to push'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Select all'));
      await t.pumpAndSettle();
      expect(find.text('3 selected'), findsOneWidget);
      await t.tap(find.text('Push'));
      await t.pumpAndSettle();
      expect(h.backend.count(h.user.id), 3);
    });

    testWidgets('green for processed, red for not processed, with a word as well', (t) async {
      final h = await Harness.create();
      await seedLocal(h);
      h.db.rows['a'] = h.db.rows['a']!.copyWith(processed: true);
      await h.repo.reload();
      await pumpApp(t, h);

      Color cardColor(String title) => t
          .widget<Card>(find.ancestor(of: find.text(title), matching: find.byType(Card)).first)
          .color!;
      expect(cardColor('Lunch').g, greaterThan(cardColor('Lunch').r));
      expect(cardColor('Taxi').r, greaterThan(cardColor('Taxi').g));
      expect(find.text('Processed'), findsOneWidget);
      expect(find.text('Unprocessed'), findsNWidgets(2));
    });
  });

  group('adding an expense', () {
    testWidgets('Auto, online: saved and uploaded straight away', (t) async {
      final h = await Harness.create();
      await pumpApp(t, h, tall: true);
      await t.tap(find.byType(FloatingActionButton));
      await t.pumpAndSettle();
      await fillForm(t);
      await t.tap(find.text('Save expense'));
      await t.pumpAndSettle();

      final row = h.db.rows.values.single;
      expect(row.synced, isTrue);
      expect(h.backend.count(h.user.id), 1);
      expect(lastBody(h, '/create/')['name'], 'Dinner');
      expect(lastBody(h, '/create/')['amount'], 99);
      expect(find.text('Saved and uploaded'), findsOneWidget);
    });

    testWidgets('offline: saved on the phone, pushed later by hand', (t) async {
      final h = await Harness.create();
      await pumpApp(t, h, tall: true);
      h.backend.offline = true;
      await t.tap(find.byType(FloatingActionButton));
      await t.pumpAndSettle();
      await fillForm(t);
      await t.tap(find.text('Save expense'));
      await t.pumpAndSettle();

      expect(h.db.rows.values.single.synced, isFalse);
      expect(find.text('Dinner'), findsOneWidget);
      expect(find.textContaining('push it later'), findsOneWidget);

      h.backend.offline = false;
      await t.tap(find.byTooltip('Select expenses to push'));
      await t.pumpAndSettle();
      await t.tap(find.text('Dinner'));
      await t.pumpAndSettle();
      await t.tap(find.text('Push'));
      await t.pumpAndSettle();
      expect(h.db.rows.values.single.synced, isTrue);
      expect(h.backend.count(h.user.id), 1);
    });

    testWidgets('Manual: saving never uploads', (t) async {
      final h = await Harness.create(autoSync: false);
      await pumpApp(t, h, tall: true);
      await t.tap(find.byType(FloatingActionButton));
      await t.pumpAndSettle();
      await fillForm(t);
      await t.tap(find.text('Save expense'));
      await t.pumpAndSettle();

      expect(h.backend.calls, isEmpty);
      expect(h.db.rows.values.single.synced, isFalse);
      expect(find.text('Saved on device'), findsOneWidget);
    });

    testWidgets('the mode defaults to Direct and that is what the server gets', (t) async {
      final h = await Harness.create();
      await pumpApp(t, h, tall: true);
      await t.tap(find.byType(FloatingActionButton));
      await t.pumpAndSettle();
      await fillForm(t);
      await t.tap(find.text('Save expense'));
      await t.pumpAndSettle();
      expect(h.db.rows.values.single.mode, 'Direct');
      expect(lastBody(h, '/create/')['mode'], 'Direct');
    });

    testWidgets('the note goes to the server as the comment', (t) async {
      final h = await Harness.create();
      await pumpApp(t, h, tall: true);
      await t.tap(find.byType(FloatingActionButton));
      await t.pumpAndSettle();
      await fillForm(t);
      await t.enterText(find.byType(TextFormField).at(2), 'with Sam');
      await t.tap(find.text('Save expense'));
      await t.pumpAndSettle();
      expect(lastBody(h, '/create/')['comment'], 'with Sam');
    });
  });

  group('refreshing from the server', () {
    testWidgets('new expenses from the website come in', (t) async {
      final h = await Harness.create();
      await pumpApp(t, h);
      h.backend.addExpense(h.user.id, title: 'Chai', amount: 15, date: '2026-10-05');
      expect(find.text('Chai'), findsNothing);

      await t.tap(find.byTooltip('Sync from server'));
      await t.pumpAndSettle();

      expect(find.text('Chai'), findsOneWidget);
      expect(find.text('Added 1.'), findsOneWidget);
    });

    testWidgets('an edit made on the website shows up', (t) async {
      final h = await Harness.create();
      final id = h.backend.addExpense(h.user.id, title: 'Chai', amount: 15, date: '2026-10-05');
      await h.repo.refreshFromServer();
      await pumpApp(t, h);
      h.backend.editExpense(h.user.id, id, {'title': 'Masala chai', 'amount': 18});

      await t.tap(find.byTooltip('Sync from server'));
      await t.pumpAndSettle();

      expect(find.text('Masala chai'), findsOneWidget);
      expect(find.text('Chai'), findsNothing);
      expect(find.textContaining('updated 1 from the server'), findsOneWidget);
    });

    testWidgets('pulling the list down refreshes too', (t) async {
      final h = await Harness.create();
      await seedLocal(h);
      await pumpApp(t, h);
      h.backend.addExpense(h.user.id, title: 'From the web', date: '2026-10-04');
      await t.fling(find.text('Lunch'), const Offset(0, 400), 1000);
      await t.pumpAndSettle();
      expect(find.text('From the web'), findsOneWidget);
    });

    testWidgets('asks before removing expenses deleted on the server', (t) async {
      final h = await Harness.create();
      final gone = h.backend.addExpense(h.user.id, title: 'Doomed', date: '2026-10-06');
      h.backend.addExpense(h.user.id, title: 'Stays', date: '2026-10-07');
      await h.repo.refreshFromServer();
      await pumpApp(t, h);
      h.backend.removeExpense(h.user.id, gone);

      await t.tap(find.byTooltip('Sync from server'));
      await t.pumpAndSettle();
      expect(find.textContaining('deleted on the server'), findsOneWidget);
      expect(find.textContaining('Doomed'), findsWidgets); // named in the question

      // Keep it: it stays, and says "On device" now.
      await t.tap(find.widgetWithText(TextButton, 'Keep on phone'));
      await t.pumpAndSettle();
      expect(find.text('Doomed'), findsOneWidget);
      expect(find.textContaining('kept on the phone and marked not uploaded'), findsOneWidget);
      expect(h.db.rows.values.firstWhere((e) => e.title == 'Doomed').synced, isFalse);

      // Another one uploaded and then deleted on the server: remove it this time.
      final again = h.backend.addExpense(h.user.id, title: 'Doomed too', date: '2026-10-08');
      await h.repo.refreshFromServer();
      h.backend.removeExpense(h.user.id, again);
      await t.tap(find.byTooltip('Sync from server'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(TextButton, 'Remove'));
      await t.pumpAndSettle();
      expect(find.text('Doomed too'), findsNothing);
      expect(find.textContaining('removed 1 deleted on the server'), findsOneWidget);
    });

    testWidgets('a server problem is reported, not silent', (t) async {
      final h = await Harness.create();
      await pumpApp(t, h);
      h.backend.offline = true;
      await t.tap(find.byTooltip('Sync from server'));
      await t.pumpAndSettle();
      expect(find.textContaining('No connection'), findsOneWidget);
    });
  });

  group('deleting', () {
    Future<Harness> withUploaded({bool autoSync = true}) async {
      final h = await Harness.create(autoSync: autoSync);
      h.backend.addExpense(h.user.id, title: 'Lunch', date: '2026-10-03');
      await h.repo.refreshFromServer();
      return h;
    }

    testWidgets('from the edit screen: asks, can be cancelled, then removes it on the server too',
        (t) async {
      final h = await withUploaded();
      await pumpApp(t, h, tall: true);
      await t.tap(find.text('Lunch'));
      await t.pumpAndSettle();

      await t.tap(find.byTooltip('Delete expense'));
      await t.pumpAndSettle();
      expect(find.textContaining('deleted on the server'), findsOneWidget);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await t.pumpAndSettle();
      expect(h.db.rows, isNotEmpty);

      await t.tap(find.byTooltip('Delete expense'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(TextButton, 'Delete'));
      await t.pumpAndSettle();

      expect(h.db.rows, isEmpty);
      expect(find.text('Lunch'), findsNothing);
      expect(h.backend.count(h.user.id), 0);
      expect(find.textContaining('Deleted 1 expense'), findsOneWidget);
    });

    testWidgets('several at once from selection mode', (t) async {
      final h = await Harness.create();
      await seedLocal(h);
      await pumpApp(t, h);
      await t.longPress(find.text('Lunch'));
      await t.pumpAndSettle();
      await t.tap(find.text('Taxi'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Delete selected'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(TextButton, 'Delete'));
      await t.pumpAndSettle();
      expect(h.db.rows.keys, ['c']);
      expect(find.text('Coffee'), findsOneWidget);
    });

    testWidgets('Manual: a banner waits for Apply, which tells the server', (t) async {
      final h = await withUploaded(autoSync: false);
      await pumpApp(t, h);
      await t.longPress(find.text('Lunch'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Delete selected'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(TextButton, 'Delete'));
      await t.pumpAndSettle();

      expect(h.backend.count(h.user.id), 1); // not told yet
      expect(find.textContaining('not deleted on the server yet'), findsOneWidget);

      await t.tap(find.text('Apply'));
      await t.pumpAndSettle();
      expect(h.backend.count(h.user.id), 0);
      expect(find.textContaining('not deleted on the server yet'), findsNothing);
    });
  });

  group('the form: order, and your own categories, modes and sources', () {
    testWidgets('fields are in the requested order', (t) async {
      final h = await Harness.create();
      await pumpApp(t, h, tall: true);
      await t.tap(find.byType(FloatingActionButton));
      await t.pumpAndSettle();

      double y(String label) => t.getTopLeft(find.text(label)).dy;
      const order = [
        'Expense name', 'Price', 'Date & time', 'Category', 'Mode', 'Source', 'Note (optional)',
      ];
      for (var i = 0; i < order.length - 1; i++) {
        expect(y(order[i]), lessThan(y(order[i + 1])), reason: '${order[i]} above ${order[i + 1]}');
      }
    });

    Future<void> addOption(WidgetTester t, int newChip, String name) async {
      await t.tap(find.widgetWithText(ActionChip, 'New').at(newChip));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).last, name);
      await t.tap(find.widgetWithText(TextButton, 'Add'));
      await t.pumpAndSettle();
    }

    testWidgets('create a category, mode and source, and use them', (t) async {
      final h = await Harness.create();
      await pumpApp(t, h, tall: true);
      await t.tap(find.byType(FloatingActionButton));
      await t.pumpAndSettle();
      await addOption(t, 0, 'Groceries');
      await addOption(t, 1, 'Cash');
      await addOption(t, 2, 'SBI');
      for (final n in ['Groceries', 'Cash', 'SBI']) {
        expect(t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, n)).selected, isTrue, reason: n);
      }
      await fillForm(t, name: 'Veggies', price: '120');
      await t.tap(find.text('Save expense'));
      await t.pumpAndSettle();

      final row = h.db.rows.values.single;
      expect([row.category, row.mode, row.source], ['Groceries', 'Cash', 'SBI']);
      final body = lastBody(h, '/create/');
      expect(body['categories'], ['Groceries']);
      expect(body['mode'], 'Cash');
      expect(body['source'], 'SBI');
      expect(h.repo.options.categories, contains('Groceries'));
      // The server learned them from the expense too.
      expect(h.backend.pickList(h.user.id, 'categories'), ['Groceries']);
    });

    testWidgets('the account\'s own options from the server show up as chips', (t) async {
      final options = OptionsStore.memory();
      final h = await Harness.create(options: options);
      await options.mergeFromServer(sources: ['HDFC']);
      await pumpApp(t, h, tall: true);
      await t.tap(find.byType(FloatingActionButton));
      await t.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, 'HDFC'), findsOneWidget);
      expect(t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'HDFC')).selected, isFalse);
      expect(t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Direct')).selected, isTrue);
    });

    testWidgets('hold a chip to remove an unused option; used ones are kept', (t) async {
      final h = await Harness.create();
      await seedLocal(h);
      await h.repo.options.add(OptionKind.source, 'OldBank');
      await pumpApp(t, h, tall: true);
      await t.tap(find.byType(FloatingActionButton));
      await t.pumpAndSettle();

      await t.longPress(find.widgetWithText(ChoiceChip, 'OldBank'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(TextButton, 'Remove'));
      await t.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, 'OldBank'), findsNothing);

      await t.longPress(find.widgetWithText(ChoiceChip, 'Other')); // used by every expense
      await t.pumpAndSettle();
      expect(find.textContaining('Can’t remove'), findsOneWidget);

      await t.longPress(find.widgetWithText(ChoiceChip, 'Direct'));
      await t.pumpAndSettle();
      expect(find.textContaining('default mode'), findsOneWidget);
    });
  });
}
