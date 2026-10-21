import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../models/expense.dart';
import 'notion_settings.dart';

const String _base = 'https://api.notion.com/v1';
const String _notionVersion = '2022-06-28';

class UploadResult {
  const UploadResult.ok(this.pageId) : ok = true;
  const UploadResult.failed()
      : ok = false,
        pageId = null;
  final bool ok;
  final String? pageId;
}

/// Notion answered with a 4xx that retrying won't fix (bad token, wrong column...).
class ApiRejected implements Exception {
  ApiRejected(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => 'Notion rejected the request ($status): $message';
}

/// Couldn't reach Notion, or it is busy (network error, timeout, 409/429/5xx).
class ApiOffline implements Exception {
  @override
  String toString() => 'Could not reach Notion';
}

/// Talks to Notion: create (POST /pages), read (POST /databases/{id}/query),
/// update (PATCH /pages/{id}) and delete (PATCH /pages/{id} with archived: true).
class ApiService {
  ApiService({
    http.Client? client,
    required this.settings,
    this.pageGap = const Duration(milliseconds: 350),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final NotionSettings settings;

  /// Pause between paginated query calls (Notion allows ~3 requests/second).
  final Duration pageGap;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${settings.token.trim()}',
        'Notion-Version': _notionVersion,
        'Content-Type': 'application/json',
      };

  Future<http.Response> _send(String method, Uri uri, [String? body]) async {
    Future<http.Response> once() => (switch (method) {
          'POST' => _client.post(uri, headers: _headers, body: body),
          'PATCH' => _client.patch(uri, headers: _headers, body: body),
          _ => _client.get(uri, headers: _headers),
        })
            .timeout(const Duration(seconds: 15));

    var res = await once();
    if (res.statusCode == 429) {
      // Notion allows ~3 requests/second. Wait as told, then try once more.
      final secs =
          (int.tryParse(res.headers['retry-after'] ?? '') ?? 1).clamp(1, 10);
      await Future<void>.delayed(Duration(seconds: secs));
      res = await once();
    }
    return res;
  }

  static bool _transient(int code) => code == 429 || code == 409 || code >= 500;

  // ---------------------------------------------------------------- create/update

  /// Notion multi-select names can't contain commas.
  static List<Map<String, String>> _tags(String v) {
    final name = v.replaceAll(',', ' ').trim();
    return name.isEmpty ? [] : [{'name': name}];
  }

  /// Local date and time with a UTC offset, e.g. 2026-10-23T09:30:00+05:30,
  /// so Notion shows the same wall-clock time as the phone.
  static String notionDate(DateTime d) {
    final off = d.timeZoneOffset;
    final sign = off.isNegative ? '-' : '+';
    final a = off.abs();
    final hh = a.inHours.toString().padLeft(2, '0');
    final mm = (a.inMinutes % 60).toString().padLeft(2, '0');
    return "${DateFormat("yyyy-MM-dd'T'HH:mm:ss").format(d)}$sign$hh:$mm";
  }

  /// Column names/types must match the Notion database. "Processed" is owned by
  /// Notion and never sent.
  static Map<String, dynamic> properties(Expense e) => {
        'Expense': {
          'title': [
            {
              'text': {'content': e.title}
            }
          ]
        },
        'Amount': {'number': e.amount},
        'Date': {
          'date': {'start': notionDate(e.date)}
        },
        'Category': {'multi_select': _tags(e.category)},
        'Source': {'multi_select': _tags(e.source)},
        'Mode': {'multi_select': _tags(e.mode)},
      };

  /// Creates the page, or updates it if the expense was pushed before.
  /// ok: the page now exists/is updated in Notion.
  /// failed: network error, timeout, 409/429/5xx. Safe to retry later.
  /// Throws [ApiRejected] for other 4xx (bad token, wrong column, ...).
  Future<UploadResult> upload(Expense e) async {
    final update = e.remoteId != null;
    final uri = Uri.parse(update ? '$_base/pages/${e.remoteId}' : '$_base/pages');
    final body = jsonEncode({
      if (!update) 'parent': {'database_id': settings.databaseId.trim()},
      'properties': properties(e),
    });

    try {
      final res = await _send(update ? 'PATCH' : 'POST', uri, body);
      final code = res.statusCode;
      if (kDebugMode) {
        String? stored;
        try {
          stored = (jsonDecode(res.body)['properties']['Date']['date']['start'])
              as String?;
        } catch (_) {}
        debugPrint('[Notion] ${update ? 'PATCH' : 'POST'} $code '
            'sent date=${notionDate(e.date)} | Notion stored date=$stored');
      }
      if (code >= 200 && code < 300) {
        String? id = e.remoteId;
        if (!update) {
          try {
            id = (jsonDecode(res.body) as Map<String, dynamic>)['id'] as String?;
          } catch (_) {}
        }
        return UploadResult.ok(id);
      }
      if (_transient(code)) return const UploadResult.failed();
      throw ApiRejected(code, _errorMessage(res.body));
    } on ApiRejected {
      rethrow;
    } catch (_) {
      return const UploadResult.failed(); // offline, DNS failure, timeout...
    }
  }

  // ---------------------------------------------------------------- delete

  /// Notion has no real delete: this archives the page (recoverable from
  /// Notion's trash). A page that is already gone/archived counts as done.
  Future<UploadResult> archive(String pageId) async {
    try {
      final res = await _send(
          'PATCH', Uri.parse('$_base/pages/$pageId'), jsonEncode({'archived': true}));
      final code = res.statusCode;
      if (code >= 200 && code < 300) return const UploadResult.ok(null);
      if (code == 404) return const UploadResult.ok(null); // already deleted
      final msg = _errorMessage(res.body);
      if (code == 400 && msg.toLowerCase().contains('archived')) {
        return const UploadResult.ok(null);
      }
      if (_transient(code)) return const UploadResult.failed();
      throw ApiRejected(code, msg);
    } on ApiRejected {
      rethrow;
    } catch (_) {
      return const UploadResult.failed();
    }
  }

  // ---------------------------------------------------------------- read

  /// Every (non-archived) page of the database, following pagination.
  /// Throws [ApiRejected] or [ApiOffline].
  Future<List<Map<String, dynamic>>> queryAllPages() async {
    final uri = Uri.parse('$_base/databases/${settings.databaseId.trim()}/query');
    final pages = <Map<String, dynamic>>[];
    String? cursor;
    for (var i = 0; i < 100; i++) {
      // 100 per page, so this caps at 10,000 expenses.
      final body = jsonEncode({
        'page_size': 100,
        if (cursor != null) 'start_cursor': cursor,
      });
      final http.Response res;
      try {
        res = await _send('POST', uri, body);
      } catch (_) {
        throw ApiOffline();
      }
      final code = res.statusCode;
      if (_transient(code)) throw ApiOffline();
      if (code < 200 || code >= 300) {
        throw ApiRejected(code, _errorMessage(res.body));
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      pages.addAll((json['results'] as List<dynamic>).cast<Map<String, dynamic>>());
      cursor = json['next_cursor'] as String?;
      if (json['has_more'] != true || cursor == null) break;
      await Future<void>.delayed(pageGap);
    }
    return pages;
  }

  /// Turns a Notion page into an expense (new local id, already synced).
  /// Missing columns fall back to sensible defaults.
  static Expense? expenseFromPage(Map<String, dynamic> page) {
    final pageId = page['id'] as String?;
    if (pageId == null) return null;
    final props = (page['properties'] as Map<String, dynamic>?) ?? {};

    String firstTag(String name) {
      final list = (props[name]?['multi_select'] as List<dynamic>?) ?? [];
      return list.isEmpty ? '' : (list.first['name'] as String? ?? '');
    }

    final titleParts = (props['Expense']?['title'] as List<dynamic>?) ?? [];
    final title =
        titleParts.map((t) => t['plain_text'] as String? ?? '').join().trim();

    final dateStr = props['Date']?['date']?['start'] as String?;
    var date = DateTime.now();
    if (dateStr != null) {
      final d = DateTime.tryParse(dateStr);
      if (d != null) date = d.isUtc ? d.toLocal() : d;
    }

    final category = firstTag('Category');
    final mode = firstTag('Mode');
    return Expense(
      id: const Uuid().v4(),
      title: title.isEmpty ? '(untitled)' : title,
      amount: ((props['Amount']?['number'] as num?) ?? 0).toDouble(),
      category: category.isEmpty ? 'Other' : category,
      date: date,
      source: firstTag('Source'),
      mode: mode.isEmpty ? kDefaultMode : mode,
      synced: true,
      processed: props['Processed']?['checkbox'] == true,
      remoteId: pageId,
    );
  }

  // ---------------------------------------------------------------- check

  /// Checks the token, the database id and that the columns exist with the
  /// right types. Returns a human-readable result.
  Future<String> checkDatabase() async {
    const expected = {
      'Expense': 'title',
      'Amount': 'number',
      'Date': 'date',
      'Category': 'multi_select',
      'Source': 'multi_select',
      'Mode': 'multi_select',
    };
    try {
      final res = await _client
          .get(Uri.parse('$_base/databases/${settings.databaseId.trim()}'),
              headers: _headers)
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 401) return 'Notion says the token is invalid.';
      if (res.statusCode == 404) {
        return 'Database not found. Open it in Notion, tap ••• → Connections '
            'and add your integration to it.';
      }
      if (res.statusCode != 200) {
        return 'Notion error ${res.statusCode}: ${_errorMessage(res.body)}';
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final props = (json['properties'] as Map<String, dynamic>? ?? {});
      final problems = <String>[];
      expected.forEach((name, type) {
        final p = props[name] as Map<String, dynamic>?;
        if (p == null) {
          problems.add('missing column "$name" ($type)');
        } else if (p['type'] != type) {
          problems.add('"$name" is ${p['type']}, should be $type');
        }
      });
      final titles = json['title'] as List<dynamic>? ?? [];
      final name = titles.isEmpty ? 'database' : titles.first['plain_text'];
      final processedNote = props['Processed']?['type'] == 'checkbox'
          ? ''
          : ' (No "Processed" checkbox column found, so every row will show '
              'as unprocessed.)';
      return problems.isEmpty
          ? 'Connected to "$name". All 6 columns look right.$processedNote'
          : 'Connected to "$name", but: ${problems.join('; ')}.';
    } catch (_) {
      return 'Could not reach Notion. Check your internet connection.';
    }
  }

  static String _errorMessage(String body) {
    try {
      final m = (jsonDecode(body) as Map<String, dynamic>)['message'];
      if (m is String && m.isNotEmpty) return m;
    } catch (_) {}
    return body.length > 200 ? '${body.substring(0, 200)}…' : body;
  }
}
