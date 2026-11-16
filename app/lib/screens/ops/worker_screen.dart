import 'package:flutter/material.dart';

import '../../api/finance_models.dart' show payoutReason;
import '../../api/ops_models.dart';
import '../../app_scope.dart';
import '../../core/action_keys.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/money.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/portal_tokens.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/date_field.dart';
import '../../core/widgets/form_sheet.dart';
import '../../core/widgets/loader.dart';
import '../../core/widgets/portal_page.dart';
import '../../core/widgets/stage_bar.dart';
import '../../core/widgets/tables.dart';
import '../../core/widgets/action_dialog.dart';
import '../../widgets/load_view.dart';
import '../shell.dart';
import 'finance_screen.dart' show confirmBankAccount;
import 'workers_screen.dart' show availabilityLabel;
import '../../core/widgets/detail_frame.dart';

const workerStatuses = ['unknown', 'eligible', 'active', 'suspended', 'offboarded'];

/// One worker: the profile, the gates editor, the status, the documents they uploaded, reviewer clearance
/// for sensitive projects, their bank account and payout hold, and their recent tracked sessions. Gates and
/// status go through `PUT /v1/workers/{id}` (the whole record, per `WorkerIn`).
class WorkerScreen extends StatefulWidget {
  const WorkerScreen({super.key, required this.workerId});
  final String workerId;

  @override
  State<WorkerScreen> createState() => _WorkerScreenState();
}

class _WorkerScreenState extends State<WorkerScreen> {
  String? _error;
  bool _busy = false;
  Future<void> Function()? _reload;

  /// Whether the PUT landed. The target (the status, the gate set) is part of [action], so a key kept
  /// after a failure is never reused for a different change.
  Future<bool> _put(
    WorkerRow w, {
    required String status,
    required List<String> gates,
    required String action,
    required String done,
  }) async {
    final scope = AppScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await scope.ops.putWorker(w.id, status: status, certGates: gates, partnerRef: w.partnerRef, key: scope.keys.start(action));
      scope.keys.finish(action);
      scope.stale.mark([Destination.workers]);
      if (!mounted) return true;
      toast(context, done);
      await _reload?.call();
      return true;
    } on Object catch (e) {
      scope.keys.settle(action, e);
      if (mounted) setState(() => _error = describeError(e));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setStatus(WorkerRow w, String status) async {
    if (status == w.status) return;
    final body = switch (status) {
      'suspended' => 'They stop seeing pools and cannot claim until the status changes again.',
      'offboarded' => 'They leave the bench. Earnings already recorded still pay out.',
      'eligible' || 'active' => 'They can claim from pools whose gate they hold.',
      _ => 'The status is set to ${humanize(status).toLowerCase()}.',
    };
    final ok = await confirm(
      context,
      title: 'Set ${w.name.isEmpty ? shortId(w.id) : w.name} to ${humanize(status).toLowerCase()}?',
      body: body,
      confirmLabel: 'Set status',
      destructive: status == 'offboarded',
    );
    if (!ok || !mounted) return;
    await _put(
      w,
      status: status,
      gates: w.certGates,
      action: 'worker:status:${w.id}:$status',
      done: 'Status set to ${humanize(status).toLowerCase()}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return DetailFrame(
      crumbs: [
        const Crumb('Operate'),
        Crumb('Workers', path: Destination.workers.path),
        const Crumb('Worker'),
      ],
      body: LoadView<WorkerRow>(
        firstWait: LoadWait.brand,
        load: () => AppScope.of(context).ops.worker(widget.workerId),
        builder: (context, w, reload) {
          _reload = reload;
          return PortalPage(
            kicker: 'Operate · Worker',
            title: w.name.isEmpty ? shortId(w.id) : w.name,
            subtitle:
                '${w.onboarded ? 'onboarded' : 'onboarding in progress'} · ${w.certGates.isEmpty ? 'no gate' : '${w.certGates.length} ${w.certGates.length == 1 ? 'gate' : 'gates'}'} · ${availabilityLabel(w.availability)}',
            onRefresh: reload,
            actions: [ConsoleStatus(w.status)],
            children: [
              // always in the tree: a banner that appears would shift the cards below it and drop their typed state
              ErrorBanner(_error, key: const Key('worker-error')),
              TwoColumn(
                left: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Profile(w),
                    _Gates(
                      w,
                      busy: _busy,
                      onSave: (gates) =>
                          _put(w, status: w.status, gates: gates, action: 'worker:gates:${w.id}:${gates.join(',')}', done: 'Gates saved'),
                    ),
                    _DocumentsCard(workerId: w.id),
                  ],
                ),
                right: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Status(w, busy: _busy, onChange: (s) => _setStatus(w, s)),
                    _ReviewerCard(workerId: w.id),
                    _HoldCard(workerId: w.id),
                  ],
                ),
              ),
              _SessionsCard(workerId: w.id),
            ],
          );
        },
      ),
    );
  }
}

class _Profile extends StatelessWidget {
  const _Profile(this.w);
  final WorkerRow w;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Profile', style: theme.textTheme.titleMedium),
          LabelValue(label: 'Name', value: w.name.isEmpty ? 'Not known yet' : w.name),
          LabelValue(label: 'Worker id', value: w.id, mono: true, selectable: true),
          LabelValue(label: 'Onboarding', value: w.onboarded ? 'Done' : 'In progress'),
          LabelValue(label: 'Partner ref (Odoo)', value: w.partnerRef == null ? '—' : '${w.partnerRef}', mono: true),
          LabelValue(label: 'Availability', value: availabilityLabel(w.availability)),
          LabelValue(label: 'Updated', value: w.updatedAt == null ? '—' : dateTime(w.updatedAt!)),
        ],
      ),
    );
  }
}

class _Gates extends StatefulWidget {
  const _Gates(this.w, {required this.busy, required this.onSave});
  final WorkerRow w;
  final bool busy;

  /// Saves the gates; answers whether they landed.
  final Future<bool> Function(List<String>) onSave;

  @override
  State<_Gates> createState() => _GatesState();
}

class _GatesState extends State<_Gates> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final gate = _input.text.trim().toLowerCase();
    if (gate.isEmpty || widget.w.certGates.contains(gate)) return;
    // the typed gate stays in the field until it has landed
    if (await widget.onSave([...widget.w.certGates, gate]) && mounted) _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Certification gates', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x4),
          Text(
            'A gate opens every pool and listing that asks for it. Papers add gates on their own; this is the manual override.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Space.x12),
          TagChips(
            widget.w.certGates,
            onRemove: widget.busy
                ? null
                : (g) => widget.onSave([
                    for (final x in widget.w.certGates)
                      if (x != g) x,
                  ]),
          ),
          const SizedBox(height: Space.x12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('gate-input'),
                  controller: _input,
                  enabled: !widget.busy,
                  decoration: const InputDecoration(hintText: 'Add a gate, e.g. transcription'),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: Space.x8),
              OutlinedButton(key: const Key('gate-add'), onPressed: widget.busy ? null : _add, child: const Text('Add')),
            ],
          ),
        ],
      ),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status(this.w, {required this.busy, required this.onChange});
  final WorkerRow w;
  final bool busy;
  final void Function(String) onChange;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Status', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x4),
          Text(
            'Eligible and active workers can claim; suspended ones cannot; offboarded ones have left.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Space.x12),
          DropdownButtonFormField<String>(
            key: const Key('worker-status'),
            isExpanded: true,
            initialValue: workerStatuses.contains(w.status) ? w.status : 'unknown',
            items: [for (final s in workerStatuses) DropdownMenuItem(value: s, child: Text(humanize(s)))],
            onChanged: busy ? null : (v) => v == null ? null : onChange(v),
          ),
        ],
      ),
    );
  }
}

class _HoldCard extends StatefulWidget {
  const _HoldCard({required this.workerId});
  final String workerId;

  @override
  State<_HoldCard> createState() => _HoldCardState();
}

class _HoldCardState extends State<_HoldCard> {
  Future<PayoutAccount?>? _future;
  bool _busy = false;
  String? _error;

  Future<PayoutAccount?> _load() async {
    try {
      return await AppScope.of(context).ops.payoutAccount(widget.workerId);
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  void _refresh() {
    final next = _load();
    setState(() {
      _future = next;
    });
  }

  Future<void> _set({String? reason, DateTime? until, required String done}) async {
    final scope = AppScope.of(context);
    final action = 'hold:${widget.workerId}:${bodyTag([reason, until?.toUtc().toIso8601String()])}';
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await scope.ops.setHold(widget.workerId, reason: reason, until: until, key: scope.keys.start(action));
      scope.keys.finish(action);
      scope.stale.mark([Destination.workers]);
      if (!mounted) return;
      toast(context, done);
      _refresh();
    } on Object catch (e) {
      scope.keys.settle(action, e);
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Finance confirms an account the penny drop proved without a name; never their own (the server refuses too).
  Future<void> _confirmBank() async {
    final ok = await confirmBankAccount(context, widget.workerId);
    if (!ok || !mounted) return;
    final scope = AppScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await withActionKey(
        scope.keys,
        'account:confirm:${widget.workerId}',
        (key) => scope.finance.confirmAccount(widget.workerId, key: key),
      );
      if (!mounted) return;
      toast(context, 'Bank account confirmed');
      _refresh();
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _hold() async {
    final result = await showDialog<(String, DateTime?)>(context: context, builder: (_) => const _HoldDialog());
    if (result == null || !mounted) return;
    await _set(reason: result.$1, until: result.$2, done: 'Hold placed');
  }

  Future<void> _lift() async {
    final ok = await confirm(
      context,
      title: 'Lift the hold?',
      body: 'Held earnings roll into the next pay window.',
      confirmLabel: 'Lift hold',
    );
    if (!ok || !mounted) return;
    await _set(done: 'Hold lifted');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final future = _future ??= _load();
    final session = AppScope.of(context).session;
    final canConfirm = session.roles.contains('finance') && session.subject != widget.workerId;
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Payout', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x4),
          Text(
            'The bank account they are paid into, and the hold that keeps earnings out of pay windows; nothing is lost.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Space.x12),
          ErrorBanner(_error),
          FutureBuilder<PayoutAccount?>(
            future: future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) return const Skeleton(lines: 3);
              if (snap.hasError) return ErrorView(message: describeError(snap.error!), onRetry: () async => _refresh());
              final a = snap.data;
              if (a == null) {
                return Text(
                  'No payout account yet: it appears with the first accepted unit.',
                  key: const Key('hold-none'),
                  style: theme.textTheme.bodyMedium?.copyWith(color: t.textSecondary),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (a.isHeld)
                    StatusBanner(
                      'On hold: ${payoutReason(a.holdReason).toLowerCase()}${a.holdUntil == null ? '' : ' until ${shortDate(a.holdUntil!)}'}',
                      key: const Key('hold-banner'),
                      kind: StatusKind.warn,
                      icon: Icons.pause_circle_outline,
                    ),
                  _BankLine(bank: a.bank),
                  if (a.bank?.awaitingConfirmation ?? false) ...[
                    const StatusBanner(
                      'Verified, but the bank returned no name for it. Nothing is paid into it until finance confirms the account.',
                      key: Key('bank-awaiting'),
                      kind: StatusKind.warn,
                      icon: Icons.help_outline,
                    ),
                    if (canConfirm)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: Space.x8),
                          child: FilledButton.icon(
                            key: const Key('bank-confirm'),
                            onPressed: _busy ? null : _confirmBank,
                            icon: const Icon(Icons.verified_outlined, size: Sizes.iconSm),
                            label: const Text('Confirm account'),
                          ),
                        ),
                      ),
                  ],
                  Wrap(
                    spacing: Space.x24,
                    children: [
                      LabelValue(label: 'Payable', value: formatMoney(a.payable), mono: true),
                      LabelValue(label: 'Paid', value: formatMoney(a.paid), mono: true),
                      LabelValue(label: 'Held', value: formatMoney(a.held), mono: true),
                      LabelValue(label: 'First paid', value: a.firstPaidAt == null ? 'never' : shortDate(a.firstPaidAt!)),
                    ],
                  ),
                  const SizedBox(height: Space.x8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: a.isHeld
                        ? FilledButton.icon(
                            key: const Key('hold-lift'),
                            onPressed: _busy ? null : _lift,
                            icon: const Icon(Icons.play_arrow_outlined, size: Sizes.iconSm),
                            label: const Text('Lift hold'),
                          )
                        : OutlinedButton.icon(
                            key: const Key('hold-open'),
                            onPressed: _busy ? null : _hold,
                            icon: const Icon(Icons.pause_outlined, size: Sizes.iconSm),
                            label: const Text('Hold'),
                          ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _HoldDialog extends StatefulWidget {
  const _HoldDialog();

  @override
  State<_HoldDialog> createState() => _HoldDialogState();
}

class _HoldDialogState extends State<_HoldDialog> {
  final _reason = TextEditingController();
  final _until = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    _until.dispose();
    super.dispose();
  }

  void _submit() {
    final reason = _reason.text.trim().replaceAll(' ', '_').toLowerCase();
    if (reason.isEmpty || reason.length > 40) {
      setState(() => _error = 'A reason is required (up to 40 characters); the worker reads it on their statement');
      return;
    }
    final DateTime? until;
    try {
      until = parseDay(_until.text, label: 'Until');
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    Navigator.of(context).pop((reason, until));
  }

  @override
  Widget build(BuildContext context) {
    return FormSheet(
      title: 'Hold payouts',
      saveLabel: 'Place hold',
      saveKey: const Key('hold-confirm'),
      error: ErrorBanner(_error),
      onSave: _submit,
      children: [
        TextField(
          key: const Key('hold-reason'),
          controller: _reason,
          decoration: const InputDecoration(
            labelText: 'Reason',
            hintText: 'quality_review',
            helperText: 'A short code; it shows on the worker\'s statement',
          ),
        ),
        fieldGap,
        DateField(
          controller: _until,
          label: 'Until',
          helper: 'Empty holds until someone lifts it',
          fieldKey: const Key('hold-until'),
          pickKey: const Key('hold-until-pick'),
          first: DateTime.now(),
        ),
      ],
    );
  }
}

/// Where the worker is paid: account name, last four, IFSC, and whether the penny drop matched the name.
class _BankLine extends StatelessWidget {
  const _BankLine({required this.bank});
  final BankStatus? bank;

  @override
  Widget build(BuildContext context) {
    final b = bank;
    if (b == null) {
      return const StatusBanner(
        'No bank account yet: payouts wait until the worker adds one in onboarding.',
        key: Key('bank-none'),
        kind: StatusKind.warn,
        icon: Icons.account_balance_outlined,
      );
    }
    final kind = switch (b.status) {
      'verified' => StatusKind.success,
      'failed' => StatusKind.dest,
      _ => StatusKind.info,
    };
    final check = b.verification == 'none'
        ? 'not checked by the rail'
        : (b.nameMatch == false ? 'the bank holds a different name' : 'penny drop');
    return StatusBanner(
      '${humanize(b.status)} · ${b.accountName} · ••••${b.last4} · ${b.ifsc} · $check'
      '${b.confirmedAt == null ? '' : ' · confirmed by finance ${shortDate(b.confirmedAt!)}'}'
      '${b.failureReason.isEmpty ? '' : ' · ${humanize(b.failureReason)}'}',
      key: const Key('bank-status'),
      kind: kind,
      icon: Icons.account_balance_outlined,
    );
  }
}

/// The identity and agreement files the worker uploaded; View opens a five-minute link in a new tab.
class _DocumentsCard extends StatelessWidget {
  const _DocumentsCard({required this.workerId});
  final String workerId;

  Future<void> _view(BuildContext context, String kind) async {
    final scope = AppScope.of(context);
    try {
      final url = await scope.ops.documentUrl(workerId, kind);
      scope.downloader.open(Uri.parse(url));
    } on Object catch (e) {
      if (context.mounted) toast(context, describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Documents', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x8),
          LoadView<List<WorkerDocument>>(
            load: () => AppScope.of(context).ops.documents(workerId),
            isEmpty: (d) => d.isEmpty,
            emptyMessage: 'No documents uploaded.',
            builder: (context, docs, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final d in docs)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Space.x4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${humanize(d.kind)} · ${(d.sizeBytes / 1024).ceil()} KB${d.uploadedAt == null ? '' : ' · ${shortDate(d.uploadedAt!)}'}',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        TextButton(key: Key('doc-view-${d.kind}'), onPressed: () => _view(context, d.kind), child: const Text('View')),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Reviewer standing in quality: the gates quality knows they hold, and clearance for sensitive projects.
class _ReviewerCard extends StatefulWidget {
  const _ReviewerCard({required this.workerId});
  final String workerId;

  @override
  State<_ReviewerCard> createState() => _ReviewerCardState();
}

class _ReviewerCardState extends State<_ReviewerCard> {
  final _loader = GlobalKey<LoadViewState<ReviewerProfile>>();
  bool _busy = false;

  Future<void> _set(bool cleared) async {
    final scope = AppScope.of(context);
    setState(() => _busy = true);
    try {
      await withActionKey(
        scope.keys,
        'reviewer:sensitive:${widget.workerId}:$cleared',
        (key) => scope.ops.setSensitiveCleared(widget.workerId, cleared, key: key),
      );
      if (!mounted) return;
      toast(context, cleared ? 'Cleared for sensitive projects' : 'Clearance removed');
      await _loader.currentState?.reload();
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Reviewing', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x4),
          Text(
            'Reviewers only draw work for gates they hold; sensitive projects also need this clearance.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Space.x8),
          LoadView<ReviewerProfile>(
            key: _loader,
            load: () => AppScope.of(context).ops.reviewer(widget.workerId),
            builder: (context, r, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile(
                  key: const Key('reviewer-sensitive'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Cleared for sensitive projects'),
                  value: r.sensitiveCleared,
                  onChanged: _busy ? null : _set,
                ),
                Text(
                  r.gates.isEmpty ? 'Quality knows no gate for them yet.' : 'Review gates: ${r.gates.join(', ')}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The worker's last tracked sessions: when, how long active and idle, and whether a cap was passed.
class _SessionsCard extends StatelessWidget {
  const _SessionsCard({required this.workerId});
  final String workerId;

  static String _hours(int seconds) => seconds < 3600 ? '${(seconds / 60).round()} min' : '${(seconds / 3600).toStringAsFixed(1)} h';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('Tracked sessions', subtitle: 'Active and idle time while a claim was open; the last twenty'),
        LoadView<List<TrackerSession>>(
          wrapInCard: true,
          load: () => AppScope.of(context).ops.trackerSessions(workerId),
          isEmpty: (l) => l.isEmpty,
          emptyMessage: 'No tracked session yet.',
          builder: (context, sessions, _) => PortalTable(
            minWidth: 640,
            columns: const [
              PortalColumn('Started', flex: 2),
              PortalColumn('Active', numeric: true, width: 100),
              PortalColumn('Idle', numeric: true, width: 100),
              PortalColumn('Source', width: 90),
              PortalColumn('Ended', flex: 2),
            ],
            rows: [
              for (final x in sessions)
                PortalRow(key: Key('session-${x.id}'), [
                  Text(x.startedAt == null ? '—' : dateTime(x.startedAt!)),
                  Text(_hours(x.activeSeconds)),
                  Text(_hours(x.idleSeconds)),
                  Text(humanize(x.source)),
                  Text(
                    x.endedAt == null
                        ? 'Open'
                        : '${humanize(x.endReason.isEmpty ? 'ended' : x.endReason)}${x.overCapAt == null ? '' : ' · over the weekly cap'}',
                  ),
                ]),
            ],
          ),
        ),
      ],
    );
  }
}
