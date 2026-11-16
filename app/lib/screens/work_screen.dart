import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../api/models.dart';
import '../app_router.dart';
import '../app_scope.dart';
import '../core/action_keys.dart';
import '../core/activity_agent.dart';
import '../core/drafts.dart';
import '../core/widgets/loader.dart';
import '../core/errors.dart';
import '../core/format.dart';
import '../core/json.dart';
import '../core/money.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/portal_tokens.dart';
import '../core/widgets/cards.dart';
import '../core/widgets/portal_page.dart';
import '../widgets/payload_view.dart';
import '../widgets/load_view.dart';
import '../core/widgets/detail_frame.dart';
import 'policies_screen.dart';
import 'shell.dart';
import 'work_route.dart';

/// The claimed unit as a full-screen route: the brief and the payload at the left, the answer at the right.
/// The answer form is built from the batch's JSON Schema when it has one; otherwise key/value rows or raw JSON.
class WorkScreen extends StatefulWidget {
  const WorkScreen({super.key, required this.claim, required this.unit, this.batch, this.clock});

  final Claim claim;
  final Unit unit;

  /// The batch the unit came from, when the caller knows it: currency, TTL, the answer schema.
  final Batch? batch;

  final DateTime Function()? clock;

  String get currency => (batch?.currency ?? '').isEmpty ? unit.currency : batch!.currency;
  String get rubricVersion => (batch?.rubricVersion ?? '').isEmpty ? unit.rubricVersion : batch!.rubricVersion;

  @override
  State<WorkScreen> createState() => _WorkScreenState();
}

/// Under this much time left the countdown turns destructive.
const _urgent = Duration(minutes: 5);

class _WorkScreenState extends State<WorkScreen> with WidgetsBindingObserver {
  late final List<_SchemaField> _schemaFields = _SchemaField.fromSchema(widget.batch?.answerSchema ?? const {});
  final List<_AnswerField> _fields = [_AnswerField()];
  final _raw = TextEditingController(text: '{}');
  bool _rawMode = false;
  bool _busy = false;
  String? _error;
  Timer? _ticker;
  late DateTime _now = _clock();

  /// The gateway's clock (`AppScope.serverNow`): Submit closes and tracking stops at the server's expiry.
  DateTime _clock() => (widget.clock ?? AppScope.of(context).serverNow)();

  /// Where drafts live, kept from the last dependency change so the last keystrokes are saved in dispose.
  DraftStore? _drafts;

  /// Set once the server confirmed the claim ended under us (a refused submit): the reason, shown with
  /// the "no longer live" view instead of the form.
  String? _ended;

  bool get _hasSchema => _schemaFields.isNotEmpty;

  ExitGuards? _guards;

  /// Submitted or released: leaving needs no question any more.
  bool _done = false;

  /// The last draft written, so the once-a-second check writes only on a change.
  String _savedDraft = '';

  /// Records active, idle or away every 30 seconds while this claim is open (docs/PRODUCT.md 5.7).
  ActivityAgent? _agent;

  /// The tracker refused for withdrawn consent: the note says tracking is off.
  bool _trackingOff = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _now = _clock());
      _saveDraft();
      if (_remaining == Duration.zero) _stopTracking();
    });
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreDraft();
      _startTracking();
    });
  }

  void _startTracking() {
    if (!mounted || _remaining == Duration.zero) return;
    final scope = AppScope.of(context);
    _agent = ActivityAgent(
      tracker: scope.tracker,
      claimId: widget.claim.id,
      devices: scope.drafts,
      now: scope.serverNow,
      onTrackingOff: () {
        if (mounted) setState(() => _trackingOff = true);
      },
    )..start();
  }

  /// Ends the session once: on submit, release, expiry or leaving the screen.
  void _stopTracking() {
    final agent = _agent;
    _agent = null;
    if (agent != null) unawaited(agent.end());
  }

  bool _onKey(KeyEvent event) {
    _agent?.input();
    return false;
  }

  /// Only a hidden or paused tab is away; `inactive` (a dialog, the tab strip, a moment between states)
  /// changes nothing.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        _agent?.visible(false);
      case AppLifecycleState.resumed:
        _agent?.visible(true);
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = AppScope.of(context);
    _drafts = scope.drafts;
    _guards ??= scope.exitGuards..set(GuardedRoute.unit, _confirmLeave);
  }

  String get _draftKey => DraftStore.unit(widget.claim.id);

  /// What the worker has typed, in the shape of the active editor; empty when nothing is entered.
  Map<String, Object?> _draft() {
    if (_hasSchema) {
      final values = <String, Object?>{
        for (final f in _schemaFields)
          if (f.text.text.isNotEmpty || f.choice != null || f.flag) f.name: {'text': f.text.text, 'choice': f.choice, 'flag': f.flag},
      };
      return values.isEmpty ? const {} : {'schema': values};
    }
    if (_rawMode) return _raw.text.trim() == '{}' || _raw.text.trim().isEmpty ? const {} : {'raw': _raw.text};
    final rows = [
      for (final f in _fields)
        if (f.key.text.isNotEmpty || f.value.text.isNotEmpty) [f.key.text, f.value.text],
    ];
    return rows.isEmpty ? const {} : {'rows': rows};
  }

  bool get _dirty => !_done && _draft().isNotEmpty;

  void _saveDraft() {
    if (_done) return;
    final draft = _draft();
    final encoded = jsonEncode(draft);
    if (encoded == _savedDraft) return;
    _savedDraft = encoded;
    final drafts = _drafts;
    if (drafts == null) return;
    if (draft.isEmpty) {
      drafts.remove(_draftKey);
    } else {
      drafts.write(_draftKey, draft);
    }
  }

  Future<void> _restoreDraft() async {
    if (!mounted) return;
    final draft = await AppScope.of(context).drafts.read(_draftKey);
    if (draft == null || !mounted) return;
    setState(() {
      final schema = draft['schema'];
      if (schema is Map && _hasSchema) {
        for (final f in _schemaFields) {
          final v = schema[f.name];
          if (v is! Map) continue;
          if (v['text'] is String) f.text.text = v['text'] as String;
          final choice = v['choice'];
          if (choice is String && f.options.contains(choice)) f.choice = choice;
          if (v['flag'] is bool) f.flag = v['flag'] as bool;
        }
      }
      final raw = draft['raw'];
      if (raw is String && !_hasSchema) {
        _rawMode = true;
        _raw.text = raw;
      }
      final rows = draft['rows'];
      if (rows is List && !_hasSchema && rows.isNotEmpty) {
        for (final f in _fields) {
          f.dispose();
        }
        _fields
          ..clear()
          ..addAll([
            for (final r in rows)
              if (r is List && r.length == 2)
                _AnswerField()
                  ..key.text = '${r[0]}'
                  ..value.text = '${r[1]}',
          ]);
        if (_fields.isEmpty) _fields.add(_AnswerField());
      }
    });
    _savedDraft = jsonEncode(_draft());
    if (mounted) toast(context, 'Your draft from this device is back');
  }

  /// Leaving with an unsent answer asks first: the draft stays on this device and the claim keeps
  /// running; releasing hands the unit back to the pool.
  Future<bool> _confirmLeave(BuildContext context) async {
    if (!_dirty || !mounted) return true;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave this unit?'),
        content: const Text(
          'Your draft stays on this device and the claim keeps running until it expires. '
          'Release the claim if you will not finish it.',
        ),
        actions: [
          TextButton(key: const Key('leave-stay'), onPressed: () => Navigator.of(ctx).pop('stay'), child: const Text('Stay')),
          OutlinedButton(
            key: const Key('leave-release'),
            onPressed: () => Navigator.of(ctx).pop('release'),
            child: const Text('Release claim'),
          ),
          FilledButton(key: const Key('leave-confirm'), onPressed: () => Navigator.of(ctx).pop('leave'), child: const Text('Leave')),
        ],
      ),
    );
    if (!mounted) return false;
    if (choice == 'release') return _release(ask: false, leave: false);
    if (choice == 'leave') _saveDraft();
    return choice == 'leave';
  }

  /// Gives the unit back to the pool. Returns whether it was released.
  Future<bool> _release({bool ask = true, bool leave = true}) async {
    final scope = AppScope.of(context);
    if (ask) {
      final ok = await confirm(
        context,
        title: 'Release this claim?',
        body: 'The unit goes back to the pool for someone else, and the draft on this device is deleted.',
        confirmLabel: 'Release claim',
        destructive: true,
      );
      if (!ok || !mounted) return false;
    }
    final action = 'release:${widget.claim.id}';
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await scope.work.release(widget.claim.id, key: scope.keys.start(action));
      scope.keys.finish(action);
      _done = true;
      _stopTracking();
      await scope.drafts.remove(_draftKey);
      scope.stale.mark([Destination.home, Destination.myWork]);
      if (!mounted) return true;
      toast(context, 'Claim released');
      if (leave) await DetailFrame.back(context, WorkRoute.crumbs);
      return true;
    } on Object catch (e) {
      scope.keys.settle(action, e);
      if (mounted) setState(() => _error = describeError(e));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _saveDraft(); // a sign-out or an expired session leaves without asking: the last keystrokes stay too
    _stopTracking();
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _guards?.set(GuardedRoute.unit, null);
    _raw.dispose();
    for (final f in _fields) {
      f.dispose();
    }
    for (final f in _schemaFields) {
      f.dispose();
    }
    super.dispose();
  }

  Duration get _remaining {
    final expires = widget.claim.expiresAt;
    if (expires == null) return Duration.zero;
    final left = expires.difference(_now);
    return left.isNegative ? Duration.zero : left;
  }

  /// The answer object from whichever editor is active, or null with [_error] (and field errors) set.
  Json? _answer() {
    if (_hasSchema) return _schemaAnswer();
    if (_rawMode) {
      try {
        final v = jsonDecode(_raw.text);
        if (v is Map) return Map<String, dynamic>.from(v);
        _error = 'Raw answer must be a JSON object';
      } on FormatException catch (e) {
        _error = 'Raw answer is not valid JSON: ${e.message}';
      }
      return null;
    }
    final out = <String, dynamic>{};
    for (final f in _fields) {
      final k = f.key.text.trim();
      if (k.isEmpty) continue;
      out[k] = f.value.text;
    }
    if (out.isEmpty) {
      _error = 'Add at least one answer field';
      return null;
    }
    return out;
  }

  Json? _schemaAnswer() {
    final out = <String, dynamic>{};
    var problems = 0;
    for (final f in _schemaFields) {
      f.error = null;
      final value = f.value();
      if (value is _Invalid) {
        f.error = value.message;
        problems++;
      } else if (value == null) {
        if (f.required) {
          f.error = 'Required';
          problems++;
        }
      } else {
        out[f.name] = value;
      }
    }
    if (problems > 0) {
      _error = problems == 1 ? 'Fix the highlighted field before you submit.' : 'Fix the $problems highlighted fields before you submit.';
      return null;
    }
    return out;
  }

  void _toggleRaw(bool raw) {
    setState(() {
      _error = null;
      if (raw) {
        final current = <String, dynamic>{
          for (final f in _fields)
            if (f.key.text.trim().isNotEmpty) f.key.text.trim(): f.value.text,
        };
        _raw.text = prettyJson.convert(current);
      } else {
        final parsed = _answer();
        if (parsed != null) {
          for (final f in _fields) {
            f.dispose();
          }
          _fields
            ..clear()
            ..addAll(
              parsed.entries.map(
                (e) => _AnswerField()
                  ..key.text = e.key
                  ..value.text = e.value is String ? e.value as String : jsonEncode(e.value),
              ),
            );
          if (_fields.isEmpty) _fields.add(_AnswerField());
        } else {
          return; // stay in raw mode so the worker can fix the JSON
        }
      }
      _rawMode = raw;
    });
  }

  Future<void> _submit() async {
    final scope = AppScope.of(context);
    _error = null;
    final answer = _answer();
    if (answer == null) {
      setState(() {});
      return;
    }
    final action = 'submit:${widget.claim.id}:${bodyTag(answer)}';
    setState(() => _busy = true);
    try {
      final submission = await scope.work.submit(widget.claim.id, answer, key: scope.keys.start(action));
      scope.keys.finish(action);
      _done = true;
      _stopTracking();
      await scope.drafts.remove(_draftKey);
      if (!mounted) return;
      setState(() => _busy = false);
      await _showSubmitted(submission);
      if (mounted) await DetailFrame.back(context, WorkRoute.crumbs);
    } on ApiException catch (e) {
      scope.keys.settle(action, e);
      final ended = (e.isConflict && e.code != 'request_in_flight') || e.status == 404;
      if (ended) {
        await _confirmEnded(e);
      } else if (mounted) {
        setState(() => _error = describeError(e));
      }
    } on Object catch (e) {
      scope.keys.settle(action, e);
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A submit refused as a conflict or a missing claim: asks the server whether this claim is still live.
  /// Still live (or the question fails) keeps the form and the draft; gone shows the "no longer live"
  /// view, stops tracking and only then deletes the draft.
  Future<void> _confirmEnded(ApiException refusal) async {
    final scope = AppScope.of(context);
    try {
      final live = await scope.work.activeWork();
      if (live.isLive && live.claim!.id == widget.claim.id) {
        if (mounted) setState(() => _error = describeError(refusal));
        return;
      }
    } on Object {
      if (mounted) setState(() => _error = describeError(refusal));
      return;
    }
    _done = true;
    _stopTracking();
    await scope.drafts.remove(_draftKey);
    scope.stale.mark([Destination.home, Destination.myWork]);
    if (mounted) setState(() => _ended = describeError(refusal));
  }

  Future<void> _showSubmitted(Submission submission) {
    final rubric = submission.rubricVersion.isEmpty ? widget.rubricVersion : submission.rubricVersion;
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Submitted'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StatusChip('Submitted · rubric $rubric', kind: StatusKind.success),
            const SizedBox(height: Space.x12),
            Text(
              '${widget.unit.externalRef.isEmpty ? 'This unit' : 'Unit ${widget.unit.externalRef}'} is in the review queue. '
              'Only an accepted unit creates an earning.',
            ),
          ],
        ),
        actions: [FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ended = _ended;
    if (ended != null) {
      return DetailFrame(
        crumbs: WorkRoute.crumbs,
        body: ClaimNotLive(reason: ended),
      );
    }
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final left = _remaining;
    final expired = left == Duration.zero;
    final narrow = MediaQuery.sizeOf(context).width < Layout.twoColumn;
    final title = widget.batch?.title.isNotEmpty == true ? widget.batch!.title : 'Work';
    final countdownPill = _CountdownPill(left: left, expired: expired);
    final submit = FilledButton(
      key: const Key('submit'),
      onPressed: _busy || expired ? null : _submit,
      child: _busy
          ? SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : Text(expired ? 'Claim expired' : 'Submit'),
    );
    return DetailFrame(
      crumbs: [
        const Crumb('Work'),
        Crumb('Home', path: Destination.home.path),
        Crumb(title),
      ],
      actions: [
        if (!narrow)
          Padding(
            padding: const EdgeInsets.only(right: Space.x8),
            child: Center(child: countdownPill),
          ),
        TextButton.icon(
          key: const Key('release-claim'),
          onPressed: _busy || expired ? null : _release,
          icon: const Icon(Icons.undo, size: Sizes.iconSm),
          label: Text(narrow ? 'Release' : 'Release claim'),
          style: TextButton.styleFrom(foregroundColor: t.destText),
        ),
      ],
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _agent?.input(),
        onPointerSignal: (_) => _agent?.input(),
        child: PortalPage(
          children: [
            TwoColumn(
              ratio: 1.15,
              left: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _BriefCard(unit: widget.unit, batch: widget.batch, currency: widget.currency, rubricVersion: widget.rubricVersion),
                  _TrackingNote(off: _trackingOff),
                  PortalCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('What you are given', style: theme.textTheme.titleMedium),
                        const SizedBox(height: Space.x8),
                        PayloadView(widget.unit.payload, mediaUrl: () => AppScope.of(context).work.payloadUrl(widget.unit.id)),
                      ],
                    ),
                  ),
                ],
              ),
              right: PortalCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text('Your answer', style: theme.textTheme.titleMedium)),
                        if (!_hasSchema)
                          MergeSemantics(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('Raw JSON', style: theme.textTheme.labelMedium),
                                const SizedBox(width: Space.x6),
                                Switch(key: const Key('raw-toggle'), value: _rawMode, onChanged: _busy ? null : _toggleRaw),
                              ],
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: Space.x8),
                    ErrorBanner(_error),
                    if (_hasSchema)
                      _SchemaForm(fields: _schemaFields, enabled: !_busy, onChanged: () => setState(() {}))
                    else if (_rawMode)
                      TextField(
                        key: const Key('raw-answer'),
                        controller: _raw,
                        maxLines: 10,
                        style: AppTheme.mono(context),
                        decoration: const InputDecoration(helperText: 'A JSON object; it is sent exactly as typed.'),
                      )
                    else
                      _KeyValueForm(fields: _fields, onChanged: () => setState(() {})),
                    if (!narrow) ...[const SizedBox(height: Space.x16), Align(alignment: Alignment.centerRight, child: submit)],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      footer: narrow ? _StickyBar(countdown: countdownPill, submit: submit) : null,
    );
  }
}

/// One quiet line under the brief: activity is recorded while a claim is open, with a link to what exactly.
class _TrackingNote extends StatelessWidget {
  const _TrackingNote({this.off = false});

  /// The worker withdrew consent, so nothing is recorded.
  final bool off;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    if (off) {
      return Padding(
        key: const Key('tracking-off'),
        padding: const EdgeInsets.only(bottom: Space.x12),
        child: Row(
          children: [
            Icon(Icons.timer_off_outlined, size: Sizes.iconSm, color: t.textSecondary),
            const SizedBox(width: Space.x4),
            Expanded(
              child: Text(
                'Tracking is off: you withdrew your data consent.',
                style: theme.textTheme.bodySmall?.copyWith(color: t.textSecondary),
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      key: const Key('tracking-note'),
      padding: const EdgeInsets.only(bottom: Space.x12),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Space.x4,
        children: [
          Icon(Icons.timer_outlined, size: Sizes.iconSm, color: t.textSecondary),
          Text('Activity is recorded while you work.', style: theme.textTheme.bodySmall?.copyWith(color: t.textSecondary)),
          TextButton(
            key: const Key('tracking-policy'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: Space.x4),
              minimumSize: const Size(48, 32),
            ),
            onPressed: () => showPolicySheet(context, 'tracking', load: AppScope.of(context).tracker.policy),
            child: const Text('What we track'),
          ),
        ],
      ),
    );
  }
}

/// A countdown pill: neutral, destructive under five minutes, "Expired" at zero. Text carries the meaning.
class _CountdownPill extends StatelessWidget {
  const _CountdownPill({required this.left, required this.expired});
  final Duration left;
  final bool expired;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final urgent = expired || left < _urgent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.x10, vertical: Space.x4),
      decoration: BoxDecoration(color: urgent ? t.destBg : t.bgMuted, borderRadius: Radii.rFull),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_outlined, size: Sizes.iconSm, color: urgent ? t.destDot : t.textSecondary),
          const SizedBox(width: Space.x6),
          Flexible(
            child: Text(
              expired ? 'Expired' : 'Expires in ${countdown(left)}',
              key: const Key('countdown'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.figure(context, fontSize: 12, color: urgent ? t.destText : t.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// On narrow screens the countdown and Submit stay reachable at the bottom while the page scrolls.
class _StickyBar extends StatelessWidget {
  const _StickyBar({required this.countdown, required this.submit});
  final Widget countdown;
  final Widget submit;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return Material(
      color: t.bgApp,
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Space.x16, vertical: Space.x12),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: t.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Row(children: [Flexible(child: countdown)]),
              ),
              const SizedBox(width: Space.x12),
              submit,
            ],
          ),
        ),
      ),
    );
  }
}

class _BriefCard extends StatelessWidget {
  const _BriefCard({required this.unit, required this.batch, required this.currency, required this.rubricVersion});
  final Unit unit;
  final Batch? batch;
  final String currency;
  final String rubricVersion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final project = batch?.projectName ?? '';
    final title = batch?.title.isNotEmpty == true ? batch!.title : 'Unit in progress';
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (project.isNotEmpty) Text(project, style: theme.textTheme.bodySmall),
          Text(title, style: theme.textTheme.titleLarge),
          const SizedBox(height: Space.x8),
          Wrap(
            spacing: Space.x8,
            runSpacing: Space.x8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Unit ${unit.ref}', style: AppTheme.mono(context, fontSize: 12, color: t.textSecondary)),
              if (rubricVersion.isNotEmpty) StatusChip('Rubric $rubricVersion', kind: StatusKind.info),
            ],
          ),
          const SizedBox(height: Space.x12),
          Row(
            children: [
              Icon(Icons.payments_outlined, size: Sizes.iconSm, color: t.textMuted),
              const SizedBox(width: Space.x6),
              Expanded(
                child: Text(
                  'Pays ${formatMoney(unit.unitPay, currency: currency)} per accepted unit',
                  key: const Key('unit-pay'),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          if (batch != null && batch!.claimTtlMinutes > 0) ...[
            const SizedBox(height: Space.x6),
            Row(
              children: [
                Icon(Icons.timer_outlined, size: Sizes.iconSm, color: t.textMuted),
                const SizedBox(width: Space.x6),
                Text('${minutesLabel(batch!.claimTtlMinutes)} per claim', style: theme.textTheme.bodyMedium),
              ],
            ),
          ],
          const SizedBox(height: Space.x12),
          Text(
            'Judged against rubric ${rubricVersion.isEmpty ? '—' : rubricVersion}. Only an accepted unit creates an earning.',
            key: const Key('guidelines'),
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

// ── No schema: free key/value rows ───────────────────────────────────────────

class _AnswerField {
  _AnswerField() : key = TextEditingController(), value = TextEditingController();
  final TextEditingController key;
  final TextEditingController value;
  void dispose() {
    key.dispose();
    value.dispose();
  }
}

class _KeyValueForm extends StatelessWidget {
  const _KeyValueForm({required this.fields, required this.onChanged});
  final List<_AnswerField> fields;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < fields.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.x8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    key: Key('answer-key-$i'),
                    controller: fields[i].key,
                    decoration: const InputDecoration(labelText: 'Field'),
                  ),
                ),
                const SizedBox(width: Space.x8),
                Expanded(
                  flex: 3,
                  child: TextField(
                    key: Key('answer-value-$i'),
                    controller: fields[i].value,
                    decoration: const InputDecoration(labelText: 'Value'),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove field',
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: fields.length > 1
                      ? () {
                          fields.removeAt(i).dispose();
                          onChanged();
                        }
                      : null,
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('add-field'),
            onPressed: () {
              fields.add(_AnswerField());
              onChanged();
            },
            icon: const Icon(Icons.add),
            label: const Text('Add field'),
          ),
        ),
      ],
    );
  }
}

// ── Schema-driven form ───────────────────────────────────────────────────────

enum _Kind { text, choice, number, integer, flag, other }

/// A value that could not be read from the field: the message is shown inline.
class _Invalid {
  const _Invalid(this.message);
  final String message;
}

/// One property of the answer schema and the worker's input for it.
class _SchemaField {
  _SchemaField({required this.name, required this.spec, required this.required})
    : kind = _kindOf(spec),
      options = readList(spec, 'enum').map((e) => e.toString()).toList() {
    final initial = spec['default'];
    switch (kind) {
      case _Kind.flag:
        flag = initial is bool && initial;
      case _Kind.choice:
        choice = initial is String && options.contains(initial) ? initial : null;
      default:
        if (initial != null) text.text = initial.toString();
    }
  }

  final String name;
  final Json spec;
  final bool required;
  final _Kind kind;
  final List<String> options;
  final TextEditingController text = TextEditingController();
  String? choice;
  bool flag = false;
  String? error;

  String get label => readString(spec, 'title').isEmpty ? humanize(name) : readString(spec, 'title');
  String? get helper => readString(spec, 'description').isEmpty ? null : readString(spec, 'description');
  bool get multiline => readString(spec, 'format') == 'textarea' || readBool(spec, 'x-multiline');
  int? get maxLength => spec['maxLength'] is int && (spec['maxLength'] as int) > 0 ? spec['maxLength'] as int : null;

  /// The typed value, null when left empty, or [_Invalid] when it cannot be read.
  Object? value() {
    switch (kind) {
      case _Kind.flag:
        return flag;
      case _Kind.choice:
        return choice;
      case _Kind.integer:
        final raw = text.text.trim();
        if (raw.isEmpty) return null;
        return int.tryParse(raw) ?? const _Invalid('Enter a whole number');
      case _Kind.number:
        final raw = text.text.trim();
        if (raw.isEmpty) return null;
        return num.tryParse(raw) ?? const _Invalid('Enter a number');
      case _Kind.text:
      case _Kind.other:
        final raw = text.text;
        return raw.trim().isEmpty ? null : raw;
    }
  }

  void dispose() => text.dispose();

  static _Kind _kindOf(Json spec) {
    if (readList(spec, 'enum').isNotEmpty) return _Kind.choice;
    final type = spec['type'];
    final name = type is String ? type : (type is List && type.isNotEmpty ? type.first.toString() : '');
    return switch (name) {
      'string' => _Kind.text,
      'number' => _Kind.number,
      'integer' => _Kind.integer,
      'boolean' => _Kind.flag,
      _ => _Kind.other,
    };
  }

  /// The fields of a JSON Schema object, in declaration order; empty when the schema has no properties.
  static List<_SchemaField> fromSchema(Json schema) {
    final properties = readMap(schema, 'properties');
    final required = readList(schema, 'required').map((e) => e.toString()).toSet();
    return [
      for (final e in properties.entries)
        _SchemaField(
          name: e.key,
          spec: e.value is Map ? Map<String, dynamic>.from(e.value as Map) : const {},
          required: required.contains(e.key),
        ),
    ];
  }
}

class _SchemaForm extends StatelessWidget {
  const _SchemaForm({required this.fields, required this.enabled, required this.onChanged});
  final List<_SchemaField> fields;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final f in fields)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.x12),
            child: _SchemaFieldView(field: f, enabled: enabled, onChanged: onChanged),
          ),
      ],
    );
  }
}

class _SchemaFieldView extends StatelessWidget {
  const _SchemaFieldView({required this.field, required this.enabled, required this.onChanged});
  final _SchemaField field;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final f = field;
    final key = Key('field-${f.name}');
    final label = f.required ? '${f.label} *' : f.label;
    switch (f.kind) {
      case _Kind.flag:
        return _Labelled(
          label: null,
          helper: f.helper,
          error: f.error,
          child: SwitchListTile(
            key: key,
            contentPadding: EdgeInsets.zero,
            title: Text(label),
            value: f.flag,
            onChanged: enabled
                ? (v) {
                    f.flag = v;
                    onChanged();
                  }
                : null,
          ),
        );
      case _Kind.choice:
        if (f.options.length <= 4) {
          return _Labelled(
            label: label,
            helper: f.helper,
            error: f.error,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<String>(
                key: key,
                showSelectedIcon: false,
                emptySelectionAllowed: true,
                segments: [for (final o in f.options) ButtonSegment(value: o, label: Text(humanize(o)))],
                selected: f.choice == null ? const {} : {f.choice!},
                onSelectionChanged: enabled
                    ? (s) {
                        f.choice = s.isEmpty ? null : s.first;
                        onChanged();
                      }
                    : null,
              ),
            ),
          );
        }
        return DropdownButtonFormField<String>(
          key: key,
          initialValue: f.choice,
          decoration: InputDecoration(labelText: label, helperText: f.helper, errorText: f.error),
          items: [for (final o in f.options) DropdownMenuItem(value: o, child: Text(humanize(o)))],
          onChanged: enabled
              ? (v) {
                  f.choice = v;
                  onChanged();
                }
              : null,
        );
      case _Kind.number:
      case _Kind.integer:
        return TextField(
          key: key,
          controller: f.text,
          enabled: enabled,
          keyboardType: TextInputType.numberWithOptions(decimal: f.kind == _Kind.number, signed: true),
          decoration: InputDecoration(labelText: label, helperText: f.helper, errorText: f.error),
        );
      case _Kind.text:
      case _Kind.other:
        return TextField(
          key: key,
          controller: f.text,
          enabled: enabled,
          maxLength: f.maxLength,
          maxLines: f.multiline ? 5 : 1,
          minLines: f.multiline ? 3 : null,
          decoration: InputDecoration(labelText: label, helperText: f.helper, errorText: f.error),
        );
    }
  }
}

/// A label, a control, then helper or error text — for controls without an InputDecoration of their own.
class _Labelled extends StatelessWidget {
  const _Labelled({required this.label, required this.helper, required this.error, required this.child});
  final String? label;
  final String? helper;
  final String? error;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[Text(label!, style: theme.textTheme.labelMedium), const SizedBox(height: Space.x6)],
        child,
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: Space.x4),
            child: Text(error!, style: theme.textTheme.bodySmall?.copyWith(color: t.destText)),
          )
        else if (helper != null)
          Padding(
            padding: const EdgeInsets.only(top: Space.x4),
            child: Text(helper!, style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }
}

/// A claim that is no longer live (submitted, released, expired, or refused by the server): says so, with
/// the server's reason in plain words when there is one, and offers Home.
class ClaimNotLive extends StatelessWidget {
  const ClaimNotLive({super.key, this.reason});
  final String? reason;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return Center(
      key: const Key('claim-not-live'),
      child: Padding(
        padding: const EdgeInsets.all(Space.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hourglass_disabled_outlined, size: 40, color: t.textMuted),
            const SizedBox(height: Space.x12),
            Text('This claim is no longer live', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Space.x4),
            Text(
              reason ?? 'It was submitted, released or it expired. Open pools are on Home.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: t.textSecondary),
            ),
            const SizedBox(height: Space.x16),
            FilledButton(
              key: const Key('claim-not-live-home'),
              onPressed: () => context.go(Destination.home.path),
              child: const Text('Go to Home'),
            ),
          ],
        ),
      ),
    );
  }
}
