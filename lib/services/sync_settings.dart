import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Auto or Manual pushing of expenses to the server.
///
/// Auto: each new or edited expense is pushed right after saving (failures stay
/// on the phone). Manual: nothing is sent until you select expenses and push.
class SyncSettings extends ChangeNotifier {
  SyncSettings({this.autoSync = true});

  bool autoSync;

  static const _kAuto = 'auto_sync'; // the same key the earlier versions used

  static Future<SyncSettings> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      return SyncSettings(autoSync: p.getBool(_kAuto) ?? true);
    } catch (_) {
      return SyncSettings();
    }
  }

  Future<void> setAutoSync(bool value) async {
    autoSync = value;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kAuto, value);
    } catch (_) {}
  }
}
