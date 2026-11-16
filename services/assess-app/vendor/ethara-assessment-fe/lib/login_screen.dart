import 'package:flutter/material.dart';

import 'assessment/domain/enums.dart';
import 'assessment/theme.dart';
import 'assessment/widgets/buttons.dart';
import 'assessment/widgets/feedback.dart';
import 'deep_link.dart' show examTokenFrom;
import 'password_reset.dart' show ResetRequest, showResetRequestSheet;
import 'services/seb_stub.dart'
    if (dart.library.js_interop) 'services/seb_web.dart'
    show navigateTo;
import 'session.dart';
import 'widgets/ethara_mark.dart';
import 'yantra_launch.dart' show continueWithYantraUri;

/// The sign-in screen.
///
/// FOLLOWS THE HOST PORTAL (`ops-ethara-frontend/lib/screens/login_screen.dart`)
/// so a user moving between the two products does not meet a different front
/// door, and is drawn in this app's own vocabulary - `PortalTokens`,
/// `context.type`, `Radii`, `Btn` - never raw Material defaults.
class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.session,
    this.onToggleTheme,
    this.isDark = true,
    this.continueWithYantra = continueWithYantraUri,
  });

  final Session session;

  /// Yantra's address for "Continue with Yantra", or null for none. A Yantra
  /// worker has no password here; Yantra opens the assessment for them.
  final Uri? Function() continueWithYantra;

  /// The same toggle `AppShell` gets. The host portal offers it before sign-in
  /// too, and somebody who prefers the light theme should not have to
  /// authenticate in the dark one first to reach the switch.
  final VoidCallback? onToggleTheme;
  final bool isDark;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _login = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final FocusNode _passwordFocus = FocusNode();
  bool _obscure = true;

  /// Why a reset request was refused, shown on the card until the next action.
  ///
  /// Shares the banner slot with a failed sign-in: both are the same kind of
  /// thing - this form was not accepted, here is why - and giving them two
  /// slots would let the card show two red boxes at once.
  String? _refusal;

  @override
  void dispose() {
    _login.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (widget.session.busy) return;
    if (_login.text.trim().isEmpty || _password.text.isEmpty) return;
    final bool ok = await widget.session.signIn(
      _login.text.trim(),
      _password.text,
    );
    if (ok || !mounted) return;

    // GIVE THE CARET BACK after a refusal.
    //
    // A candidate shown "Access Denied" could not retype their password: the
    // box looked normal, swallowed every keystroke, and only a page reload
    // freed it. The field is neither disabled nor cleared at that point - it
    // is UNFOCUSED, and on web a keystroke with nothing focused goes to the
    // document. Flutter drops the focus on the way IN to the request, by two
    // routes: `EditableText` unfocuses on the Enter key before it calls
    // `onSubmitted` (`editable_text.dart:3872`), and its tap-outside action
    // unfocuses for every pointer kind on web when the Sign in button is
    // pressed (`editable_text.dart:6777-6807`). Nothing hands it back, so the
    // form returns with the primary focus on the route's scope. Restoring it
    // here is what closes the report - NOT dropping the `enabled:` argument
    // below, which is only a second, later cause of an already-lost focus.
    //
    // AFTER the next frame, not now. `enabled: !s.busy` means the field is
    // still built disabled at this instant - `signIn`'s `finally` cleared the
    // flag but the rebuild it scheduled has not run - and a disabled
    // `TextField` holds `canRequestFocus == false`
    // (`material/text_field.dart:1287,1318`), which makes `requestFocus()` a
    // silent no-op. That scheduled frame is the one that re-enables it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _passwordFocus.requestFocus();
    });
  }

  Future<void> _forgotPassword() async {
    // Seeded with whatever is already typed: the address is almost always
    // right and the password is what was forgotten.
    final ResetRequest? result = await showResetRequestSheet(
      context,
      email: _login.text.trim(),
    );
    if (result == null || !mounted) return;

    if (result.error != null) {
      // ON THE CARD, not in the dialog. A refusal is something to correct, and
      // it belongs beside the field you correct it in - which is this one, the
      // dialog having closed. It shares the slot with a failed sign-in for the
      // same reason.
      setState(() => _refusal = result.error);
      return;
    }

    setState(() => _refusal = null);
    // A TOAST AT THE FOOT OF THE WINDOW, and the SERVER'S sentence rather than
    // one written here: it is deliberately identical whether or not an account
    // exists, and restating it locally is how that property gets quietly
    // broken by a well-meaning edit.
    //
    // `ScaffoldMessenger` rather than the console's own `Toaster`, which is
    // mounted inside `AssessmentSection` and so does not exist until after
    // sign-in - and this is the one screen that runs before it.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.sent!),
        behavior: SnackBarBehavior.fixed,
        duration: const Duration(seconds: 6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;

    return Scaffold(
      backgroundColor: t.bgSubtle,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            final bool wide = c.maxWidth >= Layout.twoColumn;
            final Widget card = Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (!wide) ...<Widget>[
                        _brandRow(t, compact: true),
                        const SizedBox(height: 32),
                      ],
                      Container(
                        padding: const EdgeInsets.all(32),
                        decoration: BoxDecoration(
                          color: t.bgApp,
                          borderRadius: Radii.panel,
                          border: Border.all(color: t.border),
                        ),
                        child: _form(t),
                      ),
                    ],
                  ),
                ),
              ),
            );

            final Widget body = wide
                ? Row(
                    children: <Widget>[
                      Expanded(child: _brandPane(t)),
                      Expanded(child: card),
                    ],
                  )
                : card;
            if (widget.onToggleTheme == null) return body;
            // Stacked, not in a Scaffold app bar: the brand pane is a
            // full-bleed gradient and an AppBar would cut a band out of it.
            return Stack(
              children: <Widget>[
                Positioned.fill(child: body),
                Positioned(
                  top: 12,
                  right: 16,
                  child: IconBtn(
                    widget.isDark
                        ? Icons.light_mode_outlined
                        : Icons.dark_mode_outlined,
                    tooltip: widget.isDark
                        ? 'Switch to light'
                        : 'Switch to dark',
                    onPressed: widget.onToggleTheme,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Left pane: the brand on the page canvas under a restrained magenta wash.
  Widget _brandPane(AppTokens t) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(-0.1, -0.2),
          radius: 1.1,
          colors: <Color>[
            t.primary.withValues(alpha: t.isDark ? 0.10 : 0.06),
            t.bgSubtle.withValues(alpha: 0),
          ],
        ),
      ),
      child: Center(child: _brandRow(t)),
    );
  }

  Widget _brandRow(AppTokens t, {bool compact = false}) {
    final double markSize = compact ? 40 : 96;
    final double textSize = compact ? 26 : 44;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            EtharaMark(
              size: markSize,
              color: t.textPrimary,
              // Only the large pane mark revolves. At 40px in the compact
              // layout it sits directly above the form and would read as a
              // spinner rather than as the brand.
              spin: !compact,
            ),
            SizedBox(width: compact ? 10 : 20),
            Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(
                    text: 'Ethara',
                    style: PortalType.ui(
                      fontSize: textSize,
                      fontWeight: FontWeight.w700,
                      color: t.textPrimary,
                      letterSpacing: -1,
                    ),
                  ),
                  TextSpan(
                    text: '.AI',
                    style: PortalType.ui(
                      fontSize: textSize,
                      fontWeight: FontWeight.w700,
                      color: t.primary,
                      letterSpacing: -1,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _form(AppTokens t) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (BuildContext context, _) {
        final Session s = widget.session;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('Sign in', style: context.type.sheetTitle),
            // WHY THEY ARE HERE, when they arrived on an invitation.
            //
            // A candidate opening their invite link met a bare "Sign in" with
            // nothing tying it to the assessment they were invited to - the
            // same screen an administrator sees. It cannot NAME the assessment:
            // resolving a token to a title before anyone has authenticated
            // would hand the paper's existence to whoever holds the link, and
            // the exam routes refuse it for exactly that reason. Saying why
            // they are signing in costs nothing and leaks nothing.
            if (examTokenFrom(Uri.base) != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                'Sign in to open the assessment you were invited to.',
                style: context.type.bodySecondary,
              ),
            ],
            const SizedBox(height: 20),
            // A sign-in failure or a refused reset - one slot, because they
            // are the same kind of thing and two would stack.
            if (s.error != null || _refusal != null) ...<Widget>[
              // A LIVE REGION, or the refusal is drawn and never spoken.
              //
              // `Notice` is a Container/Row/Text.rich with no semantics of its
              // own, so the banner appearing told a screen reader nothing -
              // and `_submit` then drives the accessibility cursor back onto
              // the password field on the next frame, so the only thing read
              // out is that field's hint, "Your password". A candidate on
              // VoiceOver or NVDA retyped the same password until the
              // gateway's attempt limit stopped them, never having been told
              // the sign-in was refused at all.
              //
              // `label` + `excludeSemantics`, not a bare `liveRegion:` wrapper:
              // a region with no label of its own has nothing to announce, and
              // `Notice` has several children so the annotation cannot merge
              // into one of them. The same shape the exam clock uses.
              Semantics(
                liveRegion: true,
                label: s.error ?? _refusal!,
                excludeSemantics: true,
                child: Notice(tone: Tone.bad, text: s.error ?? _refusal!),
              ),
              const SizedBox(height: 16),
            ],
            Text('Email address', style: context.type.fieldLabel),
            const SizedBox(height: 6),
            AuthInput(
              controller: _login,
              enabled: !s.busy,
              hint: 'you@ethara.ai',
              keyboardType: TextInputType.emailAddress,
              onSubmitted: (_) => _passwordFocus.requestFocus(),
            ),
            const SizedBox(height: 16),
            Text('Password', style: context.type.fieldLabel),
            const SizedBox(height: 6),
            AuthInput(
              controller: _password,
              enabled: !s.busy,
              focusNode: _passwordFocus,
              hint: 'Your password',
              obscure: _obscure,
              onSubmitted: (_) => _submit(),
              suffix: IconButton(
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                  color: t.textMuted,
                ),
                tooltip: _obscure ? 'Show password' : 'Hide password',
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            const SizedBox(height: 8),
            // Right-aligned under the password field, which is where a person
            // looks the moment the one they typed is refused.
            Align(
              alignment: Alignment.centerRight,
              child: LinkBtn(
                'Forgot password?',
                // MAGENTA AT REST, not on hover, and not semibold. `LinkBtn`
                // defaults to a bold body face that only turns primary under
                // the cursor, which reads as a heading sitting under the
                // field rather than as the one thing on this card you can
                // click when the password you typed is refused. The Workflow
                // Manager's sign-in - the same front door under another name -
                // has always drawn it this way.
                style: context.type.body.copyWith(color: t.primary),
                // DEAD DURING A COOLDOWN, and this link specifically. A
                // rate-limited refusal is not a wrong password, and this is
                // the one control on the card that looks like the answer to
                // one - on 2026-09-17 several hundred candidates followed it
                // and produced 679 reset emails for a problem no password
                // could fix. The server now says so and sends `Retry-After`;
                // this is the half that makes the client act on it.
                onPressed: s.busy || s.cooldownSeconds > 0
                    ? null
                    : _forgotPassword,
              ),
            ),
            const SizedBox(height: 14),
            Btn.primary(
              // The countdown IS the explanation. A disabled button with no
              // reason reads as a broken form; one that says how long reads as
              // a queue, which is what it is.
              s.busy
                  ? 'Signing in...'
                  : s.cooldownSeconds > 0
                  ? 'Try again in ${s.cooldownSeconds}s'
                  : 'Sign in',
              size: BtnSize.lg,
              icon: Icons.login,
              onPressed: s.busy || s.cooldownSeconds > 0 ? null : _submit,
            ),
            if (widget.continueWithYantra() case final Uri yantra) ...<Widget>[
              const SizedBox(height: 10),
              Btn(
                'Continue with Yantra',
                size: BtnSize.lg,
                icon: Icons.arrow_forward,
                onPressed: () => navigateTo(yantra.toString()),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// A text field in the app's own shape, so the login page does not introduce a
/// second input style.
///
/// PUBLIC because the reset-password page is the same front door under another
/// name, and a fourth private copy of this field (there are already three -
/// see `account_screen.dart`) is how the two pages start looking different.
class AuthInput extends StatelessWidget {
  const AuthInput({
    super.key,
    required this.controller,
    required this.hint,
    this.enabled = true,
    this.obscure = false,
    this.focusNode,
    this.keyboardType,
    this.onSubmitted,
    this.suffix,
    this.prefix,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String hint;
  final bool enabled;
  final bool obscure;
  final FocusNode? focusNode;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onSubmitted;
  final Widget? suffix;

  /// A leading icon inside the field. Used by the reset dialog, where the one
  /// input on the card would otherwise be indistinguishable from a password
  /// box at a glance.
  final Widget? prefix;

  /// Focus the field as soon as it appears. For a dialog whose only control
  /// is this field, so it can be typed into without a click first.
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return SizedBox(
      height: 40,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        enabled: enabled,
        autofocus: autofocus,
        obscureText: obscure,
        keyboardType: keyboardType,
        onSubmitted: onSubmitted,
        style: context.type.body,
        cursorColor: t.primary,
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: context.type.bodyMuted,
          filled: true,
          fillColor: t.bgSubtle,
          suffixIcon: suffix,
          prefixIcon: prefix,
          // Without a tight box the default 48px leading gutter pushes the
          // hint away from the icon and the field stops looking like one
          // control.
          prefixIconConstraints: const BoxConstraints(minWidth: 36),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          border: OutlineInputBorder(
            borderRadius: Radii.input,
            borderSide: BorderSide(color: t.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: Radii.input,
            borderSide: BorderSide(color: t.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: Radii.input,
            borderSide: BorderSide(color: t.primary),
          ),
        ),
      ),
    );
  }
}
