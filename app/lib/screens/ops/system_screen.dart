import 'package:flutter/material.dart';

import '../../api/system_models.dart';
import '../../api/system_repository.dart';
import '../../app_scope.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/page_commands.dart';
import '../../core/people.dart' show shortId;
import '../../core/theme/app_theme.dart';
import '../../core/theme/portal_tokens.dart';
import '../../core/widgets/action_dialog.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/loader.dart';
import '../../core/widgets/page_tabs.dart';
import '../../core/widgets/people.dart';
import '../../core/widgets/portal_page.dart';
import '../../core/widgets/tables.dart';
import '../../widgets/load_view.dart';

extension on AppScope {
  SystemRepository get system => SystemRepository(client.gateway);
}

enum _Tab {
  stuck('Stuck work'),
  dead('Dead letters'),
  jobs('Jobs');

  const _Tab(this.label);
  final String label;
}

/// The System page (admin and ops): what the background left behind and how it is doing. Stuck work lists
/// claims and review claims past their time with a Release button each and Release all (the scheduler also
/// releases them within a minute; this is for seeing it and not waiting), plus what was released in the
/// last 7 days and by whom. Dead letters lists, per module, the messages a consumer gave up on, each with
/// Replay. Jobs shows every scheduled job: next run, last run, last error, and the ones that are behind.
class SystemScreen extends StatefulWidget {
  const SystemScreen({super.key});

  @override
  State<SystemScreen> createState() => _SystemScreenState();
}

class _SystemScreenState extends State<SystemScreen> {
  _Tab _tab = _Tab.stuck;
  final _stuck = GlobalKey<LoadViewState<_Stuck>>();
  final _dead = GlobalKey<LoadViewState<List<ModuleDead>>>();
  final _jobs = GlobalKey<LoadViewState<List<ModuleJobs>>>();

  Future<void> _refresh() async {
    await switch (_tab) {
      _Tab.stuck => _stuck.currentState?.reload(),
      _Tab.dead => _dead.currentState?.reload(),
      _Tab.jobs => _jobs.currentState?.reload(),
    };
  }

  /// Row actions in flight (by action name); their buttons and Release all wait for them.
  final Set<String> _running = {};
  bool _releasingAll = false;

  bool get _busy => _releasingAll || _running.isNotEmpty;

  Future<void> _act(String action, Future<void> Function(String key) call, String done) async {
    if (_releasingAll || _running.contains(action)) return;
    final scope = AppScope.of(context);
    setState(() => _running.add(action));
    try {
      await withActionKey(scope.keys, action, call);
      if (!mounted) return;
      toast(context, done);
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e));
    } finally {
      if (mounted) setState(() => _running.remove(action));
    }
    await _refresh();
  }

  Future<void> _releaseAll() async {
    final ok = await confirm(
      context,
      title: 'Release all stuck work?',
      body:
          'Every claim and review claim past its time goes back to its queue now. The people holding them lose them; anything they had not submitted is not saved.',
      confirmLabel: 'Release all',
      destructive: true,
    );
    if (!ok || !mounted || _busy) return;
    final scope = AppScope.of(context);
    setState(() => _releasingAll = true);
    try {
      final r = await withActionKey(scope.keys, 'release-all', (key) => scope.system.releaseAll(key: key));
      final n = r.released;
      if (mounted) toast(context, '${n == 1 ? '1 claim released' : '$n claims released'}${r.more ? '; more remain, run it again' : ''}');
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e));
    } finally {
      if (mounted) setState(() => _releasingAll = false);
    }
    await _refresh();
  }

  /// A unit waiting days for one worker (a rework author who left or is held) goes back to the pool.
  Future<void> _unassign(StuckAssignedUnit u) async {
    final ok = await confirm(
      context,
      title: 'Return this unit to the pool?',
      body:
          '${u.externalRef.isEmpty ? 'The unit' : u.externalRef} has waited ${_days(u.daysWaiting)} for ${personLabel(context, u.workerId, name: u.workerName)}. '
          'It goes back to the pool and any eligible worker can claim it. The change is signed with your name.',
      confirmLabel: 'Return to pool',
    );
    if (!ok || !mounted) return;
    final ops = AppScope.of(context).ops;
    await _act('unassign:${u.unitId}', (key) => ops.unassignUnit(u.unitId, key: key), 'Unit back in the pool');
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return PortalPage(
      kicker: 'Admin · System',
      title: 'System',
      subtitle: 'Stuck work, dead letters and the scheduled jobs of every module',
      onRefresh: _refresh,
      commands: [
        PageCommand('Release all stuck work', Icons.lock_open_outlined, _releaseAll, key: const Key('cmd-release-all')),
        PageCommand('Refresh', Icons.refresh, _refresh),
      ],
      actions: [IconButton(key: const Key('system-refresh'), tooltip: 'Refresh', onPressed: _refresh, icon: const Icon(Icons.refresh))],
      children: [
        PageTabs<_Tab>(tabs: {for (final t in _Tab.values) t: t.label}, selected: _tab, onSelected: (t) => setState(() => _tab = t)),
        switch (_tab) {
          _Tab.stuck => LoadView<_Stuck>(
            key: _stuck,
            wrapInCard: true,
            load: () async {
              // units waiting for one worker are their own section: market failing there leaves the claims usable
              final assigned = scope.system.stuckAssigned().then<Object>((v) => v).catchError((Object e) => describeError(e));
              final r = await Future.wait<Object>([
                scope.system.expiredClaims(),
                scope.system.expiredReviews(),
                scope.system.released(),
                assigned,
              ]);
              final waiting = r[3];
              return _Stuck(
                r[0] as List<ExpiredClaim>,
                r[1] as List<ExpiredReview>,
                r[2] as List<Released>,
                assigned: waiting is List<StuckAssignedUnit> ? waiting : const [],
                assignedError: waiting is String ? waiting : null,
              );
            },
            builder: (context, s, _) => _StuckView(
              s,
              onReleaseAll: _busy ? null : _releaseAll,
              running: (action) => _releasingAll || _running.contains(action),
              onClaim: (c) => _act('release-claim:${c.claimId}', (key) => scope.system.releaseClaim(c.claimId, key: key), 'Claim released'),
              onReview: (r) =>
                  _act('release-review:${r.taskId}', (key) => scope.system.releaseReview(r.taskId, key: key), 'Review claim released'),
              onUnassign: _unassign,
            ),
          ),
          _Tab.dead => LoadView<List<ModuleDead>>(
            key: _dead,
            wrapInCard: true,
            load: scope.system.deadLetters,
            builder: (context, modules, _) => _DeadView(
              modules,
              running: (action) => _running.contains(action),
              onReplay: (m, d) => _act('replay:$m:${d.id}', (key) => scope.system.replay(m, d.id, key: key), 'Replayed'),
            ),
          ),
          _Tab.jobs => LoadView<List<ModuleJobs>>(
            key: _jobs,
            wrapInCard: true,
            load: scope.system.jobs,
            builder: (context, modules, _) => _JobsView(modules),
          ),
        },
      ],
    );
  }
}

class _Stuck {
  const _Stuck(this.claims, this.reviews, this.released, {this.assigned = const [], this.assignedError});
  final List<ExpiredClaim> claims;
  final List<ExpiredReview> reviews;
  final List<Released> released;

  /// Units waiting days for one worker; [assignedError] when market could not list them.
  final List<StuckAssignedUnit> assigned;
  final String? assignedError;
}

String _days(int n) => n == 1 ? '1 day' : '$n days';

/// A job's next run: `in 5 h` ahead of now, `within a minute` when it is about to, `due 3 min ago` once it has passed.
String _when(DateTime at, DateTime now) {
  if (!at.isAfter(now)) return 'due ${relative(at, now: now)}';
  return at.difference(now) < const Duration(minutes: 1) ? 'within a minute' : untilShort(at, now: now);
}

String _overdue(int minutes) => minutes < 60 ? '$minutes min' : '${minutes ~/ 60} h ${minutes % 60} min';

class _StuckView extends StatelessWidget {
  const _StuckView(
    this.s, {
    required this.onReleaseAll,
    required this.running,
    required this.onClaim,
    required this.onReview,
    required this.onUnassign,
  });
  final _Stuck s;

  /// Null while anything is in flight.
  final VoidCallback? onReleaseAll;

  /// Whether the row action named so is in flight (or Release all is).
  final bool Function(String action) running;
  final void Function(ExpiredClaim) onClaim;
  final void Function(ExpiredReview) onReview;
  final void Function(StuckAssignedUnit) onUnassign;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = s.claims.length + s.reviews.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PortalCard(
          key: const Key('stuck-summary'),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      total == 0 ? 'Nothing is stuck' : '$total stuck: ${s.claims.length} work, ${s.reviews.length} review',
                      style: theme.textTheme.titleMedium,
                    ),
                    Text(
                      'The scheduler releases expired claims within a minute. Release here when you cannot wait.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Space.x12),
              FilledButton.icon(
                key: const Key('release-all'),
                onPressed: total == 0 ? null : onReleaseAll,
                icon: const Icon(Icons.lock_open_outlined, size: Sizes.iconSm),
                label: const Text('Release all'),
              ),
            ],
          ),
        ),
        const SectionTitle('Work claims past their time'),
        PortalTable(
          minWidth: 860,
          emptyMessage: 'No work claim is past its time.',
          columns: const [
            PortalColumn('Unit', flex: 2),
            PortalColumn('Project · batch', flex: 3),
            PortalColumn('Held by', flex: 2),
            PortalColumn('Overdue', numeric: true, width: 100),
            PortalColumn('', width: 120),
          ],
          rows: [
            for (final c in s.claims)
              PortalRow(key: Key('stuck-claim-${c.claimId}'), [
                Text(c.externalRef.isEmpty ? shortId(c.unitId) : c.externalRef, style: AppTheme.mono(context, fontSize: 12)),
                Text('${c.projectName} · ${c.batchTitle}', overflow: TextOverflow.ellipsis),
                NameOf(c.workerId, name: c.workerName),
                Text(_overdue(c.minutesOverdue)),
                TextButton(
                  key: Key('release-claim-${c.claimId}'),
                  onPressed: running('release-claim:${c.claimId}') ? null : () => onClaim(c),
                  child: Text(
                    'Release',
                    semanticsLabel: 'Release the claim of ${personLabel(context, c.workerId, name: c.workerName)} on ${c.batchTitle}',
                  ),
                ),
              ]),
          ],
        ),
        const SizedBox(height: Space.x16),
        const SectionTitle('Review claims past their time'),
        PortalTable(
          minWidth: 760,
          emptyMessage: 'No review claim is past its time.',
          columns: const [
            PortalColumn('Kind', width: 90),
            PortalColumn('Batch', flex: 2),
            PortalColumn('Held by', flex: 2),
            PortalColumn('Overdue', numeric: true, width: 100),
            PortalColumn('', width: 120),
          ],
          rows: [
            for (final r in s.reviews)
              PortalRow(key: Key('stuck-review-${r.taskId}'), [
                Text(humanize(r.kind)),
                ShortId(r.batchId),
                NameOf(r.holderId),
                Text(_overdue(r.minutesOverdue)),
                TextButton(
                  key: Key('release-review-${r.taskId}'),
                  onPressed: running('release-review:${r.taskId}') ? null : () => onReview(r),
                  child: Text(
                    'Release',
                    semanticsLabel:
                        'Release the ${humanize(r.kind).toLowerCase()} claim of ${personLabel(context, r.holderId)} on batch ${shortId(r.batchId)}',
                  ),
                ),
              ]),
          ],
        ),
        const SizedBox(height: Space.x16),
        const SectionTitle(
          'Units waiting for one worker',
          subtitle: 'Assigned to a worker more than 3 days ago and not taken: a rework author who left, is held or paused',
        ),
        if (s.assignedError != null)
          StatusBanner(
            "Couldn't list them: ${s.assignedError}",
            key: const Key('stuck-assigned-error'),
            kind: StatusKind.warn,
            icon: Icons.sync_problem_outlined,
          )
        else
          PortalTable(
            minWidth: 860,
            emptyMessage: 'No unit is waiting for one worker.',
            columns: const [
              PortalColumn('Unit', flex: 2),
              PortalColumn('Project · batch', flex: 3),
              PortalColumn('Assigned to', flex: 2),
              PortalColumn('Waiting', numeric: true, width: 100),
              PortalColumn('', width: 150),
            ],
            rows: [
              for (final u in s.assigned)
                PortalRow(key: Key('stuck-assigned-${u.unitId}'), [
                  Text(u.externalRef.isEmpty ? shortId(u.unitId) : u.externalRef, style: AppTheme.mono(context, fontSize: 12)),
                  Text('${u.projectName} · ${u.batchTitle}', overflow: TextOverflow.ellipsis),
                  NameOf(u.workerId, name: u.workerName),
                  Text(_days(u.daysWaiting)),
                  TextButton(
                    key: Key('unassign-${u.unitId}'),
                    onPressed: running('unassign:${u.unitId}') ? null : () => onUnassign(u),
                    child: Text(
                      'Return to pool',
                      semanticsLabel: 'Return the unit waiting for ${personLabel(context, u.workerId, name: u.workerName)} to the pool',
                    ),
                  ),
                ]),
            ],
          ),
        const SizedBox(height: Space.x16),
        const SectionTitle(
          'Released in the last 7 days',
          subtitle: 'By the scheduler, by an operator, or given back by the person holding it',
        ),
        PortalTable(
          minWidth: 720,
          emptyMessage: 'Nothing was released in the last 7 days.',
          columns: const [
            PortalColumn('Kind', width: 90),
            PortalColumn('Held by', flex: 2),
            PortalColumn('Released by', flex: 2),
            PortalColumn('When', width: 140),
          ],
          rows: [
            for (final r in s.released)
              PortalRow(key: Key('released-${r.id}'), [
                Text(humanize(r.kind)),
                NameOf(r.holderId, name: r.holderName),
                r.byHolder
                    ? const Text('Given back')
                    : r.byJob
                    ? const Text('Scheduler')
                    : NameOf(r.releasedBy, name: r.releasedByName),
                Text(r.releasedAt == null ? '—' : relative(r.releasedAt!)),
              ]),
          ],
        ),
      ],
    );
  }
}

class _DeadView extends StatelessWidget {
  const _DeadView(this.modules, {required this.running, required this.onReplay});
  final List<ModuleDead> modules;
  final bool Function(String action) running;
  final void Function(String module, DeadLetter d) onReplay;

  @override
  Widget build(BuildContext context) {
    final total = modules.fold<int>(0, (a, m) => a + m.letters.length);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatusBanner(
          total == 0
              ? 'No dead letters. Every event was handled.'
              : '$total dead ${total == 1 ? 'letter' : 'letters'}. Fix the cause, then replay; a replay that fails again stays here.',
          kind: total == 0 ? StatusKind.success : StatusKind.warn,
          key: const Key('dead-summary'),
        ),
        for (final m in modules)
          if (m.error != null || m.letters.isNotEmpty) ...[
            SectionTitle(humanize(m.module), subtitle: m.error ?? '${m.letters.length} waiting'),
            if (m.error == null)
              PortalTable(
                minWidth: 860,
                columns: const [
                  PortalColumn('Event', flex: 3),
                  PortalColumn('Consumer', flex: 2),
                  PortalColumn('Tries', numeric: true, width: 70),
                  PortalColumn('Reason', flex: 3),
                  PortalColumn('Dead', width: 110),
                  PortalColumn('', width: 110),
                ],
                rows: [
                  for (final d in m.letters)
                    PortalRow(key: Key('dead-${d.id}'), [
                      Text(d.type ?? 'undecodable', style: AppTheme.mono(context, fontSize: 12), overflow: TextOverflow.ellipsis),
                      Text(d.consumer, style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                      Text('${d.deliveries}'),
                      Tooltip(
                        message: d.reason,
                        child: Text(d.reason, overflow: TextOverflow.ellipsis),
                      ),
                      Text(d.deadAt == null ? '—' : relative(d.deadAt!)),
                      TextButton(
                        key: Key('replay-${d.id}'),
                        onPressed: running('replay:${m.module}:${d.id}') ? null : () => onReplay(m.module, d),
                        child: Text('Replay', semanticsLabel: 'Replay ${d.type ?? 'the undecodable event'} for ${d.consumer}'),
                      ),
                    ]),
                ],
              ),
            const SizedBox(height: Space.x12),
          ],
      ],
    );
  }
}

class _JobsView extends StatelessWidget {
  const _JobsView(this.modules);
  final List<ModuleJobs> modules;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final all = [for (final m in modules) ...m.jobs];
    final behind = all.where((j) => j.overdue(now)).length;
    final failing = all.where((j) => (j.lastError ?? '').isNotEmpty).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatusBanner(
          behind == 0 && failing == 0
              ? 'All ${all.length} jobs are on schedule.'
              : '${all.length} jobs: $behind behind schedule, $failing whose last run failed.',
          kind: behind == 0 && failing == 0 ? StatusKind.success : StatusKind.warn,
          key: const Key('jobs-summary'),
        ),
        for (final m in modules) ...[
          SectionTitle(humanize(m.module), subtitle: m.error),
          if (m.error == null)
            PortalTable(
              minWidth: 820,
              emptyMessage: 'No scheduled job.',
              columns: const [
                PortalColumn('Job', flex: 3),
                PortalColumn('Next run', width: 130),
                PortalColumn('Last run', width: 130),
                PortalColumn('Result', numeric: true, width: 80),
                PortalColumn('State', width: 160),
              ],
              rows: [
                for (final j in m.jobs)
                  PortalRow(key: Key('job-${j.name}'), [
                    Text(j.name, style: AppTheme.mono(context, fontSize: 12), overflow: TextOverflow.ellipsis),
                    Text(j.nextRunAt == null ? '—' : _when(j.nextRunAt!, now)),
                    Text(j.lastRunAt == null ? 'never' : relative(j.lastRunAt!)),
                    Text(j.lastResult == null ? '—' : '${j.lastResult}'),
                    FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: _jobState(j, now)),
                  ]),
              ],
            ),
          const SizedBox(height: Space.x12),
        ],
      ],
    );
  }

  Widget _jobState(JobRow j, DateTime now) {
    final error = j.lastError ?? '';
    if (error.isNotEmpty) {
      return Tooltip(
        message: error,
        child: const StatusChip('Last run failed', kind: StatusKind.dest),
      );
    }
    if (j.overdue(now)) return const StatusChip('Behind', kind: StatusKind.warn);
    if (j.lockedUntil != null && j.lockedUntil!.isAfter(now)) return const StatusChip('Running', kind: StatusKind.info);
    return const StatusChip('On schedule', kind: StatusKind.success);
  }
}
