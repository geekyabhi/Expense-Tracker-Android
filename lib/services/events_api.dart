import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/app_event.dart';
import 'api_service.dart' show ApiRejected, ApiOffline;
import 'events_settings.dart';

const String _base = 'https://api.notion.com/v1';
const String _notionVersion = '2022-06-28';

/// Reads events from the Notion events database (POST /databases/{id}/query,
/// sorted by Date ascending). Read-only.
class EventsApi {
  EventsApi({
    http.Client? client,
    required this.settings,
    this.pageGap = const Duration(milliseconds: 350),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final EventsSettings settings;
  final Duration pageGap;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${settings.token.trim()}',
        'Notion-Version': _notionVersion,
        'Content-Type': 'application/json',
      };

  Future<http.Response> _send(String method, Uri uri, [String? body]) async {
    Future<http.Response> once() => (method == 'POST'
            ? _client.post(uri, headers: _headers, body: body)
            : _client.get(uri, headers: _headers))
        .timeout(const Duration(seconds: 15));

    var res = await once();
    if (res.statusCode == 429) {
      final secs =
          (int.tryParse(res.headers['retry-after'] ?? '') ?? 1).clamp(1, 10);
      await Future<void>.delayed(Duration(seconds: secs));
      res = await once();
    }
    return res;
  }

  static bool _transient(int code) => code == 429 || code == 409 || code >= 500;

  /// All events, soonest first. Throws [ApiRejected] or [ApiOffline].
  Future<List<AppEvent>> fetchAll() async {
    final uri = Uri.parse('$_base/databases/${settings.databaseId.trim()}/query');
    final events = <AppEvent>[];
    String? cursor;
    for (var i = 0; i < 100; i++) {
      final body = jsonEncode({
        'sorts': [
          {'property': 'Date', 'direction': 'ascending'}
        ],
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
      for (final page in (json['results'] as List<dynamic>).cast<Map<String, dynamic>>()) {
        final e = eventFromPage(page);
        if (e != null) events.add(e);
      }
      cursor = json['next_cursor'] as String?;
      if (json['has_more'] != true || cursor == null) break;
      await Future<void>.delayed(pageGap);
    }
    return events;
  }

  /// Notion page -> event. Needs a Date; Title falls back to the row's Name.
  static AppEvent? eventFromPage(Map<String, dynamic> page) {
    final id = page['id'] as String?;
    if (id == null) return null;
    final props = (page['properties'] as Map<String, dynamic>?) ?? {};

    String text(String name) {
      final p = props[name] as Map<String, dynamic>?;
      if (p == null) return '';
      final parts = (p['rich_text'] ?? p['title']) as List<dynamic>? ?? [];
      return parts.map((t) => t['plain_text'] as String? ?? '').join().trim();
    }

    String select(String name) =>
        (props[name]?['select'] as Map<String, dynamic>?)?['name'] as String? ?? '';

    final start = props['Date']?['date']?['start'] as String?;
    if (start == null) return null;
    final parsed = DateTime.tryParse(start);
    if (parsed == null) return null;
    final date = parsed.isUtc ? parsed.toLocal() : parsed;

    final name = text('Name');
    var title = text('Title');
    if (title.isEmpty) title = name;
    if (title.isEmpty) return null;

    return AppEvent(
      id: id,
      name: name,
      title: title,
      subtitle: text('Subtitle'),
      date: date,
      type: select('Type'),
      repeats: select('Repeats'),
    );
  }

  /// Checks the token, the database id and the columns. Returns a message.
  Future<String> checkConnection() async {
    const required = {
      'Title': 'rich_text',
      'Subtitle': 'rich_text',
      'Date': 'date',
    };
    const optional = {
      'Repeats': 'select',
      'Type': 'select',
    };
    try {
      final res = await _send(
          'GET', Uri.parse('$_base/databases/${settings.databaseId.trim()}'));
      if (res.statusCode == 401) {
        return 'Notion says the events token is invalid.';
      }
      if (res.statusCode == 404) {
        return 'Events database not found. Open it in Notion, tap ••• → '
            'Connections and add the integration that owns this token.';
      }
      if (res.statusCode != 200) {
        return 'Notion error ${res.statusCode}: ${_errorMessage(res.body)}';
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final props = (json['properties'] as Map<String, dynamic>? ?? {});
      final problems = <String>[];
      required.forEach((name, type) {
        final p = props[name] as Map<String, dynamic>?;
        if (p == null) {
          problems.add('missing column "$name" ($type)');
        } else if (p['type'] != type) {
          problems.add('"$name" is ${p['type']}, should be $type');
        }
      });
      final notes = <String>[];
      optional.forEach((name, type) {
        if (props[name]?['type'] != type) {
          notes.add(name == 'Repeats'
              ? 'no "Repeats" column, so events won\'t repeat'
              : 'no "Type" column');
        }
      });
      final titles = json['title'] as List<dynamic>? ?? [];
      final dbName = titles.isEmpty ? 'database' : titles.first['plain_text'];
      if (problems.isNotEmpty) {
        return 'Connected to "$dbName", but: ${problems.join('; ')}.';
      }
      var count = '';
      try {
        count = ' ${(await fetchAll()).length} events found.';
      } catch (_) {}
      return 'Connected to "$dbName". Title, Subtitle and Date look right.$count'
          '${notes.isEmpty ? '' : ' Note: ${notes.join('; ')}.'}';
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
