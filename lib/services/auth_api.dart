import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'session.dart';

class AuthException implements Exception {
  AuthException(this.message, [this.status = 0]);
  final String message;

  /// HTTP status, or 0 when the server could not be reached.
  final int status;
  @override
  String toString() => message;
}

class AuthResult {
  const AuthResult({
    required this.user,
    required this.token,
    this.expiresAt,
    this.passwordReset = false,
  });
  final AppUser user;
  final String token;
  final DateTime? expiresAt;

  /// The server cut off an old password while linking this Google sign-in.
  final bool passwordReset;
}

/// The backend's sign-in calls (/api/users/…): email or phone + password, Google.
class AuthApi {
  AuthApi({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  static const _timeout = Duration(seconds: 20);

  Future<AuthResult> login(String server, String identifier, String password) =>
      _result(_post(server, 'login/', {
        'identifier': identifier.trim(),
        'password': password,
      }));

  /// [identifier] is an email (has an @) or a phone number.
  Future<AuthResult> signup(String server,
      {required String identifier, required String password, String name = ''}) {
    final id = identifier.trim();
    return _result(_post(server, 'signup/', {
      if (name.trim().isNotEmpty) 'name': name.trim(),
      if (id.contains('@')) 'email': id else 'phone': id,
      'password': password,
    }));
  }

  /// Sign in (or up) with the ID token Google gave the app.
  Future<AuthResult> google(String server, String idToken) async {
    try {
      return await _result(_post(server, 'google/', {'id_token': idToken}));
    } on AuthException catch (e) {
      // A 404/405 here means the server is reachable but has no Google endpoint
      // (an older deployment), not that the address is wrong.
      if (e.status == 404 || e.status == 405) {
        throw AuthException(
            'This server does not support Google sign-in yet. Sign in with '
            'your email or phone instead.',
            e.status);
      }
      rethrow;
    }
  }

  Future<AppUser> me(String server, String token) async {
    final json = await _decode(_send(() => _client.get(
          _uri(server, 'me/'),
          headers: _headers(token),
        )));
    return AppUser.fromJson(json['user'] as Map<String, dynamic>);
  }

  /// Revokes this token (or every token of the account).
  Future<void> logout(String server, String token, {bool all = false}) async {
    await _decode(_send(() => _client.post(
          _uri(server, 'logout/'),
          headers: _headers(token),
          body: jsonEncode({'all': all}),
        )));
  }

  // ---------------------------------------------------------------- internals

  Uri _uri(String server, String path) =>
      Uri.parse('${Session.normalizeServerUrl(server)}/api/users/$path');

  Map<String, String> _headers([String? token]) => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<http.Response> _post(String server, String path, Map<String, dynamic> body) =>
      _send(() => _client.post(_uri(server, path),
          headers: _headers(), body: jsonEncode(body)));

  Future<http.Response> _send(Future<http.Response> Function() call) async {
    try {
      return await call().timeout(_timeout);
    } catch (_) {
      throw AuthException(
          'Could not reach the server. Check your connection and the server address.');
    }
  }

  Future<Map<String, dynamic>> _decode(Future<http.Response> pending) async {
    final res = await pending;
    Map<String, dynamic>? json;
    try {
      final d = jsonDecode(res.body);
      if (d is Map<String, dynamic>) json = d;
    } catch (_) {}
    if (res.statusCode >= 200 && res.statusCode < 300 && json != null) return json;
    final message = json?['error'];
    if (message is String && message.isNotEmpty) {
      throw AuthException(message, res.statusCode);
    }
    throw AuthException(
        res.statusCode >= 500
            ? 'The server had a problem (HTTP ${res.statusCode}). Try again later.'
            : 'Unexpected reply from the server (HTTP ${res.statusCode}). '
                'Is the server address right?',
        res.statusCode);
  }

  Future<AuthResult> _result(Future<http.Response> pending) async {
    final json = await _decode(pending);
    final token = json['token'];
    final user = json['user'];
    if (token is! String || token.isEmpty || user is! Map<String, dynamic>) {
      throw AuthException('Unexpected reply from the server.');
    }
    return AuthResult(
      user: AppUser.fromJson(user),
      token: token,
      expiresAt: DateTime.tryParse('${json['expires_at'] ?? ''}')?.toLocal(),
      passwordReset: json['password_reset'] == true,
    );
  }
}
