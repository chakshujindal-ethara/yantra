import 'package:flutter/material.dart' hide StepState;

import '../api/assess_models.dart';
import '../api/talent_models.dart';
import '../app_scope.dart';
import '../core/errors.dart';
import '../core/format.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/portal_tokens.dart';
import '../core/widgets/cards.dart';
import '../core/widgets/loader.dart';
import '../core/widgets/portal_page.dart';
import '../core/widgets/steps.dart';
import '../widgets/load_view.dart';
import 'listing_screen.dart';
import 'shell.dart';
import '../app_router.dart';
import 'package:go_router/go_router.dart';

/// Where each application stands: offers to answer first, then the ones in progress, then history.
class ApplicationsScreen extends StatefulWidget {
  const ApplicationsScreen({super.key, this.clock});

  final DateTime Function()? clock;

  @override
  State<ApplicationsScreen> createState() => _ApplicationsScreenState();
}

class _ApplicationsData {
  const _ApplicationsData({required this.applications, this.onboarding, this.sittings = const {}});
  final List<Application> applications;

  /// The worker's latest attempt per paper id: where "Take the paper" stands (ready, in progress, awaiting).
  final Map<String, WorkerSitting> sittings;

  /// Null when the talent module has nothing for this worker yet.
  final Onboarding? onboarding;

  List<Application> get offered => applications.where((a) => a.isOffered).toList();
  List<Application> get inProgress => applications.where((a) => a.isInProgress).toList();
  List<Application> get history => applications.where((a) => a.isHistory).toList();

  /// An accepted or offered application is useless until onboarding is done.
  bool get needsOnboarding => onboarding?.complete == false && applications.any((a) => a.isOffered || a.status == 'accepted');
}

class _ApplicationsScreenState extends State<ApplicationsScreen> {
  final _loadKey = GlobalKey<LoadViewState<_ApplicationsData>>();

  /// Offers the gateway refused as expired, by application id, with its reason.
  final Map<String, String> _expired = {};
  String? _busyId;
  String? _error;

  DateTime get _now => (widget.clock ?? DateTime.now)();

  Future<_ApplicationsData> _load() async {
    final scope = AppScope.of(context);
    final apps = await scope.talent.myApplications();
    Onboarding? onboarding;
    try {
      onboarding = await scope.talent.onboarding();
    } on ApiException catch (e) {
      // only "nothing on file yet" reads as no checklist; anything else is the page's error
      if (e.status != 404) rethrow;
      onboarding = null;
    }
    return _ApplicationsData(applications: apps, onboarding: onboarding, sittings: await _latestSittings(scope));
  }

  /// The newest attempt per paper. Extra: when the sittings cannot be read every paper shows "Take the paper".
  Future<Map<String, WorkerSitting>> _latestSittings(AppScope scope) async {
    try {
      final latest = <String, WorkerSitting>{};
      for (final s in await scope.assess.mySittings()) {
        final had = latest[s.paperId];
        if (had == null || s.attemptNo > had.attemptNo) latest[s.paperId] = s;
      }
      return latest;
    } on Object {
      return const {};
    }
  }

  Future<void> _reload() async => _loadKey.currentState?.reload();

  Future<void> _push(String location) async {
    await context.push(location);
    await _reload();
  }

  /// One mutation with one idempotency key per user action; [onConflict] handles a 409 and says whether
  /// it was consumed.
  Future<void> _mutate(
    Application app,
    String name,
    Future<Application> Function(String key) call, {
    required String done,
    bool Function(ApiException)? onConflict,
  }) async {
    final scope = AppScope.of(context);
    final action = '$name:${app.id}';
    setState(() {
      _busyId = app.id;
      _error = null;
    });
    try {
      await call(scope.keys.start(action));
      scope.keys.finish(action);
      if (!mounted) return;
      // Home counts offers and reads readiness from these
      ShellActions.of(context).markStale(Destination.home);
      toast(context, done);
      await _reload();
    } on ApiException catch (e) {
      scope.keys.settle(action, e);
      if (!mounted) return;
      if (!(e.isConflict && (onConflict?.call(e) ?? false))) setState(() => _error = describeError(e));
    } on Object catch (e) {
      scope.keys.settle(action, e);
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _answerOffer(Application app, {required bool accept}) async {
    final ok = await confirm(
      context,
      title: accept ? 'Accept the offer?' : 'Decline the offer?',
      body: accept
          ? 'You take a slot in ${app.listingTitle}. Finish onboarding if you have not, then claim units from Home.'
          : 'The slot goes to someone else; you can apply again later if the pool is still open.',
      confirmLabel: accept ? 'Accept' : 'Decline',
      destructive: !accept,
    );
    if (!ok || !mounted) return;
    final scope = AppScope.of(context);
    await _mutate(
      app,
      accept ? 'offer-accept' : 'offer-decline',
      (key) => scope.talent.answerOffer(app.id, accept: accept, key: key),
      done: accept ? 'Offer accepted; welcome to ${app.listingTitle}' : 'Offer declined',
      onConflict: (e) {
        if (e.code != 'offer_expired') return false;
        setState(() => _expired[app.id] = describeError(e));
        return true;
      },
    );
  }

  Future<void> _withdraw(Application app) async {
    final ok = await confirm(
      context,
      title: 'Withdraw this application?',
      body: 'You leave the ${app.listingTitle} pipeline. You can apply again while the pool is open.',
      confirmLabel: 'Withdraw',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final scope = AppScope.of(context);
    await _mutate(app, 'withdraw', (key) => scope.talent.withdraw(app.id, key: key), done: 'Application withdrawn');
  }

  @override
  Widget build(BuildContext context) {
    return LoadView<_ApplicationsData>(
      firstWait: LoadWait.brand,
      key: _loadKey,
      load: _load,
      builder: (context, data, reload) {
        final theme = Theme.of(context);
        return PortalPage(
          kicker: 'Work · Applications',
          title: 'Applications',
          subtitle: 'Where each application stands, and the offers waiting for your answer',
          onRefresh: reload,
          children: [
            ErrorBanner(_error),
            if (data.needsOnboarding)
              _OnboardingNudge(
                onboarding: data.onboarding!,
                onOpen: () => _push(Paths.onboarding(from: Destination.applications)),
              ),
            if (data.applications.isEmpty)
              PortalCard(
                child: Column(
                  children: [
                    const EmptyView(message: 'No applications yet. Open pools are waiting in Explore.'),
                    FilledButton(
                      key: const Key('applications-empty-explore'),
                      onPressed: () => ShellActions.of(context).go(Destination.explore),
                      child: const Text('Explore pools'),
                    ),
                    const SizedBox(height: Space.x8),
                  ],
                ),
              )
            else ...[
              if (data.offered.isNotEmpty) ...[
                SectionTitle('Needs your answer', subtitle: 'An offer that expires counts as declined'),
                for (final a in data.offered)
                  _OfferCard(
                    app: a,
                    now: _now,
                    busy: _busyId == a.id,
                    expiredMessage: _expired[a.id],
                    onAccept: () => _answerOffer(a, accept: true),
                    onDecline: () => _answerOffer(a, accept: false),
                  ),
              ],
              if (data.inProgress.isNotEmpty) ...[
                SectionTitle('In progress', subtitle: 'Steps complete once and stay done'),
                for (final a in data.inProgress)
                  _ProgressCard(
                    app: a,
                    sittings: data.sittings,
                    busy: _busyId == a.id,
                    onWithdraw: a.canWithdraw ? () => _withdraw(a) : null,
                    onPaper: (paperId) => _push(Paths.assessment(paperId)),
                  ),
              ],
              if (data.history.isNotEmpty) ...[const SectionTitle('History'), for (final a in data.history) _HistoryCard(a)],
            ],
            const SizedBox(height: Space.x8),
            Text(
              'Ops decides within a few days of your paper or screening; the answer lands in your inbox too.',
              style: theme.textTheme.labelSmall,
            ),
          ],
        );
      },
    );
  }
}

class _OnboardingNudge extends StatelessWidget {
  const _OnboardingNudge({required this.onboarding, required this.onOpen});
  final Onboarding onboarding;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PortalCard(
      key: const Key('onboarding-nudge'),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Finish onboarding to claim work', style: theme.textTheme.titleMedium),
                Text(
                  '${onboarding.left} of ${onboarding.total} steps left; an accepted offer only pays once you are eligible.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.x12),
          OutlinedButton(key: const Key('finish-onboarding'), onPressed: onOpen, child: const Text('Finish onboarding')),
        ],
      ),
    );
  }
}

/// The offer: a magenta-washed card with the countdown and the two answers; flips to expired when the
/// gateway says so.
class _OfferCard extends StatelessWidget {
  const _OfferCard({
    required this.app,
    required this.now,
    required this.busy,
    required this.expiredMessage,
    required this.onAccept,
    required this.onDecline,
  });
  final Application app;
  final DateTime now;
  final bool busy;
  final String? expiredMessage;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final expires = app.offerExpiresAt;
    final expired = expiredMessage != null || (expires != null && !expires.isAfter(now));
    return PortalCard(
      key: Key('offer-${app.id}'),
      emphasis: !expired,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Space.x8,
            runSpacing: Space.x8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(app.listingTitle, style: theme.textTheme.titleMedium),
              if (expired)
                const StatusChip('Expired', kind: StatusKind.warn)
              else if (expires != null)
                Countdown(until: expires, now: now, prefix: 'Expires'),
            ],
          ),
          const SizedBox(height: Space.x8),
          if (expired)
            StatusBanner(
              expiredMessage ?? 'This offer expired; expired counts as declined.',
              kind: StatusKind.warn,
              icon: Icons.timer_off_outlined,
            )
          else ...[
            Text(
              app.note.isNotEmpty
                  ? app.note
                  : 'You are offered a slot in this pool. Accept to take it; the slot waits only until the offer expires.',
              style: theme.textTheme.bodyMedium,
            ),
            if (expires != null) ...[
              const SizedBox(height: Space.x4),
              Text('Expires ${dateTime(expires)}', style: AppTheme.mono(context, fontSize: 12, color: t.textSecondary)),
            ],
            const SizedBox(height: Space.x12),
            Wrap(
              spacing: Space.x8,
              runSpacing: Space.x8,
              children: [
                FilledButton(key: Key('offer-accept-${app.id}'), onPressed: busy ? null : onAccept, child: const Text('Accept')),
                OutlinedButton(key: Key('offer-decline-${app.id}'), onPressed: busy ? null : onDecline, child: const Text('Decline')),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.app, this.sittings = const {}, required this.busy, required this.onWithdraw, required this.onPaper});
  final Application app;
  final Map<String, WorkerSitting> sittings;
  final bool busy;
  final VoidCallback? onWithdraw;
  final void Function(String paperId) onPaper;

  StepState _state(int i) {
    final s = app.steps[i];
    if (s.isDone) return StepState.done;
    if (s.isFailed) return StepState.failed;
    final firstOpen = app.steps.indexWhere((x) => !x.isDone);
    return i == firstOpen ? StepState.active : StepState.pending;
  }

  String? _hint(ApplicationStep s) {
    if (s.isDone) return null;
    return switch (s.kind) {
      'paper' => app.needsPaper ? 'Pass the paper to move to screening' : 'Opens after the form',
      'availability' => 'Confirmed when ops screens you',
      'form' => 'Your answers are in',
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PortalCard(
      key: Key('application-${app.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(app.listingTitle, style: theme.textTheme.titleMedium)),
              StatusChip(applicationLabel(app.status), kind: applicationKind(app.status)),
            ],
          ),
          if (app.createdAt != null) Text('Applied ${relative(app.createdAt!)}', style: theme.textTheme.labelSmall),
          const SizedBox(height: Space.x12),
          if (app.steps.isNotEmpty)
            StepList(
              steps: [for (final (i, s) in app.steps.indexed) StepTile(title: s.title, state: _state(i), hint: _hint(s))],
            ),
          if (app.needsPaper) _PaperAction(app: app, sittings: sittings, onPaper: onPaper),
          if (onWithdraw != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(key: Key('withdraw-${app.id}'), onPressed: busy ? null : onWithdraw, child: const Text('Withdraw')),
            ),
        ],
      ),
    );
  }
}

/// "Take the paper" needs the listing's paper id, which the application does not carry: fetched here,
/// with a skeleton while it loads and a quiet line when the listing cannot be read.
class _PaperAction extends StatefulWidget {
  const _PaperAction({required this.app, required this.sittings, required this.onPaper});
  final Application app;
  final Map<String, WorkerSitting> sittings;
  final void Function(String paperId) onPaper;

  @override
  State<_PaperAction> createState() => _PaperActionState();
}

class _PaperActionState extends State<_PaperAction> {
  late final Future<Listing> _listing = AppScope.of(context).talent.listing(widget.app.listingId);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<Listing>(
      future: _listing,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Skeleton(lines: 1, height: 36);
        final paperId = snap.data?.paperId ?? '';
        if (snap.hasError || paperId.isEmpty) {
          return Text('The paper for this pool could not be read; pull to refresh.', style: theme.textTheme.bodySmall);
        }
        final sitting = widget.sittings[paperId];
        if (sitting != null && sitting.awaitingResult) {
          return Wrap(
            spacing: Space.x12,
            runSpacing: Space.x6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusChip('Awaiting result', kind: StatusKind.info, key: Key('paper-awaiting-${widget.app.id}')),
              Text(heldReasonLabel(sitting.heldReason), style: theme.textTheme.bodySmall),
              TextButton(key: Key('take-paper-${widget.app.id}'), onPressed: () => widget.onPaper(paperId), child: const Text('View')),
            ],
          );
        }
        final resume = sitting != null && sitting.isOpen;
        return Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            key: Key('take-paper-${widget.app.id}'),
            onPressed: () => widget.onPaper(paperId),
            child: Text(resume ? 'Resume the paper' : 'Take the paper'),
          ),
        );
      },
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard(this.app);
  final Application app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final at = app.updatedAt ?? app.createdAt;
    return PortalCard(
      key: Key('application-${app.id}'),
      padding: const EdgeInsets.symmetric(horizontal: Space.x16, vertical: Space.x12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(app.listingTitle, style: theme.textTheme.bodyMedium?.copyWith(color: t.textSecondary)),
                if (app.note.isNotEmpty) Text(app.note, style: theme.textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                if (at != null) Text(relative(at), style: theme.textTheme.labelSmall?.copyWith(color: t.textMuted)),
              ],
            ),
          ),
          const SizedBox(width: Space.x12),
          StatusChip(applicationLabel(app.status), kind: applicationKind(app.status)),
        ],
      ),
    );
  }
}
