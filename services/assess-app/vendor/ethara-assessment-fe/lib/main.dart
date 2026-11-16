import 'dart:async';

import 'package:flutter/material.dart';

import 'app_shell.dart';
import 'assessment/data/api_client.dart' show LaunchGrant;
import 'assessment/route_url.dart';
import 'assessment/theme.dart';
import 'assessment/widgets/buttons.dart';
import 'config.dart';
import 'deep_link.dart';
import 'login_screen.dart';
import 'password_reset.dart';
import 'services/prefs_stub.dart'
    if (dart.library.js_interop) 'services/prefs_web.dart';
import 'services/reset_url_stub.dart'
    if (dart.library.js_interop) 'services/reset_url_web.dart';
import 'services/url_bar_stub.dart'
    if (dart.library.js_interop) 'services/url_bar_web.dart';
import 'session.dart';
import 'yantra_launch.dart';

const String kThemePrefKey = 'etp.theme';

ThemeMode themeFromPref(String? v) =>
    v == 'light' ? ThemeMode.light : ThemeMode.dark;

void main() {
  // Before `runApp`, or the engine has already claimed browser history. The
  // app writes the address bar itself - see `assessment/route_url.dart`.
  takeOverBrowserHistory();
  runApp(const EtharaAssessmentApp());
}

/// Assessment v2, as a standalone app.
///
/// The whole product against the Odoo `etp_assessment_pro` REST API: sign in,
/// author generators, review drafts, launch assessments, sit an exam, release
/// results. It holds no business rules - every gate, score and threshold is the
/// module's, reached over `/api/v1/...`.
class EtharaAssessmentApp extends StatefulWidget {
  const EtharaAssessmentApp({super.key, this.pageUrl, this.session});

  /// The address the app was opened at: `Uri.base` unless a test says
  /// otherwise (on the VM `Uri.base` is a file path).
  final Uri? pageUrl;

  /// The session to drive; a fresh one unless a test supplies its own.
  final Session? session;

  @override
  State<EtharaAssessmentApp> createState() => _EtharaAssessmentAppState();
}

class _EtharaAssessmentAppState extends State<EtharaAssessmentApp> {
  late final Session _session = widget.session ?? Session();

  late final Uri _page = widget.pageUrl ?? Uri.base;

  /// Read ONCE at startup, not on every build.
  ///
  /// `Uri.base` changes as the app navigates, so re-reading it later would let
  /// a candidate who finished their exam and clicked away be yanked back into
  /// the runner on the next rebuild.
  // Not final: a Yantra launch learns the token from the redeem, not the URL.
  late String? _examToken = examTokenFrom(_page);

  /// The password-reset token, read the same way and for the same reason.
  ///
  /// MUTABLE, unlike the exam token: finishing a reset has to clear it, or a
  /// refresh lands back on a form whose token has just been burned and reports
  /// an expired link to somebody who has only this second used it.
  late String? _resetToken = resetTokenFrom(_page);

  /// Dark by default: this is an operator console that people keep open all
  /// day, and the token set was designed dark-first.
  ///
  /// The visitor's last choice survives a reload (`etp.theme`); anything other
  /// than "light" - nothing stored, garbage, blocked storage - is dark.
  ThemeMode _mode = themeFromPref(readPref(kThemePrefKey));

  /// Leave the reset page for the sign-in form.
  ///
  /// The URL is rewritten as well as the field. Without that a refresh puts
  /// the token back - and it has just been burned, so the page would tell
  /// somebody who succeeded a second ago that their link had expired.
  void _leaveReset() {
    setState(() => _resetToken = null);
    clearResetTokenFromUrl();
  }

  @override
  void initState() {
    super.initState();
    _session.addListener(_rebuild);
    // Resume a session the previous page load left behind, BEFORE the first
    // paint decides between the login form and the console. Without this a
    // refresh looked like a sign-out: the token lived only in memory, so the
    // VM restart lost it while the server session stayed open.
    // Opened from Yantra: the one-time ticket signs in instead. It leaves the
    // address bar at once, so neither a reload nor history replays it.
    final String? ticket = launchTicketFrom(_page);
    if (ticket != null) {
      writeBrowserUrl('/', push: false);
      unawaited(_session.launch(ticket, onGrant: _openGrant));
    } else {
      unawaited(_session.restore());
    }
    // Keep the context-free token lookup in step with the app's mode. The
    // chart painters and cell builders read `PortalTokens.current`, which has
    // no BuildContext to resolve brightness from.
    PortalTokens.overrideBrightness = _mode == ThemeMode.dark
        ? Brightness.dark
        : Brightness.light;
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  /// Point the app at what the ticket opened, before the console is built:
  /// the sitting for a candidate (a reload is then the invitation link), the
  /// page asked for by staff.
  void _openGrant(LaunchGrant grant) {
    writeBrowserUrl(
      afterLaunchPath(examToken: grant.examToken, next: grant.next),
      push: false,
    );
    _examToken = grant.examToken ?? _examToken;
  }

  @override
  void dispose() {
    _session.removeListener(_rebuild);
    if (widget.session == null) _session.dispose();
    super.dispose();
  }

  void _toggleTheme() {
    setState(() {
      _mode = _mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
      PortalTokens.overrideBrightness = _mode == ThemeMode.dark
          ? Brightness.dark
          : Brightness.light;
    });
    writePref(kThemePrefKey, _mode == ThemeMode.dark ? 'dark' : 'light');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kAppName,
      debugShowCheckedModeBanner: false,
      themeMode: _mode,
      // `PortalTokens.of` resolves off `Theme.brightness`, so setting the two
      // schemes here is all that is needed for the whole token set to follow.
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: PortalTokens.light.bgApp,
        fontFamilyFallback: PortalType.fallback,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: PortalTokens.dark.bgApp,
        fontFamilyFallback: PortalType.fallback,
        useMaterial3: true,
      ),
      // A RESET LINK OUTRANKS EVERYTHING, including a live session. Whoever
      // opened it is holding a one-time token that expires in an hour, and
      // showing them the console instead - because a stale session happened to
      // resume first - strands them with no route to the form the email sent
      // them to.
      home: _resetToken != null
          ? ResetPasswordScreen(
              token: _resetToken!,
              onToggleTheme: _toggleTheme,
              isDark: _mode == ThemeMode.dark,
              onDone: _leaveReset,
            )
          : switch ((_session.signedIn, _session.restoring)) {
              (true, _) => AppShell(
                // Keyed on the user so signing in as somebody else builds a NEW
                // shell, and therefore a new store. Without this the previous
                // user's cached assessments would survive the switch.
                key: ValueKey<String>(_session.uid),
                session: _session,
                examToken: _examToken,
                url: const BrowserUrlBar(),
                onToggleTheme: _toggleTheme,
                isDark: _mode == ThemeMode.dark,
              ),
              // Verifying a stored token. Neither surface is correct yet: the login
              // form would be a lie that gets replaced a moment later, which is the
              // flash that made a refresh feel like a sign-out.
              (false, true) => Resuming(session: _session),
              (false, false) => LoginScreen(
                session: _session,
                onToggleTheme: _toggleTheme,
                isDark: _mode == ThemeMode.dark,
              ),
            },
    );
  }
}

/// The gap between "a token was found" and "the server vouched for it".
///
/// Bare for the one round trip it usually lasts - a spinner on the app
/// background, no branding: anything more reads as a page in its own right.
/// A server that does not answer keeps it up (the saved login is kept and
/// tried again, [Session.restore]), so then it says so, and offers the
/// sign-in form to whoever would rather not wait.
class Resuming extends StatelessWidget {
  const Resuming({super.key, required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ListenableBuilder(
        listenable: session,
        builder: (BuildContext context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            if (session.reconnecting) ...<Widget>[
              const SizedBox(height: 16),
              Text(
                'No connection to the server. Trying again automatically.',
                textAlign: TextAlign.center,
                style: context.type.bodySecondary,
              ),
              const SizedBox(height: 12),
              Btn('Sign in again', onPressed: session.stopReconnecting),
            ],
          ],
        ),
      ),
    ),
  );
}
