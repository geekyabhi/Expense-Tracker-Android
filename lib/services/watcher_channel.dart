import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class InstalledApp {
  const InstalledApp({required this.name, required this.package, this.icon});
  final String name;
  final String package;
  final Uint8List? icon;
}

class PermissionStatus {
  const PermissionStatus(
      {required this.usage, required this.overlay, required this.battery});
  final bool usage;
  final bool overlay;
  final bool battery;
}

/// Bridge to the Android-only "popup after closing an app" feature
/// (see android/app/src/main/kotlin/.../WatcherService.kt).
class WatcherChannel {
  static const _ch = MethodChannel('expense_tracker/watcher');

  static bool get supported => defaultTargetPlatform == TargetPlatform.android;

  static Future<List<InstalledApp>> installedApps() async {
    final raw = await _ch.invokeListMethod<Map<dynamic, dynamic>>(
            'getInstalledApps') ??
        [];
    return [
      for (final m in raw)
        InstalledApp(
          name: m['name'] as String,
          package: m['package'] as String,
          icon: m['icon'] as Uint8List?,
        )
    ];
  }

  static Future<Set<String>> watched() async =>
      (await _ch.invokeListMethod<String>('getWatched') ?? []).toSet();

  static Future<void> setWatched(Set<String> packages) =>
      _ch.invokeMethod('setWatched', {'packages': packages.toList()});

  static Future<bool> isBubbleEnabled() async =>
      await _ch.invokeMethod<bool>('isBubbleEnabled') ?? false;

  /// Shows or hides the floating + button. Throws a [PlatformException] if
  /// "Display over other apps" isn't granted.
  static Future<void> setBubbleEnabled(bool enabled) =>
      _ch.invokeMethod('setBubbleEnabled', {'enabled': enabled});

  static Future<bool> isEnabled() async =>
      await _ch.invokeMethod<bool>('isEnabled') ?? false;

  static Future<void> setEnabled(bool enabled) =>
      _ch.invokeMethod('setEnabled', {'enabled': enabled});

  /// Gives the native popup the Notion credentials and sync mode.
  static Future<void> setNotion(
          String token, String databaseId, bool autoSync) =>
      _ch.invokeMethod('setNotion',
          {'token': token, 'databaseId': databaseId, 'autoSync': autoSync});

  /// Shows the popup right now (nothing is saved).
  static Future<void> previewPopup() => _ch.invokeMethod('previewPopup');

  static Future<PermissionStatus> permissions() async {
    final m = await _ch.invokeMapMethod<String, bool>('permissionStatus') ?? {};
    return PermissionStatus(
      usage: m['usage'] ?? false,
      overlay: m['overlay'] ?? false,
      battery: m['battery'] ?? false,
    );
  }

  static Future<void> openUsageSettings() =>
      _ch.invokeMethod('openUsageSettings');
  static Future<void> openOverlaySettings() =>
      _ch.invokeMethod('openOverlaySettings');
  static Future<void> requestIgnoreBattery() =>
      _ch.invokeMethod('requestIgnoreBattery');
}
