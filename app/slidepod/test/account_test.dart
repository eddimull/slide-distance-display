import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slidepod/account.dart';
import 'package:slidepod/account_screen.dart';
import 'package:slidepod/flash_card_game.dart';
import 'package:slidepod/flash_card_screen.dart' show ordinal;
import 'package:slidepod/high_scores.dart';
import 'package:slidepod/high_scores_screen.dart';
import 'package:slidepod/seventh_api.dart';

/// A stand-in for seventh-server: records requests, answers from [routes].
class FakeServer {
  final requests = <http.Request>[];
  final routes = <String, (int, Object?)>{};

  late final client = MockClient((req) async {
    requests.add(req);
    final (status, body) = routes['${req.method} ${req.url}'
            .replaceFirst('https://seventh.test', '')] ??
        routes['${req.method} ${req.url.path}'] ??
        (404, {'message': 'Not found'});
    return http.Response(body == null ? '' : jsonEncode(body), status,
        headers: {'content-type': 'application/json'});
  });

  http.Request last(String method, String path) => requests
      .lastWhere((r) => r.method == method && r.url.path == '/api$path');

  Map<String, dynamic> bodyOf(String method, String path) =>
      jsonDecode(last(method, path).body) as Map<String, dynamic>;
}

Future<(Account, FakeServer)> account({String? platform = 'android'}) async {
  final server = FakeServer();
  final a = Account(
      SeventhApi(base: 'https://seventh.test/api', client: server.client),
      await SharedPreferences.getInstance(),
      platform: platform);
  return (a, server);
}

const signedIn = {
  'token': 'tok-1',
  'user': {'id': 7, 'display_name': null},
  'needs_name': true,
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('signing in with Google keeps the token, and asks for a name', () async {
    final (a, server) = await account();
    server.routes['POST /api/auth/google'] = (200, signedIn);

    await a.signInWithGoogle('google-id-token');

    expect(server.bodyOf('POST', '/auth/google'),
        {'id_token': 'google-id-token', 'device': 'android'});
    expect(a.signedIn, isTrue);
    expect(a.needsName, isTrue);

    // Still signed in when the app opens again.
    final again = Account(SeventhApi(client: server.client),
        await SharedPreferences.getInstance(),
        platform: 'android');
    expect(again.signedIn, isTrue);
    expect(again.player!.id, 7);
  });

  test('Apple sends the authorization code too', () async {
    final (a, server) = await account(platform: 'ios');
    server.routes['POST /api/auth/apple'] = (200, signedIn);

    await a.signInWithApple('apple-id-token', code: 'auth-code');

    expect(server.bodyOf('POST', '/auth/apple'),
        {'id_token': 'apple-id-token', 'code': 'auth-code', 'device': 'ios'});
  });

  test('a name the server refuses comes back as its message', () async {
    final (a, server) = await account();
    server.routes['POST /api/auth/google'] = (200, signedIn);
    await a.signInWithGoogle('t');
    server.routes['PATCH /api/me'] = (422, {'message': 'That name is taken.'});

    await expectLater(a.setName('Alice'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', 'That name is taken.')));

    server.routes['PATCH /api/me'] =
        (200, {'user': {'id': 7, 'display_name': 'Alice'}});
    await a.setName('  Alice ');
    expect(server.bodyOf('PATCH', '/me'), {'display_name': 'Alice'});
    expect(server.last('PATCH', '/me').headers['Authorization'], 'Bearer tok-1');
    expect(a.needsName, isFalse);
  });

  test('posting a round sends its card log for the server to re-score', () async {
    final (a, server) = await account();
    server.routes['POST /api/auth/google'] = (200, signedIn);
    await a.signInWithGoogle('t');
    server.routes['POST /api/rounds'] = (201, {
      'score': 1234,
      'all': {'rank': 41, 'score': 2000},
      'week': {'rank': 3, 'score': 1234},
    });
    final round = FlashCardRound()
      ..results.add(CardResult(
          card: PositionDeck().cards[3],
          from: 1,
          position: 4,
          ms: 840,
          base: 100,
          multiplier: 1,
          parMs: 900,
          comboAfter: 1));

    final posted = await a.postRound('position_flash', 1, round);

    expect(server.bodyOf('POST', '/rounds'), {
      'game': 'position_flash',
      'rules_version': 1,
      'platform': 'android',
      'client_score': round.score,
      'cards': [
        {'card': 'p4', 'from': 1, 'position': 4, 'ms': 840, 'cents': null},
      ],
    });
    expect(posted!.week!.rank, 3);
    expect(posted.all!.rank, 41);
  });

  test('a token the server no longer knows signs out', () async {
    final (a, server) = await account();
    server.routes['POST /api/auth/google'] = (200, signedIn);
    await a.signInWithGoogle('t');
    server.routes['GET /api/me'] = (401, {'message': 'Unauthenticated.'});

    await a.refresh();

    expect(a.signedIn, isFalse);
    expect((await SharedPreferences.getInstance()).getString('seventh_token'),
        isNull);
  });

  test('deleting the account signs out; a failure keeps you signed in',
      () async {
    final (a, server) = await account();
    server.routes['POST /api/auth/google'] = (200, signedIn);
    await a.signInWithGoogle('t');

    server.routes['DELETE /api/me'] = (500, {'message': 'Server Error'});
    await expectLater(a.deleteAccount(), throwsA(isA<ApiException>()));
    expect(a.signedIn, isTrue);

    server.routes['DELETE /api/me'] = (200, {'deleted': true});
    await a.deleteAccount();
    expect(a.signedIn, isFalse);
  });

  test('no leaderboards on desktop', () async {
    final (a, _) = await account(platform: null);
    expect(a.available, isFalse);
    expect(await a.postRound('position_flash', 1, FlashCardRound()), isNull);
  });

  test('ordinals', () {
    expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 101, 111].map(ordinal),
        ['1st', '2nd', '3rd', '4th', '11th', '12th', '13th', '21st', '22nd', '101st', '111th']);
  });

  testWidgets('account screen: sign in, pick a name, sign out', (tester) async {
    final (a, server) = await account();
    server.routes['POST /api/auth/apple'] = (200, signedIn);
    server.routes['PATCH /api/me'] =
        (200, {'user': {'id': 7, 'display_name': 'Slider'}});
    server.routes['POST /api/auth/sign-out'] = (200, {'ok': true});

    await tester.pumpWidget(MaterialApp(
        home: AccountScreen(
      account: a,
      googleIdToken: () async => 'g',
      appleCredential: () async => ('apple-token', 'apple-code'),
    )));
    expect(find.text('Sign in with Google'), findsOneWidget);

    await tester.tap(find.byKey(const Key('apple')));
    await tester.pumpAndSettle();
    expect(server.bodyOf('POST', '/auth/apple')['code'], 'apple-code');
    expect(find.text('Pick a name for the leaderboards.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('name')), 'Slider');
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    expect(a.player!.displayName, 'Slider');
    expect(find.text('Your rounds go on the leaderboards as:'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sign_out')));
    await tester.pumpAndSettle();
    expect(a.signedIn, isFalse);
    expect(find.text('Sign in with Google'), findsOneWidget);
  });

  testWidgets('account screen: a refused sign-in shows why', (tester) async {
    final (a, server) = await account();
    server.routes['POST /api/auth/google'] =
        (401, {'message': 'Sign-in failed: Not issued for this app.'});

    await tester.pumpWidget(MaterialApp(
        home: AccountScreen(
      account: a,
      googleIdToken: () async => 'g',
      appleCredential: () async => ('a', 'c'),
    )));
    await tester.tap(find.byKey(const Key('google')));
    await tester.pumpAndSettle();

    expect(find.text('Sign-in failed: Not issued for this app.'), findsOneWidget);
    expect(a.signedIn, isFalse);
  });

  Map<String, Object?> entry(int rank, int id, String? name, int score) => {
        'rank': rank,
        'user_id': id,
        'display_name': name,
        'score': score,
        'found': 6,
        'best_combo': 2,
        'achieved_at': '2026-11-23T14:16:39+00:00',
      };

  Future<void> openScores(WidgetTester tester, Account a) async {
    await tester.pumpWidget(MaterialApp(
        home: HighScoresScreen(
      scores: HighScores(await SharedPreferences.getInstance()),
      gameId: 'position_flash',
      title: 'Position Flash',
      subtitle: 'Position Flash · Level 1',
      account: a,
    )));
  }

  testWidgets('leaderboards: this week and all time, with your place',
      (tester) async {
    final (a, server) = await account();
    server.routes['POST /api/auth/google'] =
        (200, {'token': 'tok-1', 'user': {'id': 7, 'display_name': 'Slider'}, 'needs_name': false});
    await a.signInWithGoogle('t');
    server.routes['GET /api/leaderboards/position_flash?period=week'] = (200, {
      'players': 2,
      'entries': [entry(1, 3, 'Ace', 5000), entry(2, 7, 'Slider', 4055)],
      'me': {'rank': 2, 'score': 4055},
    });
    server.routes['GET /api/leaderboards/position_flash?period=all'] = (200, {
      'players': 120,
      'entries': [entry(1, 3, 'Ace', 9000), entry(2, 9, null, 8000)],
      'me': {'rank': 61, 'score': 4055},
    });

    await openScores(tester, a);
    // Signed in: this week's board comes first.
    await tester.pumpAndSettle();
    expect(find.text('Slider (you)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tab_phone')));
    await tester.pumpAndSettle();
    expect(find.text('No scores yet. Play a round!'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tab_week')));
    await tester.pumpAndSettle();
    expect(find.text('Ace'), findsOneWidget);
    expect(find.text('Slider (you)'), findsOneWidget);
    expect(find.byKey(const Key('my_place')), findsNothing);
    expect(server.last('GET', '/leaderboards/position_flash').headers['Authorization'],
        'Bearer tok-1');

    await tester.tap(find.byKey(const Key('tab_all')));
    await tester.pumpAndSettle();
    expect(find.text('Unnamed player'), findsOneWidget);
    expect(find.text('You\'re 61st of 120, with 4,055.'), findsOneWidget);
  });

  testWidgets('leaderboards: signed out asks to sign in; errors can retry',
      (tester) async {
    final (a, server) = await account();
    server.routes['GET /api/leaderboards/position_flash'] =
        (503, {'message': 'Down for maintenance.'});

    await openScores(tester, a);
    await tester.tap(find.byKey(const Key('tab_week')));
    await tester.pumpAndSettle();
    expect(find.text('Down for maintenance.'), findsOneWidget);
    expect(server.last('GET', '/leaderboards/position_flash').headers['Authorization'],
        isNull);

    server.routes['GET /api/leaderboards/position_flash'] =
        (200, {'players': 0, 'entries': [], 'me': null});
    await tester.tap(find.byKey(const Key('retry')));
    await tester.pumpAndSettle();
    expect(find.text('No scores this week yet. Be the first!'), findsOneWidget);
    expect(find.byKey(const Key('board_sign_in')), findsOneWidget);
  });

  testWidgets('no leaderboard tabs on desktop', (tester) async {
    final (a, _) = await account(platform: null);
    await openScores(tester, a);
    expect(find.byKey(const Key('tab_week')), findsNothing);
  });
}
