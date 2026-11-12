import 'package:google_sign_in/google_sign_in.dart';

import '../config/app_config.dart';

/// Google sign-in failed in a way worth telling the user about.
class GoogleAuthFailure implements Exception {
  GoogleAuthFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Gets a Google ID token from the phone. Faked in tests.
abstract class GoogleTokenProvider {
  /// The ID token, or null if the person closed the Google dialog.
  Future<String?> idToken();
  Future<void> signOut();
}

class GoogleSignInProvider implements GoogleTokenProvider {
  bool _ready = false;

  Future<void> _init() async {
    if (_ready) return;
    await GoogleSignIn.instance.initialize(serverClientId: kGoogleWebClientId);
    _ready = true;
  }

  @override
  Future<String?> idToken() async {
    if (kGoogleWebClientId.isEmpty) {
      throw GoogleAuthFailure('Google sign-in is not set up in this app.');
    }
    try {
      await _init();
      await GoogleSignIn.instance.signOut(); // always offer the account chooser
      final account = await GoogleSignIn.instance.authenticate();
      final token = account.authentication.idToken;
      if (token == null || token.isEmpty) {
        throw GoogleAuthFailure('Google did not return a sign-in token. Try again.');
      }
      return token;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      final detail = (e.description ?? '').trim();
      throw GoogleAuthFailure(
          'Google sign-in failed (${e.code.name}${detail.isEmpty ? '' : ': $detail'}). '
          'Check that a Google account is added on this device and that the '
          'Google Cloud Android client matches this app.');
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _init();
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
  }
}
