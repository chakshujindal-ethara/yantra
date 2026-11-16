/// Opening this app from Yantra.
///
/// Yantra (the worker and ops app) signs people in with Keycloak; this app
/// does not. Yantra's server asks the assessment bridge for a one-time launch
/// ticket and sends the browser to `<app>/yantra/launch#ticket=<ticket>`. The
/// ticket rides in the FRAGMENT, which a browser never sends, so it is never in
/// an access log; the app trades it once for a session
/// (`/api/v1/yantra/launch/redeem`), wipes it from the address bar, and opens
/// the sitting. "Back to Yantra" then returns to the page the person came from.
///
/// Pure functions on their inputs so they run on the VM in tests.
library;

import 'services/yantra_return_stub.dart'
    if (dart.library.js_interop) 'services/yantra_return_web.dart';

/// Yantra's own address, given at build time. Empty in Ethara's builds, where
/// none of the Yantra controls appear.
const String kYantraAppUrl = String.fromEnvironment('YANTRA_APP_URL');

/// The launch ticket in [uri], or null when this is not a launch link.
String? launchTicketFrom(Uri uri) {
  final List<String> path = uri.pathSegments
      .where((String s) => s.isNotEmpty)
      .toList();
  if (path.length != 2 || path[0] != 'yantra' || path[1] != 'launch') {
    return null;
  }
  try {
    final String t = (Uri.splitQueryString(uri.fragment)['ticket'] ?? '')
        .trim();
    return t.isEmpty ? null : t;
  } on ArgumentError {
    // A malformed escape in the fragment: not a ticket this app can read.
    return null;
  }
}

/// [raw] when it is a web address worth sending a person to, else null.
///
/// http(s) only, so a stored value can never become `javascript:`. When the
/// build knows Yantra's address, only that origin is accepted (the server
/// already checks this; the client does not take it on trust).
String? safeReturnUrl(String? raw, {String yantraAppUrl = kYantraAppUrl}) {
  final Uri? u = Uri.tryParse((raw ?? '').trim());
  if (u == null || !_isWeb(u)) return null;
  final Uri? yantra = Uri.tryParse(yantraAppUrl.trim());
  if (yantra != null && _isWeb(yantra) && yantra.origin != u.origin) {
    return null;
  }
  return u.toString();
}

/// Remember (or, with null, forget) where "Back to Yantra" goes.
void rememberYantraReturn(String? url) =>
    writeYantraReturn(safeReturnUrl(url, yantraAppUrl: ''));

/// Where "Back to Yantra" goes, or null when this session did not come from
/// Yantra.
String? yantraReturnUrl({String yantraAppUrl = kYantraAppUrl}) =>
    safeReturnUrl(readYantraReturn(), yantraAppUrl: yantraAppUrl);

/// The address to open once a ticket is redeemed: the sitting for a candidate,
/// the page asked for by staff, else home. Never another origin.
String afterLaunchPath({String? examToken, String? next}) {
  if (examToken != null && examToken.isNotEmpty) {
    return '/exam/${Uri.encodeComponent(examToken)}';
  }
  final String n = next ?? '';
  return n.startsWith('/') && !n.startsWith('//') && !n.contains('://')
      ? n
      : '/';
}

/// Yantra's sign-in, for the login form, or null when this build has none.
Uri? continueWithYantraUri({String yantraAppUrl = kYantraAppUrl}) {
  final Uri? u = Uri.tryParse(yantraAppUrl.trim());
  return u != null && _isWeb(u) ? u : null;
}

bool _isWeb(Uri u) =>
    (u.scheme == 'http' || u.scheme == 'https') && u.host.isNotEmpty;
