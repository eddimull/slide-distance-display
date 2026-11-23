import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'account.dart';
import 'google_button.dart' as google_web;
import 'seventh_api.dart';
import 'sign_in.dart' as sign_in;
import 'sign_in.dart' show SignInCanceled;
import 'take_style.dart';

/// Signing in for the online leaderboards, the leaderboard name, signing
/// out and deleting the account.
class AccountScreen extends StatefulWidget {
  final Account account;

  /// The platform sign-in, swappable for tests.
  final Future<String> Function() googleIdToken;
  final Future<(String, String)> Function() appleCredential;
  final Stream<String> Function()? googleIdTokens;

  const AccountScreen({
    super.key,
    required this.account,
    this.googleIdToken = sign_in.googleIdToken,
    this.appleCredential = sign_in.appleCredential,
    this.googleIdTokens,
  });

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  Account get _account => widget.account;
  final _name = TextEditingController();
  StreamSubscription<String>? _webGoogle;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _account.addListener(_changed);
    _name.text = _account.player?.displayName ?? '';
    final tokens = widget.googleIdTokens ?? (kIsWeb ? sign_in.googleIdTokens : null);
    _webGoogle = tokens?.call().listen(
        (t) => _run(() => _account.signInWithGoogle(t)),
        onError: (Object e) => setState(() => _error = '$e'));
  }

  @override
  void dispose() {
    _account.removeListener(_changed);
    _webGoogle?.cancel();
    _name.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      if (_name.text.isEmpty) _name.text = _account.player?.displayName ?? '';
    });
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
    } on SignInCanceled {
      // Backed out.
    } on ApiException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = 'Sign-in didn\'t work: $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _google() => _run(() async =>
      _account.signInWithGoogle(await widget.googleIdToken()));

  Future<void> _apple() => _run(() async {
        final (token, code) = await widget.appleCredential();
        await _account.signInWithApple(token, code: code);
      });

  Future<void> _saveName() => _run(() => _account.setName(_name.text));

  Future<void> _signOut() => _run(() async {
        await _account.signOut();
        await sign_in.signOutGoogle();
        _name.clear();
      });

  Future<void> _delete() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete your account?'),
        content: const Text(
            'This removes your leaderboard name, rounds and scores from '
            'Seventh for good. High scores on this device stay.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: TextButton.styleFrom(foregroundColor: TakeStyle.bad),
              child: const Text('Delete')),
        ],
      ),
    );
    if (sure != true) return;
    await _run(() async {
      await _account.deleteAccount();
      await sign_in.signOutGoogle();
      _name.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TakeStyle.ground,
      appBar: AppBar(
        backgroundColor: TakeStyle.ground,
        foregroundColor: TakeStyle.text,
        title: const Text('Leaderboards account',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (!_account.available)
            const Text('Online leaderboards are on the phone and web apps.',
                style: TextStyle(color: TakeStyle.muted))
          else if (!_account.signedIn)
            ..._signedOut()
          else
            ..._signedIn(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_error!,
                  style: const TextStyle(fontSize: 13, color: TakeStyle.bad)),
            ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  List<Widget> _signedOut() => [
        const Text(
            'Sign in to put your rounds on the worldwide and weekly '
            'leaderboards. Your high scores on this device stay either way.',
            style: TextStyle(fontSize: 14, height: 1.45, color: TakeStyle.body)),
        const SizedBox(height: 20),
        SignInWithAppleButton(
          key: const Key('apple'),
          height: 48,
          style: SignInWithAppleButtonStyle.white,
          onPressed: () => _busy ? null : _apple(),
        ),
        const SizedBox(height: 12),
        if (kIsWeb && widget.googleIdTokens == null)
          Center(child: google_web.renderButton())
        else
          _wide(OutlinedButton(
            key: const Key('google'),
            style: OutlinedButton.styleFrom(foregroundColor: TakeStyle.text),
            onPressed: _busy ? null : _google,
            child: const Text('Sign in with Google'),
          )),
      ];

  List<Widget> _signedIn() => [
        Text(
            _account.needsName
                ? 'Pick a name for the leaderboards.'
                : 'Your rounds go on the leaderboards as:',
            style: const TextStyle(fontSize: 14, color: TakeStyle.body)),
        const SizedBox(height: 12),
        TextField(
          key: const Key('name'),
          controller: _name,
          maxLength: 20,
          style: const TextStyle(color: TakeStyle.text),
          decoration: const InputDecoration(
            labelText: 'Leaderboard name',
            helperText: '3–20 letters, numbers, spaces, . _ -',
          ),
          onSubmitted: (_) => _saveName(),
        ),
        const SizedBox(height: 8),
        _wide(FilledButton(
          key: const Key('save'),
          onPressed: _busy ? null : _saveName,
          child: const Text('Save name'),
        )),
        const SizedBox(height: 32),
        _wide(OutlinedButton(
          key: const Key('sign_out'),
          style: OutlinedButton.styleFrom(foregroundColor: TakeStyle.text),
          onPressed: _busy ? null : _signOut,
          child: const Text('Sign out'),
        )),
        const SizedBox(height: 12),
        _wide(TextButton(
          key: const Key('delete'),
          style: TextButton.styleFrom(foregroundColor: TakeStyle.bad),
          onPressed: _busy ? null : _delete,
          child: const Text('Delete account'),
        )),
      ];

  Widget _wide(Widget b) => SizedBox(height: 48, child: b);
}
