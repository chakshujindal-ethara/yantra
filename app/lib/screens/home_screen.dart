import 'dart:async';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/talent_models.dart';
import '../api/tracker_models.dart';
import '../app_scope.dart';
import '../core/errors.dart';
import '../core/format.dart';
import '../core/money.dart';
import '../core/poller.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/portal_tokens.dart';
import '../core/widgets/cards.dart';
import '../core/widgets/loader.dart';
import '../core/widgets/portal_page.dart';
import '../widgets/load_view.dart';
import 'policies_screen.dart';
import 'shell.dart';
import '../app_router.dart';
import 'package:go_router/go_router.dart';

/// The worker's dashboard: the numbers that matter today, the live claim, readiness, then the open pools.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.clock});

  final DateTime Function()? clock;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// Everything Home shows, loaded together. The statement, the profile, the onboarding checklist and the
/// applications are optional: a worker with no earnings yet, or one the market or talent module does not
/// know yet, still gets a page.
class HomeData {
  const HomeData({
    required this.active,
    required this.batches,
    this.me,
    this.statement,
    this.email = '',
    this.onboarding,
    this.offers = 0,
    this.papersWaiting = const [],
    this.bank,
    this.activity,
  });

  final ActiveWork active;
  final List<Batch> batches;
  final WorkerMe? me;
  final Statement? statement;
  final String email;

  /// Null when the talent module has nothing for this worker yet (a 404): onboarding not started.
  final Onboarding? onboarding;

  /// Offers waiting for the worker's answer.
  final int offers;

  /// Applications waiting on the worker's assessment paper.
  final List<Application> papersWaiting;

  /// The payout account and its bank check (null: none registered yet).
  final BankAccount? bank;

  /// This week's tracked activity (null when the tracker has nothing or cannot be read).
  final MyActivity? activity;

  bool get isPaused => me?.availability?.isPaused() ?? false;
}

class _HomeScreenState extends State<HomeScreen> {
  final _loadKey = GlobalKey<LoadViewState<HomeData>>();
  String? _claimingBatch;
  String? _error;
  Timer? _ticker;

  /// While a claim is live, the server's view of it is read again every minute (expiry is the server's, not
  /// this device's clock), quietly: the page stays on screen.
  Poller? _resync;

  /// The gateway's clock (`AppScope.serverNow`): the live claim's countdown is the server's.
  DateTime get _now => (widget.clock ?? AppScope.of(context).serverNow)();

  /// The countdown ticks only while a claim is live; otherwise nothing on the page changes by itself.
  void _tick(bool live) {
    if (live && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      var fresh = true; // the page was just read: the poller's immediate first tick has nothing to add
      _resync = Poller(
        every: const Duration(seconds: 60),
        tick: () async {
          if (fresh) {
            fresh = false;
            return;
          }
          await _loadKey.currentState?.reload();
        },
      )..start();
    } else if (!live) {
      _ticker?.cancel();
      _ticker = null;
      _resync?.stop();
      _resync = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _resync?.stop();
    super.dispose();
  }

  Future<HomeData> _load() async {
    final scope = AppScope.of(context);
    final active = await scope.work.activeWork();
    // the rest are independent: asked together, so the page waits for the slowest, not the sum
    final batchesF = active.isLive ? Future.value(<Batch>[]) : scope.work.openBatches();
    final meF = _optional(scope.work.me);
    final statementF = _optional(scope.payout.statement);
    final channelF = _optional(scope.notify.channel);
    final onboardingF = _optional(scope.talent.onboarding);
    final applicationsF = _optional(scope.talent.myApplications);
    final bankF = _optional(scope.payout.bankAccount);
    final activityF = _soft(scope.tracker.mine);
    // every future is awaited here first, so a second failure is never left unhandled; the first one is
    // the page's error, as before
    await Future.wait<Object?>([batchesF, meF, statementF, channelF, onboardingF, applicationsF, bankF, activityF]);
    final batches = await batchesF;
    final me = await meF;
    final statement = await statementF;
    final channel = await channelF;
    final onboarding = await onboardingF;
    final applications = await applicationsF ?? const <Application>[];
    final bank = await bankF;
    final activity = await activityF;
    return HomeData(
      active: active,
      batches: batches,
      me: me,
      statement: statement,
      email: channel?.email ?? '',
      onboarding: onboarding,
      offers: applications.where((a) => a.isOffered).length,
      papersWaiting: applications.where((a) => a.status == 'assessment').toList(),
      bank: bank,
      activity: activity,
    );
  }

  /// A side panel that must never take the page down with it: any failure reads as "nothing to show".
  Future<T?> _soft<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on Object {
      return null;
    }
  }

  Future<void> _openOnboarding() async {
    await context.push(Paths.onboarding());
    await _loadKey.currentState?.reload();
  }

  /// Null only when the module has nothing for this worker yet (a 404); any other failure is the page's
  /// error, never fake empty data.
  Future<T?> _optional<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  Future<void> _openWork(Claim claim, Unit unit, {Batch? batch}) async {
    await context.push(
      Paths.unit(claim.id),
      extra: ActiveWork(claim: claim, unit: unit, batch: batch),
    );
    await _loadKey.currentState?.reload();
  }

  Future<void> _claim(Batch batch) async {
    final scope = AppScope.of(context);
    final action = 'claim:${batch.id}';
    setState(() {
      _claimingBatch = batch.id;
      _error = null;
    });
    var claimed = false;
    try {
      final claim = await scope.work.claim(batch.id, key: scope.keys.start(action));
      scope.keys.finish(action);
      claimed = true;
      scope.stale.mark([Destination.myWork]);
      final unit = await scope.work.unit(claim.unitId);
      if (mounted) await _openWork(claim, unit, batch: batch);
    } on ApiException catch (e) {
      if (!claimed) scope.keys.settle(action, e);
      if (mounted) setState(() => _error = _claimMessage(e));
    } on Object catch (e) {
      if (!claimed) scope.keys.settle(action, e);
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _claimingBatch = null);
      // the claim may have landed even when what followed failed: show the page as it now is
      if (claimed && mounted) await _loadKey.currentState?.reload();
    }
  }

  String _claimMessage(ApiException e) => switch (e.code) {
    'one_live_claim' => 'You already hold a claim. Finish it first.',
    'no_units_available' => 'No units left in this pool.',
    'availability_paused' => 'Your availability is paused. Resume it in Profile to claim.',
    'forbidden' => 'You are not eligible for this pool yet.',
    _ => describeError(e),
  };

  @override
  Widget build(BuildContext context) {
    final username = AppScope.of(context).session.username;
    return LoadView<HomeData>(
      firstWait: LoadWait.brand,
      key: _loadKey,
      load: _load,
      builder: (context, data, reload) {
        final claim = data.active.claim;
        final unit = data.active.unit;
        final theme = Theme.of(context);
        _tick(claim != null);
        return PortalPage(
          kicker: 'Today',
          title: '${_greeting(_now)}, ${username.isEmpty ? 'there' : username}',
          subtitle: claim != null ? 'You have a unit in progress.' : 'Here is what is ready for you.',
          onRefresh: reload,
          children: [
            _Kpis(data: data, now: _now),
            ErrorBanner(_error),
            if (data.isPaused) _PausedBanner(until: data.me!.availability!.pausedUntil),
            if (claim != null && unit != null)
              _LiveClaimCard(
                claim: claim,
                unit: unit,
                batch: data.active.batch,
                now: _now,
                onOpen: () => _openWork(claim, unit, batch: data.active.batch),
              ),
            if (data.offers > 0) _OffersCard(count: data.offers),
            if (data.papersWaiting.isNotEmpty) _PaperWaitingCard(apps: data.papersWaiting),
            _Readiness(data: data, onOnboarding: _openOnboarding),
            if (data.activity case final a? when a.sessions.isNotEmpty || a.week.activeSeconds > 0 || claim != null)
              _ActivityCard(activity: a),
            if (claim == null) ...[
              SectionTitle('Open pools', subtitle: 'Pools you are certified for, with the pay per accepted unit'),
              if (data.batches.isEmpty)
                const PortalCard(
                  child: EmptyView(message: 'No open pools right now. New work appears here as soon as a batch is published.'),
                )
              else
                for (final b in data.batches)
                  _BatchCard(
                    batch: b,
                    busy: _claimingBatch == b.id,
                    onClaim: _claimingBatch == null && !data.isPaused ? () => _claim(b) : null,
                  ),
            ],
            const SizedBox(height: Space.x8),
            Text(
              'Pay week: Saturday 00:00 to Friday 23:59 IST. Only an accepted unit creates an earning.',
              style: theme.textTheme.labelSmall,
            ),
          ],
        );
      },
    );
  }

  static String _greeting(DateTime now) {
    final h = now.hour;
    if (h < 5) return 'Good night';
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }
}

class _Kpis extends StatelessWidget {
  const _Kpis({required this.data, required this.now});
  final HomeData data;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final s = data.statement;
    final pending = s?.pendingNext ?? MoneySum.none;
    final closes = s?.nextWindowClosesAt;
    final gates = data.me?.certGates ?? const [];
    final open = data.batches.fold<int>(0, (n, b) => n + b.availableUnits);
    return KpiRow(
      children: [
        KpiTile(
          label: 'Pending for next payout',
          value: formatMoney(pending.amount, currency: pending.currency),
          note: pending.count == 0 ? 'Accepted units land here' : '${pending.count} accepted ${pending.count == 1 ? 'unit' : 'units'}',
          kind: pending.count == 0 ? null : StatusKind.success,
          icon: Icons.account_balance_wallet_outlined,
        ),
        KpiTile(
          label: 'Units open to you',
          value: '$open',
          note: data.batches.isEmpty ? 'No pools published' : '${data.batches.length} ${data.batches.length == 1 ? 'pool' : 'pools'}',
          icon: Icons.layers_outlined,
        ),
        KpiTile(
          label: 'Certifications',
          value: '${gates.length}',
          note: gates.isEmpty ? 'None yet' : gates.map(humanize).join(', '),
          kind: gates.isEmpty ? StatusKind.warn : StatusKind.success,
          icon: Icons.verified_outlined,
        ),
        KpiTile(
          label: 'Pay week closes',
          value: closes == null ? '—' : untilShort(closes, now: now).replaceFirst('in ', ''),
          note: closes == null ? 'Friday 23:59 IST' : '${dateTime(closes)} (IST week)',
          icon: Icons.event_outlined,
        ),
      ],
    );
  }
}

class _PausedBanner extends StatelessWidget {
  const _PausedBanner({required this.until});
  final DateTime? until;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return PortalCard(
      color: t.warnBg,
      borderColor: t.warnDot.withValues(alpha: 0.4),
      child: Row(
        children: [
          Icon(Icons.pause_circle_outline, color: t.warnDot),
          const SizedBox(width: Space.x12),
          Expanded(
            child: Text(
              'Your availability is paused${until == null ? '' : ' until ${shortDate(until!)}'}. Pools are hidden while paused.',
              style: TextStyle(color: t.warnText),
            ),
          ),
          TextButton(
            key: const Key('resume-availability'),
            onPressed: () => ShellActions.of(context).go(Destination.profile),
            child: const Text('Resume'),
          ),
        ],
      ),
    );
  }
}

class _LiveClaimCard extends StatelessWidget {
  const _LiveClaimCard({required this.claim, required this.unit, required this.batch, required this.now, required this.onOpen});
  final Claim claim;
  final Unit unit;
  final Batch? batch;
  final DateTime now;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final expires = claim.expiresAt;
    final left = expires == null ? Duration.zero : expires.difference(now);
    final expired = left.isNegative || left == Duration.zero;
    return PortalCard(
      key: const Key('live-claim'),
      emphasis: true,
      onTap: onOpen,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: t.bgApp, borderRadius: Radii.rMd),
            child: Icon(Icons.timer_outlined, color: t.primary),
          ),
          const SizedBox(width: Space.x12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(batch?.title.isNotEmpty == true ? batch!.title : 'Unit in progress', style: theme.textTheme.titleMedium),
                Text(
                  'Ref ${unit.ref}  ·  ${expired ? 'claim expired' : '${countdown(left.isNegative ? Duration.zero : left)} left'}',
                  key: const Key('live-claim-countdown'),
                  style: AppTheme.figure(context, fontSize: 12, color: expired ? t.destText : t.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.x12),
          FilledButton(onPressed: onOpen, child: const Text('Continue')),
        ],
      ),
    );
  }
}

/// Offers waiting for an answer: the one card that asks for attention when there is no live claim.
/// An application stands at its paper: one tap opens it. With several, the Applications page lists them.
class _PaperWaitingCard extends StatefulWidget {
  const _PaperWaitingCard({required this.apps});
  final List<Application> apps;

  @override
  State<_PaperWaitingCard> createState() => _PaperWaitingCardState();
}

class _PaperWaitingCardState extends State<_PaperWaitingCard> {
  bool _busy = false;

  Future<void> _open() async {
    if (widget.apps.length > 1) {
      ShellActions.of(context).go(Destination.applications);
      return;
    }
    setState(() => _busy = true);
    try {
      // the application names its listing, the listing names its paper
      final listing = await AppScope.of(context).talent.listing(widget.apps.single.listingId);
      if (!mounted) return;
      if (listing.paperId.isEmpty) {
        ShellActions.of(context).go(Destination.applications);
      } else {
        context.go(Paths.assessment(listing.paperId));
      }
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final one = widget.apps.length == 1;
    return PortalCard(
      key: const Key('paper-waiting'),
      emphasis: true,
      child: Wrap(
        spacing: Space.x12,
        runSpacing: Space.x12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: t.bgApp, borderRadius: Radii.rMd),
            child: Icon(Icons.assignment_outlined, color: t.primary),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your paper is waiting', style: theme.textTheme.titleMedium),
                Text(
                  one
                      ? 'Pass it to move your application to ${widget.apps.single.listingTitle} on to screening.'
                      : '${widget.apps.length} applications wait on a paper.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          FilledButton(key: const Key('open-paper'), onPressed: _busy ? null : _open, child: Text(one ? 'Take the paper' : 'See papers')),
        ],
      ),
    );
  }
}

class _OffersCard extends StatelessWidget {
  const _OffersCard({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    return PortalCard(
      key: const Key('offers-waiting'),
      emphasis: true,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: t.bgApp, borderRadius: Radii.rMd),
            child: Icon(Icons.mark_email_unread_outlined, color: t.primary),
          ),
          const SizedBox(width: Space.x12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$count ${count == 1 ? 'offer' : 'offers'} waiting for your answer', style: theme.textTheme.titleMedium),
                Text('An offer that expires counts as declined', style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: Space.x12),
          FilledButton(
            key: const Key('see-offers'),
            onPressed: () => ShellActions.of(context).go(Destination.applications),
            child: const Text('See offers'),
          ),
        ],
      ),
    );
  }
}

/// What the worker still has to do before work flows. Hidden once everything is done.
class _Readiness extends StatelessWidget {
  const _Readiness({required this.data, required this.onOnboarding});
  final HomeData data;
  final VoidCallback onOnboarding;

  @override
  Widget build(BuildContext context) {
    final me = data.me;
    final ob = data.onboarding;
    final onboarded = me?.isOnboarded ?? false;
    final eligible = me?.isEligible ?? false;
    final checklistDone = ob?.complete ?? false;
    final onboardingDone = checklistDone || (onboarded && eligible);
    final certified = (me?.certGates ?? const []).isNotEmpty;
    final availability = me?.availability != null;
    final email = data.email.isNotEmpty;
    final done = [onboardingDone, certified, availability, email].where((x) => x).length;
    if (done == 4) return const SizedBox.shrink();
    final go = ShellActions.of(context).go;
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Ready to work', style: Theme.of(context).textTheme.titleMedium)),
              Text('$done of 4', style: AppTheme.figure(context, fontSize: 12, color: PortalTokens.of(context).textSecondary)),
            ],
          ),
          const SizedBox(height: Space.x4),
          ProgressRow(label: 'Finish these to unlock every pool you qualify for', value: done.toDouble(), total: 4, trailing: ''),
          const SizedBox(height: Space.x8),
          ChecklistRow(
            done: onboardingDone,
            pending: !onboardingDone && (checklistDone || onboarded),
            title: 'Onboarded and eligible',
            hint: onboardingDone
                ? 'You can claim work'
                : data.bank?.isFailed ?? false
                ? 'Your bank account could not be confirmed. Open onboarding to fix it.'
                : (data.bank?.isVerifying ?? false) && !(ob?.isDone('bank') ?? false)
                ? 'Checking your bank account with the bank; ${ob?.left ?? 6} ${(ob?.left ?? 6) == 1 ? 'step' : 'steps'} left'
                : checklistDone
                ? 'Your checklist is done; your account is ${humanize(me?.status ?? 'unknown').toLowerCase()} until ops confirms'
                : ob == null
                ? 'Profile, documents, identity and bank details: 0 of 6 steps done'
                : '${ob.done} of ${ob.total} steps done; ${ob.left} left',
            action: onboardingDone
                ? null
                : TextButton(
                    key: const Key('finish-onboarding'),
                    onPressed: onOnboarding,
                    child: Text(ob == null || ob.done == 0 ? 'Start' : 'Finish'),
                  ),
          ),
          ChecklistRow(
            done: certified,
            title: 'Certified for at least one pool',
            hint: certified
                ? (me?.certGates ?? const []).map(humanize).join(', ')
                : 'Apply to a pool and pass its paper to open a category of work',
            action: certified
                ? null
                : TextButton(key: const Key('explore-pools'), onPressed: () => go(Destination.explore), child: const Text('Explore pools')),
          ),
          ChecklistRow(
            done: availability,
            title: 'Weekly availability set',
            hint: availability ? '${me!.availability!.weeklyHours} h per week' : 'Tell ops how many hours you can give this week',
            action: availability
                ? null
                : TextButton(key: const Key('set-availability'), onPressed: () => go(Destination.profile), child: const Text('Set')),
          ),
          ChecklistRow(
            done: email,
            title: 'Notification email set',
            hint: email ? data.email : 'Verdicts and payouts reach you by email too',
            action: email
                ? null
                : TextButton(key: const Key('set-email'), onPressed: () => go(Destination.profile), child: const Text('Set')),
          ),
        ],
      ),
    );
  }
}

/// This week's tracked time against the weekly cap. Pay is per accepted unit; the cap is a limit, not a target.
class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.activity});
  final MyActivity activity;

  static String hours(double h) => h < 10 ? h.toStringAsFixed(1) : h.toStringAsFixed(0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final week = activity.week;
    final cap = week.capHours;
    return PortalCard(
      key: const Key('activity-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Activity this week', style: theme.textTheme.titleMedium)),
              TextButton(
                key: const Key('activity-policy'),
                onPressed: () => showPolicySheet(context, 'tracking', load: AppScope.of(context).tracker.policy),
                child: const Text('What we track'),
              ),
            ],
          ),
          const SizedBox(height: Space.x4),
          ProgressRow(
            label: cap > 0 ? '${hours(week.activeHours)} h active of a ${hours(cap)} h weekly cap' : '${hours(week.activeHours)} h active',
            value: week.activeHours,
            total: cap > 0 ? cap : 1,
            trailing: '',
          ),
          const SizedBox(height: Space.x4),
          Text(
            week.overCap
                ? 'You are over this week\'s cap. Your work is still recorded; ops may ask you to slow down.'
                : '${activity.sessions.length} ${activity.sessions.length == 1 ? 'session' : 'sessions'} this week. You are paid per accepted unit, not per hour.',
            key: const Key('activity-note'),
            style: theme.textTheme.bodySmall?.copyWith(color: week.overCap ? t.warnText : t.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _BatchCard extends StatelessWidget {
  const _BatchCard({required this.batch, required this.busy, required this.onClaim});
  final Batch batch;
  final bool busy;
  final VoidCallback? onClaim;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canClaim = batch.availableUnits > 0 && onClaim != null;
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(batch.title, style: theme.textTheme.titleMedium),
                    if (batch.projectName.isNotEmpty) Text(batch.projectName, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              StatusChip('${batch.availableUnits} available', kind: batch.availableUnits > 0 ? StatusKind.success : StatusKind.warn),
            ],
          ),
          const SizedBox(height: Space.x12),
          Wrap(
            spacing: Space.x20,
            runSpacing: Space.x6,
            children: [
              Fact(
                icon: Icons.payments_outlined,
                text: '${formatMoney(batch.unitPay, currency: batch.currency)} per unit',
              ),
              Fact(icon: Icons.timer_outlined, text: '${minutesLabel(batch.claimTtlMinutes)} per claim'),
              Fact(icon: Icons.rule_outlined, text: 'Rubric ${batch.rubricVersion}', mono: true),
              if (batch.hasAnswerSchema) const Fact(icon: Icons.list_alt_outlined, text: 'Guided form'),
            ],
          ),
          const SizedBox(height: Space.x12),
          Row(
            children: [
              Expanded(child: Text('One claim at a time. The pay is frozen on every unit.', style: theme.textTheme.labelSmall)),
              FilledButton(
                key: Key('claim-${batch.id}'),
                onPressed: canClaim && !busy ? onClaim : null,
                child: busy
                    ? SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Claim a unit'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
