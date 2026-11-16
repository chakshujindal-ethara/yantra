import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../auth/session.dart';
import '../core/errors.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/portal_tokens.dart';
import '../core/widgets/backdrop.dart';
import '../core/widgets/portal_page.dart';
import '../widgets/load_view.dart';
import 'shell.dart';

/// Sign in. The primary path is the Keycloak redirect (authorization code with PKCE); the local rig also
/// offers the password form. Wide screens get a brand panel beside the card.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _showPassword = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final user = _username.text.trim();
    final pass = _password.text;
    if (user.isEmpty || pass.isEmpty) {
      setState(() => _error = 'Enter your username and password');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.of(context).session.login(user, pass);
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = AppScope.of(context).session;
    final card = _Card(
      error: _error ?? session.redirectError,
      busy: _busy,
      username: _username,
      password: _password,
      showPassword: _showPassword || !session.canRedirect,
      onShowPassword: () => setState(() => _showPassword = true),
      onSubmit: _submit,
    );
    final scope = AppScope.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    // the studio's sign-in: the brand on a faint technical grid at the left, the card on the board at the
    // right, a light/dark pill in the corner
    final toggle = Positioned(
      top: Space.x24,
      right: Space.x24,
      child: OutlinedButton.icon(
        key: const Key('login-theme'),
        onPressed: () => scope.theme.toggle(Theme.of(context).brightness),
        icon: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined, size: Sizes.iconSm),
        label: Text(dark ? 'Light' : 'Dark'),
      ),
    );
    return Scaffold(
      body: StudioBackdrop(
        child: LayoutBuilder(
          builder: (context, c) {
            if (c.maxWidth < Layout.wide) {
              return Stack(
                children: [
                  Center(
                    child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(Space.x16, 80, Space.x16, Space.x24), child: card),
                  ),
                  toggle,
                ],
              );
            }
            return Stack(
              children: [
                Row(
                  children: [
                    Expanded(flex: 10, child: _BrandPanel()),
                    Expanded(
                      flex: 11,
                      child: Center(
                        child: SingleChildScrollView(padding: const EdgeInsets.all(Space.x32), child: card),
                      ),
                    ),
                  ],
                ),
                toggle,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.error,
    required this.busy,
    required this.username,
    required this.password,
    required this.showPassword,
    required this.onShowPassword,
    required this.onSubmit,
  });

  final String? error;
  final bool busy;
  final TextEditingController username;
  final TextEditingController password;
  final bool showPassword;
  final VoidCallback onShowPassword;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final session = AppScope.of(context).session;
    final directLogin = session.config.directLogin;
    final redirect = session.canRedirect;
    return Container(
      constraints: const BoxConstraints(maxWidth: 500),
      padding: const EdgeInsets.all(Space.x32),
      decoration: BoxDecoration(
        color: t.bgApp,
        borderRadius: Radii.rLg,
        border: Border.all(color: t.cardLine),
        boxShadow: t.shadowS3,
      ),
      child: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('ETHARA.AI · YANTRA', style: theme.textTheme.labelSmall?.copyWith(color: t.primary, fontSize: 10.5, letterSpacing: 1.7)),
            const SizedBox(height: Space.x10),
            Text('Sign in to Yantra', style: theme.textTheme.headlineLarge?.copyWith(fontSize: 28)),
            const SizedBox(height: Space.x8),
            Text(
              'Workers, reviewers, operators and clients all sign in here.',
              style: theme.textTheme.bodyLarge?.copyWith(color: t.textSecondary),
            ),
            const SizedBox(height: Space.x24),
            if (session.lastEnd == SessionEnd.expired && error == null)
              const Padding(
                padding: EdgeInsets.only(bottom: Space.x12),
                child: StatusBanner(
                  'You were signed out because your session expired. Sign in again to continue.',
                  key: Key('session-expired'),
                  kind: StatusKind.info,
                  icon: Icons.schedule_outlined,
                ),
              ),
            ErrorBanner(error),
            if (redirect) ...[
              FilledButton.icon(
                key: const Key('login-keycloak'),
                onPressed: busy ? null : session.beginRedirectLogin,
                icon: const Icon(Icons.shield_outlined, size: Sizes.iconSm),
                label: const Text('Continue with Keycloak'),
              ),
              const SizedBox(height: Space.x8),
              Text(
                'You will be taken to the Ethara identity service and back.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (redirect && directLogin && !showPassword) ...[
              const SizedBox(height: Space.x12),
              TextButton(key: const Key('login-use-password'), onPressed: onShowPassword, child: const Text('Use a password instead')),
            ],
            if (directLogin && showPassword) ...[
              if (redirect) ...[
                const SizedBox(height: Space.x16),
                Row(
                  children: [
                    Expanded(child: Divider(color: t.border)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Space.x12),
                      child: Text('or', style: theme.textTheme.labelSmall),
                    ),
                    Expanded(child: Divider(color: t.border)),
                  ],
                ),
                const SizedBox(height: Space.x16),
              ],
              TextField(
                key: const Key('login-username'),
                controller: username,
                autofillHints: const [AutofillHints.username],
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Username'),
              ),
              const SizedBox(height: Space.x12),
              TextField(
                key: const Key('login-password'),
                controller: password,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => busy ? null : onSubmit(),
                decoration: const InputDecoration(labelText: 'Password'),
              ),
              const SizedBox(height: Space.x16),
              (redirect ? OutlinedButton.new : FilledButton.new)(
                key: const Key('login-submit'),
                onPressed: busy ? null : onSubmit,
                child: busy
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Sign in'),
              ),
            ],
            if (!redirect && !directLogin)
              const StatusBanner('Sign-in is only available in the browser app.', kind: StatusKind.info, icon: Icons.info_outline),
            const SizedBox(height: Space.x16),
            Text(
              'One account per person. Never share your password; Yantra never asks for it by message.',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// The left panel on wide screens: the mark and the name large on a faint technical grid, what Yantra is in
/// four lines a worker cares about, and the studio's wide-tracked footer line.
class _BrandPanel extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    const points = [
      (Icons.work_outline, 'Workers: certified once, one unit at a time, the pay shown before you claim'),
      (Icons.rule_outlined, 'Reviewers and operators: every unit judged against a versioned rubric, with a reason'),
      (Icons.insights_outlined, 'Clients: throughput, acceptance and every delivery, with its manifest'),
      (Icons.account_balance_wallet_outlined, 'Paid every week for accepted work. Pay week: Saturday to Friday, IST'),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: t.border)),
      ),
      child: CustomPaint(
        painter: _GridPainter(t.isDark ? const Color(0x0BC5CBE9) : const Color(0x0D1A1426)),
        // the brand block centred and scrollable (short windows), the footer line pinned to the bottom when there is room
        child: LayoutBuilder(
          builder: (context, box) => Stack(
            children: [
              Positioned.fill(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(64, 48, 64, 72),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const BrandMark(size: 72),
                            const SizedBox(width: Space.x24),
                            // scales down rather than overflowing on a narrower desktop
                            Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text.rich(
                                  TextSpan(
                                    text: 'Yantra',
                                    children: [
                                      TextSpan(
                                        text: '.',
                                        style: TextStyle(color: PortalTokens.brand.colors.last),
                                      ),
                                    ],
                                  ),
                                  style: theme.textTheme.displayLarge
                                      ?.copyWith(fontSize: 64, letterSpacing: -1.6)
                                      .merge(AppTheme.weight(FontWeight.w600)),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: Space.x32),
                        Text('Trusted human work for AI labs.', style: theme.textTheme.headlineMedium),
                        const SizedBox(height: Space.x8),
                        Text(
                          'Small units of work, reviewed fairly, delivered with a manifest, paid on time.',
                          style: theme.textTheme.bodyLarge?.copyWith(color: t.textSecondary),
                        ),
                        const SizedBox(height: Space.x24),
                        for (final (icon, text) in points)
                          Padding(
                            padding: const EdgeInsets.only(bottom: Space.x12),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 30,
                                  height: 30,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: t.primarySubtle,
                                    borderRadius: const BorderRadius.all(Radius.circular(9)),
                                  ),
                                  child: Icon(icon, size: Sizes.iconSm, color: t.primary),
                                ),
                                const SizedBox(width: Space.x12),
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 5),
                                    child: Text(text, style: theme.textTheme.bodyMedium),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (box.maxHeight >= 640)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 32,
                  child: Center(
                    child: Text(
                      'ETHARA.AI · YANTRA · TRUSTED HUMAN WORK',
                      style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 2.2, color: t.textMuted),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The studio's faint 48px technical grid.
class _GridPainter extends CustomPainter {
  const _GridPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 0.0; x <= size.width; x += 48) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (var y = 0.0; y <= size.height; y += 48) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.color != color;
}
