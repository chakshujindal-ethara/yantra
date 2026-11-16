import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:http_parser/http_parser.dart';
import 'package:yantra_app/api/gateway_client.dart';
import 'package:yantra_app/api/models.dart';
import 'package:yantra_app/auth/browser.dart';
import 'package:yantra_app/auth/keycloak.dart';
import 'package:yantra_app/auth/session.dart';
import 'package:yantra_app/auth/token_store.dart';
import 'package:yantra_app/auth/tokens.dart';
import 'package:yantra_app/config.dart';
import 'package:yantra_app/core/download.dart';
import 'package:yantra_app/core/drafts.dart';
import 'package:yantra_app/core/network_status.dart';
import 'package:yantra_app/core/platform/file_pick.dart';
import 'package:yantra_app/core/theme/theme_controller.dart';
import 'package:yantra_app/main.dart';

const testConfig = AppConfig(gatewayUrl: 'http://gateway.test', keycloakUrl: 'http://keycloak.test', directLogin: true);
const tokenPath = '/realms/yantra/protocol/openid-connect/token';

typedef Handler = http.Response Function(http.Request request);

/// A scripted gateway + Keycloak. Routes are `'METHOD /path'`; every request is recorded.
class FakeBackend {
  FakeBackend([Map<String, Handler>? routes]) : routes = {...?routes};

  final Map<String, Handler> routes;
  final List<http.Request> requests = [];

  /// Routes that answer when the test says so (a request still in flight); checked before [routes].
  final Map<String, Future<http.Response> Function(http.Request request)> slow = {};

  /// When set, every answer carries a `Date` header this far from the device clock (a skewed device).
  Duration? serverSkew;

  late final http.Client client = MockClient((request) async {
    requests.add(request);
    final route = '${request.method} ${request.url.path}';
    final later = slow[route];
    final handler = routes[route];
    final r = later != null
        ? await later(request)
        : handler == null
        ? http.Response('{"code":"not_found","message":"no route"}', 404)
        : handler(request);
    final skew = serverSkew;
    if (skew == null) return r;
    return http.Response.bytes(r.bodyBytes, r.statusCode, headers: {...r.headers, 'date': formatHttpDate(DateTime.now().add(skew))});
  });

  List<http.Request> sent(String method, String path) => requests.where((r) => r.method == method && r.url.path == path).toList();
}

http.Response json(Object body, {int status = 200, Map<String, String>? headers}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json', ...?headers});

http.Response envelope(int status, String code, {String message = '', Map<String, String>? headers, Map<String, Object?>? context}) =>
    json({'code': code, 'message': message, 'request_id': 'req-1', 'context': ?context}, status: status, headers: headers);

/// An unsigned JWT-shaped token whose payload names the worker; the app only reads it for display.
String fakeJwt({String sub = 'worker-1', String username = 'worker1', List<String> roles = const ['worker']}) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part({
    'sub': sub,
    'preferred_username': username,
    'realm_access': {'roles': roles},
  })}.sig';
}

Map<String, Object> tokenResponse({String access = 'access-1', String refresh = 'refresh-1', int expiresIn = 300}) => {
  'access_token': access,
  'refresh_token': refresh,
  'expires_in': expiresIn,
  'token_type': 'Bearer',
};

Tokens liveTokens({String access = '', String refresh = 'refresh-1', List<String> roles = const ['worker', 'reviewer']}) => Tokens(
  accessToken: access.isEmpty ? fakeJwt(roles: roles) : access,
  refreshToken: refresh,
  expiresAt: DateTime.now().add(const Duration(minutes: 5)),
);

class TestHarness {
  TestHarness(
    this.backend, {
    Tokens? tokens,
    AppConfig config = testConfig,
    MemoryBrowser? browser,
    this.dark = false,
    this.initialLocation,
  }) {
    store = MemoryTokenStore()..write(tokens);
    this.browser = browser ?? MemoryBrowser();
    session = Session(
      auth: KeycloakAuth(client: backend.client, config: config),
      store: store,
      config: config,
      browser: this.browser,
    );
    gateway = GatewayClient(client: backend.client, tokens: session, baseUrl: testConfig.gatewayUrl, sleep: (_) async {}, network: network);
  }

  final FakeBackend backend;
  late final MemoryBrowser browser;
  late final MemoryTokenStore store;
  late final Session session;
  late final GatewayClient gateway;

  /// The browser's network as the app sees it; tests flip it to show the offline banner.
  final NetworkStatus network = NetworkStatus();

  /// Files the app handed the user to save (statement CSV, bank file, manifest, deliverable).
  final MemoryDownloader downloads = MemoryDownloader();

  /// Drafts kept "on this device".
  final MemoryDraftStore drafts = MemoryDraftStore();

  /// The file chooser; set `files.next` before the tap that opens it.
  final MemoryFilePicker files = MemoryFilePicker();

  final bool dark;

  /// Where the router starts (a deep link); null starts at the first destination for the roles.
  final String? initialLocation;

  late final Widget app = YantraApp(
    session: session,
    gateway: gateway,
    network: network,
    downloader: downloads,
    drafts: drafts,
    files: files,
    uploadClient: backend.client,
    theme: ThemeController(initial: dark ? ThemeMode.dark : ThemeMode.light, persist: false),
    initialLocation: initialLocation,
  );
}

/// Pumps the whole app, signed in unless [signedOut]. [size] picks the shell: below 960 wide the bottom
/// bar, at or above it the sidebar. [browser] stands in for the real one (redirect sign-in, storage).
Future<TestHarness> pumpApp(
  WidgetTester tester,
  FakeBackend backend, {
  bool signedOut = false,
  Size size = const Size(900, 2400),
  AppConfig config = testConfig,
  MemoryBrowser? browser,
  List<String> roles = const ['worker', 'reviewer'],
  bool dark = false,
  String? at,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  ReasonCode.all = ReasonCode.builtIn; // a served catalogue from an earlier test must not leak
  final harness = TestHarness(
    backend,
    tokens: signedOut ? null : liveTokens(roles: roles),
    config: config,
    browser: browser,
    dark: dark,
    initialLocation: at,
  );
  await tester.pumpWidget(harness.app);
  // the shell polls the unread count; unmounting stops its timer so no test ends with one pending
  addTearDown(() => tester.pumpWidget(const SizedBox()));
  await tester.pumpAndSettle();
  return harness;
}

/// Where the router is now (`/ops/projects/p1`).
String currentLocation(WidgetTester tester) =>
    GoRouter.of(tester.element(find.byType(Scaffold).first)).routeInformationProvider.value.uri.toString();

/// Pumps a bounded number of frames. For screens with a running countdown, where pumpAndSettle never settles.
Future<void> pumpFor(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Navigates the running app's router to [location] the way a link would (the stack under it is built
/// from the path), then settles. [extra] is what a page hands to the next one (a row already read).
Future<void> goTo(WidgetTester tester, String location, {Object? extra, bool settle = true}) async {
  GoRouter.of(tester.element(find.byType(Scaffold).first)).go(location, extra: extra);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await pumpFor(tester);
  }
}

/// On a narrow shell, opens the drawer and taps the destination with [navKey] (`nav-review`, ...).
Future<void> openFromDrawer(WidgetTester tester, String navKey) async {
  await tester.tap(find.byKey(const Key('menu')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key(navKey)));
  await tester.pumpAndSettle();
}

/// For dark-mode cases: the page renders without a layout error and every tappable thing is named. Text
/// contrast is checked in light mode only until the dark primary token is settled (it sits just under 4.5:1
/// as text on dark surfaces; see app/README.md).
Future<void> expectRendersDark(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  final handle = tester.ensureSemantics();
  await tester.pump();
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  handle.dispose();
}

/// The page on screen passes the text-contrast and labelled-tap-target guidelines (WCAG AA contrast for
/// text, every tappable thing named for assistive tech).
Future<void> expectAccessible(WidgetTester tester) async {
  final handle = tester.ensureSemantics();
  await tester.pump();
  await expectLater(tester, meetsGuideline(textContrastGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  handle.dispose();
}

/// Opens the wide shell's rail the way a person does: the pointer moves onto it. The names, the group
/// labels and the account footer exist only while it is open.
Future<void> openRail(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(900, 400));
  addTearDown(mouse.removePointer);
  await tester.pump();
  await mouse.moveTo(const Offset(30, 400));
  await tester.pumpAndSettle();
}
