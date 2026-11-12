import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

/// The signed-in account, as the backend describes it.
class AppUser {
  const AppUser({
    required this.id,
    this.email,
    this.phone,
    this.name = '',
    this.googleConnected = false,
  });

  final String id; // the backend's uid
  final String? email;
  final String? phone;
  final String name;
  final bool googleConnected;

  /// What to call this account on screen.
  String get label => name.isNotEmpty ? name : (email ?? phone ?? 'Account');

  /// How the person signs in: their email or phone.
  String get identifier => email ?? phone ?? '';

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: '${j['id']}',
        email: (j['email'] as String?)?.isEmpty ?? true ? null : j['email'] as String,
        phone: (j['phone'] as String?)?.isEmpty ?? true ? null : j['phone'] as String,
        name: (j['name'] as String?) ?? '',
        googleConnected: j['google_connected'] == true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'phone': phone,
        'name': name,
        'google_connected': googleConnected,
      };
}

/// Everything that is remembered between app launches.
class SessionSnapshot {
  const SessionSnapshot({
    this.serverUrl,
    this.token,
    this.expiresAt,
    this.user,
    this.ownerId,
  });

  final String? serverUrl;
  final String? token;
  final DateTime? expiresAt;
  final AppUser? user;

  /// Whose expenses are on this phone. It outlives a sign-out, so signing back
  /// in as the same person keeps them and anyone else starts clean.
  final String? ownerId;
}

abstract class SessionStorage {
  Future<SessionSnapshot> read();
  Future<void> write(SessionSnapshot s);
}

/// The token goes in the platform's secure storage (Android Keystore); the
/// rest, which isn't secret, in ordinary preferences.
class SecureSessionStorage implements SessionStorage {
  SecureSessionStorage([FlutterSecureStorage? secure])
      : _secure = secure ?? const FlutterSecureStorage();
  final FlutterSecureStorage _secure;

  static const _kServer = 'server_url';
  static const _kUser = 'session_user';
  static const _kExpires = 'session_expires_at';
  static const _kOwner = 'data_owner_id';
  static const _kToken = 'session_token';

  @override
  Future<SessionSnapshot> read() async {
    String? token;
    try {
      token = await _secure.read(key: _kToken);
    } catch (_) {}
    try {
      final p = await SharedPreferences.getInstance();
      final user = p.getString(_kUser);
      return SessionSnapshot(
        serverUrl: p.getString(_kServer),
        token: token,
        expiresAt: DateTime.tryParse(p.getString(_kExpires) ?? ''),
        user: user == null
            ? null
            : AppUser.fromJson(jsonDecode(user) as Map<String, dynamic>),
        ownerId: p.getString(_kOwner),
      );
    } catch (_) {
      return SessionSnapshot(token: token);
    }
  }

  @override
  Future<void> write(SessionSnapshot s) async {
    try {
      if (s.token == null) {
        await _secure.delete(key: _kToken);
      } else {
        await _secure.write(key: _kToken, value: s.token);
      }
    } catch (_) {}
    try {
      final p = await SharedPreferences.getInstance();
      Future<void> put(String k, String? v) async =>
          v == null ? p.remove(k) : p.setString(k, v);
      await put(_kServer, s.serverUrl);
      await put(_kUser, s.user == null ? null : jsonEncode(s.user!.toJson()));
      await put(_kExpires, s.expiresAt?.toIso8601String());
      await put(_kOwner, s.ownerId);
    } catch (_) {}
  }
}

/// Keeps everything in memory (tests).
class MemorySessionStorage implements SessionStorage {
  SessionSnapshot snapshot = const SessionSnapshot();
  @override
  Future<SessionSnapshot> read() async => snapshot;
  @override
  Future<void> write(SessionSnapshot s) async => snapshot = s;
}

/// Who is signed in, and where. Listen to it to switch between the login screen
/// and the app.
class Session extends ChangeNotifier {
  Session({SessionStorage? storage, DateTime Function()? clock})
      : _storage = storage ?? SecureSessionStorage(),
        _now = clock ?? DateTime.now;

  final SessionStorage _storage;
  final DateTime Function() _now;

  String serverUrl = kDefaultServerUrl;
  AppUser? user;
  String? ownerId;
  DateTime? expiresAt;
  String? _token;

  /// Why the login screen is showing, if it isn't a plain first sign-in.
  String? notice;

  bool get _expired => expiresAt != null && !_now().isBefore(expiresAt!);

  bool get isSignedIn => _token != null && user != null && !_expired;

  /// The bearer token, or null when signed out or expired.
  String? get token => isSignedIn ? _token : null;

  /// "https://host" with no trailing slash and a scheme (https if none given).
  static String normalizeServerUrl(String input) {
    var s = input.trim();
    if (s.isEmpty) return kDefaultServerUrl;
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(s)) s = 'https://$s';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Future<void> load() async {
    final s = await _storage.read();
    serverUrl = normalizeServerUrl(s.serverUrl ?? '');
    _token = s.token;
    user = s.user;
    expiresAt = s.expiresAt;
    ownerId = s.ownerId;
    if (_token != null && _expired) notice = 'Your session expired. Sign in again.';
    notifyListeners();
  }

  Future<void> _save() => _storage.write(SessionSnapshot(
        serverUrl: serverUrl,
        token: _token,
        expiresAt: expiresAt,
        user: user,
        ownerId: ownerId,
      ));

  Future<void> setServerUrl(String url) async {
    serverUrl = normalizeServerUrl(url);
    await _save();
    notifyListeners();
  }

  Future<void> signIn({
    required String serverUrl,
    required String token,
    required AppUser user,
    DateTime? expiresAt,
  }) async {
    this.serverUrl = normalizeServerUrl(serverUrl);
    _token = token;
    this.user = user;
    this.expiresAt = expiresAt;
    notice = null;
    await _save();
    notifyListeners();
  }

  Future<void> setOwner(String id) async {
    ownerId = id;
    await _save();
  }

  /// Signs out on purpose. The phone's expenses stay for the same account.
  Future<void> signOut() async {
    _token = null;
    user = null;
    expiresAt = null;
    notice = null;
    await _save();
    notifyListeners();
  }

  /// The server said the token is no longer valid. Back to the login screen
  /// (with a note), keeping the expenses on the phone.
  void expire([String? message]) {
    if (_token == null && user == null) return;
    _token = null;
    expiresAt = null;
    notice = message ?? 'Your session expired. Sign in again.';
    _save();
    notifyListeners();
  }
}
