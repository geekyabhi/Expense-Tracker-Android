import 'dart:convert';

import 'package:expense_tracker/config/app_config.dart';
import 'package:expense_tracker/services/account_controller.dart';
import 'package:expense_tracker/services/auth_api.dart';
import 'package:expense_tracker/services/google_auth.dart';
import 'package:expense_tracker/services/options_store.dart';
import 'package:expense_tracker/services/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

void main() {
  group('Session', () {
    test('server addresses are tidied up', () {
      expect(Session.normalizeServerUrl('https://a.example.com/'), 'https://a.example.com');
      expect(Session.normalizeServerUrl('  a.example.com///'), 'https://a.example.com');
      expect(Session.normalizeServerUrl('http://10.0.0.5:8000/'), 'http://10.0.0.5:8000');
      expect(Session.normalizeServerUrl(''), kDefaultServerUrl);
    });

    test('the default server is the real backend', () {
      expect(kDefaultServerUrl, 'https://personal.singhabhinav.in');
      expect(kGoogleWebClientId, endsWith('.apps.googleusercontent.com'));
    });

    test('signing in is remembered across launches', () async {
      final storage = MemorySessionStorage();
      final a = Session(storage: storage);
      await a.signIn(
        serverUrl: 'https://s.test/',
        token: 'tok-1',
        user: const AppUser(id: 'u1', email: 'a@b.co', name: 'Ann'),
        expiresAt: DateTime(2099),
      );
      await a.setOwner('u1');

      final b = Session(storage: storage);
      await b.load();
      expect(b.isSignedIn, isTrue);
      expect(b.token, 'tok-1');
      expect(b.user!.email, 'a@b.co');
      expect(b.serverUrl, 'https://s.test');
      expect(b.ownerId, 'u1');
    });

    test('an expired token is not usable, and the login screen says why', () async {
      var now = DateTime(2026, 1, 1);
      final storage = MemorySessionStorage();
      final s = Session(storage: storage, clock: () => now);
      await s.signIn(
          serverUrl: 'https://s.test',
          token: 't',
          user: const AppUser(id: 'u'),
          expiresAt: DateTime(2026, 1, 31));
      expect(s.isSignedIn, isTrue);

      now = DateTime(2026, 1, 30);
      expect(s.token, 't');
      now = DateTime(2026, 2, 1);
      expect(s.isSignedIn, isFalse);
      expect(s.token, isNull);

      final later = Session(storage: storage, clock: () => now);
      await later.load();
      expect(later.isSignedIn, isFalse);
      expect(later.notice, contains('expired'));
    });

    test('signing out keeps the server and whose expenses are on the phone', () async {
      final storage = MemorySessionStorage();
      final s = Session(storage: storage);
      await s.signIn(serverUrl: 'https://s.test', token: 't', user: const AppUser(id: 'u'));
      await s.setOwner('u');
      await s.signOut();
      expect(s.isSignedIn, isFalse);
      expect(storage.snapshot.token, isNull);
      expect(storage.snapshot.user, isNull);
      expect(storage.snapshot.ownerId, 'u');
      expect(storage.snapshot.serverUrl, 'https://s.test');
    });

    test('expire() tells listeners, leaves a note, and forgets the token', () async {
      final storage = MemorySessionStorage();
      final s = Session(storage: storage);
      await s.signIn(serverUrl: 'https://s.test', token: 't', user: const AppUser(id: 'u'));
      var heard = 0;
      s.addListener(() => heard++);
      s.expire();
      expect(heard, 1);
      expect(s.isSignedIn, isFalse);
      expect(s.notice, contains('expired'));
      await pumpEventQueue();
      expect(storage.snapshot.token, isNull);
    });
  });

  group('AuthApi', () {
    late FakeBackend be;
    late AuthApi api;
    setUp(() {
      be = FakeBackend();
      api = AuthApi(client: be.client);
    });

    test('email + password', () async {
      final a = be.addAccount(email: 'me@example.com');
      final r = await api.login(FakeBackend.base, ' ME@example.com ', 'secret-pass-1');
      expect(r.user.id, a.id);
      expect(r.token, isNotEmpty);
      expect(r.expiresAt, isNotNull);
      final req = be.callsTo('/login/').single;
      expect(req.url.toString(), 'https://server.test/api/users/login/');
      expect(jsonDecode(req.body), {'identifier': 'ME@example.com', 'password': 'secret-pass-1'});
    });

    test('phone + password, typed the way people type it', () async {
      final a = be.addAccount(phone: '+919876543210');
      final r = await api.login(FakeBackend.base, '98765 43210', 'secret-pass-1');
      expect(r.user.id, a.id);
      expect(r.user.phone, '+919876543210');
    });

    test('a wrong password shows the server\'s message', () async {
      be.addAccount(email: 'me@example.com');
      await expectLater(
        api.login(FakeBackend.base, 'me@example.com', 'nope'),
        throwsA(isA<AuthException>()
            .having((e) => e.message, 'message', 'Invalid email/phone or password')
            .having((e) => e.status, 'status', 401)),
      );
    });

    test('sign up with an email, or with a phone', () async {
      final e = await api.signup(FakeBackend.base,
          identifier: 'new@example.com', password: 'secret-pass-1', name: ' Ann ');
      expect(jsonDecode(be.callsTo('/signup/').first.body),
          {'name': 'Ann', 'email': 'new@example.com', 'password': 'secret-pass-1'});
      expect(e.user.email, 'new@example.com');

      final p = await api.signup(FakeBackend.base,
          identifier: '+91 98765 43210', password: 'secret-pass-1');
      expect(jsonDecode(be.callsTo('/signup/').last.body).containsKey('email'), isFalse);
      expect(p.user.phone, '+919876543210');
    });

    test('sign up problems are explained', () async {
      be.addAccount(email: 'taken@example.com');
      await expectLater(
          api.signup(FakeBackend.base, identifier: 'taken@example.com', password: 'secret-pass-1'),
          throwsA(isA<AuthException>().having((e) => e.status, 'status', 409)));
      await expectLater(
          api.signup(FakeBackend.base, identifier: 'x@example.com', password: 'short'),
          throwsA(isA<AuthException>()
              .having((e) => e.message, 'message', contains('Password must be'))));
    });

    test('Google: the ID token is sent, the same response comes back', () async {
      final r = await api.google(FakeBackend.base, be.googleToken());
      expect(r.user.email, 'me@example.com');
      expect(r.user.googleConnected, isTrue);
      expect(jsonDecode(be.callsTo('/google/').single.body).keys, ['id_token']);
    });

    test('Google: a refused token', () async {
      await expectLater(api.google(FakeBackend.base, 'garbage'),
          throwsA(isA<AuthException>().having((e) => e.status, 'status', 401)));
    });

    test('me() and logout()', () async {
      final a = be.addAccount(email: 'me@example.com');
      final r = await api.login(FakeBackend.base, 'me@example.com', 'secret-pass-1');
      expect((await api.me(FakeBackend.base, r.token)).id, a.id);
      expect(be.callsTo('/me/').single.headers['Authorization'], 'Bearer ${r.token}');

      await api.logout(FakeBackend.base, r.token);
      expect(be.tokens.containsKey(r.token), isFalse);
      await expectLater(api.me(FakeBackend.base, r.token),
          throwsA(isA<AuthException>().having((e) => e.status, 'status', 401)));
    });

    test('logout everywhere revokes every token', () async {
      be.addAccount(email: 'me@example.com');
      final one = await api.login(FakeBackend.base, 'me@example.com', 'secret-pass-1');
      final two = await api.login(FakeBackend.base, 'me@example.com', 'secret-pass-1');
      await api.logout(FakeBackend.base, one.token, all: true);
      expect(be.tokens.containsKey(two.token), isFalse);
    });

    test('server unreachable', () async {
      be.offline = true;
      await expectLater(
          api.login(FakeBackend.base, 'a@b.co', 'secret-pass-1'),
          throwsA(isA<AuthException>()
              .having((e) => e.status, 'status', 0)
              .having((e) => e.message, 'message', contains('Could not reach the server'))));
    });

    test('a wrong server address (a web page, not the API) is explained', () async {
      final wrong = AuthApi(client: MockClient((r) async => http.Response('<html>Not Found</html>', 404)));
      await expectLater(wrong.login('https://nope.test', 'a@b.co', 'secret-pass-1'),
          throwsA(isA<AuthException>().having((e) => e.message, 'message', contains('server address'))));
      final broken = AuthApi(client: MockClient((r) async => http.Response('oops', 502)));
      await expectLater(broken.login('https://nope.test', 'a@b.co', 'secret-pass-1'),
          throwsA(isA<AuthException>().having((e) => e.message, 'message', contains('server had a problem'))));
    });

    test('a server address without https:// still works', () async {
      be.addAccount(email: 'me@example.com');
      final r = await api.login('server.test/', 'me@example.com', 'secret-pass-1');
      expect(r.token, isNotEmpty);
    });
  });

  group('AccountController: every way in opens the same account', () {
    test('email, phone and Google all land in one account with one set of expenses',
        () async {
      final be = FakeBackend();
      final person = be.addAccount(email: 'me@example.com', phone: '+919876543210')
        ..emailVerified = true;
      be.addExpense(person.id, title: 'Chai');
      final h = await Harness.create(signedIn: false, backend: be);
      h.google.token = be.googleToken(email: 'me@example.com');

      final ids = <String>[];
      for (final signIn in [
        () => h.account.signInWithPassword(FakeBackend.base, 'me@example.com', 'secret-pass-1'),
        () => h.account.signInWithPassword(FakeBackend.base, '9876543210', 'secret-pass-1'),
        () => h.account.signInWithGoogle(FakeBackend.base),
      ]) {
        final out = await signIn();
        expect(out.ok, isTrue, reason: out.error);
        ids.add(h.session.user!.id);
        await pumpEventQueue();
        expect(h.repo.expenses.map((e) => e.title), ['Chai']); // same expenses each time
        await h.session.signOut();
      }
      expect(ids.toSet(), {person.id}); // one account, three doors
      expect(be.accounts.length, 1);
    });

    test('Google on a new Google account creates it; signing in again reuses it', () async {
      final h = await Harness.create(signedIn: false);
      h.google.token = h.backend.googleToken(sub: 'g-7', email: 'new@example.com');
      expect((await h.account.signInWithGoogle(FakeBackend.base)).ok, isTrue);
      final first = h.session.user!.id;
      await h.session.signOut();
      expect((await h.account.signInWithGoogle(FakeBackend.base)).ok, isTrue);
      expect(h.session.user!.id, first);
      expect(h.backend.accounts.length, 1);
    });

    test('an unverified email + password account is taken over by Google (the website rule)',
        () async {
      final be = FakeBackend();
      final acct = be.addAccount(email: 'me@example.com'); // typed in, never verified
      final h = await Harness.create(signedIn: false, backend: be);
      h.google.token = be.googleToken(email: 'me@example.com');

      final out = await h.account.signInWithGoogle(FakeBackend.base);

      expect(out.ok, isTrue);
      expect(out.passwordReset, isTrue); // the app can tell the person
      expect(h.session.user!.id, acct.id); // still the same account
      await h.session.signOut();
      final again = await h.account.signInWithPassword(
          FakeBackend.base, 'me@example.com', 'secret-pass-1');
      expect(again.error, 'Invalid email/phone or password'); // that password is gone
    });
  });

  group('AccountController: the phone holds one account\'s expenses', () {
    test('the first sign-in removes what was on the phone, then loads the account\'s',
        () async {
      final be = FakeBackend();
      final acct = be.addAccount(email: 'me@example.com');
      be.addExpense(acct.id, title: 'From the server');
      final options = OptionsStore.memory();
      await options.add(OptionKind.category, 'Old custom');
      final h = await Harness.create(signedIn: false, backend: be, options: options);
      // Left over from before there was any server (and not even uploaded).
      await h.repo.add(title: 'Old Notion one', amount: 1, category: 'Food', date: DateTime(2026, 5, 1));
      await h.db.insert(h.local('x'));
      expect(h.db.rows.length, 2);

      final out = await h.account.signInWithPassword(FakeBackend.base, 'me@example.com', 'secret-pass-1');
      await pumpEventQueue();

      expect(out.ok, isTrue);
      expect(h.repo.expenses.map((e) => e.title), ['From the server']);
      expect(options.categories, isNot(contains('Old custom'))); // pick-lists reset
      expect(h.session.ownerId, acct.id);
    });

    test('a failed sign-in never touches the phone\'s expenses', () async {
      final be = FakeBackend()..addAccount(email: 'me@example.com');
      final h = await Harness.create(signedIn: false, backend: be);
      await h.db.insert(h.local('keep'));

      final wrong = await h.account.signInWithPassword(FakeBackend.base, 'me@example.com', 'wrong');
      expect(wrong.ok, isFalse);
      be.offline = true;
      final off = await h.account.signInWithPassword(FakeBackend.base, 'me@example.com', 'secret-pass-1');
      expect(off.error, contains('Could not reach the server'));

      expect(h.db.rows.containsKey('keep'), isTrue);
      expect(h.session.isSignedIn, isFalse);
    });

    test('signing back in as the same account keeps what was not uploaded', () async {
      final h = await Harness.create();
      await h.repo.add(title: 'Not uploaded yet', amount: 9, category: 'Food', date: DateTime(2026, 10, 1));
      await h.account.signOut();

      final out = await h.account.signInWithPassword(FakeBackend.base, 'user@example.com', 'secret-pass-1');
      await pumpEventQueue();

      expect(out.ok, isTrue);
      expect(h.repo.expenses.map((e) => e.title), contains('Not uploaded yet'));
    });

    test('a different account starts clean', () async {
      final be = FakeBackend();
      final a = be.addAccount(email: 'a@example.com');
      final b = be.addAccount(email: 'b@example.com');
      be.addExpense(a.id, title: 'A secret');
      be.addExpense(b.id, title: 'B expense');
      final h = await Harness.create(backend: be); // signs in as the first account (a)
      await h.repo.refreshFromServer();
      await h.repo.add(title: 'A local only', amount: 1, category: 'Food', date: DateTime(2026, 10, 1));
      expect(h.repo.expenses.map((e) => e.title), containsAll(['A secret', 'A local only']));

      await h.account.signOut();
      await h.account.signInWithPassword(FakeBackend.base, 'b@example.com', 'secret-pass-1');
      await pumpEventQueue();

      expect(h.repo.expenses.map((e) => e.title), ['B expense']); // nothing of A's
      expect(h.session.ownerId, b.id);
    });
  });

  group('AccountController: Google problems', () {
    test('closing the Google dialog changes nothing', () async {
      final h = await Harness.create(signedIn: false);
      h.google.token = null;
      final out = await h.account.signInWithGoogle(FakeBackend.base);
      expect(out.cancelled, isTrue);
      expect(out.error, isNull);
      expect(h.backend.callsTo('/google/'), isEmpty);
    });

    test('Google failing on the phone is explained', () async {
      final h = await Harness.create(signedIn: false);
      h.google.failure = GoogleAuthFailure('Google sign-in failed (clientConfigurationError).');
      final out = await h.account.signInWithGoogle(FakeBackend.base);
      expect(out.error, contains('Google sign-in failed'));
      expect(h.session.isSignedIn, isFalse);
    });

    test('the server refusing the Google token is explained, nothing is wiped', () async {
      final h = await Harness.create(signedIn: false);
      await h.db.insert(h.local('keep'));
      h.google.token = 'a-token-the-server-does-not-know';
      final out = await h.account.signInWithGoogle(FakeBackend.base);
      expect(out.error, 'Invalid Google token');
      expect(h.db.rows.containsKey('keep'), isTrue);
    });

    test('a server that has no Google endpoint yet gets a clear message', () async {
      final h = await Harness.create(signedIn: false);
      h.google.token = 'x';
      final old = AccountController(
        session: h.session,
        auth: AuthApi(client: MockClient((r) async => http.Response('<h1>Not Found</h1>', 404))),
        repo: h.repo,
        google: h.google,
      );
      final out = await old.signInWithGoogle(FakeBackend.base);
      expect(out.ok, isFalse);
      // Not "check the server address": the server is fine, it just has no such door.
      expect(out.error, contains('does not support Google sign-in yet'));
      expect(out.error, isNot(contains('server address')));
    });
  });

  group('AccountController: signing out', () {
    test('this phone: the token is revoked, the expenses stay', () async {
      final h = await Harness.create();
      await h.repo.add(title: 'Mine', amount: 1, category: 'Food', date: DateTime(2026, 10, 1));
      final token = h.session.token!;

      final revoked = await h.account.signOut();

      expect(revoked, isTrue);
      expect(h.backend.tokens.containsKey(token), isFalse);
      expect(h.session.isSignedIn, isFalse);
      expect(h.google.signOuts, 1);
      expect(h.repo.expenses.length, 1);
    });

    test('all devices', () async {
      final h = await Harness.create();
      final other = await h.auth.login(FakeBackend.base, 'user@example.com', 'secret-pass-1');
      await h.account.signOut(everywhere: true);
      expect(h.backend.tokens.containsKey(other.token), isFalse);
      expect(jsonDecode(h.backend.callsTo('/logout/').single.body), {'all': true});
    });

    test('offline: this phone is signed out anyway, and the app says others are not',
        () async {
      final h = await Harness.create();
      h.backend.offline = true;
      final revoked = await h.account.signOut(everywhere: true);
      expect(revoked, isFalse);
      expect(h.session.isSignedIn, isFalse);
    });
  });

  group('AccountController: test connection', () {
    test('says who you are', () async {
      final h = await Harness.create();
      expect(await h.account.testConnection(), 'Connected as user@example.com (user@example.com).');
    });

    test('an expired session is reported and ends the session', () async {
      final h = await Harness.create();
      h.backend.expireAllTokens();
      expect(await h.account.testConnection(), contains('expired'));
      expect(h.session.isSignedIn, isFalse);
    });

    test('offline', () async {
      final h = await Harness.create();
      h.backend.offline = true;
      expect(await h.account.testConnection(), contains('Could not reach the server'));
      expect(h.session.isSignedIn, isTrue); // being offline is not being signed out
    });
  });
}
