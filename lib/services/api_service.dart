import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../models/expense.dart';
import 'session.dart';

class UploadResult {
  const UploadResult.ok(this.pageId) : ok = true;
  const UploadResult.failed()
      : ok = false,
        pageId = null;
  final bool ok;

  /// The server's id of the expense ("page_id").
  final String? pageId;
}

/// The server answered with a 4xx that retrying won't fix (a bad value...).
class ApiRejected implements Exception {
  ApiRejected(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => 'The server rejected the request ($status): $message';
}

/// Couldn't reach the server, or it is busy (network error, timeout, 5xx).
class ApiOffline implements Exception {
  @override
  String toString() => 'Could not reach the server';
}

/// The token is missing, expired or revoked (HTTP 401). The [Session] has been
/// told, which sends the app back to the login screen.
class SessionExpired implements Exception {
  @override
  String toString() => 'Your session expired. Sign in again.';
}

/// The expenses of the signed-in account on the backend (/api/expenses/…):
/// create, update, delete and read, with `Authorization: Bearer <token>`.
class ApiService {
  ApiService({http.Client? client, required this.session})
      : _client = client ?? http.Client();

  final http.Client _client;
  final Session session;

  static const _timeout = Duration(seconds: 20);

  Uri _uri(String path, [Map<String, String>? query]) => Uri.parse(
          '${session.serverUrl}/api/expenses/$path')
      .replace(queryParameters: query);

  /// Sends the request as the signed-in account. A 401 ends the session.
  Future<http.Response> _send(String method, Uri uri, [String? body]) async {
    final token = session.token;
    if (token == null) throw SessionExpired();
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    final http.Response res = await (switch (method) {
      'POST' => _client.post(uri, headers: headers, body: body),
      'PATCH' => _client.patch(uri, headers: headers, body: body),
      'DELETE' => _client.delete(uri, headers: headers),
      _ => _client.get(uri, headers: headers),
    })
        .timeout(_timeout);
    if (res.statusCode == 401) {
      session.expire();
      throw SessionExpired();
    }
    return res;
  }

  static bool _transient(int code) => code == 408 || code == 429 || code >= 500;

  // ------------------------------------------------------------------ writing

  /// Local date and time with a UTC offset, e.g. 2026-10-23T09:30:00+05:30, so
  /// the server keeps the same wall-clock time as the phone.
  static String isoWithOffset(DateTime d) {
    final off = d.timeZoneOffset;
    final sign = off.isNegative ? '-' : '+';
    final a = off.abs();
    final hh = a.inHours.toString().padLeft(2, '0');
    final mm = (a.inMinutes % 60).toString().padLeft(2, '0');
    return "${DateFormat("yyyy-MM-dd'T'HH:mm:ss").format(d)}$sign$hh:$mm";
  }

  /// "Food, Travel" -> [Food, Travel]. An expense with several categories is
  /// kept as one comma-separated label in the app, so editing it never loses one.
  static List<String> splitList(String v) =>
      v.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

  /// The request body for create and update. The server overwrites categories,
  /// source and mode on every update, so all of them are always sent.
  static Map<String, dynamic> body(Expense e) => {
        'name': e.title,
        'amount': e.amount,
        'date': isoWithOffset(e.date),
        'categories': splitList(e.category),
        'source': e.source,
        'mode': e.mode,
        'comment': e.note,
      };

  /// Creates the expense, or updates it if it was pushed before.
  ///
  /// ok: the server has it now. failed: offline, timeout or a busy server; safe
  /// to retry. Throws [ApiRejected] for a 4xx that retrying won't fix and
  /// [SessionExpired] when the token is no longer valid.
  Future<UploadResult> upload(Expense e) async {
    var update = e.remoteId != null;
    try {
      var res = update
          ? await _send('PATCH', _uri('${e.remoteId}/update/'), jsonEncode(body(e)))
          : await _send('POST', _uri('create/'), jsonEncode(body(e)));

      if (update &&
          res.statusCode == 400 &&
          _errorMessage(res.body).toLowerCase().contains('not found')) {
        // Deleted on the server since. Create it again instead of failing forever.
        update = false;
        res = await _send('POST', _uri('create/'), jsonEncode(body(e)));
      }

      final code = res.statusCode;
      if (code >= 200 && code < 300) {
        if (update) return UploadResult.ok(e.remoteId);
        try {
          final id = (jsonDecode(res.body) as Map<String, dynamic>)['page_id'];
          if (id != null) return UploadResult.ok('$id');
        } catch (_) {}
        // Created, but no id came back: there is no way to link it. Treat as a
        // rejection rather than risk creating a duplicate on the next try.
        throw ApiRejected(code, 'The server did not say which expense it created.');
      }
      if (_transient(code)) return const UploadResult.failed();
      throw ApiRejected(code, _errorMessage(res.body));
    } on ApiRejected {
      rethrow;
    } on SessionExpired {
      rethrow;
    } catch (_) {
      return const UploadResult.failed(); // offline, DNS failure, timeout...
    }
  }

  /// Deletes the expense on the server. One that is already gone counts as done.
  Future<UploadResult> remove(String remoteId) async {
    try {
      final res = await _send('DELETE', _uri('$remoteId/delete/'));
      final code = res.statusCode;
      if ((code >= 200 && code < 300) || code == 404) {
        return const UploadResult.ok(null);
      }
      if (_transient(code)) return const UploadResult.failed();
      throw ApiRejected(code, _errorMessage(res.body));
    } on ApiRejected {
      rethrow;
    } on SessionExpired {
      rethrow;
    } catch (_) {
      return const UploadResult.failed();
    }
  }

  // ------------------------------------------------------------------ reading

  /// Every expense of the account, newest first. Throws [ApiRejected],
  /// [ApiOffline] or [SessionExpired].
  Future<List<Expense>> listAll() async {
    final http.Response res;
    try {
      res = await _send('GET',
          _uri('list/', {'all': '1', 'sort': 'date_desc', 'force': '1'}));
    } on SessionExpired {
      rethrow;
    } catch (_) {
      throw ApiOffline();
    }
    final code = res.statusCode;
    if (_transient(code)) throw ApiOffline();
    if (code < 200 || code >= 300) throw ApiRejected(code, _errorMessage(res.body));
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final entries = (json['entries'] as List<dynamic>).cast<Map<String, dynamic>>();
    return [
      for (final e in entries)
        if (expenseFromEntry(e) case final x?) x
    ];
  }

  /// A server entry becomes an expense (new local id, already uploaded).
  static Expense? expenseFromEntry(Map<String, dynamic> e) {
    final id = e['page_id'];
    if (id == null) return null;
    final categories = ((e['categories'] as List<dynamic>?) ?? [])
        .map((c) => '$c'.trim())
        .where((c) => c.isNotEmpty)
        .toList();
    var date = DateTime.now();
    final raw = (e['datetime'] as String?)?.isNotEmpty == true
        ? e['datetime'] as String
        : e['date'] as String?;
    if (raw != null && raw.isNotEmpty) {
      final d = DateTime.tryParse(raw);
      if (d != null) date = d.isUtc ? d.toLocal() : d;
    }
    final title = ((e['title'] as String?) ?? '').trim();
    final mode = ((e['mode'] as String?) ?? '').trim();
    return Expense(
      id: const Uuid().v4(),
      title: title.isEmpty || title == '—' ? '(untitled)' : title,
      amount: ((e['amount'] as num?) ?? 0).toDouble(),
      category: categories.isEmpty ? 'Other' : categories.join(', '),
      date: date,
      note: (e['comment'] as String?) ?? '',
      source: ((e['source'] as String?) ?? '').trim(),
      mode: mode.isEmpty ? kDefaultMode : mode,
      synced: true,
      processed: e['processed'] == true,
      remoteId: '$id',
    );
  }

  // ------------------------------------------------------------- pick-lists

  /// The account's own categories, modes and sources.
  Future<ServerOptions> options() async {
    final res = await _send('GET', _uri('options/'));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiRejected(res.statusCode, _errorMessage(res.body));
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    List<String> names(String k) => ((j[k] as List<dynamic>?) ?? [])
        .map((o) => '${(o as Map<String, dynamic>)['name']}')
        .where((n) => n.isNotEmpty)
        .toList();
    return ServerOptions(
        categories: names('categories'), modes: names('modes'), sources: names('sources'));
  }

  /// Saves a new category/mode/source on the server. [kind] is `categories`,
  /// `modes` or `sources`. Best effort.
  Future<void> addOption(String kind, String name) async {
    await _send('POST', _uri('options/$kind/'), jsonEncode({'name': name}));
  }

  static String _errorMessage(String body) {
    try {
      final m = (jsonDecode(body) as Map<String, dynamic>)['error'];
      if (m is String && m.isNotEmpty) return m;
    } catch (_) {}
    return body.length > 200 ? '${body.substring(0, 200)}…' : body;
  }
}

class ServerOptions {
  const ServerOptions({
    this.categories = const [],
    this.modes = const [],
    this.sources = const [],
  });
  final List<String> categories;
  final List<String> modes;
  final List<String> sources;
}
