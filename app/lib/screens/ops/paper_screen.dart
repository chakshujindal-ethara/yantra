import 'package:flutter/material.dart';

import '../../api/assess_models.dart';
import '../../api/ops_models.dart';
import '../../app_scope.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/portal_tokens.dart';
import '../../core/widgets/action_dialog.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/detail_frame.dart';
import '../../core/widgets/loader.dart';
import '../../core/widgets/people.dart';
import '../../core/widgets/portal_page.dart';
import '../../core/widgets/stage_bar.dart';
import '../../core/widgets/tables.dart';
import '../../widgets/load_view.dart';
import '../assessment_screen.dart' show sittingStatus;
import '../shell.dart';
import 'papers_screen.dart' show assessmentLabel;

typedef _PaperView = ({Paper paper, List<PaperSittingRow> sittings});

/// One paper: the exam Assessment v2 runs for it, the cohorts (one per attempt number), every attempt with its
/// result, and the actions: Publish, Release, Rotate, Sync now, and Open in Assessment admin for anything about
/// the exam itself (questions, proctoring, marking, evidence).
class PaperScreen extends StatefulWidget {
  const PaperScreen({super.key, required this.paperId});
  final String paperId;

  @override
  State<PaperScreen> createState() => _PaperScreenState();
}

class _PaperScreenState extends State<PaperScreen> {
  String? _error;
  bool _busy = false;
  final Set<String> _selected = {};

  Future<_PaperView> _load() async {
    final ops = AppScope.of(context).ops;
    final paper = await ops.paper(widget.paperId);
    final sittings = await ops.paperSittings(widget.paperId);
    return (paper: paper, sittings: sittings);
  }

  /// Runs one action with its idempotency key, shows its outcome, and reloads.
  Future<void> _act(String action, Future<String> Function(String key) call, Future<void> Function() reload) async {
    final scope = AppScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final done = await withActionKey(scope.keys, action, call);
      if (!mounted) return;
      toast(context, done);
      _selected.clear();
      await reload();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = _withGates(e));
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A refused publish (`launch_blocked`) names every launch check Assessment v2 failed (`context.gates`:
  /// `{code, label, reason}`).
  String _withGates(ApiException e) {
    final gates = e.context['gates'];
    final lines = gates is List
        ? [
            for (final g in gates)
              if (g is Map) _gateLine(g) else '$g',
          ].where((l) => l.isNotEmpty).toList()
        : const <String>[];
    if (lines.isEmpty) return describeError(e);
    return 'Assessment v2 cannot open this exam yet:\n${[for (final l in lines) '• $l'].join('\n')}';
  }

  static String _gateLine(Map<dynamic, dynamic> g) {
    final label = '${g['label'] ?? g['message'] ?? g['code'] ?? ''}'.trim();
    final reason = '${g['reason'] ?? ''}'.trim();
    return reason.isEmpty ? label : '$label ($reason)';
  }

  Future<void> _publish(Paper p, Future<void> Function() reload) async {
    final ok = await confirm(
      context,
      title: 'Publish "${p.title}"?',
      body: 'Workers who apply to its pools can sit it from now on. Assessment v2 checks the exam can open first.',
      confirmLabel: 'Publish',
    );
    if (!ok || !mounted) return;
    final ops = AppScope.of(context).ops;
    await _act('paper:publish:${p.id}', (key) async {
      await ops.publishPaper(p.id, key: key);
      return 'Paper published';
    }, reload);
  }

  Future<void> _release(Paper p, List<String> ids, Future<void> Function() reload) async {
    final what = ids.isEmpty ? 'every result waiting for release' : '${ids.length} selected ${ids.length == 1 ? 'result' : 'results'}';
    final ok = await confirm(
      context,
      title: 'Release $what?',
      body: 'Workers see their scores, and a pass certifies them for ${p.gate} pools at once.',
      confirmLabel: 'Release',
    );
    if (!ok || !mounted) return;
    final ops = AppScope.of(context).ops;
    await _act('paper:release:${p.id}:${ids.join(',')}', (key) async {
      final n = await ops.releasePaper(p.id, sittingIds: ids, key: key);
      return '$n ${n == 1 ? 'result' : 'results'} released';
    }, reload);
  }

  Future<void> _rotate(Paper p, Future<void> Function() reload) async {
    final ok = await confirm(
      context,
      title: 'Rotate "${p.title}"?',
      body: 'Open cohorts close; the next attempt at every number draws a fresh set of questions. Sittings in progress finish as they are.',
      confirmLabel: 'Rotate',
    );
    if (!ok || !mounted) return;
    final ops = AppScope.of(context).ops;
    await _act('paper:rotate:${p.id}', (key) async {
      await ops.rotatePaper(p.id, key: key);
      return 'Paper rotated';
    }, reload);
  }

  Future<void> _sync(Future<void> Function() reload) async {
    final ops = AppScope.of(context).ops;
    await _act('assess:sync:${DateTime.now().millisecondsSinceEpoch ~/ 1000}', (key) async {
      await ops.syncAssess(key: key);
      return 'Read the latest attempts from Assessment v2';
    }, reload);
  }

  Future<void> _openAdmin(Paper p) async {
    final scope = AppScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final next = p.engineBaseId.isEmpty ? '/' : '/assessments/${p.engineBaseId}';
      final ticket = await withActionKey(scope.keys, 'assess:admin:$next', (key) => scope.assess.adminLaunch(next: next, key: key));
      scope.downloader.open(ticket.launchUrl);
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DetailFrame(
      crumbs: [
        const Crumb('Operate'),
        Crumb('Papers', path: Destination.papers.path),
        const Crumb('Paper'),
      ],
      body: LoadView<_PaperView>(
        firstWait: LoadWait.brand,
        load: _load,
        builder: (context, view, reload) {
          final p = view.paper;
          final waiting = view.sittings.where((s) => s.awaitingResult && !s.released).toList();
          return PortalPage(
            kicker: 'Operate · Paper',
            title: p.title,
            subtitle: 'gate ${p.gate} · ${assessmentLabel(p)} · ${p.maxAttempts} ${p.maxAttempts == 1 ? 'attempt' : 'attempts'}',
            onRefresh: reload,
            actions: [
              ConsoleStatus(p.status),
              if (p.status == 'draft')
                FilledButton.icon(
                  key: const Key('paper-publish'),
                  onPressed: _busy ? null : () => _publish(p, reload),
                  icon: const Icon(Icons.publish_outlined, size: Sizes.iconSm),
                  label: const Text('Publish'),
                ),
              if (p.isPublished)
                OutlinedButton.icon(
                  key: const Key('paper-rotate'),
                  onPressed: _busy ? null : () => _rotate(p, reload),
                  icon: const Icon(Icons.autorenew, size: Sizes.iconSm),
                  label: const Text('Rotate'),
                ),
              OutlinedButton.icon(
                key: const Key('paper-sync'),
                onPressed: _busy ? null : () => _sync(reload),
                icon: const Icon(Icons.sync, size: Sizes.iconSm),
                label: const Text('Sync now'),
              ),
              if (p.engine == 'v2')
                OutlinedButton.icon(
                  key: const Key('paper-open-admin'),
                  onPressed: _busy ? null : () => _openAdmin(p),
                  icon: const Icon(Icons.open_in_new, size: Sizes.iconSm),
                  label: const Text('Open in Assessment admin'),
                ),
            ],
            children: [
              // always in the tree so an appearing banner never shifts the cards below it
              ErrorBanner(_error, key: const Key('paper-error')),
              KpiRow(
                children: [
                  KpiTile(label: 'Attempts', value: '${p.stats.total}', note: 'Every sitting so far', icon: Icons.event_seat_outlined),
                  KpiTile(
                    label: 'Passed',
                    value: '${p.stats.passed}',
                    note: 'Certified for ${p.gate}',
                    kind: StatusKind.success,
                    icon: Icons.verified_outlined,
                  ),
                  KpiTile(
                    label: 'Awaiting result',
                    value: '${p.stats.awaitingResult}',
                    note: p.autoRelease ? 'Being marked' : 'Marked or marking; ops release',
                    kind: p.stats.awaitingResult > 0 ? StatusKind.warn : StatusKind.info,
                    icon: Icons.hourglass_top_outlined,
                  ),
                  KpiTile(
                    label: 'Pass rate',
                    value: p.stats.total == 0 ? '—' : percent(p.stats.passRate),
                    note: p.stats.total == 0 ? 'Nobody has sat it yet' : 'Of decided attempts',
                    icon: Icons.percent,
                  ),
                ],
              ),
              _ExamCard(paper: p),
              if (p.cohorts.isNotEmpty) ...[
                SectionTitle('Cohorts', subtitle: 'One exam in Assessment v2 per attempt number'),
                PortalTable(
                  minWidth: 520,
                  columns: const [
                    PortalColumn('Attempt', width: 90),
                    PortalColumn('Generation', width: 110, numeric: true),
                    PortalColumn('Assessment'),
                    PortalColumn('State', width: 120),
                  ],
                  rows: [
                    for (final c in p.cohorts)
                      PortalRow([
                        Text('${c.attemptNo}'),
                        Text('${c.generation}'),
                        Text('#${c.engineAssessmentId}', style: AppTheme.mono(context, fontSize: 13)),
                        ConsoleStatus(c.state),
                      ], key: Key('cohort-${c.id}')),
                  ],
                ),
              ],
              SectionTitle(
                'Attempts',
                subtitle: view.sittings.isEmpty ? 'Nobody has sat it yet' : '${view.sittings.length} · newest first',
                trailing: waiting.isEmpty
                    ? null
                    : Wrap(
                        spacing: Space.x8,
                        children: [
                          if (_selected.isNotEmpty)
                            OutlinedButton(
                              key: const Key('release-selected'),
                              onPressed: _busy ? null : () => _release(p, _selected.toList(), reload),
                              child: Text('Release ${_selected.length}'),
                            ),
                          FilledButton(
                            key: const Key('release-all'),
                            onPressed: _busy ? null : () => _release(p, const [], reload),
                            child: const Text('Release all'),
                          ),
                        ],
                      ),
              ),
              if (view.sittings.isEmpty)
                const PortalCard(child: EmptyView(message: 'No attempts yet. Workers start the exam from their application.'))
              else
                PortalTable(
                  minWidth: 960,
                  columns: const [
                    PortalColumn('', width: 48),
                    PortalColumn('Worker', flex: 2),
                    PortalColumn('Attempt', width: 80, numeric: true),
                    PortalColumn('Status', width: 150),
                    PortalColumn('Score', width: 80, numeric: true),
                    PortalColumn('Released', width: 90),
                    PortalColumn('Waiting for', flex: 2),
                    PortalColumn('Flags', flex: 2),
                  ],
                  rows: [
                    for (final s in view.sittings)
                      PortalRow(
                        [
                          s.awaitingResult && !s.released
                              ? Checkbox(
                                  key: Key('select-${s.id}'),
                                  value: _selected.contains(s.id),
                                  semanticLabel: 'Select the attempt of ${s.workerName.isEmpty ? 'this worker' : s.workerName}',
                                  onChanged: _busy ? null : (v) => setState(() => v == true ? _selected.add(s.id) : _selected.remove(s.id)),
                                )
                              : const SizedBox.shrink(),
                          NameOf(s.workerId, name: s.workerName),
                          Text('${s.attemptNo}'),
                          Builder(
                            builder: (_) {
                              final (label, kind) = sittingStatus(s.status);
                              // a fixed column: the chip shrinks rather than overflow at large text sizes
                              return FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: StatusChip(label, kind: kind),
                              );
                            },
                          ),
                          Text(s.score == null ? '—' : percent(s.score)),
                          Text(s.released ? 'Yes' : 'No'),
                          Text(s.awaitingResult ? heldReasonLabel(s.heldReason) : '—', overflow: TextOverflow.ellipsis),
                          Text(s.flags.isEmpty ? '—' : s.flags.map(humanize).join(', '), overflow: TextOverflow.ellipsis),
                        ],
                        key: Key('sitting-${s.id}'),
                        selected: _selected.contains(s.id),
                      ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The exam as Assessment v2 last reported it.
class _ExamCard extends StatelessWidget {
  const _ExamCard({required this.paper});
  final Paper paper;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final s = paper.snapshot;
    return PortalCard(
      key: const Key('paper-exam'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('The exam', style: theme.textTheme.titleSmall),
          const SizedBox(height: Space.x8),
          if (paper.description.isNotEmpty) ...[
            Text(paper.description, style: theme.textTheme.bodyMedium),
            const SizedBox(height: Space.x8),
          ],
          Wrap(
            spacing: Space.x20,
            runSpacing: Space.x8,
            children: [
              Fact(icon: Icons.timer_outlined, text: s.durationMinutes > 0 ? minutesLabel(s.durationMinutes) : 'No time limit'),
              Fact(icon: Icons.help_outline, text: '${s.questionCount} ${s.questionCount == 1 ? 'question' : 'questions'}'),
              Fact(icon: Icons.flag_outlined, text: 'Pass mark ${percent(s.passThreshold)}'),
              Fact(icon: Icons.lock_open_outlined, text: paper.autoRelease ? 'Objective results release at once' : 'Ops release results'),
            ],
          ),
          if (s.questionTypes.isNotEmpty) ...[
            const SizedBox(height: Space.x12),
            Wrap(
              spacing: Space.x8,
              runSpacing: Space.x6,
              children: [for (final q in s.questionTypes) StatusChip(questionTypeLabel(q), kind: StatusKind.info)],
            ),
          ],
          const SizedBox(height: Space.x12),
          Text(
            s.proctoring.isEmpty ? 'No proctoring rules' : 'Proctoring: ${s.proctoring.on.map(Proctoring.label).join(' · ')}',
            key: const Key('paper-proctoring'),
            style: theme.textTheme.bodySmall?.copyWith(color: t.textSecondary),
          ),
        ],
      ),
    );
  }
}
