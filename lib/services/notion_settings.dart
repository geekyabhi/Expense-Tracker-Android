import 'package:shared_preferences/shared_preferences.dart';

/// Notion credentials, entered in the Settings screen and kept on the device
/// (SharedPreferences, not encrypted). They are never part of the source code.
class NotionSettings {
  NotionSettings(
      {this.token = '', this.databaseId = '', this.autoSync = true});

  String token;
  String databaseId;

  /// true: push each new expense right after saving (failures stay on the
  /// device). false: never push until the user does it manually.
  bool autoSync;

  bool get isConfigured =>
      token.trim().isNotEmpty && databaseId.trim().isNotEmpty;

  static const _kToken = 'notion_token';
  static const _kDb = 'notion_database_id';
  static const _kAuto = 'auto_sync';

  static Future<NotionSettings> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      return NotionSettings(
        token: p.getString(_kToken) ?? '',
        databaseId: p.getString(_kDb) ?? '',
        autoSync: p.getBool(_kAuto) ?? true,
      );
    } catch (_) {
      return NotionSettings();
    }
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kToken, token.trim());
    await p.setString(_kDb, databaseId.trim());
    await p.setBool(_kAuto, autoSync);
  }

  /// Accepts a bare id or a pasted database URL and returns the 32-char id.
  static String normalizeDatabaseId(String input) {
    final m = RegExp(r'[0-9a-fA-F]{32}')
        .firstMatch(input.replaceAll('-', '').trim());
    return m?.group(0) ?? input.trim();
  }
}
