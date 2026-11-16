import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../api/support_models.dart';
import '../api/talent_models.dart';
import '../app_scope.dart';
import '../core/action_keys.dart';
import '../core/errors.dart';
import '../core/format.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/portal_tokens.dart';
import '../core/widgets/action_dialog.dart';
import '../core/widgets/cards.dart';
import '../core/widgets/loader.dart';
import '../core/widgets/portal_page.dart';
import '../widgets/load_view.dart';
import 'policies_screen.dart';
import 'report_problem.dart';
import 'shell.dart';
import '../app_router.dart';
import 'package:go_router/go_router.dart';

/// Who you are, how much you can work, where notices go, how the app looks, the rules, sign out.
/// The worker record and the notification channel load separately: one failing leaves the other card usable.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, this.clock});

  final DateTime Function()? clock;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  WorkerMe? _me;
  String? _meError;
  bool _loadingMe = true;

  Channel? _channel;
  String? _channelError;
  bool _loadingChannel = true;

  /// The onboarding record: consent and any erasure request (workers only; null until read or when absent).
  Onboarding? _onboarding;

  /// The policies this person reads: the server's copies, shipped ones when it cannot be reached.
  List<Policy> _policies = shippedPolicies;

  /// The slider's value; starts from the worker record once it is loaded.
  double _hours = 0;
  Availability? _availability;
  bool _saving = false;

  DateTime get _now => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// The worker record, availability and notification email exist only for workers; an operator or a
  /// client never calls for them.
  bool get _isWorker => Destination.visibleTo(AppScope.of(context).session.roles).contains(Destination.home);

  Future<void> _load() async {
    if (!mounted) return;
    final policies = loadPolicies(context);
    if (!_isWorker) {
      await _tickets.currentState?.reload();
      final served = await policies;
      if (mounted) setState(() => _policies = served);
      return;
    }
    setState(() {
      _loadingMe = true;
      _loadingChannel = true;
      _meError = null;
      _channelError = null;
    });
    await Future.wait([_loadMe(), _loadChannel(), _loadOnboarding()]);
    final served = await policies;
    if (mounted) setState(() => _policies = served);
  }

  Future<void> _loadOnboarding() async {
    try {
      final ob = await AppScope.of(context).talent.onboarding();
      if (mounted) setState(() => _onboarding = ob);
    } on Object {
      // the data card says what it can without it
    }
  }

  /// Withdrawing consent stops new work and payouts until it is given again; earnings already accepted are
  /// still paid, as the law allows.
  Future<void> _withdrawConsent() async {
    final ok = await confirm(
      context,
      title: 'Withdraw your data consent?',
      body:
          'Yantra stops using your personal data for new work. You cannot claim units or receive new payouts until you '
          'give consent again here. Earnings already accepted are still paid, and tax records are kept as the law requires.',
      confirmLabel: 'Withdraw consent',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final scope = AppScope.of(context);
    const action = 'consent:withdraw';
    try {
      final ob = await scope.talent.putOnboardingStep('consent', {'accepted': false}, key: scope.keys.start(action));
      scope.keys.finish(action);
      scope.stale.mark([Destination.home, Destination.applications]);
      if (!mounted) return;
      setState(() => _onboarding = ob);
      toast(context, 'Consent withdrawn. Give it again here when you want to work.');
    } on Object catch (e) {
      scope.keys.settle(action, e);
      if (mounted) toast(context, describeError(e));
    }
  }

  /// Consent given again accepts the consent text as the server holds it now (its version is sent back);
  /// new work and payouts start again. A text updated meanwhile (`policy_outdated`) is read again.
  Future<void> _giveConsent() async {
    final consent = Policy.bySlug('dpdp-consent', _policies);
    final ok = await confirm(
      context,
      title: 'Give your data consent again?',
      body:
          'You consent to Yantra using your personal data as "${consent.title}"${consent.version.isEmpty ? '' : ' (version ${consent.version})'} '
          'describes. You can take new work again, and held payouts go out with the next window.',
      confirmLabel: 'Give consent',
    );
    if (!ok || !mounted) return;
    final scope = AppScope.of(context);
    final body = {'accepted': true, if (consent.version.isNotEmpty) 'version': consent.version};
    try {
      final ob = await withActionKey(
        scope.keys,
        'consent:give:${bodyTag(body)}',
        (key) => scope.talent.putOnboardingStep('consent', body, key: key),
      );
      scope.stale.mark([Destination.home, Destination.applications]);
      if (!mounted) return;
      setState(() => _onboarding = ob);
      toast(context, 'Consent given. You can take new work again.');
    } on Object catch (e) {
      if (!mounted) return;
      toast(context, describeError(e));
      if (e is ApiException && e.code == 'policy_outdated') {
        final served = await loadPolicies(context);
        if (mounted) setState(() => _policies = served);
      }
    }
  }

  /// Asks for erasure: done within 30 days (sooner when ops approve), after every payout owed is made.
  Future<void> _requestErasure() async {
    final ok = await confirm(
      context,
      title: 'Delete your personal data?',
      body:
          'Your name, phone, city, documents and bank details are erased within 30 days, after anything you are owed is paid. '
          'Your account then stops working. Tax records (your PAN digest and payout amounts) are kept as the law requires.',
      confirmLabel: 'Delete my data',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final scope = AppScope.of(context);
    const action = 'erasure:request';
    try {
      final erasure = await scope.talent.requestErasure(key: scope.keys.start(action));
      scope.keys.finish(action);
      if (!mounted) return;
      await _loadOnboarding();
      if (!mounted) return;
      final due = erasure.dueAt;
      toast(context, due == null ? 'Erasure requested' : 'Erasure requested; done by ${shortDate(due)}');
    } on Object catch (e) {
      scope.keys.settle(action, e);
      if (mounted) toast(context, describeError(e));
    }
  }

  Future<void> _loadMe() async {
    final scope = AppScope.of(context);
    try {
      final me = await scope.work.me();
      if (!mounted) return;
      setState(() {
        _me = me;
        _availability = me.availability;
        _hours = (me.availability?.weeklyHours ?? 0).clamp(0, 60).toDouble();
      });
    } on AppException catch (e) {
      if (mounted) setState(() => _meError = describeError(e));
    } finally {
      if (mounted) setState(() => _loadingMe = false);
    }
  }

  Future<void> _loadChannel() async {
    final scope = AppScope.of(context);
    try {
      final channel = await scope.notify.channel();
      if (mounted) setState(() => _channel = channel);
    } on AppException catch (e) {
      if (mounted) setState(() => _channelError = describeError(e));
    } finally {
      if (mounted) setState(() => _loadingChannel = false);
    }
  }

  /// Sends the whole availability record; [action] names the user action for its idempotency key.
  Future<void> _putAvailability(Availability next, {required String action, required String done}) async {
    final scope = AppScope.of(context);
    setState(() => _saving = true);
    try {
      final saved = await scope.work.setAvailability(next, key: scope.keys.start(action));
      scope.keys.finish(action);
      if (!mounted) return;
      setState(() {
        _availability = saved;
        _hours = saved.weeklyHours.clamp(0, 60).toDouble();
      });
      toast(context, done);
    } on AppException catch (e) {
      scope.keys.settle(action, e);
      if (mounted) toast(context, describeError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveHours() => _putAvailability(
    Availability(weeklyHours: _hours.round(), pausedUntil: _availability?.pausedUntil),
    action: 'availability:hours',
    done: 'Availability saved',
  );

  Future<void> _pause(Duration d, String label) async {
    final ok = await confirm(
      context,
      title: 'Pause for $label?',
      body: 'While paused you see no pools and cannot claim; nothing else changes.',
      confirmLabel: 'Pause',
    );
    if (!ok || !mounted) return;
    await _putAvailability(
      Availability(weeklyHours: _hours.round(), pausedUntil: _now.add(d)),
      action: 'availability:pause',
      done: 'Paused for $label',
    );
  }

  Future<void> _resume() => _putAvailability(
    Availability(weeklyHours: _hours.round()),
    action: 'availability:resume',
    done: 'Availability resumed',
  );

  Future<void> _editEmail() async {
    final scope = AppScope.of(context);
    final result = await showDialog<Channel>(
      context: context,
      builder: (ctx) => _EmailDialog(
        initial: (_channel?.isPending ?? false) ? _channel!.pendingEmail : _channel?.email ?? '',
        onSave: (email) async {
          const action = 'channel:email';
          try {
            final channel = await scope.notify.setEmail(email, key: scope.keys.start(action));
            scope.keys.finish(action);
            return channel;
          } on Object catch (e) {
            scope.keys.settle(action, e);
            rethrow;
          }
        },
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _channel = result;
        _channelError = null;
      });
      toast(context, result.isPending ? _codeOnItsWay(result) : 'Notification email saved');
    }
  }

  static String _codeOnItsWay(Channel c) =>
      c.verifySentAt == null ? 'We are sending a code to ${c.pendingEmail}' : 'We sent a code to ${c.pendingEmail}';

  /// The code mailed to the pending address; on success it is the address mail goes to.
  Future<void> _verifyEmail(String code) async {
    final scope = AppScope.of(context);
    final channel = await withActionKey(scope.keys, 'channel:verify:$code', (key) => scope.notify.verifyEmail(code, key: key));
    if (!mounted) return;
    setState(() => _channel = channel);
    toast(context, 'Email verified');
  }

  /// Asks again for the pending address: a new code goes out and the old one stops working.
  Future<void> _resendCode() async {
    final scope = AppScope.of(context);
    final address = _channel?.pendingEmail ?? '';
    final channel = await withActionKey(scope.keys, 'channel:resend:$address', (key) => scope.notify.setEmail(address, key: key));
    if (!mounted) return;
    setState(() => _channel = channel);
    toast(context, 'We sent a new code to $address');
  }

  final _tickets = GlobalKey<LoadViewState<List<Ticket>>>();

  Future<void> _report() async {
    final sent = await showReportProblem(context, title: 'Profile');
    if (sent == null || !mounted) return;
    await _tickets.currentState?.reload();
  }

  Future<void> _openPolicy(String slug) => context.push(Paths.policy(slug));

  Future<void> _signOut() async {
    final ok = await confirm(context, title: 'Sign out?', body: 'You can sign back in any time.', confirmLabel: 'Sign out');
    if (!ok || !mounted) return;
    await AppScope.of(context).session.logout();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final worker = _isWorker;
    return PortalPage(
      kicker: 'You',
      title: 'Profile',
      subtitle: worker ? 'Availability, notifications, policies' : 'Theme, policies, support',
      onRefresh: _load,
      children: [
        if (worker) ...[
          _IdentityCard(
            username: scope.session.username,
            subject: scope.session.subject,
            me: _me,
            error: _meError,
            loading: _loadingMe,
            onRetry: _load,
          ),
          _AvailabilityCard(
            hours: _hours,
            availability: _availability,
            loading: _loadingMe,
            error: _meError,
            busy: _saving,
            now: _now,
            onHours: (h) => setState(() => _hours = h),
            onSave: _saveHours,
            onPause: _pause,
            onResume: _resume,
          ),
          _NotificationsCard(
            channel: _channel,
            loading: _loadingChannel,
            error: _channelError,
            now: _now,
            onEdit: _editEmail,
            onRetry: _load,
            onVerify: _verifyEmail,
            onResend: _resendCode,
          ),
        ] else
          _AccountCard(username: scope.session.username, role: Destination.roleName(scope.session.roles)),
        _AppearanceCard(mode: scope.theme.mode, onChanged: scope.theme.set),
        if (worker)
          _DataCard(
            onboarding: _onboarding,
            onTracking: () => showPolicySheet(context, 'tracking', load: scope.tracker.policy),
            onWithdraw: _withdrawConsent,
            onGiveConsent: _giveConsent,
            onReadConsent: () => showPolicySheet(context, 'dpdp-consent', load: () async => Policy.bySlug('dpdp-consent', _policies)),
            onErase: _requestErasure,
          ),
        _PoliciesCard(
          policies: policiesFor(_policies, worker: worker),
          onOpen: _openPolicy,
        ),
        _SupportCard(onReport: _report, loaderKey: _tickets),
        PortalCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Session', style: theme.textTheme.titleMedium),
              const SizedBox(height: Space.x4),
              Text(
                'Signing out clears this device. Your claims, earnings and inbox stay on your account.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: Space.x12),
              OutlinedButton.icon(
                key: const Key('logout-profile'),
                onPressed: _signOut,
                icon: const Icon(Icons.logout, size: Sizes.iconSm),
                label: const Text('Sign out'),
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.x8),
        Text('Yantra · Ethara', style: theme.textTheme.labelSmall?.copyWith(color: t.textMuted)),
      ],
    );
  }
}

/// A card body in one of three states: loading skeleton, an inline error with Retry, or the content.
class _CardState extends StatelessWidget {
  const _CardState({required this.loading, required this.error, required this.onRetry, required this.child});
  final bool loading;
  final String? error;
  final Future<void> Function() onRetry;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (loading) return const Skeleton(lines: 3);
    final e = error;
    if (e != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ErrorBanner(e),
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      );
    }
    return child;
  }
}

(StatusKind, String) _accountStatus(WorkerMe? me) {
  final status = me?.status ?? 'unknown';
  return switch (status) {
    'eligible' || 'active' => (StatusKind.success, humanize(status)),
    'suspended' || 'offboarded' => (StatusKind.dest, humanize(status)),
    'unknown' || '' => (StatusKind.info, 'Not onboarded yet'),
    _ => (StatusKind.info, humanize(status)),
  };
}

/// Who is signed in, for an operator or a client: no worker record stands behind them.
class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.username, required this.role});
  final String username;
  final String role;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PortalCard(
      child: Row(
        children: [
          Avatar(username, size: 48),
          const SizedBox(width: Space.x12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(username.isEmpty ? role : username, style: theme.textTheme.titleLarge, overflow: TextOverflow.ellipsis),
                Text(role, key: const Key('account-role'), style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({
    required this.username,
    required this.subject,
    required this.me,
    required this.error,
    required this.loading,
    required this.onRetry,
  });
  final String username;
  final String subject;
  final WorkerMe? me;
  final String? error;
  final bool loading;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final (kind, label) = _accountStatus(me);
    final gates = me?.certGates ?? const [];
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Avatar(username, size: 48),
              const SizedBox(width: Space.x12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(username.isEmpty ? 'Worker' : username, style: theme.textTheme.titleLarge, overflow: TextOverflow.ellipsis),
                    Text('Worker', style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.x12),
          LabelValue(label: 'Worker id', value: subject.isEmpty ? '—' : subject, mono: true),
          const SizedBox(height: Space.x8),
          _CardState(
            loading: loading,
            error: error,
            onRetry: onRetry,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Account status', style: theme.textTheme.labelMedium),
                const SizedBox(height: Space.x6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: StatusChip(label, key: const Key('account-status'), kind: kind),
                ),
                const SizedBox(height: Space.x12),
                Text('Certifications', style: theme.textTheme.labelMedium),
                const SizedBox(height: Space.x6),
                if (gates.isEmpty)
                  Text('None yet. Pass an assessment paper to open a category of work.', style: theme.textTheme.bodySmall)
                else
                  Wrap(
                    spacing: Space.x6,
                    runSpacing: Space.x6,
                    children: [for (final g in gates) StatusChip(humanize(g), kind: StatusKind.success)],
                  ),
              ],
            ),
          ),
          const SizedBox(height: Space.x12),
          Text(
            'Your legal name, PAN and bank account are set in onboarding. Only the last four digits are ever shown.',
            style: theme.textTheme.bodySmall?.copyWith(color: t.textMuted),
          ),
        ],
      ),
    );
  }
}

class _AvailabilityCard extends StatelessWidget {
  const _AvailabilityCard({
    required this.hours,
    required this.availability,
    required this.loading,
    required this.error,
    required this.busy,
    required this.now,
    required this.onHours,
    required this.onSave,
    required this.onPause,
    required this.onResume,
  });
  final double hours;
  final Availability? availability;
  final bool loading;
  final String? error;
  final bool busy;
  final DateTime now;
  final ValueChanged<double> onHours;
  final Future<void> Function() onSave;
  final Future<void> Function(Duration, String) onPause;
  final Future<void> Function() onResume;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final paused = availability?.isPaused(now: now) ?? false;
    final until = availability?.pausedUntil;
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Availability', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x4),
          Text('Ops plan staffing from this. Update it when your week changes.', style: theme.textTheme.bodySmall),
          const SizedBox(height: Space.x12),
          if (loading)
            const Skeleton(lines: 2)
          else if (error != null)
            ErrorBanner(error)
          else ...[
            Row(
              children: [
                Expanded(child: Text('Hours per week', style: theme.textTheme.labelMedium)),
                Text('${hours.round()} h per week', key: const Key('hours-value'), style: AppTheme.figure(context, fontSize: 13)),
              ],
            ),
            MergeSemantics(
              child: Semantics(
                label: 'Hours per week',
                child: Slider(
                  key: const Key('hours-slider'),
                  value: hours,
                  min: 0,
                  max: 60,
                  divisions: 12,
                  label: '${hours.round()} h',
                  semanticFormatterCallback: (v) => '${v.round()} hours per week',
                  onChanged: busy ? null : onHours,
                ),
              ),
            ),
            Row(
              children: [
                Expanded(child: Text('0 to 60 hours, in steps of 5.', style: theme.textTheme.labelSmall)),
                FilledButton(key: const Key('save-availability'), onPressed: busy ? null : onSave, child: const Text('Save')),
              ],
            ),
            const SizedBox(height: Space.x16),
            Divider(color: t.borderSubtle),
            const SizedBox(height: Space.x12),
            Text('Pause', style: theme.textTheme.titleSmall),
            const SizedBox(height: Space.x4),
            Text('While paused you see no pools and cannot claim; nothing else changes.', style: theme.textTheme.bodySmall),
            const SizedBox(height: Space.x12),
            if (paused) ...[
              StatusBanner(
                'Paused until ${shortDate(until!, now: now)}',
                key: const Key('paused-banner'),
                kind: StatusKind.warn,
                icon: Icons.pause_circle_outline,
              ),
              OutlinedButton(key: const Key('resume'), onPressed: busy ? null : onResume, child: const Text('Resume now')),
            ] else
              Wrap(
                spacing: Space.x8,
                runSpacing: Space.x8,
                children: [
                  OutlinedButton(
                    key: const Key('pause-1w'),
                    onPressed: busy ? null : () => onPause(const Duration(days: 7), '1 week'),
                    child: const Text('1 week'),
                  ),
                  OutlinedButton(
                    key: const Key('pause-2w'),
                    onPressed: busy ? null : () => onPause(const Duration(days: 14), '2 weeks'),
                    child: const Text('2 weeks'),
                  ),
                  OutlinedButton(
                    key: const Key('pause-1m'),
                    onPressed: busy ? null : () => onPause(const Duration(days: 30), '1 month'),
                    child: const Text('1 month'),
                  ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

class _NotificationsCard extends StatelessWidget {
  const _NotificationsCard({
    required this.channel,
    required this.loading,
    required this.error,
    required this.now,
    required this.onEdit,
    required this.onRetry,
    required this.onVerify,
    required this.onResend,
  });
  final Channel? channel;
  final bool loading;
  final String? error;
  final DateTime now;
  final VoidCallback onEdit;
  final Future<void> Function() onRetry;
  final Future<void> Function(String code) onVerify;
  final Future<void> Function() onResend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final email = channel?.email ?? '';
    final c = channel;
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Notifications', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x12),
          _CardState(
            loading: loading,
            error: error,
            onRetry: onRetry,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Email', style: theme.textTheme.labelMedium),
                      const SizedBox(height: Space.x2),
                      Wrap(
                        spacing: Space.x8,
                        runSpacing: Space.x4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(email.isEmpty ? 'Not set' : email, key: const Key('email-value'), style: theme.textTheme.bodyMedium),
                          if (email.isNotEmpty) const StatusChip('Verified', key: Key('email-verified'), kind: StatusKind.success),
                        ],
                      ),
                    ],
                  ),
                ),
                OutlinedButton(
                  key: const Key('email-settings'),
                  onPressed: onEdit,
                  child: Text(email.isEmpty && !(c?.isPending ?? false) ? 'Set' : 'Edit'),
                ),
              ],
            ),
          ),
          if (!loading && error == null && c != null && c.isPending)
            _VerifyPanel(key: ValueKey('verify-${c.pendingEmail}'), channel: c, now: now, onVerify: onVerify, onResend: onResend),
          const SizedBox(height: Space.x12),
          Text(
            'Transactional notices (verdicts, payouts, claim expiry) are always sent to the inbox; email is a copy.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// The six-digit code mailed to the pending address: Verify, or "Send a new code". Its own busy and error
/// state; the page holds the channel.
class _VerifyPanel extends StatefulWidget {
  const _VerifyPanel({super.key, required this.channel, required this.now, required this.onVerify, required this.onResend});
  final Channel channel;
  final DateTime now;
  final Future<void> Function(String code) onVerify;
  final Future<void> Function() onResend;

  @override
  State<_VerifyPanel> createState() => _VerifyPanelState();
}

class _VerifyPanelState extends State<_VerifyPanel> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  static String _message(Object e) =>
      e is ApiException && e.code == 'too_many_attempts' ? 'Too many wrong codes. Send a new code to try again.' : describeError(e);

  Future<void> _run(Future<void> Function() call) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await call();
    } on Object catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _error = 'Enter the 6-digit code from the email.');
      return;
    }
    await _run(() => widget.onVerify(code));
  }

  Future<void> _resend() async {
    await _run(widget.onResend);
    if (mounted && _error == null) _code.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final c = widget.channel;
    final expires = c.verifyExpiresAt;
    final lead = c.verifyError.isNotEmpty
        ? "We couldn't send a code to ${c.pendingEmail}. Send a new code."
        : c.verifySentAt == null
        ? 'We are sending a code to ${c.pendingEmail}. Enter it here when it arrives.'
        : 'We sent a code to ${c.pendingEmail}. Enter it here.';
    return Padding(
      key: const Key('verify-panel'),
      padding: const EdgeInsets.only(top: Space.x12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(lead, key: const Key('verify-lead'), style: theme.textTheme.bodyMedium),
          if (expires != null && c.verifyError.isEmpty) ...[
            const SizedBox(height: Space.x2),
            Text(
              expires.isAfter(widget.now) ? 'The code works until ${dateTime(expires)}.' : 'This code has expired. Send a new code.',
              key: const Key('verify-expiry'),
              style: theme.textTheme.bodySmall?.copyWith(color: t.textSecondary),
            ),
          ],
          const SizedBox(height: Space.x8),
          ErrorBanner(_error),
          Wrap(
            spacing: Space.x8,
            runSpacing: Space.x8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 160,
                child: TextField(
                  key: const Key('verify-code'),
                  controller: _code,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                  autofillHints: const [AutofillHints.oneTimeCode],
                  decoration: const InputDecoration(labelText: '6-digit code'),
                  onSubmitted: (_) => _busy ? null : _verify(),
                ),
              ),
              FilledButton(key: const Key('verify-submit'), onPressed: _busy ? null : _verify, child: const Text('Verify')),
              TextButton(key: const Key('verify-resend'), onPressed: _busy ? null : _resend, child: const Text('Send a new code')),
            ],
          ),
        ],
      ),
    );
  }
}

class _AppearanceCard extends StatelessWidget {
  const _AppearanceCard({required this.mode, required this.onChanged});
  final ThemeMode mode;
  final Future<void> Function(ThemeMode) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Appearance', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x4),
          Text('System follows your device setting.', style: theme.textTheme.bodySmall),
          const SizedBox(height: Space.x12),
          SegmentedButton<ThemeMode>(
            key: const Key('theme-mode'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto_outlined)),
              ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
              ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
            ],
            selected: {mode},
            onSelectionChanged: (s) => onChanged(s.first),
          ),
        ],
      ),
    );
  }
}

/// What Yantra keeps about the worker and the two rights they can use from here: withdraw consent, and ask
/// for their data to be erased.
class _DataCard extends StatelessWidget {
  const _DataCard({
    required this.onboarding,
    required this.onTracking,
    required this.onWithdraw,
    required this.onGiveConsent,
    required this.onReadConsent,
    required this.onErase,
  });
  final Onboarding? onboarding;
  final VoidCallback onTracking;
  final VoidCallback onWithdraw;
  final VoidCallback onGiveConsent;
  final VoidCallback onReadConsent;
  final VoidCallback onErase;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final consented = onboarding?.isDone('consent') ?? false;
    final erasure = onboarding?.erasure;
    return PortalCard(
      key: const Key('data-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Your data', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x4),
          Text(
            'While a claim is open we record whether you are active, every 30 seconds. Nothing about what you type or see.',
            style: theme.textTheme.bodySmall,
          ),
          TextButton(key: const Key('what-we-track'), onPressed: onTracking, child: const Text('What we track')),
          const Divider(height: Space.x24),
          Text(
            consented
                ? 'You consented to the use of your personal data${onboarding!.consentVersion.isEmpty ? '' : ' (version ${onboarding!.consentVersion})'}.'
                : 'You have not given data consent, so you cannot take new work.',
            key: const Key('consent-state'),
            style: theme.textTheme.bodySmall,
          ),
          if (onboarding != null && !consented && !(erasure?.isDone ?? false))
            Wrap(
              spacing: Space.x8,
              children: [
                TextButton(key: const Key('read-consent'), onPressed: onReadConsent, child: const Text('Read the consent text')),
                TextButton(key: const Key('give-consent'), onPressed: onGiveConsent, child: const Text('Give consent again')),
              ],
            ),
          if (consented)
            TextButton(
              key: const Key('withdraw-consent'),
              onPressed: onWithdraw,
              style: TextButton.styleFrom(foregroundColor: t.destText),
              child: const Text('Withdraw consent'),
            ),
          const Divider(height: Space.x24),
          if (erasure == null) ...[
            Text('You can ask for your personal data to be erased.', style: theme.textTheme.bodySmall),
            TextButton(
              key: const Key('request-erasure'),
              onPressed: onErase,
              style: TextButton.styleFrom(foregroundColor: t.destText),
              child: const Text('Delete my data'),
            ),
          ] else
            StatusBanner(
              erasure.isDone
                  ? 'Your personal data was erased${erasure.doneAt == null ? '' : ' on ${shortDate(erasure.doneAt!)}'}.'
                  : 'Erasure requested. Your personal data is erased by ${erasure.dueAt == null ? 'the end of the 30 days' : shortDate(erasure.dueAt!)}, after anything owed is paid.',
              key: const Key('erasure-state'),
              kind: StatusKind.warn,
              icon: Icons.delete_outline,
            ),
        ],
      ),
    );
  }
}

class _PoliciesCard extends StatelessWidget {
  const _PoliciesCard({required this.policies, required this.onOpen});
  final List<Policy> policies;
  final Future<void> Function(String slug) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    return PortalCard(
      padding: const EdgeInsets.symmetric(vertical: Space.x8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.x16, Space.x8, Space.x16, Space.x4),
            child: Text('Policies', style: theme.textTheme.titleMedium),
          ),
          for (final p in policies)
            ListTile(
              key: Key('policy-${p.slug}'),
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: Space.x16),
              title: Text(p.title, style: theme.textTheme.bodyMedium),
              subtitle: Text(p.summary, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: Icon(Icons.chevron_right, color: t.textMuted),
              onTap: () => onOpen(p.slug),
            ),
        ],
      ),
    );
  }
}

class _EmailDialog extends StatefulWidget {
  const _EmailDialog({required this.initial, required this.onSave});
  final String initial;
  final Future<Channel> Function(String email) onSave;

  @override
  State<_EmailDialog> createState() => _EmailDialogState();
}

class _EmailDialogState extends State<_EmailDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final email = _controller.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = 'Enter a valid email');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await widget.onSave(email);
      if (mounted) Navigator.of(context).pop(saved);
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      // whatever went wrong, the buttons come back
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Notification email'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ErrorBanner(_error),
          TextField(
            key: const Key('email-input'),
            controller: _controller,
            keyboardType: TextInputType.emailAddress,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Email'),
            onSubmitted: (_) => _busy ? null : _save(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const Key('email-save'), onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    );
  }
}

/// "Report a problem" and the person's own tickets. The ticket list loads on its own: a failure there
/// leaves the button usable.
class _SupportCard extends StatelessWidget {
  const _SupportCard({required this.onReport, required this.loaderKey});
  final VoidCallback onReport;
  final GlobalKey<LoadViewState<List<Ticket>>> loaderKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Support', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x4),
          Text('Something broken, a payment question, a problem with a unit: ops read every ticket.', style: theme.textTheme.bodySmall),
          const SizedBox(height: Space.x12),
          FilledButton.icon(
            key: const Key('report-problem'),
            onPressed: onReport,
            icon: const Icon(Icons.flag_outlined, size: Sizes.iconSm),
            label: const Text('Report a problem'),
          ),
          const SizedBox(height: Space.x16),
          Text('My tickets', style: theme.textTheme.titleSmall),
          const SizedBox(height: Space.x8),
          LoadView<List<Ticket>>(
            wrapInCard: true,
            key: loaderKey,
            load: () => AppScope.of(context).support.mine(),
            isEmpty: (t) => t.isEmpty,
            emptyMessage: 'No tickets yet.',
            builder: (context, tickets, _) =>
                Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final t in tickets) _TicketRow(t)]),
          ),
        ],
      ),
    );
  }
}

(String, StatusKind) _ticketStatus(String status) => switch (status) {
  'open' => ('Open', StatusKind.warn),
  'in_progress' => ('In progress', StatusKind.info),
  'resolved' => ('Resolved', StatusKind.success),
  _ => (humanize(status), StatusKind.info),
};

class _TicketRow extends StatelessWidget {
  const _TicketRow(this.t);
  final Ticket t;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = PortalTokens.of(context);
    final (label, kind) = _ticketStatus(t.status);
    final created = t.createdAt;
    return Container(
      key: Key('my-ticket-${t.id}'),
      margin: const EdgeInsets.only(bottom: Space.x8),
      padding: const EdgeInsets.all(Space.x12),
      decoration: BoxDecoration(
        color: tokens.bgSubtle,
        borderRadius: Radii.rMd,
        border: Border.all(color: tokens.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(t.title, style: theme.textTheme.bodyMedium, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: Space.x8),
              StatusChip(label, kind: kind),
            ],
          ),
          const SizedBox(height: Space.x4),
          Text(
            [humanize(t.category), if (t.screen.isNotEmpty) 'on ${t.screen}', if (created != null) relative(created)].join(' · '),
            style: theme.textTheme.labelSmall,
          ),
          if (t.isResolved && t.note.isNotEmpty) ...[
            const SizedBox(height: Space.x8),
            Text('Ops: ${t.note}', style: theme.textTheme.bodySmall?.copyWith(color: tokens.textPrimary)),
          ],
        ],
      ),
    );
  }
}

/// Category, title and body; the screen is given by the page, the context by the device.
