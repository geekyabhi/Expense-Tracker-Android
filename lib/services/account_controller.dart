import 'dart:async';

import 'auth_api.dart';
import 'expense_repository.dart';
import 'google_auth.dart';
import 'session.dart';

/// What came of a sign-in attempt.
class AuthOutcome {
  const AuthOutcome.ok({this.passwordReset = false})
      : error = null,
        cancelled = false;
  const AuthOutcome.failed(String this.error)
      : cancelled = false,
        passwordReset = false;
  const AuthOutcome.cancelled()
      : error = null,
        cancelled = true,
        passwordReset = false;

  final String? error;
  final bool cancelled;
  final bool passwordReset;
  bool get ok => error == null && !cancelled;
}

/// Signing in and out, and what that means for the expenses on the phone.
///
/// Every sign-in method (email + password, phone + password, Google) ends in the
/// same place: a bearer token for the one account, so they all open the same
/// expenses. The phone only ever holds ONE account's expenses: the first time
/// anyone signs in, and whenever a different account does, what was on the phone
/// is removed first. Signing back in as the same account keeps them.
class AccountController {
  AccountController({
    required this.session,
    required this.auth,
    required this.repo,
    required this.google,
  });

  final Session session;
  final AuthApi auth;
  final ExpenseRepository repo;
  final GoogleTokenProvider google;

  Future<AuthOutcome> signInWithPassword(
      String server, String identifier, String password) {
    return _run(server, () => auth.login(server, identifier, password));
  }

  Future<AuthOutcome> signUp(String server,
      {required String identifier, required String password, String name = ''}) {
    return _run(
        server,
        () => auth.signup(server,
            identifier: identifier, password: password, name: name));
  }

  Future<AuthOutcome> signInWithGoogle(String server) async {
    final String? idToken;
    try {
      idToken = await google.idToken();
    } on GoogleAuthFailure catch (e) {
      return AuthOutcome.failed(e.message);
    } catch (e) {
      return AuthOutcome.failed('Google sign-in failed ($e).');
    }
    if (idToken == null) return const AuthOutcome.cancelled();
    return _run(server, () => auth.google(server, idToken!));
  }

  Future<AuthOutcome> _run(String server, Future<AuthResult> Function() call) async {
    final url = Session.normalizeServerUrl(server);
    final AuthResult result;
    try {
      result = await call();
    } on AuthException catch (e) {
      return AuthOutcome.failed(e.message);
    } catch (e) {
      return AuthOutcome.failed('Something went wrong ($e).');
    }

    // One account's expenses on the phone at a time.
    if (session.ownerId != result.user.id) {
      await repo.wipeLocal();
      await session.setOwner(result.user.id);
    }
    await session.signIn(
      serverUrl: url,
      token: result.token,
      user: result.user,
      expiresAt: result.expiresAt,
    );
    unawaited(repo.refreshFromServer()); // load their expenses
    return AuthOutcome.ok(passwordReset: result.passwordReset);
  }

  /// Signs out of this phone (or, with [everywhere], of every device). Returns
  /// false when the server could not be told (offline): this phone is signed
  /// out either way, but other devices stay signed in until then.
  Future<bool> signOut({bool everywhere = false}) async {
    var revoked = true;
    final token = session.token;
    if (token != null) {
      try {
        await auth.logout(session.serverUrl, token, all: everywhere);
      } catch (_) {
        revoked = false;
      }
    }
    await google.signOut();
    await session.signOut();
    return revoked;
  }

  /// Checks the token with the server. Returns a sentence about the result.
  Future<String> testConnection() async {
    final token = session.token;
    if (token == null) return 'Not signed in.';
    try {
      final me = await auth.me(session.serverUrl, token);
      return 'Connected as ${me.label}'
          '${me.identifier.isEmpty ? '' : ' (${me.identifier})'}.';
    } on AuthException catch (e) {
      if (e.status == 401) {
        session.expire();
        return 'Your session expired. Sign in again.';
      }
      return e.message;
    }
  }
}
