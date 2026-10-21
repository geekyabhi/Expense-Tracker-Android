import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_event.dart';
import 'api_service.dart' show ApiRejected, ApiOffline;
import 'events_api.dart';
import 'events_settings.dart';

/// Decides which event to pop up when the app opens.
///
/// Events are fetched from Notion every time the app opens (no caching by
/// time), and kept on the phone only as an offline fallback. An event is a candidate when it falls on today (repeats
/// included); one is shown at a time, at least [EventsSettings.gapMinutes]
/// after the previous popup.
class EventsService {
  EventsService({
    required this.api,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final EventsApi api;
  final DateTime Function() _now;

  EventsSettings get settings => api.settings;

  /// What the last check did, so Settings can show it.
  DateTime? lastCheckAt;
  bool? lastCheckFromNotion; // false = Notion couldn't be reached, saved copy used
  String? lastCheckProblem;

  /// One line for Settings: when events were last checked and where from.
  String get lastCheckText {
    final at = lastCheckAt;
    if (at == null) return 'Not checked yet since the app started.';
    final time = DateFormat.jms().format(at);
    return lastCheckFromNotion == true
        ? 'Last check: $time, asked Notion.'
        : 'Last check: $time, could not reach Notion '
            '(${lastCheckProblem ?? 'unknown problem'}), used the saved copy.';
  }

  static const _kCache = 'events_cache';
  static const _kLegacyFetchedAt = 'events_fetched_at'; // no longer used
  static const _kShown = 'events_last_shown';

  Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  List<AppEvent>? _readCache(SharedPreferences? p) {
    final raw = p?.getString(_kCache);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .map((e) => AppEvent.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// Forget cached events (the credentials changed).
  Future<void> clearCache() async {
    final p = await _prefs();
    await p?.remove(_kCache);
    await p?.remove(_kLegacyFetchedAt);
  }

  /// All events, asked from Notion every time. There is no time-based reuse of
  /// an earlier answer: a change made in Notion is seen on the next check. The
  /// last saved events are only a fallback for when Notion can't be reached.
  Future<List<AppEvent>> loadEvents() async {
    if (!settings.isConfigured) return [];
    final p = await _prefs();

    List<AppEvent> fallback(String problem) {
      lastCheckAt = _now();
      lastCheckFromNotion = false;
      lastCheckProblem = problem;
      debugPrint('[Events] could not reach Notion ($problem), using the saved copy');
      return _readCache(p) ?? [];
    }

    try {
      final events = await api.fetchAll();
      await p?.setString(
          _kCache, jsonEncode(events.map((e) => e.toJson()).toList()));
      lastCheckAt = _now();
      lastCheckFromNotion = true;
      lastCheckProblem = null;
      debugPrint('[Events] asked Notion: ${events.length} event(s)');
      return events;
    } on ApiRejected catch (e) {
      return fallback('Notion said no: ${e.message}');
    } on ApiOffline {
      return fallback('no connection or Notion is busy');
    } catch (e) {
      return fallback('$e');
    }
  }

  Future<Map<String, DateTime>> _lastShown(SharedPreferences? p) async {
    final raw = p?.getString(_kShown);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, DateTime.parse(v as String)));
    } catch (_) {
      return {};
    }
  }

  /// The one event to pop up now, or null.
  ///
  /// Only events that fall on today are candidates, and only one is shown at a
  /// time. The gap counts from the last popup of *any* event, so popups are at
  /// least [EventsSettings.gapMinutes] apart. When several events are on today
  /// they take turns: the one shown longest ago goes first (never-shown ones
  /// before any), ties keep Notion's order.
  Future<AppEvent?> nextDue() async {
    if (!settings.isConfigured || !settings.popupEnabled) return null;
    final now = _now();
    final events = await loadEvents();
    final shown = await _lastShown(await _prefs());

    if (shown.isNotEmpty) {
      final lastAny = shown.values.reduce((a, b) => a.isAfter(b) ? a : b);
      if (now.difference(lastAny) < Duration(minutes: settings.gapMinutes)) {
        return null;
      }
    }

    final today = [
      for (var i = 0; i < events.length; i++)
        if (events[i].occursOn(now)) (events[i], i)
    ];
    if (today.isEmpty) return null;
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    today.sort((x, y) {
      final byTurn = (shown[x.$1.id] ?? epoch).compareTo(shown[y.$1.id] ?? epoch);
      return byTurn != 0 ? byTurn : x.$2.compareTo(y.$2);
    });
    return today.first.$1;
  }

  /// A sentence for Settings: what is on today, or what comes next. Always asks
  /// Notion afresh.
  Future<String> todaySummary() async {
    final events = await loadEvents();
    final now = _now();
    final today = events.where((e) => e.occursOn(now)).toList();
    if (today.isNotEmpty) {
      final n = today.length;
      return 'Today: $n event${n == 1 ? '' : 's'} (${today.map((e) => '"${e.title}"').join(', ')}). '
          'The popup shows when you open the app${n > 1 ? ', one at a time' : ''}.';
    }
    for (var i = 1; i <= 366; i++) {
      final day = DateTime(now.year, now.month, now.day + i);
      final hit = events.where((e) => e.occursOn(day)).toList();
      if (hit.isNotEmpty) {
        return 'No event today. Next: "${hit.first.title}" on '
            '${DateFormat.yMMMd().format(day)} (in $i day${i == 1 ? '' : 's'}).';
      }
    }
    return events.isEmpty
        ? 'No events found in the database.'
        : 'No event today, and none coming up.';
  }

  /// Records that [e] was just shown, which starts its gap.
  Future<void> markShown(AppEvent e) async {
    final p = await _prefs();
    if (p == null) return;
    final shown = await _lastShown(p);
    shown[e.id] = _now();
    await p.setString(
        _kShown, jsonEncode(shown.map((k, v) => MapEntry(k, v.toIso8601String()))));
  }
}
