/// Password reset: asking for a link, and setting a new password from one.
///
/// WHY THIS IS ITS OWN FILE AND NOT PART OF THE APP SHELL. Both surfaces are
/// reachable ONLY when nobody is signed in - one from the login card, the other
/// from an emailed URL - so neither can use `AppStore`, the sidebar, or
/// `ToastHost`, all of which are mounted inside `AssessmentSection` after
/// authentication. They talk to [ApiClient] directly and say everything they
/// have to say inside their own card.
///
/// The server is the one that decides the wording. Both handlers render
/// `message` off the response rather than a local string, because the
/// forgot-password answer is deliberately identical whether or not an account
/// exists - a locally written "we've sent you an email" would quietly turn an
/// unauthenticated route into an account-existence oracle.
library;

import 'package:flutter/material.dart';

import 'assessment/data/api_client.dart';
import 'assessment/domain/enums.dart';
import 'assessment/theme.dart';
import 'assessment/widgets/buttons.dart';
import 'assessment/widgets/feedback.dart';
import 'login_screen.dart' show AuthInput;
import 'widgets/ethara_mark.dart';

/// The reset ROUTE's own floor (`MIN_PASSWORD_LEN` in
/// `controllers/api/auth.py`), checked before the round trip. The account
/// policy the write then applies is stricter - see [kPasswordRules].
const int kMinPasswordLength = 8;

/// One checklist line: what it says, and whether a password meets it.
typedef PasswordRule = ({String label, bool Function(String) met});

/// The checklist for [minLength] and the classes in [require] (`upper`,
/// `lower`, `digit`, `special`; anything else is skipped), always in the
/// order the server checks them.
List<PasswordRule> passwordRulesFor(int minLength, Set<String> require) =>
    <PasswordRule>[
      (
        label: 'At least $minLength characters',
        met: (String p) => p.runes.length >= minLength,
      ),
      if (require.contains('upper'))
        (
          label: 'One uppercase letter',
          met: (String p) => p.contains(RegExp('[A-Z]')),
        ),
      if (require.contains('lower'))
        (
          label: 'One lowercase letter',
          met: (String p) => p.contains(RegExp('[a-z]')),
        ),
      if (require.contains('digit'))
        (
          label: 'One number',
          met: (String p) => p.contains(RegExp(r'\p{Nd}', unicode: true)),
        ),
      if (require.contains('special'))
        (
          label: 'One special character, e.g. ! @ # or a space',
          met: (String p) => p.contains(RegExp('[^A-Za-z0-9]')),
        ),
    ];

/// What the server demands of a new password, in the order it checks.
///
/// THE FALLBACK until `/auth/password_policy` answers (see
/// [fetchPasswordPolicy]), and what a backend without that route gets. It
/// mirrors the policy by hand (ethara-etp):
/// * length - `auth_password_policy.minlength` is 12
///   (`custom_addons/etp_security/data/security_params.xml:3-6`), refused by
///   `src/addons/auth_password_policy/models/res_users.py:25-30` as "must
///   contain at least 12 characters and only has N", and again by
///   `custom_addons/etp_security/models/res_users.py:7,25`;
/// * the four classes - the same regexes as
///   `custom_addons/etp_security/models/res_users.py:8-13`.
/// Python counts code points and its `\d` is any Unicode digit, hence
/// `runes` and `\p{Nd}`. A guide, never a gate: the server stays the
/// authority and its own refusal is still what the form shows.
final List<PasswordRule> kPasswordRules = passwordRulesFor(12, const <String>{
  'upper',
  'lower',
  'digit',
  'special',
});

/// The server's policy: its length floor, and the checklist built from it.
typedef PasswordPolicy = ({int minLength, List<PasswordRule> rules});

Future<PasswordPolicy?>? _policy;

/// `/auth/password_policy`, fetched at most once per session and shared by
/// the reset page and the Account screen.
///
/// Null when the call failed or answered something unreadable (an older
/// backend has no such route): the caller keeps [kPasswordRules]. A failure
/// is not cached, so the next screen that opens asks again.
Future<PasswordPolicy?> fetchPasswordPolicy(ApiClient api) =>
    _policy ??= () async {
      try {
        final Map<String, dynamic> data = await api.passwordPolicy();
        final Object? min = data['min_length'];
        final Object? require = data['require'];
        if (min is num && min >= 1 && require is List<dynamic>) {
          return (
            minLength: min.toInt(),
            rules: passwordRulesFor(min.toInt(), <String>{
              for (final Object? r in require) '$r',
            }),
          );
        }
      } catch (_) {
        // Fall through: the static list is the answer.
      }
      _policy = null;
      return null;
    }();

@visibleForTesting
void resetPasswordPolicyCache() => _policy = null;

/// Loose on purpose, matching the server's own shape check: this is here to
/// catch a typo, not to adjudicate what an address may look like.
bool looksLikeEmail(String value) =>
    RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value.trim());

/// What a reset request came back with.
///
/// TWO OUTCOMES, TWO PLACES. The Workflow Manager - the same front door under
/// another name - puts the refusal on the SIGN-IN CARD and the confirmation in
/// a toast at the foot of the window, and neither inside the dialog. That is
/// the right split: a refusal is something to correct next to the field you
/// correct it in, and a confirmation is the last thing you read before leaving
/// for your inbox, so it must outlive the dialog it was asked from.
typedef ResetRequest = ({String? sent, String? error});

/// Ask for a reset link. Null when the dialog was dismissed without sending.
///
/// NOT `showSheet`. That is the console's full-width sheet - 640px, a header
/// band and a close X - and this is a one-field question on a sign-in page.
/// The reference draws a narrow card with the two buttons on its own footer
/// row, and matching it matters here more than reusing the widget: the two
/// products share this screen and a user moving between them should not meet
/// two different dialogs asking the same thing.
Future<ResetRequest?> showResetRequestSheet(
  BuildContext context, {
  String email = '',
}) => showDialog<ResetRequest>(
  context: context,
  barrierColor: const Color(0x8C030213),
  builder: (BuildContext ctx) {
    final AppTokens t = ctx.tokens;
    return Dialog(
      backgroundColor: const Color(0x00000000),
      insetPadding: const EdgeInsets.all(22),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 375),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: t.bgApp,
            borderRadius: Radii.sheet,
            border: Border.all(color: t.border),
          ),
          child: _ResetRequestBody(
            controller: TextEditingController(text: email),
          ),
        ),
      ),
    );
  },
);

class _ResetRequestBody extends StatefulWidget {
  const _ResetRequestBody({required this.controller});

  final TextEditingController controller;

  @override
  State<_ResetRequestBody> createState() => _ResetRequestBodyState();
}

class _ResetRequestBodyState extends State<_ResetRequestBody> {
  final ApiClient _api = ApiClient();
  bool _busy = false;

  void _close(ResetRequest result) {
    if (mounted) popIfCurrent(context, result);
  }

  Future<void> _send() async {
    final String email = widget.controller.text.trim();
    // Checked here as well as on the server, because a client-side-only check
    // is not a check and a server-side-only one costs a round trip to say
    // something the form already knew. The wording is the server's own, so the
    // two paths cannot say it differently.
    if (!looksLikeEmail(email)) {
      _close((sent: null, error: 'Please enter a valid email address.'));
      return;
    }
    setState(() => _busy = true);
    try {
      final Map<String, dynamic> res = await _api.forgotPassword(email);
      _close((
        sent:
            (res['message'] as String?) ??
            'If an account exists with this email, a password reset link has '
                'been sent.',
        error: null,
      ));
    } on ApiError catch (e) {
      // The server's own words - it explains a rate limit, or an address it
      // will not mail, better than anything restated here.
      _close((sent: null, error: e.message));
    } catch (e) {
      _close((sent: null, error: 'Could not reach the server. $e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text('Reset your password', style: context.type.sheetTitle),
        const SizedBox(height: 8),
        Text(
          'We will email you a link to set a new password.',
          style: context.type.bodySecondary,
        ),
        const SizedBox(height: 18),
        AuthInput(
          controller: widget.controller,
          enabled: !_busy,
          hint: 'you@ethara.ai',
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          onSubmitted: (_) => _send(),
          // The field carries the only icon on this card, so it reads as an
          // address rather than as a second password box.
          prefix: Icon(Icons.mail_outline, size: 17, color: t.textMuted),
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            Btn(
              'Cancel',
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 8),
            Btn.primary(
              'Send Link',
              busy: _busy,
              tooltip: 'Email a one-time link to set a new password.',
              onPressed: _busy ? null : _send,
            ),
          ],
        ),
      ],
    );
  }
}

/// The page an emailed link lands on.
///
/// STANDS ALONE, ahead of the login screen. Whoever opens it cannot sign in -
/// that is the whole reason they are here - so routing them past a login form
/// first would be asking for the thing they came to replace.
class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({
    super.key,
    required this.token,
    required this.onDone,
    this.onToggleTheme,
    this.isDark = true,
    this.api,
  });

  /// The client to call. Null builds the default one; tests pass a fake.
  final ApiClient? api;

  /// The token from the URL. EMPTY means the link reached this page without
  /// one, which is a different failure from a token the server rejects and is
  /// worth saying so.
  final String token;

  /// Leave for the sign-in screen. The caller clears the URL so a refresh does
  /// not land back here on a token that has just been burned.
  final VoidCallback onDone;

  final VoidCallback? onToggleTheme;
  final bool isDark;

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  final FocusNode _confirmFocus = FocusNode();
  bool _obscure = true;
  bool _busy = false;
  String? _error;
  String? _done;
  List<PasswordRule> _rules = kPasswordRules;

  @override
  void initState() {
    super.initState();
    fetchPasswordPolicy(_api).then((PasswordPolicy? p) {
      if (mounted && p != null) setState(() => _rules = p.rules);
    });
  }

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  /// The local half of the rules, so a mistake is caught without a round trip.
  /// The server enforces all of it again regardless.
  String? _localRefusal() {
    if (widget.token.isEmpty) {
      return 'This reset link is incomplete. Request a new one from the sign-in '
          'page.';
    }
    if (_password.text.isEmpty) return 'Enter a new password.';
    if (_password.text.length < kMinPasswordLength) {
      return 'Your new password must be at least $kMinPasswordLength '
          'characters.';
    }
    if (_password.text != _confirm.text) {
      return 'The two passwords do not match.';
    }
    return null;
  }

  Future<void> _submit() async {
    final String? refusal = _localRefusal();
    if (refusal != null) {
      setState(() => _error = refusal);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> res = await _api.resetPassword(
        token: widget.token,
        newPassword: _password.text,
        confirmPassword: _confirm.text,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _done =
            (res['message'] as String?) ??
            'Password has been reset. Sign in with your new password.';
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not reach the server. $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Scaffold(
      backgroundColor: t.bgSubtle,
      body: SafeArea(
        child: Stack(
          children: <Widget>[
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const EtharaMark(size: 44),
                      const SizedBox(height: 22),
                      Container(
                        padding: const EdgeInsets.all(32),
                        decoration: BoxDecoration(
                          color: t.bgApp,
                          borderRadius: Radii.panel,
                          border: Border.all(color: t.border),
                        ),
                        child: _done == null ? _form(t) : _finished(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (widget.onToggleTheme != null)
              Positioned(
                top: 12,
                right: 16,
                child: IconBtn(
                  widget.isDark
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
                  tooltip: widget.isDark ? 'Light theme' : 'Dark theme',
                  onPressed: widget.onToggleTheme,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _form(AppTokens t) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Text('Set a new password', style: context.type.sheetTitle),
      const SizedBox(height: 20),
      if (_error != null) ...<Widget>[
        Notice(tone: Tone.bad, text: _error!),
        const SizedBox(height: 16),
      ],
      Text('New password', style: context.type.fieldLabel),
      const SizedBox(height: 6),
      AuthInput(
        controller: _password,
        enabled: !_busy,
        hint: _rules.first.label,
        obscure: _obscure,
        onSubmitted: (_) => _confirmFocus.requestFocus(),
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
      PasswordRules(_password, rules: _rules),
      const SizedBox(height: 16),
      Text('Confirm password', style: context.type.fieldLabel),
      const SizedBox(height: 6),
      AuthInput(
        controller: _confirm,
        enabled: !_busy,
        focusNode: _confirmFocus,
        hint: 'Type it again',
        obscure: _obscure,
        onSubmitted: (_) => _submit(),
      ),
      const SizedBox(height: 10),
      Text(
        'This signs you out on every device. You will sign in again with the '
        'password you choose here.',
        style: context.type.tiny.copyWith(height: 1.45),
      ),
      const SizedBox(height: 18),
      Btn.primary(
        _busy ? 'Setting...' : 'Set new password',
        size: BtnSize.lg,
        icon: Icons.lock_reset,
        busy: _busy,
        onPressed: _busy ? null : _submit,
      ),
      const SizedBox(height: 10),
      Center(child: LinkBtn('Back to Sign In', onPressed: widget.onDone)),
    ],
  );

  Widget _finished() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Text('Password changed', style: context.type.sheetTitle),
      const SizedBox(height: 16),
      Notice(tone: Tone.ok, text: _done!),
      const SizedBox(height: 18),
      Btn.primary(
        'Go to Sign In',
        size: BtnSize.lg,
        icon: Icons.login,
        onPressed: widget.onDone,
      ),
    ],
  );
}

/// [rules] under the new-password field, ticked as the user types.
///
/// Not colour alone: the icon changes SHAPE (empty circle to tick) and each
/// line is read out as "met" or "not met".
class PasswordRules extends StatelessWidget {
  const PasswordRules(this.password, {super.key, this.rules});

  final TextEditingController password;

  /// The server's checklist once fetched; [kPasswordRules] until then.
  final List<PasswordRule>? rules;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: password,
    builder: (BuildContext context, _) {
      final AppTokens t = context.tokens;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final PasswordRule r in rules ?? kPasswordRules)
            _rule(context, t, r.label, r.met(password.text)),
        ],
      );
    },
  );

  Widget _rule(BuildContext context, AppTokens t, String label, bool met) =>
      Semantics(
        label: '$label, ${met ? 'met' : 'not met'}',
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: <Widget>[
              Icon(
                met ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 14,
                color: met ? t.successText : t.textMuted,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: context.type.tiny.copyWith(
                    color: met ? t.successText : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
