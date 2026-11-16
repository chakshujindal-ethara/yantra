import 'package:flutter/material.dart';

import '../api/assess_models.dart';
import '../app_scope.dart';
import '../core/errors.dart';
import '../core/format.dart';
import '../core/poller.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/portal_tokens.dart';
import '../core/widgets/action_dialog.dart';
import '../core/widgets/cards.dart';
import '../core/widgets/detail_frame.dart';
import '../core/widgets/loader.dart';
import '../core/widgets/portal_page.dart';
import '../widgets/load_view.dart';
import 'shell.dart';

/// How often an "awaiting result" brief is read again while the screen is open.
const assessmentPollEvery = Duration(seconds: 5);

/// A paper: what it asks, then Start, which opens the exam in Assessment v2 in this tab, already signed in.
/// The exam app sends the worker back here, where the result appears once it is marked and released.
class AssessmentScreen extends StatefulWidget {
  const AssessmentScreen({super.key, required this.paperId});

  final String paperId;

  @override
  State<AssessmentScreen> createState() => _AssessmentScreenState();
}

class _AssessmentScreenState extends State<AssessmentScreen> {
  PaperBrief? _brief;
  List<WorkerSitting> _history = const [];
  bool _loading = true;
  String? _loadError;
  String? _error;
  bool _busy = false;
  int? _unlocks;
  Poller? _poller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _poller?.dispose();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    if (!mounted) return;
    if (!quiet) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    final scope = AppScope.of(context);
    try {
      final brief = await scope.assess.brief(widget.paperId);
      final history = await _readHistory(scope);
      if (!mounted) return;
      setState(() {
        _brief = brief;
        _history = history;
      });
      _follow(brief);
      if (brief.certified && _unlocks == null) await _countUnlocks(scope, brief.gate);
    } on Object catch (e) {
      if (mounted && !quiet) setState(() => _loadError = describeError(e));
    } finally {
      if (mounted && !quiet) setState(() => _loading = false);
    }
  }

  /// The worker's attempts at this paper, newest first. The history is extra: when it cannot be read the
  /// brief still stands.
  Future<List<WorkerSitting>> _readHistory(AppScope scope) async {
    try {
      final all = await scope.assess.mySittings();
      final mine = all.where((s) => s.paperId == widget.paperId).toList()..sort((a, b) => b.attemptNo.compareTo(a.attemptNo));
      return mine;
    } on Object {
      return _history;
    }
  }

  /// While a result is on its way, read the brief again every few seconds; stop once it has landed.
  void _follow(PaperBrief brief) {
    if (brief.awaitingResult) {
      _poller ??= Poller(every: assessmentPollEvery, tick: () => _load(quiet: true))..start();
    } else {
      _poller?.dispose();
      _poller = null;
    }
  }

  Future<void> _countUnlocks(AppScope scope, String gate) async {
    try {
      final listings = await scope.talent.listings();
      if (mounted) setState(() => _unlocks = listings.where((l) => l.certGate == gate).length);
    } on Object {
      // the count is a nicety; the certification stands without it
    }
  }

  /// Start or Resume: a fresh one-time link into the exam app, opened in this tab.
  Future<void> _launch() async {
    final scope = AppScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ticket = await withActionKey(
        scope.keys,
        'paper:launch:${widget.paperId}',
        (key) => scope.assess.launch(widget.paperId, key: key),
      );
      scope.session.openExternal(ticket.launchUrl);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = describeError(e));
      if (const {'attempts_exhausted', 'already_certified', 'result_pending', 'paper_retired'}.contains(e.code)) await _load(quiet: true);
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final brief = _brief;
    return DetailFrame(
      crumbs: [
        const Crumb('Work'),
        Crumb('Applications', path: Destination.applications.path),
        Crumb(brief?.title ?? 'Assessment'),
      ],
      body: brief == null
          ? (_loading ? const Center(child: BrandLoader()) : ErrorView(message: _loadError ?? 'No data', onRetry: _load))
          : PortalPage(
              kicker: 'Work · Assessment',
              title: brief.title,
              subtitle: 'Certifies you for ${humanize(brief.gate).toLowerCase()} pools',
              onRefresh: _load,
              children: [
                ErrorBanner(_error, key: const Key('assessment-error')),
                _BriefCard(brief: brief),
                _StateCard(brief: brief, latest: _history.firstOrNull, unlocks: _unlocks, busy: _busy, onLaunch: _launch),
                if (_history.isNotEmpty) ...[
                  SectionTitle('Your attempts', subtitle: '${_history.length} so far'),
                  PortalCard(child: Column(children: [for (final s in _history) _AttemptRow(s)])),
                ],
              ],
            ),
    );
  }
}

/// What the paper asks: time, pass mark, questions, attempts, question kinds and the proctoring rules.
class _BriefCard extends StatelessWidget {
  const _BriefCard({required this.brief});
  final PaperBrief brief;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (brief.description.isNotEmpty) ...[
            Text(brief.description, style: theme.textTheme.bodyMedium),
            const SizedBox(height: Space.x12),
          ],
          Wrap(
            spacing: Space.x20,
            runSpacing: Space.x8,
            children: [
              Fact(icon: Icons.timer_outlined, text: brief.durationMinutes > 0 ? minutesLabel(brief.durationMinutes) : 'No time limit'),
              if (brief.passMark > 0) Fact(icon: Icons.flag_outlined, text: 'Pass mark ${brief.passMarkPercent}%'),
              if (brief.questionCount > 0)
                Fact(icon: Icons.help_outline, text: '${brief.questionCount} ${brief.questionCount == 1 ? 'question' : 'questions'}'),
              Fact(
                key: const Key('attempts-left'),
                icon: Icons.replay_outlined,
                text: '${brief.attemptsLeft} ${brief.attemptsLeft == 1 ? 'attempt' : 'attempts'} left',
              ),
            ],
          ),
          if (brief.questionTypes.isNotEmpty) ...[
            const SizedBox(height: Space.x12),
            Wrap(
              spacing: Space.x8,
              runSpacing: Space.x6,
              children: [for (final q in brief.questionTypes) StatusChip(questionTypeLabel(q), kind: StatusKind.info)],
            ),
          ],
          if (!brief.proctoring.isEmpty) ...[
            const SizedBox(height: Space.x16),
            Text('While you sit', style: theme.textTheme.titleSmall),
            const SizedBox(height: Space.x6),
            for (final rule in brief.proctoring.on)
              Padding(
                key: Key('rule-$rule'),
                padding: const EdgeInsets.symmetric(vertical: Space.x2),
                child: Row(
                  children: [
                    Icon(Icons.shield_outlined, size: Sizes.iconSm, color: t.textSecondary),
                    const SizedBox(width: Space.x8),
                    Expanded(child: Text(Proctoring.label(rule), style: theme.textTheme.bodyMedium)),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Where the worker stands with this paper, and the one thing to do next.
class _StateCard extends StatelessWidget {
  const _StateCard({required this.brief, required this.latest, required this.unlocks, required this.busy, required this.onLaunch});
  final PaperBrief brief;
  final WorkerSitting? latest;
  final int? unlocks;
  final bool busy;
  final VoidCallback onLaunch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = brief.current;
    if (brief.certified) {
      final pass = latest != null && latest!.passed ? latest : (current != null && current.passed ? current : null);
      final score = pass != null && pass.released ? ' with ${pass.scorePercent}%' : '';
      final n = unlocks;
      return StatusBanner(
        key: const Key('exam-certified'),
        'Certified$score. You can now work in ${humanize(brief.gate).toLowerCase()} pools'
        '${n == null ? '.' : ': $n ${n == 1 ? 'pool' : 'pools'} open right now.'}',
        kind: StatusKind.success,
        icon: Icons.verified_outlined,
      );
    }
    if (current != null && current.awaitingResult) {
      return StatusBanner(
        key: const Key('exam-awaiting'),
        'Submitted. Awaiting your result: ${heldReasonLabel(current.heldReason).toLowerCase()}. This page updates by itself.',
        kind: StatusKind.info,
        icon: Icons.hourglass_top_outlined,
      );
    }
    // the history's newest attempt, else the brief's own latest when the history could not be read
    final failed = latest != null && latest!.failed ? latest : (current != null && current.failed ? current : null);
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (failed != null) ...[
            StatusBanner(
              key: const Key('exam-failed'),
              'Not passed: ${failed.scorePercent}% against a pass mark of ${brief.passMarkPercent}%. '
              '${brief.attemptsLeft} ${brief.attemptsLeft == 1 ? 'attempt' : 'attempts'} left; a retake is a fresh paper with new questions.',
              kind: StatusKind.warn,
              icon: Icons.info_outline,
            ),
            const SizedBox(height: Space.x12),
          ],
          if (brief.canResume)
            _Action(
              text: current!.status == 'in_progress'
                  ? 'Your exam is in progress. Its clock keeps running while you are away.'
                  : 'Your exam is ready. The clock starts when you begin inside the exam.',
              button: FilledButton.icon(
                key: const Key('resume-exam'),
                onPressed: busy ? null : onLaunch,
                icon: const Icon(Icons.open_in_new, size: Sizes.iconSm),
                label: const Text('Resume in Assessment'),
              ),
            )
          else if (brief.attemptsExhausted)
            const StatusBanner(
              'You have used every attempt on this paper. Ask ops if you believe that is wrong.',
              kind: StatusKind.warn,
              icon: Icons.block_outlined,
            )
          else
            _Action(
              text: 'The exam opens in Assessment in this tab, already signed in. When you submit, it brings you back here.',
              button: FilledButton.icon(
                key: const Key('start-exam'),
                onPressed: busy ? null : onLaunch,
                icon: const Icon(Icons.play_arrow, size: Sizes.iconSm),
                label: Text(failed == null ? 'Start in Assessment' : 'Start the retake'),
              ),
            ),
          if (busy) ...[const SizedBox(height: Space.x8), Text('Opening the exam…', style: theme.textTheme.bodySmall)],
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.text, required this.button});
  final String text;
  final Widget button;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: Space.x16,
    runSpacing: Space.x12,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
      ),
      button,
    ],
  );
}

class _AttemptRow extends StatelessWidget {
  const _AttemptRow(this.s);
  final WorkerSitting s;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final (label, kind) = sittingStatus(s.status);
    final when = s.submittedAt ?? s.startedAt;
    return Padding(
      key: Key('attempt-${s.id}'),
      padding: const EdgeInsets.symmetric(vertical: Space.x6),
      child: Wrap(
        spacing: Space.x12,
        runSpacing: Space.x4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('Attempt ${s.attemptNo}', style: theme.textTheme.bodyMedium),
          StatusChip(label, kind: kind),
          if (s.released && (s.passed || s.failed)) Text('${s.scorePercent}%', style: AppTheme.figure(context, fontSize: 13)),
          if (when != null) Text(shortDate(when), style: theme.textTheme.bodySmall?.copyWith(color: t.textMuted)),
        ],
      ),
    );
  }
}

/// A sitting's status as a chip, the same words on every screen.
(String, StatusKind) sittingStatus(String status) => switch (status) {
  'assigned' => ('Ready', StatusKind.info),
  'in_progress' => ('In progress', StatusKind.info),
  'awaiting_result' => ('Awaiting result', StatusKind.info),
  'passed' => ('Passed', StatusKind.success),
  'failed' => ('Not passed', StatusKind.warn),
  'void' => ('Withdrawn', StatusKind.info),
  _ => (humanize(status), StatusKind.info),
};
