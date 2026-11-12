import 'package:expense_tracker/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';
import 'ui_helpers.dart';

Finder _field(String label) => find
    .byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == label);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> submit(WidgetTester t, String who, String pass, {String button = 'Sign in'}) async {
    await t.enterText(_field('Email or phone'), who);
    await t.enterText(_field('Password'), pass);
    await t.tap(find.widgetWithText(FilledButton, button));
    await t.pumpAndSettle();
  }

  group('the front door', () {
    testWidgets('signed out: the login screen, not the expenses', (t) async {
      final h = await Harness.create(signedIn: false);
      await pumpApp(t, h, tall: true);
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
    });

    testWidgets('email + password signs in and lands on the expenses', (t) async {
      final h = await Harness.create(signedIn: false);
      h.backend.addAccount(email: 'me@example.com');
      await pumpApp(t, h, tall: true);
      await submit(t, 'me@example.com', 'secret-pass-1');
      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(h.session.isSignedIn, isTrue);
    });

    testWidgets('phone + password reaches the same account as the email', (t) async {
      final h = await Harness.create(signedIn: false);
      final a = h.backend.addAccount(email: 'me@example.com', phone: '+919876543210');
      await pumpApp(t, h, tall: true);
      await submit(t, '+91 98765 43210', 'secret-pass-1');
      expect(h.session.ownerId, a.id);
    });

    testWidgets('a wrong password shows the server\'s message and stays put', (t) async {
      final h = await Harness.create(signedIn: false);
      h.backend.addAccount(email: 'me@example.com');
      await pumpApp(t, h, tall: true);
      await submit(t, 'me@example.com', 'nope-nope-1');
      expect(find.textContaining('Invalid'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
    });

    testWidgets('creating an account signs in', (t) async {
      final h = await Harness.create(signedIn: false);
      await pumpApp(t, h, tall: true);
      await t.tap(find.text('Create account').first);
      await t.pumpAndSettle();
      await submit(t, 'new@example.com', 'brand-new-pass', button: 'Create account');
      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(h.backend.accounts.any((a) => a.email == 'new@example.com'), isTrue);
    });

    testWidgets('Google lands in the same account as email', (t) async {
      final h = await Harness.create(signedIn: false);
      final a = h.backend.addAccount(email: 'me@example.com');
      a.emailVerified = true;
      h.google.token = h.backend.googleToken(email: 'me@example.com');
      await pumpApp(t, h, tall: true);
      await t.tap(find.text('Continue with Google'));
      await t.pumpAndSettle();
      expect(h.session.ownerId, a.id);
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });

    testWidgets('closing the Google dialog is quiet', (t) async {
      final h = await Harness.create(signedIn: false);
      h.google.token = null;
      await pumpApp(t, h, tall: true);
      await t.tap(find.text('Continue with Google'));
      await t.pumpAndSettle();
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.textContaining('Invalid'), findsNothing);
    });
  });

  group('while signed in', () {
    testWidgets('an expired session returns to login, keeps the data, and says why',
        (t) async {
      final h = await Harness.create();
      h.db.rows['a'] = h.local('a', title: 'Lunch', amount: 5, date: DateTime(2026, 10, 3));
      await h.repo.reload();
      await pumpApp(t, h);
      expect(find.text('Lunch'), findsOneWidget);

      h.backend.expireAllTokens();
      await t.tap(find.byTooltip('Sync from server'));
      await t.pumpAndSettle();

      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.textContaining('expired'), findsWidgets);
      expect(h.db.rows, isNotEmpty); // nothing is lost
    });

    Future<void> openAccount(WidgetTester t, Harness h) async {
      tallScreen(t);
      fakeAndroid(t);
      await t.pumpWidget(MaterialApp(
        key: UniqueKey(),
        home: SettingsScreen(account: h.account, repo: h.repo, events: noEvents()),
      ));
      await t.pumpAndSettle();
      await t.tap(find.text('Account & sync'));
      await t.pumpAndSettle();
    }

    testWidgets('sign-out warns about expenses not uploaded yet', (t) async {
      final h = await Harness.create(autoSync: false);
      h.db.rows['a'] = h.local('a', title: 'Lunch', amount: 5, date: DateTime(2026, 10, 3));
      await h.repo.reload();
      await openAccount(t, h);

      await t.tap(find.widgetWithText(ListTile, 'Sign out'));
      await t.pumpAndSettle();
      expect(find.textContaining('not uploaded'), findsOneWidget);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await t.pumpAndSettle();
      expect(h.session.isSignedIn, isTrue);

      await t.tap(find.widgetWithText(ListTile, 'Sign out'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(TextButton, 'Sign out'));
      await t.pumpAndSettle();
      expect(h.session.isSignedIn, isFalse);
      expect(h.db.rows, isNotEmpty); // kept for this account
    });

    testWidgets('Auto / Manual can be switched and is remembered', (t) async {
      final h = await Harness.create();
      await openAccount(t, h);
      await t.tap(find.text('Manual'));
      await t.pumpAndSettle();
      expect(h.sync.autoSync, isFalse);
    });
  });
}
