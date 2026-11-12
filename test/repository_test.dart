import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/services/api_service.dart';
import 'package:expense_tracker/services/expense_repository.dart';
import 'package:expense_tracker/services/options_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

Expense _synced(Harness h, String id, int serverId,
        {String title = 'Lunch',
        double amount = 12,
        String category = 'Food',
        DateTime? date}) =>
    Expense(
      id: id,
      title: title,
      amount: amount,
      category: category,
      date: date ?? DateTime.parse('2026-10-01T12:00:00+05:30').toLocal(),
      synced: true,
      remoteId: '$serverId',
    );

/// A repository whose server gives the answers [handler] decides.
ExpenseRepository _repoWith(Harness h, Future<http.Response> Function(http.Request) handler) =>
    ExpenseRepository(
      db: h.db,
      api: ApiService(session: h.session, client: MockClient(handler)),
      sync: h.sync,
      pushGap: Duration.zero,
    );

void main() {
  group('saving and pushing (Auto and Manual)', () {
    test('saving alone never calls the server', () async {
      final h = await Harness.create();
      await h.repo.add(title: 'Chai', amount: 20, category: 'Food', date: DateTime(2026, 11, 9));
      expect(h.backend.calls, isEmpty);
      expect(h.repo.expenses.single.synced, isFalse);
    });

    test('Auto: pushed right after saving, and linked to the server\'s id', () async {
      final h = await Harness.create(autoSync: true);
      final e = await h.repo.add(title: 'Chai', amount: 20, category: 'Food', date: DateTime(2026, 11, 9));

      final r = await h.repo.autoPush(e);

      expect(r!.ok, isTrue);
      final saved = h.db.rows[e.id]!;
      expect(saved.synced, isTrue);
      expect(saved.remoteId, h.backend.ids(h.user.id).single.toString());
      expect(h.backend.count(h.user.id), 1);
    });

    test('Manual: nothing is pushed until you push', () async {
      final h = await Harness.create(autoSync: false);
      final e = await h.repo.add(title: 'Chai', amount: 20, category: 'Food', date: DateTime(2026, 11, 9));

      expect(await h.repo.autoPush(e), isNull);
      expect(h.backend.calls, isEmpty);
      expect(h.db.rows[e.id]!.synced, isFalse);

      expect((await h.repo.push(e)).ok, isTrue); // the manual push works
      expect(h.backend.count(h.user.id), 1);
    });

    test('signed out: nothing is attempted', () async {
      final h = await Harness.create(signedIn: false);
      final e = await h.repo.add(title: 'Chai', amount: 20, category: 'Food', date: DateTime(2026, 11, 9));
      expect(await h.repo.autoPush(e), isNull);
      expect(h.backend.calls, isEmpty);
    });

    test('offline: it stays on the phone, and goes up later', () async {
      final h = await Harness.create();
      final e = await h.repo.add(title: 'Chai', amount: 20, category: 'Food', date: DateTime(2026, 11, 9));
      h.backend.offline = true;

      final r = await h.repo.autoPush(e);
      expect(r!.status, PushStatus.offline);
      expect(h.db.rows[e.id]!.synced, isFalse);

      h.backend.offline = false;
      expect((await h.repo.push(e)).ok, isTrue);
      expect(h.backend.count(h.user.id), 1); // once, not twice
    });

    test('the server refusing it shows its reason and keeps the expense', () async {
      final h = await Harness.create();
      final e = await h.repo.add(title: 'Chai', amount: 20, category: 'Food', date: DateTime(2026, 11, 9));
      h.backend.failNextWith = 400;
      final r = await h.repo.push(e);
      expect(r.status, PushStatus.rejected);
      expect(r.message, 'Server: Server trouble');
      expect(h.db.rows[e.id]!.synced, isFalse);
    });

    test('an expired session: signed out, nothing lost', () async {
      final h = await Harness.create();
      final e = await h.repo.add(title: 'Chai', amount: 20, category: 'Food', date: DateTime(2026, 11, 9));
      h.backend.expireAllTokens();

      final r = await h.repo.push(e);

      expect(r.status, PushStatus.signedOut);
      expect(r.message, contains('Sign in again'));
      expect(h.session.isSignedIn, isFalse);
      expect(h.db.rows[e.id]!.title, 'Chai'); // still on the phone
    });

    test('editing an uploaded expense updates the same one on the server', () async {
      final h = await Harness.create();
      final e = await h.repo.add(title: 'Chai', amount: 20, category: 'Food', date: DateTime(2026, 11, 9));
      await h.repo.push(e);
      final id = h.backend.ids(h.user.id).single;

      final edited = await h.repo.update(h.db.rows[e.id]!.copyWith(title: 'Tea', amount: 25));
      expect(edited.synced, isFalse); // the server's copy is stale now
      await h.repo.autoPush(edited);

      expect(h.backend.count(h.user.id), 1); // not a second one
      expect(h.backend.row(h.user.id, id)!['title'], 'Tea');
      expect(h.backend.row(h.user.id, id)!['amount'], 25);
      expect(h.db.rows[e.id]!.synced, isTrue);
    });

    test('bulk push: one call each, and one failure does not stop the rest', () async {
      final h = await Harness.create(autoSync: false);
      final a = await h.repo.add(title: 'A', amount: 1, category: 'Food', date: DateTime(2026, 11, 1));
      final b = await h.repo.add(title: 'B', amount: 2, category: 'Food', date: DateTime(2026, 11, 2));
      final c = await h.repo.add(title: 'C', amount: 3, category: 'Food', date: DateTime(2026, 11, 3));
      var n = 0;
      final repo = _repoWith(h, (r) async {
        n++;
        if (n == 2) return http.Response('{"error":"busy"}', 503); // B fails
        return h.backend.client.send(http.Request(r.method, r.url)
          ..headers.addAll(r.headers)
          ..body = r.body).then(http.Response.fromStream);
      });

      final s = await repo.pushMany([a, b, c]);

      expect(s.uploaded, 2);
      expect(s.failed, 1);
      expect(h.backend.count(h.user.id), 2);
    });

    test('bulk push stops when the session has ended', () async {
      final h = await Harness.create(autoSync: false);
      final all = [
        for (var i = 0; i < 3; i++)
          await h.repo.add(title: 'E$i', amount: 1, category: 'Food', date: DateTime(2026, 11, 1 + i))
      ];
      h.backend.expireAllTokens();
      final s = await h.repo.pushMany(all);
      expect(s.uploaded, 0);
      expect(h.backend.calls.length, 1); // it did not keep knocking
    });
  });

  group('deleting', () {
    Future<Expense> uploaded(Harness h) async {
      final e = await h.repo.add(title: 'Gone soon', amount: 5, category: 'Food', date: DateTime(2026, 11, 1));
      await h.repo.push(e);
      return h.db.rows[e.id]!;
    }

    test('Auto: removed here and on the server right away', () async {
      final h = await Harness.create();
      final e = await uploaded(h);
      final r = await h.repo.deleteExpenses([e]);
      expect(h.db.rows, isEmpty);
      expect(h.backend.count(h.user.id), 0);
      expect(r.removed, 1);
      expect(r.archived, 1);
      expect(r.queued, 0);
    });

    test('Manual: the server is not told until Apply', () async {
      final h = await Harness.create(autoSync: false);
      final e = await uploaded(h);
      h.backend.calls.clear();

      final r = await h.repo.deleteExpenses([e]);
      expect(h.backend.calls, isEmpty);
      expect(h.backend.count(h.user.id), 1);
      expect(r.queued, 1);
      expect(h.repo.pendingDeletes, 1);

      expect(await h.repo.applyPendingDeletes(), 1);
      expect(h.backend.count(h.user.id), 0);
      expect(h.repo.pendingDeletes, 0);
    });

    test('an expense that was never uploaded is only removed here', () async {
      final h = await Harness.create();
      final e = await h.repo.add(title: 'Local', amount: 1, category: 'Food', date: DateTime(2026, 11, 1));
      final r = await h.repo.deleteExpenses([e]);
      expect(h.backend.calls, isEmpty);
      expect(r.archived, 0);
      expect(h.db.tombstones, isEmpty);
    });

    test('offline: it waits, and is deleted later', () async {
      final h = await Harness.create();
      final e = await uploaded(h);
      h.backend.offline = true;
      final r = await h.repo.deleteExpenses([e]);
      expect(r.queued, 1);
      expect(h.backend.count(h.user.id), 1);

      h.backend.offline = false;
      expect(await h.repo.applyPendingDeletes(), 1);
      expect(h.backend.count(h.user.id), 0);
    });

    test('one already deleted on the server is not a problem', () async {
      final h = await Harness.create();
      final e = await uploaded(h);
      h.backend.removeExpense(h.user.id, int.parse(e.remoteId!)); // the website did it
      final r = await h.repo.deleteExpenses([e]);
      expect(r.archived, 1);
      expect(h.db.tombstones, isEmpty);
    });

    test('a waiting deletion is finished by the next successful upload', () async {
      final h = await Harness.create();
      final e = await uploaded(h);
      h.backend.offline = true;
      await h.repo.deleteExpenses([e]);
      h.backend.offline = false;

      final next = await h.repo.add(title: 'Next', amount: 1, category: 'Food', date: DateTime(2026, 11, 2));
      await h.repo.autoPush(next);

      expect(h.repo.pendingDeletes, 0);
      expect(h.backend.count(h.user.id), 1); // only the new one is left
    });
  });

  group('Sync from server: the phone matches the server', () {
    test('new expenses from the website come in', () async {
      final h = await Harness.create();
      h.backend.addExpense(h.user.id, title: 'From the website', amount: 30);
      final r = await h.repo.refreshFromServer();
      expect(r.added, 1);
      expect(r.total, 1);
      expect(h.repo.expenses.single.title, 'From the website');
      expect(h.repo.expenses.single.synced, isTrue);
    });

    test('an edit made on the website is copied (every field), same expense', () async {
      final h = await Harness.create();
      final id = h.backend.addExpense(h.user.id);
      await h.repo.refreshFromServer();
      final localId = h.repo.expenses.single.id;

      h.backend.editExpense(h.user.id, id, {
        'title': 'Dinner out',
        'amount': 450,
        'categories': ['Bills', 'Food'],
        'sources': ['HDFC'],
        'mode': 'GPay',
        'comment': 'with the team',
        'date': '2026-10-02T20:15:00+05:30',
        'processed': true,
      });
      final r = await h.repo.refreshFromServer();

      final e = h.db.rows[localId]!; // the same expense, not a new one
      expect(r.updated, 1);
      expect(e.title, 'Dinner out');
      expect(e.amount, 450);
      expect(e.category, 'Bills, Food');
      expect(e.source, 'HDFC');
      expect(e.mode, 'GPay');
      expect(e.note, 'with the team');
      expect(e.processed, isTrue);
      expect(e.synced, isTrue);
      expect(h.db.rows.length, 1);
    });

    test('nothing changed: nothing is "updated" (seconds are ignored)', () async {
      final h = await Harness.create();
      final id = h.backend.addExpense(h.user.id, date: '2026-10-01T12:00:00+05:30');
      await h.repo.refreshFromServer();
      h.backend.editExpense(h.user.id, id, {'date': '2026-10-01T12:00:41+05:30'});
      final r = await h.repo.refreshFromServer();
      expect(r.updated, 0);
      expect(r.known, 1);
    });

    test('an expense edited on the phone and not pushed is never overwritten', () async {
      final h = await Harness.create();
      final id = h.backend.addExpense(h.user.id, title: 'Server title');
      h.db.rows['a'] = _synced(h, 'a', id, title: 'My edit').copyWith(synced: false);
      await h.repo.reload();
      h.backend.editExpense(h.user.id, id, {'processed': true});

      final r = await h.repo.refreshFromServer();

      expect(h.db.rows['a']!.title, 'My edit');
      expect(h.db.rows['a']!.synced, isFalse);
      expect(r.updated, 0);
      expect(h.db.rows['a']!.processed, isTrue); // only the server-owned flag moves
    });

    test('only this account\'s expenses ever arrive', () async {
      final h = await Harness.create();
      final other = h.backend.addAccount(email: 'other@example.com');
      h.backend.addExpense(other.id, title: 'Someone else');
      await h.repo.refreshFromServer();
      expect(h.repo.expenses, isEmpty);
    });

    test('an expense whose deletion is waiting does not come back', () async {
      final h = await Harness.create(autoSync: false);
      final id = h.backend.addExpense(h.user.id);
      await h.repo.refreshFromServer();
      await h.repo.deleteExpenses(h.repo.expenses); // Manual: the server still has it
      await h.repo.refreshFromServer();
      expect(h.repo.expenses, isEmpty);
      expect(h.backend.count(h.user.id), 1);
      expect(h.backend.ids(h.user.id), [id]);
    });

    test('the account\'s own categories, modes and sources are offered afterwards',
        () async {
      final options = OptionsStore.memory();
      final h = await Harness.create(options: options);
      h.backend.addExpense(h.user.id,
          categories: ['Groceries'], sources: ['SBI Card'], mode: 'Cash');
      await h.repo.refreshFromServer();
      // (the fake server registers them as the expense is created)
      await h.repo.api.addOption('categories', 'Gym');
      await h.repo.refreshFromServer();
      expect(options.categories, contains('Gym'));
      expect(options.categories, containsAll(['Food', 'Other'])); // built-ins stay
    });

    group('deleted on the server', () {
      late Harness h;
      late int keptId, goneId;
      setUp(() async {
        h = await Harness.create();
        keptId = h.backend.addExpense(h.user.id, title: 'Kept');
        goneId = h.backend.addExpense(h.user.id, title: 'Deleted on the website');
        await h.repo.refreshFromServer();
        h.db.rows['never'] = h.local('never', title: 'Never uploaded');
        final editedId = h.backend.addExpense(h.user.id, title: 'Edited here');
        await h.repo.refreshFromServer();
        final e = h.db.rows.values.firstWhere((x) => x.remoteId == '$editedId');
        h.db.rows[e.id] = e.copyWith(synced: false); // edited since its upload
        h.backend.removeExpense(h.user.id, editedId); // and then deleted on the website
        h.backend.removeExpense(h.user.id, goneId);
        await h.repo.reload();
      });

      Expense byServerId(int id) => h.db.rows.values.firstWhere((e) => e.remoteId == '$id');

      test('it asks first, naming only the uploaded-and-unchanged ones', () async {
        List<Expense>? asked;
        await h.repo.refreshFromServer(confirmRemoval: (m) async {
          asked = m;
          return false;
        });
        expect(asked!.map((e) => e.title), ['Deleted on the website']);
      });

      test('confirmed: removed; unpushed work stays', () async {
        final r = await h.repo.refreshFromServer(confirmRemoval: (_) async => true);
        expect(r.removed, 1);
        expect(h.db.rows.values.map((e) => e.title),
            containsAll(['Kept', 'Never uploaded', 'Edited here']));
        expect(h.db.rows.values.map((e) => e.title), isNot(contains('Deleted on the website')));
        expect(byServerId(keptId).synced, isTrue);
      });

      test('declined: kept, but no longer claims to be uploaded', () async {
        final r = await h.repo.refreshFromServer(confirmRemoval: (_) async => false);
        expect(r.removed, 0);
        expect(r.missing, 1);
        final e = h.db.rows.values.firstWhere((x) => x.title == 'Deleted on the website');
        expect(e.synced, isFalse);
        expect(e.remoteId, isNull);
        // ...so it can go up again as a new expense.
        expect((await h.repo.push(e)).ok, isTrue);
        expect(h.backend.calls.last.method, 'POST');
      });

      test('with no way to ask, nothing is removed or changed', () async {
        final r = await h.repo.refreshFromServer();
        expect(r.removed, 0);
        final e = h.db.rows.values.firstWhere((x) => x.title == 'Deleted on the website');
        expect(e.synced, isTrue);
        expect(e.remoteId, '$goneId');
      });
    });

    test('an empty server answer never removes anything (but they are not "uploaded")',
        () async {
      final h = await Harness.create();
      final a = h.backend.addExpense(h.user.id);
      final b = h.backend.addExpense(h.user.id);
      await h.repo.refreshFromServer();
      h.backend.removeExpense(h.user.id, a);
      h.backend.removeExpense(h.user.id, b);
      var asked = false;

      final r = await h.repo.refreshFromServer(confirmRemoval: (_) async {
        asked = true;
        return true;
      });

      expect(asked, isFalse);
      expect(r.removed, 0);
      expect(h.db.rows.length, 2);
      expect(h.repo.expenses.every((e) => !e.synced && e.remoteId == null), isTrue);
    });

    group('when the server cannot be read, nothing is touched', () {
      Future<void> check(Harness h, void Function() breakIt, String expectInError) async {
        final id = h.backend.addExpense(h.user.id);
        await h.repo.refreshFromServer();
        h.backend.removeExpense(h.user.id, id); // would be "missing" on a good read
        breakIt();
        final r = await h.repo.refreshFromServer(confirmRemoval: (_) async => true);
        expect(r.error, contains(expectInError));
        expect(h.db.rows.length, 1);
        expect(h.db.rows.values.single.synced, isTrue);
        expect(h.repo.importing, isFalse);
      }

      test('offline', () async {
        final h = await Harness.create();
        await check(h, () => h.backend.offline = true, 'No connection');
      });

      test('busy server', () async {
        final h = await Harness.create();
        await check(h, () => h.backend.failNextWith = 503, 'No connection');
      });

      test('session expired', () async {
        final h = await Harness.create();
        await check(h, h.backend.expireAllTokens, 'Sign in again');
        expect(h.session.isSignedIn, isFalse);
      });

      test('a reply it cannot read still ends in a message', () async {
        final h = await Harness.create();
        final id = h.backend.addExpense(h.user.id);
        await h.repo.refreshFromServer();
        h.backend.removeExpense(h.user.id, id);
        final repo = _repoWith(h, (r) async => http.Response('<html>login page</html>', 200));
        final r = await repo.refreshFromServer(confirmRemoval: (_) async => true);
        expect(r.error, contains('Could not read the expenses'));
        expect(h.db.rows.length, 1);
        expect(repo.importing, isFalse);
      });

      test('a reply of the wrong shape', () async {
        final h = await Harness.create();
        final repo = _repoWith(h, (r) async => http.Response('{"unexpected": true}', 200));
        final r = await repo.refreshFromServer();
        expect(r.error, contains('Could not read the expenses'));
      });
    });
  });

  group('whose expenses are on the phone', () {
    test('wiping removes expenses, waiting deletions and custom pick-lists', () async {
      final options = OptionsStore.memory();
      final h = await Harness.create(options: options);
      await h.repo.add(title: 'A', amount: 1, category: 'Food', date: DateTime(2026, 11, 1));
      h.db.tombstones.add('77');
      await options.add(OptionKind.mode, 'Mine');
      await h.repo.reload();

      await h.repo.wipeLocal();

      expect(h.repo.expenses, isEmpty);
      expect(h.repo.pendingDeletes, 0);
      expect(options.modes, ['Direct']);
    });
  });
}
