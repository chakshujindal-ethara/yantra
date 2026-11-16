// The candidate gate outcomes - HANDOVER §4.6.
//
// One tokenised link resolves to exactly one of these; the live paths are the
// exam screens themselves, so only the dead ends live here.
//
// The rule this file encodes: EVERY DEAD END IS A DESIGNED SCREEN WITH AN
// ACTION - what happened, in plain words, and somewhere to go. No bare error.
import 'package:flutter/material.dart';

import '../../../services/seb_stub.dart'
    if (dart.library.js_interop) '../../../services/seb_web.dart';
import '../../domain/enums.dart';
import '../../domain/models.dart' show SebLinks;
import '../../widgets/buttons.dart';
import '../../widgets/marks.dart';
import '../../theme.dart';
import '../../nav.dart';
import '../../../yantra_launch.dart' show yantraReturnUrl;

/// The wire strings are the SERVER's `outcome` vocabulary verbatim
/// (`candidate.py:40-46`), so [parse] can be handed the envelope's value
/// directly. They used to read `login`/`wrong`, which matched nothing, so the
/// two most common recoverable states - not signed in, and signed in as
/// somebody else - both rendered as "this link does not work".
enum GateKind {
  invalid('invalid'),
  login('login_required'),
  wrong('wrong_candidate'),
  closed('closed'),

  /// Locked mode is on and this page is not Safe Exam Browser. Wins over the
  /// sign-in gate on the server, so the candidate signs in once, inside SEB.
  sebRequired('seb_required'),

  /// Not one of the eight link outcomes: the answer-review screen substitutes
  /// this whenever the result has not been released.
  notReleased('not_released');

  final String wire;

  const GateKind(this.wire);

  static GateKind parse(String? v) => values.firstWhere(
    (GateKind k) => k.wire == v,
    // An unrecognised kind falls through to `invalid`, which is the
    // honest answer: the app does not know what this link is.
    orElse: () => GateKind.invalid,
  );
}

class GateScreen extends StatelessWidget {
  final GateKind kind;

  /// Ends the session, for the two gates whose way out is a different account.
  ///
  /// Null on the gates that have nothing to sign out of (invalid, closed, not
  /// released), where the assessment list IS the destination.
  final VoidCallback? onSignOut;

  /// Where [GateKind.sebRequired]'s two buttons go.
  final SebLinks seb;

  const GateScreen({
    super.key,
    required this.kind,
    this.onSignOut,
    this.seb = const SebLinks(),
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final _GateCopy c = _copy(kind);
    final ToneColors tone = ToneColors.of(t, c.tone);
    void toMyAssessments() => context.nav.reset(const MyAssessments());
    // THE BUTTON DOES WHAT ITS LABEL SAYS. "Sign in" and "Switch account" end
    // the session: the list would sit behind the very session this gate
    // reports missing, or belong to somebody else. The secondary action stays
    // the list: it is the "never mind" on the one gate that offers two ways
    // out.
    final VoidCallback onAction = kind == GateKind.sebRequired
        ? () => navigateTo(seb.launchUrl)
        : (kind == GateKind.login || kind == GateKind.wrong) &&
              onSignOut != null
        ? onSignOut!
        : toMyAssessments;
    final VoidCallback onSecondary = kind == GateKind.sebRequired
        ? () => openInNewTab(seb.downloadUrl)
        : toMyAssessments;
    // Yantra: a worker who came from Yantra gets the way back on every dead
    // end; Yantra is where their next step is.
    final String? yantra = yantraReturnUrl();

    return Scaffold(
      backgroundColor: t.bgSubtle,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 54,
                  height: 54,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: tone.bg,
                    borderRadius: const BorderRadius.all(Radius.circular(14)),
                  ),
                  child: Icon(c.icon, size: 26, color: tone.fg),
                ),
                const SizedBox(height: 13),
                Text(
                  c.title,
                  textAlign: TextAlign.center,
                  style: context.type.body.copyWith(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 13),
                Text(
                  c.body,
                  textAlign: TextAlign.center,
                  style: context.type.bodySecondary.copyWith(
                    fontSize: 13.5,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 13),
                // Wrap, not Row: the "wrong candidate" and Safe Exam Browser
                // gates carry two actions, and two large buttons side by side
                // overflow the card on a narrow viewport. A gate is a dead end
                // whose whole job is to offer its one way out, so its actions
                // must never be the thing that is clipped.
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    if (yantra != null)
                      Btn(
                        'Back to Yantra',
                        size: BtnSize.lg,
                        icon: Icons.arrow_back,
                        onPressed: () => navigateTo(yantra),
                      ),
                    if (c.secondary != null)
                      Btn(
                        c.secondary!,
                        size: BtnSize.lg,
                        onPressed: onSecondary,
                      ),
                    Btn.primary(
                      c.action,
                      size: BtnSize.lg,
                      onPressed: onAction,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  _GateCopy _copy(GateKind k) => switch (k) {
    GateKind.invalid => const _GateCopy(
      icon: Icons.link_off,
      tone: Tone.bad,
      title: 'This link does not work',
      body:
          'The link is unknown or has been revoked. If somebody sent it '
          'to you recently, ask them to send it again - a new link is '
          'issued each time.',
      action: 'Go to my assessments',
    ),
    GateKind.login => const _GateCopy(
      icon: Icons.lock_outline,
      tone: Tone.info,
      title: 'Sign in to continue',
      body:
          'This link is valid, but the request carries no session. Sign '
          'in with the account the invitation was sent to and open the '
          'link again.',
      action: 'Sign in',
    ),
    GateKind.wrong => const _GateCopy(
      icon: Icons.person_off_outlined,
      tone: Tone.warn,
      title: 'This link belongs to somebody else',
      body:
          'You are signed in as a different person from the invited '
          'candidate. Sign out and back in as the invited account, or ask '
          'for your own link.',
      action: 'Switch account',
      secondary: 'My assessments',
    ),
    // No "not open yet": a draft paper reads as `invalid` (owner rule, a
    // draft is never shown to a candidate), so closed only ever means closed.
    GateKind.closed => const _GateCopy(
      icon: Icons.event_busy_outlined,
      tone: Tone.inert,
      title: 'This assessment is closed',
      body: 'This assessment has closed.',
      action: 'Go to my assessments',
    ),
    GateKind.sebRequired => const _GateCopy(
      icon: Icons.lock_outline,
      tone: Tone.info,
      title: 'Open this assessment in Safe Exam Browser',
      body:
          'This assessment runs only in Safe Exam Browser, a free app that '
          'keeps your computer locked to the exam until you submit.\n\n'
          'If Safe Exam Browser is not installed yet, download and install '
          'it, then press Open in Safe Exam Browser again.',
      action: 'Open in Safe Exam Browser',
      secondary: 'Download Safe Exam Browser',
    ),
    GateKind.notReleased => const _GateCopy(
      icon: Icons.lock_clock_outlined,
      tone: Tone.info,
      title: 'Results not released yet',
      body:
          'Your answers are recorded, and your result is held until an '
          'administrator releases it. Nothing is missing - come back once '
          'you are told it is out.',
      action: 'Go to my assessments',
    ),
  };
}

class _GateCopy {
  final IconData icon;
  final Tone tone;
  final String title;
  final String body;
  final String action;
  final String? secondary;

  const _GateCopy({
    required this.icon,
    required this.tone,
    required this.title,
    required this.body,
    required this.action,
    this.secondary,
  });
}
