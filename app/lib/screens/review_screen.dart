import 'dart:async';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../app_scope.dart';
import '../core/action_keys.dart';
import '../core/errors.dart';
import '../core/format.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/portal_tokens.dart';
import '../core/widgets/cards.dart';
import '../core/widgets/portal_page.dart';
import '../widgets/payload_view.dart';
import '../widgets/load_view.dart';

/// The review queue: claim the next task (or an audit sample), read the unit and the author's answer,
/// record a verdict with a reason code. One task at a time; the hold runs 60 minutes.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, this.clock});

  final DateTime Function()? clock;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  ReviewTaskDetail? _task;
  Verdict? _recorded;
  String? _recordedReason;
  bool _empty = false;

  /// When the queue is empty for this reviewer: tasks waiting for a certification or clearance they lack.
  ReviewClaim _waiting = const ReviewClaim();
  bool _busy = false;
  String? _error;

  /// Why the held task can no longer be worked (the hold ran out, or the gateway refused the verdict):
  /// the task stays on screen, read-only, until the worker drops it.
  String? _exit;

  /// Shown once when a task was recovered instead of claimed.
  String? _notice;

  /// Looking up a task the worker may already hold, on first build.
  bool _recovering = true;

  Verdict? _verdict;
  String? _reason;
  final _note = TextEditingController();
  bool _rubricUnclear = false;

  Timer? _ticker;
  late DateTime _now = _clock();

  /// The gateway's clock (`AppScope.serverNow`): the hold runs out when the server says so.
  DateTime _clock() => (widget.clock ?? AppScope.of(context).serverNow)();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _recover());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _note.dispose();
    super.dispose();
  }

  /// The ticker runs only while a task is held and still live.
  void _tick(bool on) {
    _ticker?.cancel();
    _ticker = !on
        ? null
        : Timer.periodic(const Duration(seconds: 1), (_) {
            if (!mounted) return;
            setState(() => _now = _clock());
            _checkHold();
          });
  }

  bool get _holdExpired {
    final left = _task?.claimExpiresAt?.difference(_now);
    return left != null && left <= Duration.zero;
  }

  /// When the countdown reaches zero the task is no longer ours: say so and stop ticking.
  void _checkHold() {
    if (_exit != null || !_holdExpired) return;
    _tick(false);
    setState(() => _exit = 'The hold on this task ran out, so it went back to the queue. Drop it and get the next task.');
  }

  /// Shows [detail] as the held task and starts the countdown.
  void _show(ReviewTaskDetail detail) {
    setState(() {
      _task = detail;
      _exit = null;
      _verdict = null;
      _reason = null;
      _rubricUnclear = false;
      _note.clear();
      _now = _clock();
    });
    _tick(true);
    _checkHold();
  }

  /// Forgets the held task: back to the queue card. Cancels the ticker here, not only in dispose.
  void _drop() {
    _tick(false);
    setState(() {
      _task = null;
      _exit = null;
      _error = null;
      _notice = null;
    });
  }

  /// On first build: a task the worker already holds (a reload mid-review, or a claim whose answer was lost).
  Future<void> _recover() async {
    if (!mounted) return;
    final scope = AppScope.of(context);
    try {
      final held = await scope.review.activeReview();
      if (!mounted) return;
      if (held != null) _show(held);
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _recovering = false);
    }
  }

  Future<void> _fetch({String kind = 'review'}) async {
    final scope = AppScope.of(context);
    final action = 'review-claim:$kind';
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
      _empty = false;
      _recorded = null;
      _recordedReason = null;
    });
    try {
      final answer = await scope.review.claimReview(key: scope.keys.start(action), kind: kind);
      scope.keys.finish(action);
      final claimed = answer.task;
      if (claimed == null) {
        if (mounted) {
          setState(() {
            _empty = true;
            _waiting = answer;
          });
        }
        return;
      }
      final detail = await scope.review.task(claimed.id);
      if (mounted) _show(detail);
    } on ApiException catch (e) {
      scope.keys.settle(action, e);
      if (!mounted) return;
      if (e.code == 'one_live_review') {
        await _recoverHeld(e);
      } else {
        setState(() => _error = describeError(e));
      }
    } on Object catch (e) {
      scope.keys.settle(action, e);
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The gateway says we still hold a task: fetch it and show it instead of the refusal.
  Future<void> _recoverHeld(ApiException refusal) async {
    final scope = AppScope.of(context);
    try {
      final held = await scope.review.activeReview();
      if (!mounted) return;
      if (held == null) {
        setState(() => _error = describeError(refusal));
        return;
      }
      _show(held);
      setState(() => _notice = 'You still hold a task; finish it first');
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    }
  }

  Future<void> _record() async {
    final task = _task;
    final verdict = _verdict;
    if (task == null) return;
    if (verdict == null) {
      setState(() => _error = 'Choose a verdict');
      return;
    }
    final reason = verdict == Verdict.accept ? null : _reason;
    if (verdict != Verdict.accept && reason == null) {
      setState(() => _error = 'Choose a reason code');
      return;
    }
    final scope = AppScope.of(context);
    final note = _note.text.trim();
    final input = ReviewInput(verdict: verdict, reasonCode: reason, rubricUnclear: _rubricUnclear, note: note.isEmpty ? null : note);
    final action = 'record:${task.id}:${bodyTag(input.toJson())}';
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await scope.review.record(task.id, input, key: scope.keys.start(action));
      scope.keys.finish(action);
      if (!mounted) return;
      _tick(false);
      setState(() {
        _task = null;
        _exit = null;
        _recorded = verdict;
        _recordedReason = reason;
      });
    } on ApiException catch (e) {
      scope.keys.settle(action, e);
      if (!mounted) return;
      if (e.code == 'review_expired') {
        _tick(false);
        setState(() => _exit = 'The hold on this task ran out, so it went back to the queue. Drop it and get the next task.');
      } else if (_isLost(e)) {
        _tick(false);
        setState(
          () => _exit = 'This task cannot be recorded any more: the hold ended or it is no longer yours. Drop it and get the next one.',
        );
      } else {
        setState(() => _error = describeError(e));
      }
    } on Object catch (e) {
      scope.keys.settle(action, e);
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The gateway no longer lets us record on this task: the hold ended (409), it is not ours (403) or it is gone (404).
  static bool _isLost(ApiException e) => e.status == 409 || e.status == 403 || e.status == 404;

  @override
  Widget build(BuildContext context) {
    final task = _task;
    final recorded = _recorded;
    final exit = _exit;
    final notice = _notice;
    return PortalPage(
      kicker: 'Work',
      title: 'Review',
      subtitle: task == null ? 'Judge the next unit in the queue' : 'Read the brief, read the answer, then record a verdict',
      children: [
        ErrorBanner(_error),
        if (notice != null) StatusBanner(notice, key: const Key('review-held'), kind: StatusKind.info, icon: Icons.info_outline),
        if (recorded != null) _Recorded(verdict: recorded, reason: _recordedReason),
        if (task != null && exit != null) _ExitCard(message: exit, onDrop: _drop),
        if (_recovering)
          const PortalCard(child: Skeleton())
        else if (task != null)
          _TaskView(
            task: task,
            now: _now,
            busy: _busy,
            locked: exit != null,
            verdict: _verdict,
            reason: _reason,
            note: _note,
            rubricUnclear: _rubricUnclear,
            onVerdict: (v) => setState(() {
              _verdict = v;
              _error = null;
            }),
            onReason: (r) => setState(() {
              _reason = r;
              _error = null;
            }),
            onRubricUnclear: (v) => setState(() => _rubricUnclear = v),
            onRecord: _record,
          )
        else if (_empty)
          PortalCard(
            child: EmptyView(message: _emptyMessage(_waiting), onRetry: _fetch),
          )
        else
          _QueueCard(
            busy: _busy,
            next: recorded != null,
            onReview: () => _fetch(),
            onAudit: () => _fetch(kind: 'audit'),
          ),
      ],
    );
  }
}

/// Why the queue is empty for this reviewer: nothing waits, or what waits needs something they lack.
String _emptyMessage(ReviewClaim w) {
  final parts = [
    if (w.waitingForGate > 0)
      '${w.waitingForGate} ${w.waitingForGate == 1 ? 'task waits' : 'tasks wait'} for a certification you do not hold',
    if (w.waitingForClearance > 0)
      '${w.waitingForClearance} ${w.waitingForClearance == 1 ? 'task needs' : 'tasks need'} sensitive-content clearance',
  ];
  if (parts.isEmpty) return 'Nothing to review right now.';
  return 'Nothing you can review right now: ${parts.join('; ')}. Ask ops if you should have it.';
}

/// The idle card: what the queue is, and the two ways in.
class _QueueCard extends StatelessWidget {
  const _QueueCard({required this.busy, required this.next, required this.onReview, required this.onAudit});
  final bool busy;
  final bool next;
  final VoidCallback onReview;
  final VoidCallback onAudit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('The review queue', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x6),
          Text('You never review your own work. Each task is held for 60 minutes.', style: theme.textTheme.bodyMedium),
          const SizedBox(height: Space.x4),
          Text(
            'An audit sample is a unit already judged once; your verdict is compared with the first reviewer.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Space.x16),
          Wrap(
            spacing: Space.x8,
            runSpacing: Space.x8,
            children: [
              FilledButton(
                key: const Key('get-review'),
                onPressed: busy ? null : onReview,
                child: busy
                    ? SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(next ? 'Next task' : 'Get next task'),
              ),
              OutlinedButton(key: const Key('get-audit'), onPressed: busy ? null : onAudit, child: const Text('Audit sample')),
            ],
          ),
        ],
      ),
    );
  }
}

/// The held task is no longer workable: why, and the one way out.
class _ExitCard extends StatelessWidget {
  const _ExitCard({required this.message, required this.onDrop});
  final String message;
  final VoidCallback onDrop;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatusBanner(message, key: const Key('review-exit'), kind: StatusKind.warn, icon: Icons.timer_off_outlined),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(bottom: Space.x12),
            child: FilledButton.icon(
              key: const Key('drop-task'),
              onPressed: onDrop,
              icon: const Icon(Icons.skip_next_outlined, size: Sizes.iconSm),
              label: const Text('Drop this task'),
            ),
          ),
        ),
      ],
    );
  }
}

class _Recorded extends StatelessWidget {
  const _Recorded({required this.verdict, required this.reason});
  final Verdict verdict;
  final String? reason;

  @override
  Widget build(BuildContext context) {
    final code = reason == null ? null : ReasonCode.byCode(reason!);
    final why = code == null ? '' : ' · ${code.label}${code.clientCaused ? ' (billable rework)' : ''}';
    return StatusBanner(
      'Verdict ${verdict.label} recorded$why',
      key: const Key('review-done'),
      kind: statusKindFor(verdict.wire),
      icon: Icons.check_circle_outline,
    );
  }
}

class _TaskView extends StatelessWidget {
  const _TaskView({
    required this.task,
    required this.now,
    required this.busy,
    required this.locked,
    required this.verdict,
    required this.reason,
    required this.note,
    required this.rubricUnclear,
    required this.onVerdict,
    required this.onReason,
    required this.onRubricUnclear,
    required this.onRecord,
  });

  final ReviewTaskDetail task;
  final DateTime now;
  final bool busy;

  /// The task can no longer be recorded: everything is read-only.
  final bool locked;
  final Verdict? verdict;
  final String? reason;
  final TextEditingController note;
  final bool rubricUnclear;
  final ValueChanged<Verdict?> onVerdict;
  final ValueChanged<String?> onReason;
  final ValueChanged<bool> onRubricUnclear;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TaskHeader(task: task, now: now),
        TwoColumn(
          ratio: 1.15,
          left: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PortalCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('What the worker was given', style: theme.textTheme.titleMedium),
                    const SizedBox(height: Space.x8),
                    PayloadView(task.payload, mediaUrl: () => AppScope.of(context).review.taskPayloadUrl(task.id)),
                  ],
                ),
              ),
              PortalCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Their answer', style: theme.textTheme.titleMedium),
                    const SizedBox(height: Space.x8),
                    AnswerView(task.answer),
                  ],
                ),
              ),
            ],
          ),
          right: _VerdictCard(
            busy: busy,
            locked: locked,
            verdict: verdict,
            reason: reason,
            note: note,
            rubricUnclear: rubricUnclear,
            onVerdict: onVerdict,
            onReason: onReason,
            onRubricUnclear: onRubricUnclear,
            onRecord: onRecord,
          ),
        ),
      ],
    );
  }
}

/// Unit id (shortened, full id in the tooltip), rubric, audit flag and the hold countdown.
class _TaskHeader extends StatelessWidget {
  const _TaskHeader({required this.task, required this.now});
  final ReviewTaskDetail task;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final expires = task.claimExpiresAt;
    final left = expires?.difference(now);
    final expired = left != null && (left.isNegative || left == Duration.zero);
    final urgent = expired || (left != null && left < const Duration(minutes: 5));
    final id = task.unitId;
    final short = id.length > 8 ? id.substring(0, 8) : id;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.x12),
      child: Wrap(
        spacing: Space.x8,
        runSpacing: Space.x8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Semantics(
            label: 'Unit $id',
            container: true,
            excludeSemantics: true,
            child: Tooltip(
              message: 'Unit $id',
              child: Text(
                'Unit $short',
                key: const Key('review-unit'),
                style: AppTheme.mono(context, color: t.textPrimary),
              ),
            ),
          ),
          if (task.rubricVersion.isNotEmpty) StatusChip('Rubric ${task.rubricVersion}', kind: StatusKind.info),
          if (task.sampledForAudit) const StatusChip('Audit sample', kind: StatusKind.warn),
          if (left != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: Space.x10, vertical: Space.x4),
              decoration: BoxDecoration(color: urgent ? t.destBg : t.bgMuted, borderRadius: Radii.rFull),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.timer_outlined, size: Sizes.iconSm, color: urgent ? t.destDot : t.textSecondary),
                  const SizedBox(width: Space.x6),
                  Text(
                    expired ? 'Hold expired' : 'Held for ${countdown(left)}',
                    key: const Key('review-countdown'),
                    style: AppTheme.figure(context, fontSize: 12, color: urgent ? t.destText : t.textSecondary),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _VerdictCard extends StatelessWidget {
  const _VerdictCard({
    required this.busy,
    required this.locked,
    required this.verdict,
    required this.reason,
    required this.note,
    required this.rubricUnclear,
    required this.onVerdict,
    required this.onReason,
    required this.onRubricUnclear,
    required this.onRecord,
  });

  final bool busy;
  final bool locked;
  final Verdict? verdict;
  final String? reason;
  final TextEditingController note;
  final bool rubricUnclear;
  final ValueChanged<Verdict?> onVerdict;
  final ValueChanged<String?> onReason;
  final ValueChanged<bool> onRubricUnclear;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final needsReason = verdict != null && verdict != Verdict.accept;
    final off = busy || locked;
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Your verdict', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x4),
          Text('Only Accept creates an earning for the worker.', style: theme.textTheme.bodySmall),
          const SizedBox(height: Space.x12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<Verdict>(
              key: const Key('verdict'),
              showSelectedIcon: false,
              emptySelectionAllowed: true,
              segments: [for (final v in Verdict.values) ButtonSegment(value: v, label: Text(v.label))],
              selected: verdict == null ? const {} : {verdict!},
              onSelectionChanged: off ? null : (s) => onVerdict(s.isEmpty ? null : s.first),
            ),
          ),
          if (needsReason) ...[
            const SizedBox(height: Space.x16),
            Text('Reason', style: theme.textTheme.labelMedium),
            RadioGroup<String>(
              groupValue: reason,
              onChanged: off ? (_) {} : onReason,
              child: Column(
                key: const Key('reason'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ReasonGroup(
                    title: 'Worker-caused',
                    codes: ReasonCode.all
                        .where((r) => !r.clientCaused && (verdict == null || r.appliesTo.contains(verdict!.wire)))
                        .toList(),
                  ),
                  _ReasonGroup(
                    title: 'Client-caused (billable rework, the worker is not at fault)',
                    codes: ReasonCode.all.where((r) => r.clientCaused && (verdict == null || r.appliesTo.contains(verdict!.wire))).toList(),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: Space.x16),
          TextField(
            key: const Key('note'),
            controller: note,
            enabled: !off,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: 'Note to the worker',
              helperText: 'Optional. Say what to fix, not who is at fault.',
            ),
          ),
          const SizedBox(height: Space.x8),
          CheckboxListTile(
            key: const Key('rubric-unclear'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('The rubric was unclear here'),
            subtitle: const Text('Flags it to the TPM; it does not change the verdict.'),
            value: rubricUnclear,
            onChanged: off ? null : (v) => onRubricUnclear(v ?? false),
          ),
          const SizedBox(height: Space.x12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const Key('record-verdict'),
              onPressed: off ? null : onRecord,
              child: busy
                  ? SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Record verdict'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReasonGroup extends StatelessWidget {
  const _ReasonGroup({required this.title, required this.codes});
  final String title;
  final List<ReasonCode> codes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: Space.x8, bottom: Space.x2),
          child: Text(title, style: theme.textTheme.labelSmall),
        ),
        for (final r in codes)
          RadioListTile<String>(
            key: Key('reason-${r.code}'),
            value: r.code,
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(r.label),
            subtitle: Text(r.detail),
          ),
      ],
    );
  }
}
