/// Reading the browser URL the app was opened with.
///
/// WHY THIS EXISTS. An invited candidate does not sign in and browse; they
/// click a link in an email. The Odoo module emails
/// `<base>/exam/<token>` when `etp_assessment_pro.candidate_app_base_url` is
/// set, so the app must open that exam FIRST, before its own list.
///
/// Kept as a pure function on a [Uri] rather than reading `Uri.base` inline:
/// a function that takes its input can be tested, and this is exactly the kind
/// of parsing that fails quietly on a trailing slash or a query string.
library;

/// The exam access token in [uri], or null when there is none.
///
/// Accepts every shape the module and a copy-pasting human produce:
///
///   /exam/abc123                 path
///   /exam/abc123/                trailing slash
///   /#/exam/abc123               hash routing (Flutter's default strategy)
///   /?token=abc123               query, for a link that lost its path
///   /pro_assessment/abc123       the ODOO portal path, so a link issued
///                                before the app existed still works here
String? examTokenFrom(Uri uri) {
  // A PASSWORD-RESET LINK IS NOT AN EXAM LINK, and it also arrives as a bare
  // `?token=`. Without this the reset link opened somebody's exam runner
  // against a token no evaluator holds, which fails as "this assessment is not
  // available" - a dead end with no way back to the reset form the token was
  // minted for.
  if (resetTokenFrom(uri) != null) return null;

  // Query first: an explicit `?token=` is unambiguous.
  final String q = uri.queryParameters['token']?.trim() ?? '';
  if (q.isNotEmpty) return q;

  // Flutter web defaults to hash routing, so the real path can live in the
  // fragment: `https://host/#/exam/<token>`.
  final List<String> segments = <String>[
    ...uri.pathSegments,
    ..._fragmentOf(uri).pathSegments,
  ];

  for (int i = 0; i < segments.length - 1; i++) {
    final String seg = segments[i];
    if (seg == 'exam' || seg == 'pro_assessment') {
      final String token = segments[i + 1].trim();
      if (token.isNotEmpty) return token;
    }
  }
  return null;
}

/// The fragment of [uri] as a Uri, or an empty one when it does not parse.
///
/// `Uri.parse` THROWS on anything that is not a URI, and a fragment is not
/// required to be one - it is whatever came after the `#`. Both readers here
/// are called during startup routing (`main.dart`) and during build
/// (`login_screen.dart`), with no try/catch anywhere above them, so a single
/// malformed fragment took down the whole app: a candidate arriving at
/// `https://host/#{...}` or any other unparseable hash got a WHITE SCREEN
/// instead of a login form, with no route back.
///
/// Reproduced in plain Dart:
///
///     Uri.parse(Uri.parse('http://h/x#{"a":1}').fragment);
///     // FormatException: Scheme not starting with alphabetic character
///
/// An empty Uri is the right fallback: it has no path segments and no query,
/// so both readers fall through to their "not a deep link" branch, which is
/// exactly what an unparseable fragment means.
Uri _fragmentOf(Uri uri) => Uri.tryParse(uri.fragment) ?? Uri();

/// The password-reset token in [uri], or null when this is not a reset link.
///
/// SCOPED BY PATH, unlike [examTokenFrom]. Both tokens travel as `?token=`,
/// so the only thing separating them is the page the link points at - and the
/// exam reader claims any bare `?token=` it is shown. This one therefore has to
/// be strict where that one is permissive, and has to be asked FIRST.
///
/// Accepts the same shapes a real link takes:
///
///   /reset-password?token=abc      the emailed form
///   /reset-password/abc            path, for a link that lost its query
///   /#/reset-password?token=abc    hash routing
String? resetTokenFrom(Uri uri) {
  const String page = 'reset-password';

  final Uri fragment = _fragmentOf(uri);
  final bool onResetPage =
      uri.pathSegments.contains(page) || fragment.pathSegments.contains(page);
  if (!onResetPage) return null;

  // A hash-routed link carries its query in the fragment, where `uri.query`
  // cannot see it.
  final String q =
      (uri.queryParameters['token'] ?? fragment.queryParameters['token'] ?? '')
          .trim();
  if (q.isNotEmpty) return q;

  for (final List<String> segments in <List<String>>[
    uri.pathSegments,
    fragment.pathSegments,
  ]) {
    final int at = segments.indexOf(page);
    if (at >= 0 && at + 1 < segments.length) {
      final String token = segments[at + 1].trim();
      if (token.isNotEmpty) return token;
    }
  }
  // On the page with no token at all: still a reset link, and the screen says
  // so far better than the login form would.
  return '';
}
