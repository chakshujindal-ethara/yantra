// Account - the signed-in person's own settings. Currently: their password.
//
// WHY THIS SCREEN EXISTS. A candidate's account is provisioned by the backend
// when an assessment is launched, and it is provisioned with a SHARED default
// password (`Ethara@123`, see `_seed_candidate_password` in
// `assessments_be_v2/models/assessment.py`). A shared password that nobody can
// change is not a credential, it is a published one - so the app that hands it
// out has to be the app that lets it be replaced.
//
// It is on BOTH rails, admin and candidate: both kinds of account are created
// the same way and neither had anywhere to do this. It is about the person,
// not the role, so it asks the store nothing about `portal`.
//
// NO CURRENT PASSWORD IS ASKED FOR. That is the product decision this screen
// implements, and the server implements the same one - see the docstring on
// `/api/v1/auth/password`. It means whoever holds a live session can replace
// the password rather than merely use it.
import 'package:flutter/material.dart';

import '../../data/api_client.dart';
import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../state/app_store.dart';
import '../../theme.dart';
import '../../widgets/buttons.dart';
import '../../widgets/feedback.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import '../../../password_reset.dart'
    show PasswordPolicy, PasswordRules, fetchPasswordPolicy;

/// The FALLBACK length until `/auth/password_policy` answers - see
/// [fetchPasswordPolicy]. The length the password write enforces today:
/// etp_security sets
/// `auth_password_policy.minlength` to 12 (see [kPasswordRules]), which is
/// stricter than `MIN_PASSWORD_LEN` (8) in the module's auth controller.
///
/// Checked here as well as there because a user who has typed six characters
/// deserves to be told before a round trip - not because the client is trusted
/// to enforce it. The server refuses independently and its wording is shown.
const int kMinPasswordLength = 12;

class AccountScreen extends StatefulWidget {
  final AppStore store;

  const AccountScreen({super.key, required this.store});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final TextEditingController _next = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  final FocusNode _confirmFocus = FocusNode();

  bool _obscure = true;
  bool _busy = false;

  /// The refusal to show above the form, in the server's words where it spoke.
  String? _error;

  /// Set once the change has gone through. Cleared the moment either field is
  /// edited again, so a stale "Password updated" never sits over a form
  /// somebody is retyping.
  String? _done;

  /// True when the password changed but the credential could not be renewed.
  /// The change SUCCEEDED; the session did not survive it. Signing out is the
  /// honest next step, and doing it silently would look like a crash.
  bool _mustSignIn = false;

  /// The server's policy, once fetched. Null on seed data, and on a backend
  /// without the route: the static rules and [kMinPasswordLength] stand.
  PasswordPolicy? _policy;

  @override
  void initState() {
    super.initState();
    final ApiClient? api = widget.store.api;
    if (api == null) return;
    fetchPasswordPolicy(api).then((PasswordPolicy? p) {
      if (mounted && p != null) setState(() => _policy = p);
    });
  }

  @override
  void dispose() {
    _next.dispose();
    _confirm.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  void _touched() {
    if (_error == null && _done == null) return;
    setState(() {
      _error = null;
      _done = null;
    });
  }

  /// The client-side refusal, or null when the form is worth sending.
  String? _localRefusal() {
    final String next = _next.text;
    if (next.isEmpty) return 'Enter a new password.';
    final int min = _policy?.minLength ?? kMinPasswordLength;
    if (next.length < min) {
      return 'Your new password must be at least $min characters.';
    }
    if (next != _confirm.text) return 'The two passwords do not match.';
    return null;
  }

  Future<void> _submit() async {
    if (_busy) return;

    final String? refusal = _localRefusal();
    if (refusal != null) {
      setState(() {
        _error = refusal;
        _done = null;
      });
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _done = null;
    });

    try {
      final bool stillIn = await widget.store.changePassword(
        _next.text,
        confirmPassword: _confirm.text,
      );
      if (!mounted) return;
      _next.clear();
      _confirm.clear();
      setState(() {
        _mustSignIn = !stillIn;
        _done = stillIn
            ? 'Your password has been updated. Any other device signed in '
                  'to this account has been signed out.'
            : 'Your password has been updated, but this session could not '
                  'be renewed. Sign in again with your new password.';
      });
    } on ApiError catch (e) {
      // The module's own wording. It is the only text that can explain a
      // refusal this screen does not know about - a password policy the
      // deployment added, for instance.
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not reach the server. $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (BuildContext context, _) => _body(context),
  );

  Widget _body(BuildContext context) {
    final String who = widget.store.meName;

    // `narrow` - one subject, one column. A form stretched to 1720px puts the
    // label and its field at opposite ends of the screen.
    return PageBody(
      narrow: true,
      children: <Widget>[
        PageHead(
          'Account',
          sub: who.isEmpty
              ? 'The account you are signed in with.'
              : 'Signed in as $who.',
        ),
        // WHO, before HOW TO CHANGE THE PASSWORD.
        //
        // The screen opened straight onto a password form, which answers the
        // second question somebody arriving here has and not the first. Where
        // accounts are provisioned by the backend - a candidate never chose
        // their own username - "which account am I actually in, and as what"
        // is a real question, and nothing but the rail card answered it.
        _ProfilePanel(store: widget.store),
        const SizedBox(height: 16),
        Panel(
          title: 'Password',
          note: 'Choose a new password. You will stay signed in here.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (_error != null) ...<Widget>[
                Notice(tone: Tone.bad, text: _error!),
                const SizedBox(height: 16),
              ],
              if (_done != null) ...<Widget>[
                Notice(
                  tone: _mustSignIn ? Tone.warn : Tone.ok,
                  text: _done!,
                  actions: _mustSignIn
                      ? <Widget>[
                          Btn(
                            'Sign In Again',
                            size: BtnSize.sm,
                            onPressed: widget.store.signOut,
                          ),
                        ]
                      : const <Widget>[],
                ),
                const SizedBox(height: 16),
              ],
              Field(
                label: 'New password',
                help: 'Must meet every rule below.',
                child: _PasswordInput(
                  controller: _next,
                  hint: 'New password',
                  obscure: _obscure,
                  enabled: !_busy,
                  onChanged: (_) => _touched(),
                  onToggleObscure: () => setState(() => _obscure = !_obscure),
                  onSubmitted: (_) => _confirmFocus.requestFocus(),
                ),
              ),
              // The same live checklist the reset form shows, so both
              // password screens state the rules the server enforces.
              PasswordRules(_next, rules: _policy?.rules),
              const SizedBox(height: 16),
              Field(
                label: 'Confirm new password',
                child: _PasswordInput(
                  controller: _confirm,
                  hint: 'Repeat the new password',
                  obscure: _obscure,
                  enabled: !_busy,
                  focusNode: _confirmFocus,
                  onChanged: (_) => _touched(),
                  onToggleObscure: () => setState(() => _obscure = !_obscure),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: <Widget>[
                  Btn.primary(
                    'Update Password',
                    busy: _busy,
                    onPressed: _busy ? null : _submit,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A password field with its own show/hide control.
///
/// Private to this screen, in the same way `_Input` is private to the login
/// screen and `_SheetInput` to the assessment detail sheet. Promoting one of
/// those into a shared widget would be the better change, but it would touch
/// screens this feature has no business editing.
class _PasswordInput extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final bool enabled;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback onToggleObscure;

  const _PasswordInput({
    required this.controller,
    required this.hint,
    required this.obscure,
    required this.enabled,
    required this.onToggleObscure,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return SizedBox(
      height: 40,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        enabled: enabled,
        obscureText: obscure,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        style: context.type.body,
        cursorColor: t.primary,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: context.type.bodyMuted,
          filled: true,
          fillColor: t.bgSubtle,
          isDense: true,
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
          suffixIcon: IconButton(
            icon: Icon(
              obscure
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 18,
              color: t.textMuted,
            ),
            tooltip: obscure ? 'Show password' : 'Hide password',
            onPressed: enabled ? onToggleObscure : null,
          ),
        ),
      ),
    );
  }
}

/// Who you are signed in as, and with what authority.
///
/// Every value here comes from the SERVER's answer to `/api/v1/auth/me`, which
/// the store adopted at sign-in - never from anything the client chose. The
/// role in particular: it decides which rail you get and which routes will
/// answer you, and a client that displayed its own idea of it could disagree
/// with the module that enforces it.
class _ProfilePanel extends StatelessWidget {
  final AppStore store;

  const _ProfilePanel({required this.store});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final String name = store.meName;
    // The roster record, when this account has one. An ADMIN normally does
    // not - they are an Odoo user rather than a candidate on an assessment -
    // so an absent one is ordinary and the rows it feeds are simply omitted.
    final Person? me = store.people
        .where((Person p) => p.id == store.meId)
        .firstOrNull;

    return Panel(
      title: 'Profile',
      note: 'From the server, not from this app',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: t.primarySubtle,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Text(
                  (name.isEmpty ? '?' : name.characters.first).toUpperCase(),
                  style: context.type.panelTitle.copyWith(color: t.primary),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      name.isEmpty ? 'Signed in' : name,
                      style: context.type.body.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    // The ROLE as a pill, because it is a state of the account
                    // rather than a detail of it: it decides which rail is
                    // drawn and which routes answer at all.
                    //
                    // `accessRole`, NOT `portal`. Portal is binary - there are
                    // two shells, the operator console and the candidate
                    // surface - and a read-only Manager belongs in the console,
                    // so `portal.label` read "Admin" for them here, on the row
                    // beneath it, and in the sentence below. This screen exists
                    // to answer "which account am I in, and as what"; it was
                    // answering the second half wrongly for a whole rung.
                    Pill(store.accessRole.label, Tone.accent),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          KvRow.text('Name', name.isEmpty ? 'Not recorded' : name),
          if (me != null && me.email.isNotEmpty) KvRow.text('Email', me.email),
          if (me != null && me.pod.isNotEmpty) KvRow.text('Pod', me.pod),
          KvRow.text('Role', store.accessRole.label),
          // The sentence used to be a two-way switch on `portal`, so it told a
          // read-only Manager they could "author, launch, score and release" -
          // four things the server refuses them. It lives on the enum now, one
          // line per rung, so a rung added later cannot inherit the wrong half
          // of a binary.
          KvRow(
            'What this role can do',
            Text(
              store.accessRole.canDo,
              textAlign: TextAlign.right,
              style: context.type.body.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          KvRow.text(
            'Account id',
            store.meId.isEmpty ? 'Not recorded' : store.meId,
            last: true,
          ),
        ],
      ),
    );
  }
}
