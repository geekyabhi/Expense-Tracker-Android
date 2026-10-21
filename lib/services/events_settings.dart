import 'package:shared_preferences/shared_preferences.dart';

/// The choices offered for the gap between event popups, in minutes.
const List<(int, String)> kEventGapChoices = [
  (0, 'Every time I open the app'),
  (5, '5 minutes'),
  (15, '15 minutes'),
  (30, '30 minutes'),
  (60, '1 hour'),
  (120, '2 hours'),
  (240, '4 hours'),
  (480, '8 hours'),
  (720, '12 hours'),
  (1440, '24 hours'),
];

/// Everything about the Notion *events* feature that the user sets: the
/// credentials of the events database (a separate token and database from the
/// expenses ones), whether popups are on, and the minimum gap between popups.
/// Kept on this phone only (SharedPreferences, not encrypted); never part of
/// the source code.
class EventsSettings {
  EventsSettings({
    this.token = '',
    this.databaseId = '',
    this.popupEnabled = true,
    this.gapMinutes = 240,
  });

  String token;
  String databaseId;

  /// Show a popup for today's events when the app is opened.
  bool popupEnabled;

  /// An event is not shown again until this many minutes have passed since it
  /// was last shown. 0 = every time the app is opened.
  int gapMinutes;

  bool get isConfigured =>
      token.trim().isNotEmpty && databaseId.trim().isNotEmpty;

  static const _kToken = 'events_token';
  static const _kDb = 'events_database_id';
  static const _kEnabled = 'events_popup_enabled';
  static const _kGap = 'events_gap_minutes';

  static Future<EventsSettings> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      return EventsSettings(
        token: p.getString(_kToken) ?? '',
        databaseId: p.getString(_kDb) ?? '',
        popupEnabled: p.getBool(_kEnabled) ?? true,
        gapMinutes: p.getInt(_kGap) ?? 240,
      );
    } catch (_) {
      return EventsSettings();
    }
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kToken, token.trim());
    await p.setString(_kDb, databaseId.trim());
    await p.setBool(_kEnabled, popupEnabled);
    await p.setInt(_kGap, gapMinutes);
  }
}
