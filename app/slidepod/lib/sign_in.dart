import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// Google and Apple sign-in, as set up for seventh.app (see seventh-server's
/// README, "Sign-in setup"). Each gives an ID token that [Account] sends
/// to the server.

/// The Web OAuth client: signs in on web, and is the audience Android's
/// tokens are issued for. iOS uses its own client (GIDClientID in
/// Info.plist).
const googleWebClientId =
    '524720389552-g3i48tkkmcdtkufshjceek3lmr0e2qs6.apps.googleusercontent.com';

/// Apple's browser flow (web, Android): the Services ID, and the server
/// route Apple posts to (it hands the result back to the Android app).
const appleServicesId = 'app.seventh.signin';
final appleRedirectUri =
    Uri.parse('https://seventh.app/api/auth/apple/callback');

/// The player backed out: not an error to show.
class SignInCanceled implements Exception {
  const SignInCanceled();
}

Future<void>? _googleReady;

/// Sets up Google sign-in once.
Future<void> initGoogle() => _googleReady ??= GoogleSignIn.instance.initialize(
      clientId: kIsWeb ? googleWebClientId : null,
      serverClientId: defaultTargetPlatform == TargetPlatform.android && !kIsWeb
          ? googleWebClientId
          : null,
    );

/// Android and iOS: Google's sign-in sheet. (Web uses Google's button and
/// [googleIdTokens] instead.)
Future<String> googleIdToken() async {
  await initGoogle();
  try {
    final account = await GoogleSignIn.instance.authenticate();
    final token = account.authentication.idToken;
    if (token == null) throw StateError('Google gave no ID token.');
    return token;
  } on GoogleSignInException catch (e) {
    if (e.code == GoogleSignInExceptionCode.canceled ||
        e.code == GoogleSignInExceptionCode.interrupted) {
      throw const SignInCanceled();
    }
    rethrow;
  }
}

/// Web: ID tokens from sign-ins through Google's button.
Stream<String> googleIdTokens() async* {
  await initGoogle();
  await for (final e in GoogleSignIn.instance.authenticationEvents) {
    if (e is GoogleSignInAuthenticationEventSignIn) {
      final token = e.user.authentication.idToken;
      if (token != null) yield token;
    }
  }
}

/// Forgets the Google session, so the next sign-in can pick another account.
Future<void> signOutGoogle() async {
  try {
    await initGoogle();
    await GoogleSignIn.instance.signOut();
  } catch (_) {
    // Nothing to sign out of.
  }
}

/// Apple's sign-in: (ID token, authorization code). Asks for no name or
/// email; the player picks a leaderboard name instead.
Future<(String, String)> appleCredential() async {
  try {
    final c = await SignInWithApple.getAppleIDCredential(
      scopes: const [],
      webAuthenticationOptions: WebAuthenticationOptions(
          clientId: appleServicesId, redirectUri: appleRedirectUri),
    );
    final token = c.identityToken;
    if (token == null) throw StateError('Apple gave no ID token.');
    return (token, c.authorizationCode);
  } on SignInWithAppleAuthorizationException catch (e) {
    if (e.code == AuthorizationErrorCode.canceled) throw const SignInCanceled();
    rethrow;
  }
}
