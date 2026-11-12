import 'dart:convert';

import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/services/account_controller.dart';
import 'package:expense_tracker/services/api_service.dart';
import 'package:expense_tracker/services/auth_api.dart';
import 'package:expense_tracker/services/expense_repository.dart';
import 'package:expense_tracker/services/google_auth.dart';
import 'package:expense_tracker/services/local_db.dart';
import 'package:expense_tracker/services/options_store.dart';
import 'package:expense_tracker/services/session.dart';
import 'package:expense_tracker/services/sync_settings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// In-memory stand-in for the sqflite database.
class FakeDb implements LocalDb {
  final Map<String, Expense> rows = {};
  final Set<String> tombstones = {};

  @override
  Future<void> insert(Expense e) async => rows[e.id] = e;

  @override
  Future<void> markSynced(String id, {String? remoteId}) async =>
      rows[id] = rows[id]!.copyWith(synced: true, remoteId: remoteId);

  @override
  Future<void> setProcessed(String id, bool processed) async =>
      rows[id] = rows[id]!.copyWith(processed: processed);

  @override
  Future<void> delete(String id) async => rows.remove(id);

  @override
  Future<void> clearAll() async {
    rows.clear();
    tombstones.clear();
  }

  @override
  Future<List<Expense>> all() async =>
      rows.values.toList()..sort((a, b) => b.date.compareTo(a.date));

  @override
  Future<List<Expense>> pending() async =>
      rows.values.where((e) => !e.synced).toList();

  @override
  Future<List<String>> pendingDeletes() async => tombstones.toList();

  @override
  Future<void> addPendingDelete(String remoteId) async =>
      tombstones.add(remoteId);

  @override
  Future<void> removePendingDelete(String remoteId) async =>
      tombstones.remove(remoteId);
}

class FakeAccount {
  FakeAccount(this.id, {this.email, this.phone, this.password, this.name = ''});
  final String id;
  String? email;
  String? phone;
  String? password; // null = no usable password (Google-only)
  String name;
  String? googleSub;
  bool emailVerified = false;

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'phone': phone,
        'name': name,
        'google_connected': googleSub != null,
      };
}

/// A small, stateful imitation of the backend (Personal Shortcut): accounts and
/// bearer tokens under /api/users/, and each account's own expenses and
/// pick-lists under /api/expenses/. Anything a test needs to do "on the
/// website" (add, edit, delete an expense; process one) has a helper.
class FakeBackend {
  static const base = 'https://server.test';

  final calls = <http.Request>[];
  bool offline = false;

  /// The next request of any kind gets this status and an error body.
  int? failNextWith;

  final accounts = <FakeAccount>[];
  final tokens = <String, String>{}; // token -> account id
  final googleIdTokens = <String, Map<String, dynamic>>{}; // id_token -> claims
  final _store = <String, Map<int, Map<String, dynamic>>>{};
  final _lists = <String, Map<String, List<String>>>{};
  int _nextId = 100, _nextUser = 1, _nextToken = 1;

  late final http.Client client = MockClient(_handle);

  // ------------------------------------------------------------ test helpers

  /// An account that signs in with [email] / [phone] and [password].
  FakeAccount addAccount({String? email, String? phone, String? password = 'secret-pass-1'}) {
    final a = FakeAccount('user-${_nextUser++}',
        email: email?.toLowerCase(), phone: phone, password: password)
      ..emailVerified = false;
    accounts.add(a);
    return a;
  }

  /// A Google ID token the fake Google "will accept".
  String googleToken({String sub = 'g-1', String email = 'me@example.com', bool verified = true, String name = 'Me'}) {
    final t = 'google-id-token-${googleIdTokens.length + 1}';
    googleIdTokens[t] = {'sub': sub, 'email': email, 'email_verified': verified, 'name': name};
    return t;
  }

  /// Makes every token invalid (the 30 days passed / revoked elsewhere).
  void expireAllTokens() => tokens.clear();

  /// An expense added "on the website" (or any other device).
  int addExpense(String accountId,
      {String title = 'Lunch',
      num amount = 12,
      String date = '2026-10-01T12:00:00+05:30',
      List<String> categories = const ['Food'],
      List<String> sources = const [],
      String mode = 'Direct',
      String comment = '',
      bool processed = false}) {
    final id = _nextId++;
    _rows(accountId)[id] = {
      'title': title,
      'amount': amount,
      'date': date,
      'categories': [...categories],
      'sources': [...sources],
      'mode': mode,
      'comment': comment,
      'processed': processed,
    };
    return id;
  }

  void editExpense(String accountId, int id, Map<String, dynamic> changes) =>
      _rows(accountId)[id]!.addAll(changes);

  void removeExpense(String accountId, int id) => _rows(accountId).remove(id);

  Map<String, dynamic>? row(String accountId, int id) => _rows(accountId)[id];
  int count(String accountId) => _rows(accountId).length;
  List<int> ids(String accountId) => _rows(accountId).keys.toList();

  List<String> pickList(String accountId, String kind) =>
      [...(_lists[accountId]?[kind] ?? const <String>[])];

  FakeAccount byId(String id) => accounts.firstWhere((a) => a.id == id);

  Iterable<http.Request> callsTo(String pathPart, [String? method]) => calls.where(
      (c) => c.url.path.contains(pathPart) && (method == null || c.method == method));

  // ------------------------------------------------------------------ routing

  Map<int, Map<String, dynamic>> _rows(String a) => _store.putIfAbsent(a, () => {});
  Map<String, List<String>> _list(String a) => _lists.putIfAbsent(
      a, () => {'categories': [], 'sources': [], 'modes': []});

  http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body), status,
      headers: {'content-type': 'application/json'});
  http.Response _error(String message, int status) => _json({'error': message}, status);

  Future<http.Response> _handle(http.Request r) async {
    calls.add(r);
    if (offline) throw http.ClientException('offline');
    if (failNextWith != null) {
      final code = failNextWith!;
      failNextWith = null;
      return _error('Server trouble', code);
    }
    final path = r.url.path;
    final Map<String, dynamic> body = r.body.isEmpty
        ? {}
        : (jsonDecode(r.body) as Map).cast<String, dynamic>();

    if (path.startsWith('/api/users/')) return _users(path.substring(11), r, body);
    if (path.startsWith('/api/expenses/')) return _expenses(path.substring(14), r, body);
    return http.Response('Not Found', 404);
  }

  // ------------------------------------------------------------------- users

  static String? _phone(Object? raw) {
    var d = '${raw ?? ''}'.replaceAll(RegExp(r'[\s\-().]'), '');
    if (d.isEmpty) return null;
    if (d.startsWith('00')) d = '+${d.substring(2)}';
    if (!d.startsWith('+') && d.length == 10) d = '+91$d';
    return RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(d) ? d : 'INVALID';
  }

  http.Response _tokenReply(FakeAccount a, {int status = 200, bool passwordReset = false}) {
    final token = 'token-${_nextToken++}';
    tokens[token] = a.id;
    return _json({
      'user': a.toJson(),
      'token': token,
      'token_type': 'Bearer',
      'expires_at': DateTime.utc(2099).toIso8601String(),
      if (passwordReset) 'password_reset': true,
    }, status);
  }

  FakeAccount? _accountOf(http.Request r) {
    final h = r.headers['Authorization'] ?? '';
    if (!h.startsWith('Bearer ')) return null;
    final id = tokens[h.substring(7).trim()];
    return id == null ? null : byId(id);
  }

  http.Response _users(String route, http.Request r, Map<String, dynamic> b) {
    switch (route) {
      case 'signup/':
        final email = '${b['email'] ?? ''}'.trim().toLowerCase();
        final phone = _phone(b['phone']);
        if (email.isEmpty && phone == null) return _error('Enter an email or a phone number', 400);
        if (phone == 'INVALID') return _error('Enter a valid phone number, e.g. +91 98765 43210', 400);
        final pw = b['password'];
        if (pw is! String || pw.length < 8 || pw.length > 128) {
          return _error('Password must be 8-128 characters', 400);
        }
        final taken = accounts.any((a) =>
            (email.isNotEmpty && a.email == email) || (phone != null && a.phone == phone));
        if (taken) return _error('An account with this email or phone already exists', 409);
        final a = FakeAccount('user-${_nextUser++}',
            email: email.isEmpty ? null : email, phone: phone, password: pw, name: '${b['name'] ?? ''}');
        accounts.add(a);
        return _tokenReply(a, status: 201);

      case 'login/':
        final ident = '${b['identifier'] ?? b['email'] ?? b['phone'] ?? ''}'.trim();
        final key = ident.contains('@') ? ident.toLowerCase() : _phone(ident);
        final a = accounts.where((x) => x.email == key || x.phone == key).firstOrNull;
        if (a == null || a.password == null || a.password != b['password']) {
          return _error('Invalid email/phone or password', 401);
        }
        return _tokenReply(a);

      case 'google/':
        final claims = googleIdTokens['${b['id_token'] ?? ''}'];
        if ('${b['id_token'] ?? ''}'.trim().isEmpty) return _error('id_token is required', 400);
        if (claims == null) return _error('Invalid Google token', 401);
        if (claims['email_verified'] != true) return _error('Your Google email is not verified', 403);
        final sub = claims['sub'] as String;
        final email = (claims['email'] as String).toLowerCase();
        var a = accounts.where((x) => x.googleSub == sub).firstOrNull;
        var reset = false;
        if (a == null) {
          a = accounts.where((x) => x.email == email).firstOrNull;
          if (a != null) {
            if (!a.emailVerified) {
              // The website's rule: an unverified email + password account is
              // taken over by its Google owner; the typed-in password is cut off.
              reset = a.password != null;
              a.password = null;
              tokens.removeWhere((_, id) => id == a!.id);
            }
            a.googleSub = sub;
            a.emailVerified = true;
          } else {
            a = FakeAccount('user-${_nextUser++}', email: email, name: '${claims['name'] ?? ''}')
              ..googleSub = sub
              ..emailVerified = true;
            accounts.add(a);
          }
        }
        return _tokenReply(a, passwordReset: reset);

      case 'me/':
        final a = _accountOf(r);
        if (a == null) return _error('Invalid or expired token', 401);
        return _json({'user': a.toJson()});

      case 'logout/':
        final a = _accountOf(r);
        if (a == null) return _error('Invalid or expired token', 401);
        if (b['all'] == true) {
          tokens.removeWhere((_, id) => id == a.id);
        } else {
          tokens.remove((r.headers['Authorization'] ?? '').substring(7).trim());
        }
        return _json({'ok': true});
    }
    return http.Response('Not Found', 404);
  }

  // ---------------------------------------------------------------- expenses

  Map<String, dynamic> _entry(int id, Map<String, dynamic> row) {
    final date = '${row['date']}';
    final sources = (row['sources'] as List).cast<String>();
    return {
      'page_id': '$id',
      'title': (row['title'] as String).isEmpty ? '—' : row['title'],
      'amount': row['amount'],
      'date': date.length >= 10 ? date.substring(0, 10) : date,
      'datetime': date,
      'categories': row['categories'],
      'source': sources.isEmpty ? '' : sources.first,
      'sources': sources,
      'mode': row['mode'],
      'comment': row['comment'],
      'processed': row['processed'] == true,
    };
  }

  void _register(FakeAccount a, Map<String, dynamic> row) {
    void add(String kind, Iterable<String> names) {
      final l = _list(a.id)[kind]!;
      for (final n in names) {
        if (n.isNotEmpty && !l.any((x) => x.toLowerCase() == n.toLowerCase())) l.add(n);
      }
    }

    add('categories', (row['categories'] as List).cast<String>());
    add('sources', (row['sources'] as List).cast<String>());
    add('modes', ['${row['mode']}']);
  }

  http.Response _expenses(String route, http.Request r, Map<String, dynamic> b) {
    final a = _accountOf(r);
    if (a == null) return _error('Invalid or expired token', 401);

    Map<String, dynamic> fromBody(Map<String, dynamic> existing) => {
          ...existing,
          'title': b['name'],
          'amount': b['amount'],
          if ('${b['date'] ?? ''}'.isNotEmpty) 'date': b['date'],
          'categories': [...((b['categories'] as List?) ?? const []).cast<String>()],
          'sources': '${b['source'] ?? ''}'.isEmpty ? <String>[] : ['${b['source']}'],
          'mode': b['mode'] ?? '',
          if (b.containsKey('comment')) 'comment': b['comment'],
        };

    if (route == 'create/' && r.method == 'POST') {
      if ('${b['name'] ?? ''}'.trim().isEmpty) return _error('Name is required', 400);
      if (b['amount'] == null) return _error('Amount is required', 400);
      if ('${b['date'] ?? ''}'.trim().isEmpty) return _error('Date is required', 400);
      final id = _nextId++;
      final row = fromBody({'comment': '', 'processed': false});
      _rows(a.id)[id] = row;
      _register(a, row);
      return _json({'ok': true, 'page_id': '$id'}, 201);
    }

    if (route == 'list/' && r.method == 'GET') {
      final entries = [for (final e in _rows(a.id).entries) _entry(e.key, e.value)]
        ..sort((x, y) => '${y['datetime']}'.compareTo('${x['datetime']}'));
      return _json({
        'entries': entries,
        'total_count': entries.length,
        'page': 1,
        'total_pages': 1,
        'page_size': 25,
      });
    }

    if (route == 'options/' && r.method == 'GET') {
      final l = _list(a.id);
      return _json({
        for (final k in l.keys)
          k: [
            for (var i = 0; i < l[k]!.length; i++) {'id': i + 1, 'name': l[k]![i], 'uses': 0}
          ]
      });
    }
    final opt = RegExp(r'^options/(categories|sources|modes)/$').firstMatch(route);
    if (opt != null && r.method == 'POST') {
      final name = '${b['name'] ?? ''}'.trim();
      if (name.isEmpty) return _error('Name is required', 400);
      final l = _list(a.id)[opt.group(1)]!;
      final created = !l.any((x) => x.toLowerCase() == name.toLowerCase());
      if (created) l.add(name);
      return _json({'ok': true, 'created': created, 'option': {'id': l.length, 'name': name}},
          created ? 201 : 200);
    }

    final m = RegExp(r'^(\d+)/(update|delete)/$').firstMatch(route);
    if (m != null) {
      final id = int.parse(m.group(1)!);
      final exists = _rows(a.id).containsKey(id);
      if (m.group(2) == 'update' && r.method == 'PATCH') {
        if ('${b['name'] ?? ''}'.trim().isEmpty) return _error('Name is required', 400);
        if (b['amount'] == null) return _error('Amount is required', 400);
        if (!exists) return _error('Expense not found', 400); // the real server: 400, not 404
        final row = fromBody(_rows(a.id)[id]!);
        _rows(a.id)[id] = row;
        _register(a, row);
        return _json({'ok': true});
      }
      if (m.group(2) == 'delete' && r.method == 'DELETE') {
        if (!exists) return _error('Expense not found', 404);
        _rows(a.id).remove(id);
        return _json({'ok': true});
      }
    }
    return http.Response('Not Found', 404);
  }
}

/// Google on the phone: hands out the ID token a test sets up.
class FakeGoogle implements GoogleTokenProvider {
  String? token;
  Object? failure;
  int signOuts = 0;
  int asked = 0;

  @override
  Future<String?> idToken() async {
    asked++;
    if (failure != null) throw failure!;
    return token; // null = the person closed the Google dialog
  }

  @override
  Future<void> signOut() async => signOuts++;
}

/// The app's services wired against a [FakeBackend] and an in-memory database.
class Harness {
  Harness._(this.backend, this.storage, this.session, this.sync, this.db, this.repo,
      this.account, this.google, this.auth);

  final FakeBackend backend;
  final MemorySessionStorage storage;
  final Session session;
  final SyncSettings sync;
  final FakeDb db;
  final ExpenseRepository repo;
  final AccountController account;
  final FakeGoogle google;
  final AuthApi auth;

  /// The signed-in account (when created signed in).
  late FakeAccount user;

  static Future<Harness> create({
    bool signedIn = true,
    bool autoSync = true,
    FakeBackend? backend,
    DateTime Function()? clock,
    OptionsStore? options,
  }) async {
    final be = backend ?? FakeBackend();
    final storage = MemorySessionStorage();
    final session = Session(storage: storage, clock: clock);
    await session.setServerUrl(FakeBackend.base);
    final sync = SyncSettings(autoSync: autoSync);
    final db = FakeDb();
    final repo = ExpenseRepository(
      db: db,
      api: ApiService(session: session, client: be.client),
      sync: sync,
      options: options,
      pushGap: Duration.zero,
    );
    final google = FakeGoogle();
    final auth = AuthApi(client: be.client);
    final account = AccountController(session: session, auth: auth, repo: repo, google: google);
    final h = Harness._(be, storage, session, sync, db, repo, account, google, auth);

    if (signedIn) {
      h.user = be.accounts.isNotEmpty
          ? be.accounts.first
          : be.addAccount(email: 'user@example.com');
      final r = await auth.login(FakeBackend.base, h.user.email ?? h.user.phone!, h.user.password!);
      await session.setOwner(r.user.id);
      await session.signIn(
          serverUrl: FakeBackend.base, token: r.token, user: r.user, expiresAt: r.expiresAt);
    }
    be.calls.clear(); // setup's own sign-in is not what tests want to inspect
    return h;
  }

  /// An expense that exists only on the phone.
  Expense local(String id,
          {String title = 'Local', double amount = 5, String category = 'Other', DateTime? date}) =>
      Expense(id: id, title: title, amount: amount, category: category, date: date ?? DateTime(2026, 10, 1));
}
