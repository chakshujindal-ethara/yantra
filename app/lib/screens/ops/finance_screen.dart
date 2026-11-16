import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../api/finance_models.dart';
import '../../app_router.dart';
import '../../app_scope.dart';
import '../../core/action_keys.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/money.dart';
import '../../core/poller.dart';
import '../../core/widgets/people.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/portal_tokens.dart';
import '../../core/widgets/action_dialog.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/currency_field.dart';
import '../../core/widgets/loader.dart';
import '../../core/widgets/mono_box.dart';
import '../../core/widgets/portal_page.dart';
import '../../core/widgets/tables.dart';
import '../../widgets/load_view.dart';
import '../../core/widgets/detail_frame.dart';

/// Finance for the operator: the money today, pay windows and their lifecycle (close, approve twice, bank
/// file, paid, reconcile), adjustments one person proposes and another approves, and margin per batch.
class FinanceScreen extends StatefulWidget {
  const FinanceScreen({super.key});

  @override
  State<FinanceScreen> createState() => _FinanceScreenState();
}

enum _Tab {
  overview('Overview'),
  windows('Pay windows'),
  holds('Holds'),
  adjustments('Adjustments'),
  margin('Margin');

  const _Tab(this.label);
  final String label;
}

class _FinanceScreenState extends State<FinanceScreen> {
  _Tab _tab = _Tab.overview;

  @override
  Widget build(BuildContext context) {
    return PortalPage(
      kicker: 'Money · Finance',
      title: 'Finance',
      subtitle: 'Pay windows on the rail, holds, adjustments and margin',
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Space.x16),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<_Tab>(
              key: const Key('finance-tab'),
              showSelectedIcon: false,
              segments: [for (final t in _Tab.values) ButtonSegment(value: t, label: Text(t.label))],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
          ),
        ),
        switch (_tab) {
          _Tab.overview => const _OverviewTab(),
          _Tab.windows => const _WindowsTab(),
          _Tab.holds => const _HoldsTab(),
          _Tab.adjustments => const _AdjustmentsTab(),
          _Tab.margin => const _MarginTab(),
        },
      ],
    );
  }
}

String _short(String id) => id.length > 8 ? id.substring(0, 8) : id;

/// A chip in a table cell: scaled down rather than clipped when the column is narrower than its label.
Widget _fit(Widget chip) => FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: chip);

/// `INR 1,250.00 · USD 30.00`, or a dash when there is nothing.
String _moneyList(Map<String, String> m) => m.isEmpty ? '—' : m.entries.map((e) => formatMoney(e.value, currency: e.key)).join(' · ');

/// A pay window by its IST dates: the whole week, or the end it has, never its id.
String _period(DateTime? starts, DateTime? ends) => switch ((starts, ends)) {
  (final s?, final e?) => payWindowRange(s, e),
  (final s?, null) => 'From ${istDate(s)}',
  (null, final e?) => 'Until ${istDate(e.subtract(const Duration(seconds: 1)))}',
  _ => 'Pay window',
};

StatusKind _windowKind(String status) => switch (status) {
  'paid' => StatusKind.success,
  'approved' => StatusKind.info,
  _ => StatusKind.warn,
};

class _Mono extends StatelessWidget {
  const _Mono(this.id);
  final String id;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: id.isEmpty ? '—' : id,
    child: Text(id.isEmpty ? '—' : _short(id), style: AppTheme.mono(context, fontSize: 12)),
  );
}

// ── Overview ───────────────────────────────────────────────────────────────

class _OverviewTab extends StatelessWidget {
  const _OverviewTab();

  @override
  Widget build(BuildContext context) {
    return LoadView<PayoutOverview>(
      firstWait: LoadWait.brand,
      wrapInCard: true,
      load: () => AppScope.of(context).finance.overview(),
      builder: (context, o, _) {
        final open = o.openWindow;
        final closes = open?.endsAt;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KpiRow(
              children: [
                KpiTile(
                  label: 'Payable now',
                  value: _moneyList(o.payableNow),
                  note: 'Earned, not yet in a window',
                  kind: StatusKind.info,
                  icon: Icons.account_balance_wallet_outlined,
                ),
                KpiTile(
                  label: 'Paid total',
                  value: _moneyList(o.paidTotal),
                  note: '${o.windows('paid')} windows paid',
                  kind: StatusKind.success,
                  icon: Icons.account_balance_outlined,
                ),
                KpiTile(
                  label: 'Held',
                  value: _moneyList(o.heldTotal),
                  note: 'Rolls into the next window',
                  kind: o.heldTotal.isEmpty ? null : StatusKind.warn,
                  icon: Icons.pause_circle_outline,
                ),
                KpiTile(
                  label: 'Open window closes',
                  value: closes != null ? untilShort(closes) : (open == null ? '—' : _seconds(open.closesInSeconds)),
                  note: open?.startsAt == null ? 'No open window' : 'Opened ${shortDate(open!.startsAt!)}',
                  icon: Icons.lock_clock_outlined,
                ),
                KpiTile(
                  label: 'Pending adjustments',
                  value: '${o.pendingAdjustments}',
                  note: o.pendingAdjustments == 0 ? 'Nothing to approve' : 'Waiting for a second person',
                  kind: o.pendingAdjustments == 0 ? null : StatusKind.warn,
                  icon: Icons.tune_outlined,
                ),
                KpiTile(
                  label: 'Awaiting approval',
                  value: '${o.windows('closed')}',
                  note: '${o.windows('approved')} approved, ${o.windows('paying')} on the rail',
                  kind: o.windows('closed') == 0 ? null : StatusKind.warn,
                  icon: Icons.how_to_vote_outlined,
                ),
                KpiTile(
                  label: 'Margin to date',
                  value: _moneyList(o.marginTotal),
                  note: 'Invoice minus pay, review and audit',
                  icon: Icons.insights_outlined,
                ),
              ],
            ),
            const SizedBox(height: Space.x16),
            const _RailCard(),
          ],
        );
      },
    );
  }

  static String _seconds(int s) => s <= 0 ? 'now' : untilShort(DateTime.now().add(Duration(seconds: s)));
}

// ── Pay windows ────────────────────────────────────────────────────────────

class _WindowsTab extends StatefulWidget {
  const _WindowsTab();

  @override
  State<_WindowsTab> createState() => _WindowsTabState();
}

class _WindowsTabState extends State<_WindowsTab> {
  final _loader = GlobalKey<LoadViewState<List<PayWindowRow>>>();

  Future<void> _close() async {
    final w = await showDialog<PayWindowRow>(context: context, builder: (_) => const _CloseDialog());
    if (w == null || !mounted) return;
    toast(context, 'Window closed: ${_period(w.startsAt, w.endsAt)}');
    await _loader.currentState?.reload();
  }

  Future<void> _open(PayWindowRow w) async {
    await context.push(Paths.window(w.id), extra: w);
    await _loader.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(
          'Pay windows',
          subtitle: 'Close (or wait for Saturday 00:05 IST), approve twice, pay on the rail, reconcile',
          trailing: _isFinance(context)
              ? FilledButton.icon(
                  key: const Key('close-window'),
                  onPressed: _close,
                  icon: const Icon(Icons.lock_outline, size: Sizes.iconSm),
                  label: const Text('Close window'),
                )
              : null,
        ),
        LoadView<List<PayWindowRow>>(
          firstWait: LoadWait.brand,
          wrapInCard: true,
          key: _loader,
          load: () => AppScope.of(context).finance.windows(),
          isEmpty: (w) => w.isEmpty,
          emptyMessage: 'No pay window yet. The week closes on its own at Saturday 00:05 IST, or close it by hand.',
          builder: (context, windows, _) => PortalTable(
            minWidth: 760,
            columns: const [
              PortalColumn('Period', flex: 3),
              PortalColumn('Currency', width: 90),
              PortalColumn('Lines', numeric: true, width: 80),
              PortalColumn('Gross', numeric: true, flex: 2),
              PortalColumn('Held', numeric: true, flex: 2),
              PortalColumn('Status', width: 120),
              PortalColumn('Approvals', numeric: true, width: 100),
            ],
            rows: [
              for (final w in windows)
                PortalRow(key: Key('window-${w.id}'), onTap: () => _open(w), [
                  Text(_period(w.startsAt, w.endsAt)),
                  Text(w.currency),
                  Text(w.lineCount == null ? '—' : '${w.lineCount}'),
                  Text(formatMoney(w.grossTotal, currency: w.currency)),
                  Text(formatMoney(w.heldTotal, currency: w.currency)),
                  _fit(StatusChip(humanize(w.status), kind: _windowKind(w.status))),
                  Text(w.approvals == null ? '—' : '${w.approvals} of 2'),
                ]),
            ],
          ),
        ),
      ],
    );
  }
}

/// One pay window: its lines on the rail and the actions its status allows. Opened from the windows table
/// (which hands the row over) or from a link (which reads the window by id first).
class WindowScreen extends StatefulWidget {
  const WindowScreen({super.key, required this.windowId, this.window});
  final String windowId;
  final PayWindowRow? window;

  static const crumbs = [Crumb('Money'), Crumb('Finance', path: '/ops/finance'), Crumb('Pay window')];

  @override
  State<WindowScreen> createState() => _WindowLoaderState();
}

class _WindowLoaderState extends State<WindowScreen> {
  late Future<PayWindowRow> _load = _read();

  Future<PayWindowRow> _read() async => widget.window ?? AppScope.of(context).finance.window(widget.windowId);

  @override
  Widget build(BuildContext context) {
    final given = widget.window;
    if (given != null) return _WindowPage(window: given, stale: true);
    return FutureBuilder<PayWindowRow>(
      future: _load,
      builder: (context, snap) {
        final w = snap.data;
        if (w != null) return _WindowPage(window: w);
        return DetailFrame(
          crumbs: WindowScreen.crumbs,
          body: snap.hasError
              ? ErrorView(
                  message: describeError(snap.error!),
                  onRetry: () async => setState(() {
                    _load = _read();
                  }),
                )
              : const Center(child: BrandLoader()),
        );
      },
    );
  }
}

class _WindowPage extends StatefulWidget {
  const _WindowPage({required this.window, this.stale = false});
  final PayWindowRow window;

  /// The row was handed over by the list and may be old: shown at once, then read again.
  final bool stale;

  @override
  State<_WindowPage> createState() => _WindowScreenState();
}

/// True when the signed-in person may move money (approve, pay, retry, release, reconcile for the record).
bool _isFinance(BuildContext context) => AppScope.of(context).session.roles.contains('finance');

StatusKind _lineKind(String status) => switch (status) {
  'paid' => StatusKind.success,
  'failed' || 'returned' => StatusKind.dest,
  'held' || 'released' => StatusKind.warn,
  _ => StatusKind.info,
};

class _WindowScreenState extends State<_WindowPage> {
  late PayWindowRow _w = widget.window;
  ReconcileReport? _reconciled;
  String? _notice;
  StatusKind _noticeKind = StatusKind.info;
  bool _busy = false;

  /// Pay answered 409 `window_over_cap`: "Pay over the cap" is offered, with a required reason.
  bool _overCap = false;
  final _lines = GlobalKey<LoadViewState<List<WindowLineRow>>>();
  final _runs = GlobalKey<LoadViewState<List<ReconcileRun>>>();
  Poller? _poller;

  /// The last re-read failed: a quiet "Couldn't refresh · Retry" line, the page stays as it was.
  bool _refreshFailed = false;

  @override
  void initState() {
    super.initState();
    if (widget.stale) WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPoller();
  }

  @override
  void dispose() {
    _poller?.dispose();
    super.dispose();
  }

  /// While lines are on the rail, the page re-reads the window and its lines every 15 s so settled lines
  /// appear without a refresh.
  void _syncPoller() {
    if (_w.isPaying && _poller == null) {
      _poller = Poller(every: const Duration(seconds: 15), tick: _refresh)..start();
    } else if (!_w.isPaying && _poller != null) {
      _poller!.dispose();
      _poller = null;
    }
  }

  /// Reads the window and its lines again: on open, after every action and every 15 s while paying. A
  /// failure keeps what is on screen and shows the quiet retry line.
  Future<void> _refresh() async {
    if (!mounted) return;
    try {
      final w = await AppScope.of(context).finance.window(_w.id);
      if (!mounted) return;
      setState(() {
        _w = w;
        _refreshFailed = false;
      });
      _syncPoller();
      await _lines.currentState?.reload();
    } on Object {
      if (mounted) setState(() => _refreshFailed = true);
    }
  }

  void _fail(Object e) {
    if (!mounted) return;
    final code = e is ApiException ? e.code : '';
    setState(() {
      _noticeKind = code == 'window_over_cap' ? StatusKind.warn : StatusKind.dest;
      if (code == 'window_over_cap') _overCap = true;
      _notice = switch (code) {
        'already_approved' => 'You already approved this window. A second person must approve it before it can be paid.',
        'window_over_cap' => '${describeError(e)} Paying it anyway needs a reason; your name, the reason and the time are recorded.',
        'too_many_attempts' => 'This line was tried too many times. Release it so its earnings roll into the next window.',
        _ => describeError(e),
      };
    });
  }

  Future<void> _run(String action, Future<void> Function(String key) call, {required String done}) async {
    final scope = AppScope.of(context);
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await withActionKey(scope.keys, action, call);
      if (mounted) toast(context, done);
    } on Object catch (e) {
      _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approve() => _run('window:approve:${_w.id}', (key) async {
    final w = await AppScope.of(context).finance.approveWindow(_w.id, key: key);
    if (!mounted) return;
    setState(() {
      _w = w;
      if (w.isClosed) {
        _noticeKind = StatusKind.info;
        _notice = 'Your approval is recorded. A second person must approve before the window can be paid.';
      }
    });
    await _refresh();
  }, done: 'Approval recorded');

  Future<void> _pay() async {
    final ok = await confirm(
      context,
      title: 'Pay this window?',
      body:
          'Every payable line goes to the rail now. Paid lines cannot be recalled; a line the bank refuses comes back as failed for you to retry or release.',
      confirmLabel: 'Pay window',
    );
    if (!ok || !mounted) return;
    await _run('window:pay:${_w.id}', (key) async {
      final w = await AppScope.of(context).finance.payWindow(_w.id, key: key);
      if (!mounted) return;
      setState(() => _w = w);
      await _refresh();
    }, done: 'Sent to the rail');
  }

  /// Pays a window above the per-window cap: the reason is required and recorded on the window with the caller.
  Future<void> _payOverCap() async {
    final scope = AppScope.of(context);
    final w = await showActionDialog<PayWindowRow>(
      context,
      title: 'Pay over the cap',
      body:
          'This window is above the per-window payout cap. Say why it should be paid anyway: your name, the reason and the time '
          'are recorded on the window. Paid lines cannot be recalled.',
      fieldLabel: 'Reason',
      confirmLabel: 'Pay over the cap',
      maxLines: 3,
      fieldKey: const Key('over-cap-reason'),
      sendKey: const Key('over-cap-send'),
      onSend: (reason) => withActionKey(
        scope.keys,
        'window:pay-over-cap:${_w.id}:${bodyTag(reason)}',
        (key) => scope.finance.payWindow(_w.id, overCapReason: reason, key: key),
      ),
    );
    if (w == null || !mounted) return;
    setState(() {
      _w = w;
      _overCap = false;
      _notice = null;
    });
    toast(context, 'Sent to the rail over the cap');
    await _refresh();
  }

  Future<void> _retry(WindowLineRow l) => _run('line:retry:${l.id}:${l.attempts}', (key) async {
    await AppScope.of(context).finance.retryLine(_w.id, l.id, key: key);
    await _refresh();
  }, done: 'Line sent again');

  Future<void> _release(WindowLineRow l) async {
    final ok = await confirm(
      context,
      title: 'Release this line?',
      body: 'Its earnings go back to payable and roll into the next window. The window can then finish.',
      confirmLabel: 'Release line',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _run('line:release:${l.id}', (key) async {
      await AppScope.of(context).finance.releaseLine(_w.id, l.id, key: key);
      await _refresh();
    }, done: 'Line released');
  }

  Future<void> _bankFile() async {
    final scope = AppScope.of(context);
    setState(() => _busy = true);
    try {
      final (:bytes, :skipped) = await scope.finance.bankFile(_w.id);
      final name = 'bank-file-${_period(_w.startsAt, _w.endsAt).replaceAll(' ', '')}.csv';
      if (!mounted) return;
      if (skipped.isNotEmpty) {
        // the lines left out went back to the queue; the table shows each one's reason once re-read
        setState(() {
          _noticeKind = StatusKind.warn;
          _notice = '${skippedSummary(skipped)} They are back in the queue and are not in this file.';
        });
        unawaited(_refresh());
      }
      if (scope.downloader.supported) {
        scope.downloader.save(name, bytes, 'text/csv');
        toast(context, 'Bank file saved: $name');
      } else {
        await showMonoDialog(context, title: 'Bank file', text: String.fromCharCodes(bytes));
      }
    } on Object catch (e) {
      _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _returnFile() async {
    final scope = AppScope.of(context);
    final file = await scope.files.pick(accept: '.csv,text/csv');
    if (file == null || !mounted) return;
    await _run('window:return:${_w.id}:${file.name}:${file.bytes.length}', (key) async {
      final r = await scope.finance.uploadReturnFile(_w.id, utf8.decode(file.bytes, allowMalformed: true), key: key);
      if (!mounted) return;
      setState(() {
        _noticeKind = r.skipped.isEmpty ? StatusKind.success : StatusKind.warn;
        _notice =
            'Return file: ${r.applied} lines settled'
            '${r.skipped.isEmpty ? '' : ', ${r.skipped.length} skipped (${r.skipped.map((s) => 'row ${s['row']}: ${humanize('${s['reason']}')}').join('; ')})'}.';
      });
      await _refresh();
    }, done: 'Return file applied');
  }

  Future<void> _check({required bool record}) async {
    final scope = AppScope.of(context);
    setState(() => _busy = true);
    try {
      final r = record
          ? await withActionKey(scope.keys, 'window:reconcile:${_w.id}', (key) => scope.finance.recordReconcile(_w.id, key: key))
          : await scope.finance.reconcile(_w.id);
      if (!mounted) return;
      setState(() => _reconciled = r);
      if (record) {
        await _runs.currentState?.reload();
        await _refresh();
      }
    } on Object catch (e) {
      _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    final scope = AppScope.of(context);
    setState(() => _busy = true);
    try {
      final bytes = await scope.finance.statementExport(_w.id);
      if (!mounted) return;
      scope.downloader.save('statement-${_w.id.substring(0, _w.id.length < 8 ? _w.id.length : 8)}.csv', bytes, 'text/csv');
      toast(context, 'Statement saved');
    } on Object catch (e) {
      _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _guide(PayWindowRow w) => switch (w.status) {
    'closed' => 'Two different people with the finance role approve a closed window; then it can be paid.',
    'approved' => 'Pay sends every payable line to the rail. Lines settle on their own; a refused line comes back as failed.',
    'paying' when w.onFileRail => 'Download the bank file, upload it to the bank, then upload the bank\'s return file to settle each line.',
    'paying' => 'The rail is paying the lines. This page refreshes every 15 seconds; retry or release any line that fails.',
    _ => 'Paid. Record a reconciliation: the first balanced run releases the statements to workers.',
  };

  @override
  Widget build(BuildContext context) {
    final w = _w;
    final r = _reconciled;
    final finance = _isFinance(context);
    final secondNeeded = w.isClosed && (w.approvals ?? 0) == 1 && _notice == null;
    return DetailFrame(
      crumbs: WindowScreen.crumbs,
      body: PortalPage(
        kicker: 'Money · Finance',
        title: _period(w.startsAt, w.endsAt),
        subtitle:
            '${w.currency} · ${w.lineCount == null ? '' : '${w.lineCount} lines · '}gross ${formatMoney(w.grossTotal, currency: w.currency)}'
            ' · held ${formatMoney(w.heldTotal, currency: w.currency)}${w.rail.isEmpty ? '' : ' · ${_railLabel(w.rail)}'}',
        actions: [StatusChip(humanize(w.status), key: const Key('window-status'), kind: _windowKind(w.status))],
        children: [
          if (_refreshFailed)
            Padding(
              key: const Key('window-refresh-failed'),
              padding: const EdgeInsets.only(bottom: Space.x8),
              child: Row(
                children: [
                  Icon(Icons.sync_problem_outlined, size: Sizes.iconSm, color: PortalTokens.of(context).textSecondary),
                  const SizedBox(width: Space.x6),
                  Text("Couldn't refresh", style: Theme.of(context).textTheme.bodySmall),
                  const Text(' · '),
                  TextButton(key: const Key('window-refresh-retry'), onPressed: _refresh, child: const Text('Retry')),
                ],
              ),
            ),
          if (_notice != null) StatusBanner(_notice!, key: const Key('window-notice'), kind: _noticeKind, icon: Icons.info_outline),
          if (!finance)
            const StatusBanner(
              'Read only: approving, paying and reconciling need the finance role.',
              key: Key('window-read-only'),
              kind: StatusKind.info,
              icon: Icons.lock_outline,
            ),
          if (secondNeeded)
            const StatusBanner(
              'One approval so far. A second person must approve before the window can be paid.',
              key: Key('window-second-approval'),
              kind: StatusKind.info,
              icon: Icons.how_to_vote_outlined,
            ),
          if (w.capOverrideAt != null || w.capOverrideReason.isNotEmpty)
            PortalCard(
              key: const Key('window-cap-override'),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: Sizes.iconSm, color: PortalTokens.of(context).warnText),
                  const SizedBox(width: Space.x8),
                  Text('Paid over the per-window cap by ', style: Theme.of(context).textTheme.bodySmall),
                  NameOf(w.capOverrideBy, style: Theme.of(context).textTheme.bodySmall),
                  Expanded(
                    child: Text(
                      '${w.capOverrideAt == null ? '' : ' on ${shortDate(w.capOverrideAt!)}'}: ${w.capOverrideReason}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          if (w.isPaid)
            StatusBanner(
              'Paid ${w.paidAt == null ? '' : shortDate(w.paidAt!)} · ${formatMoney(w.paidTotal, currency: w.currency)} moved'
              '${w.reconciledAt == null ? ' · not reconciled yet, statements are held' : ' · reconciled ${shortDate(w.reconciledAt!)}, statements released'}',
              key: const Key('window-paid'),
              kind: w.reconciledAt == null ? StatusKind.warn : StatusKind.success,
              icon: Icons.check_circle_outline,
            ),
          PortalCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Actions', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: Space.x4),
                Text(_guide(w), style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: Space.x12),
                Wrap(
                  spacing: Space.x8,
                  runSpacing: Space.x8,
                  children: [
                    if (finance && w.isClosed)
                      FilledButton(key: const Key('window-approve'), onPressed: _busy ? null : _approve, child: const Text('Approve')),
                    if (finance && w.isApproved)
                      FilledButton.icon(
                        key: const Key('window-pay'),
                        onPressed: _busy ? null : _pay,
                        icon: const Icon(Icons.send_outlined, size: Sizes.iconSm),
                        label: const Text('Pay window'),
                      ),
                    if (finance && w.isApproved && _overCap)
                      OutlinedButton.icon(
                        key: const Key('window-pay-over-cap'),
                        onPressed: _busy ? null : _payOverCap,
                        icon: const Icon(Icons.warning_amber_rounded, size: Sizes.iconSm),
                        label: const Text('Pay over the cap'),
                      ),
                    if (finance && w.onFileRail && (w.isPaying || w.isPaid))
                      OutlinedButton.icon(
                        key: const Key('window-bank-file'),
                        onPressed: _busy ? null : _bankFile,
                        icon: const Icon(Icons.download_outlined, size: Sizes.iconSm),
                        label: const Text('Bank file'),
                      ),
                    if (finance && w.onFileRail && w.isPaying)
                      OutlinedButton.icon(
                        key: const Key('window-return-file'),
                        onPressed: _busy ? null : _returnFile,
                        icon: const Icon(Icons.upload_file_outlined, size: Sizes.iconSm),
                        label: const Text('Upload return file'),
                      ),
                    OutlinedButton.icon(
                      key: const Key('window-reconcile'),
                      onPressed: _busy ? null : () => _check(record: false),
                      icon: const Icon(Icons.balance_outlined, size: Sizes.iconSm),
                      label: const Text('Check balance'),
                    ),
                    if (finance && (w.isPaying || w.isPaid))
                      OutlinedButton.icon(
                        key: const Key('window-record'),
                        onPressed: _busy ? null : () => _check(record: true),
                        icon: const Icon(Icons.fact_check_outlined, size: Sizes.iconSm),
                        label: const Text('Record reconciliation'),
                      ),
                    if (w.reconciledAt != null)
                      OutlinedButton.icon(
                        key: const Key('window-export'),
                        onPressed: _busy ? null : _export,
                        icon: const Icon(Icons.download_outlined, size: Sizes.iconSm),
                        label: const Text('Statement (CSV)'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (r != null) _ReconcileBanner(report: r, currency: w.currency),
          const SectionTitle('Lines', subtitle: 'One per worker: what the week pays, and where it is on the rail'),
          LoadView<List<WindowLineRow>>(
            key: _lines,
            wrapInCard: true,
            load: () => AppScope.of(context).finance.windowLines(w.id),
            isEmpty: (l) => l.isEmpty,
            emptyMessage: 'No lines: nothing was payable in this window.',
            builder: (context, lines, _) => PortalTable(
              minWidth: 880,
              columns: [
                const PortalColumn('Worker', flex: 2),
                const PortalColumn('Earnings', numeric: true, width: 90),
                const PortalColumn('Amount', numeric: true, flex: 2),
                const PortalColumn('Status', width: 120),
                const PortalColumn('Tries', numeric: true, width: 70),
                const PortalColumn('Bank reference or reason', flex: 3),
                if (finance) const PortalColumn('', width: 190),
              ],
              rows: [
                for (final l in lines)
                  PortalRow(key: Key('line-${l.id}'), [
                    NameOf(l.workerId),
                    Text('${l.earningCount}'),
                    Text(formatMoney(l.gross, currency: w.currency)),
                    _fit(StatusChip(humanize(l.status), kind: _lineKind(l.status))),
                    Text(l.attempts == 0 ? '—' : '${l.attempts}'),
                    Text(_lineNote(l), style: l.utr.isNotEmpty ? AppTheme.mono(context, fontSize: 12) : null),
                    if (finance)
                      l.isFailed
                          ? Wrap(
                              spacing: Space.x4,
                              children: [
                                TextButton(
                                  key: Key('line-retry-${l.id}'),
                                  onPressed: _busy ? null : () => _retry(l),
                                  child: Text('Retry', semanticsLabel: 'Retry the payout to ${personLabel(context, l.workerId)}'),
                                ),
                                TextButton(
                                  key: Key('line-release-${l.id}'),
                                  onPressed: _busy ? null : () => _release(l),
                                  child: Text('Release', semanticsLabel: 'Release the line of ${personLabel(context, l.workerId)}'),
                                ),
                              ],
                            )
                          : const SizedBox.shrink(),
                  ]),
              ],
            ),
          ),
          const SectionTitle('Reconciliation runs', subtitle: 'Recorded checks of this window; nothing is ever adjusted'),
          LoadView<List<ReconcileRun>>(
            key: _runs,
            wrapInCard: true,
            load: () => AppScope.of(context).finance.reconciliationRuns(windowId: w.id),
            isEmpty: (l) => l.isEmpty,
            emptyMessage: 'No recorded run yet.',
            builder: (context, runs, _) => PortalTable(
              minWidth: 640,
              columns: const [
                PortalColumn('Ran', flex: 2),
                PortalColumn('Lines', numeric: true, flex: 2),
                PortalColumn('Paid', numeric: true, flex: 2),
                PortalColumn('Rail moved', numeric: true, flex: 2),
                PortalColumn('Result', width: 130),
              ],
              rows: [
                for (final run in runs)
                  PortalRow(key: Key('run-${run.id}'), [
                    Text(run.ranAt == null ? '—' : dateTime(run.ranAt!)),
                    Text(formatMoney(run.linesTotal, currency: w.currency)),
                    Text(formatMoney(run.paidTotal, currency: w.currency)),
                    Text(formatMoney(run.railTotal, currency: w.currency)),
                    _fit(
                      StatusChip(
                        run.balanced ? 'Balanced' : 'Delta ${formatMoney(run.deltaLines, currency: w.currency)}',
                        kind: run.balanced ? StatusKind.success : StatusKind.dest,
                      ),
                    ),
                  ]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The bank's reference, else why the line failed, is held or is not going out.
String _lineNote(WindowLineRow l) {
  if (l.utr.isNotEmpty) return l.utr;
  if (l.failureReason.isNotEmpty) return humanize(l.failureReason);
  if (l.isBlocked) return 'Not going out: ${payoutReason(l.railStatus).toLowerCase()}';
  return l.holdReason.isEmpty ? '—' : payoutReason(l.holdReason);
}

String _railLabel(String rail) => switch (rail) {
  'razorpayx' => 'RazorpayX',
  'file' => 'bank file',
  'fake' => 'test rail',
  _ => rail,
};

class _ReconcileBanner extends StatelessWidget {
  const _ReconcileBanner({required this.report, required this.currency});
  final ReconcileReport report;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final r = report;
    String m(String v) => formatMoney(v, currency: currency);
    final problems = [
      if (r.delta != '0' && r.delta != '0.00' && r.delta != '0.000000') 'earnings ${m(r.earningsTotal)} against lines ${m(r.linesTotal)}',
      if (r.deltaRail != '0' && r.deltaRail != '0.00' && r.deltaRail != '0.000000')
        'paid ${m(r.paidTotal)} against the rail ${m(r.railTotal)}',
      if (r.failedLines > 0) '${r.failedLines} lines failed',
      if (r.processingLines > 0) '${r.processingLines} lines still on the rail',
      if (r.unpaidEarnings > 0) '${r.unpaidEarnings} earnings still unpaid',
    ];
    return StatusBanner(
      r.balanced
          ? 'Balanced: earnings ${m(r.earningsTotal)} equal the lines, and the rail moved ${m(r.railTotal)} for the paid ones.'
          : 'Not balanced: ${problems.isEmpty ? 'see the run' : problems.join('; ')}. Nothing was adjusted.',
      key: const Key('reconcile-result'),
      kind: r.balanced ? StatusKind.success : StatusKind.dest,
      icon: r.balanced ? Icons.check_circle_outline : Icons.error_outline,
    );
  }
}

// ── Adjustments ────────────────────────────────────────────────────────────

class _AdjustmentsTab extends StatefulWidget {
  const _AdjustmentsTab();

  @override
  State<_AdjustmentsTab> createState() => _AdjustmentsTabState();
}

class _AdjustmentsTabState extends State<_AdjustmentsTab> {
  static const filters = <String, String?>{'All': null, 'Pending': 'pending', 'Approved': 'approved', 'Rejected': 'rejected'};
  String? _status;
  int _generation = 0;

  void _refresh() => setState(() => _generation++);

  Future<void> _propose() async {
    final a = await showDialog<Adjustment>(context: context, builder: (_) => const _ProposeDialog());
    if (a == null || !mounted) return;
    toast(context, 'Adjustment proposed');
    _refresh();
  }

  Future<void> _decide(Adjustment a, {required bool approve}) async {
    final scope = AppScope.of(context);
    final verb = approve ? 'approve' : 'reject';
    final sent = await showActionDialog<Adjustment>(
      context,
      title: approve ? 'Approve the adjustment' : 'Reject the adjustment',
      body: approve
          ? 'Approving creates a payable earning for ${formatMoney(a.amount, currency: a.currency)}. The proposer cannot approve their own.'
          : 'Rejecting closes it; the worker is not told why unless you say so elsewhere.',
      fieldLabel: 'Note',
      minLength: 0,
      confirmLabel: approve ? 'Approve' : 'Reject',
      destructive: !approve,
      fieldKey: const Key('adjust-note'),
      sendKey: const Key('adjust-note-send'),
      messageFor: (e) =>
          e.code == 'same_person' ? 'The person who proposed an adjustment cannot approve it. Ask a colleague.' : describeError(e),
      onSend: (text) => withActionKey(
        scope.keys,
        'adjust:$verb:${a.id}',
        (key) => approve
            ? scope.finance.approveAdjustment(a.id, note: text, key: key)
            : scope.finance.rejectAdjustment(a.id, note: text, key: key),
      ),
    );
    if (sent == null || !mounted) return;
    toast(context, approve ? 'Adjustment approved' : 'Adjustment rejected');
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(
          'Adjustments',
          subtitle: 'A bonus or a correction; proposed by one person, approved by another',
          trailing: FilledButton.icon(
            key: const Key('adjust-propose'),
            onPressed: _propose,
            icon: const Icon(Icons.add, size: Sizes.iconSm),
            label: const Text('Propose'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: Space.x12),
          child: FilterChips<String>(values: filters, selected: _status, onSelected: (v) => setState(() => _status = v)),
        ),
        LoadView<List<Adjustment>>(
          wrapInCard: true,
          key: ValueKey('adjustments/$_status/$_generation'),
          load: () => AppScope.of(context).finance.adjustments(status: _status),
          isEmpty: (a) => a.isEmpty,
          emptyMessage: _status == null ? 'No adjustments yet. Propose a bonus or a correction.' : 'No $_status adjustments.',
          builder: (context, items, _) => PortalTable(
            minWidth: 900,
            columns: const [
              PortalColumn('Worker', flex: 2),
              PortalColumn('Amount', numeric: true, flex: 2),
              PortalColumn('Kind', width: 110),
              PortalColumn('Reason', flex: 4),
              PortalColumn('Status', width: 110),
              PortalColumn('Proposed by', flex: 2),
              PortalColumn('', width: 200),
            ],
            rows: [
              for (final a in items)
                PortalRow(key: Key('adjust-${a.id}'), [
                  NameOf(a.workerId),
                  Text(
                    formatMoney(a.amount, currency: a.currency),
                    style: TextStyle(color: a.amount.startsWith('-') ? t.destText : null),
                  ),
                  Text(humanize(a.kind)),
                  Tooltip(message: a.reason, child: Text(a.reason)),
                  _fit(StatusChip.status(a.status, label: humanize(a.status))),
                  NameOf(a.proposedBy),
                  if (a.isPending && _isFinance(context))
                    _fit(
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            key: Key('adjust-approve-${a.id}'),
                            onPressed: () => _decide(a, approve: true),
                            child: const Text('Approve'),
                          ),
                          TextButton(
                            key: Key('adjust-reject-${a.id}'),
                            style: TextButton.styleFrom(foregroundColor: t.destText),
                            onPressed: () => _decide(a, approve: false),
                            child: const Text('Reject'),
                          ),
                        ],
                      ),
                    )
                  else
                    a.decidedBy.isEmpty
                        ? Text(
                            a.isPending ? 'Waiting for finance' : '—',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: t.textSecondary),
                          )
                        : NameOf(a.decidedBy, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: t.textSecondary)),
                ]),
            ],
          ),
        ),
      ],
    );
  }
}

/// Worker, amount, currency, kind and reason for a new adjustment. Posts under one key per attempt set.
class _ProposeDialog extends StatefulWidget {
  const _ProposeDialog();

  @override
  State<_ProposeDialog> createState() => _ProposeDialogState();
}

class _ProposeDialogState extends State<_ProposeDialog> {
  final _worker = TextEditingController();
  final _amount = TextEditingController();
  final _currency = TextEditingController(text: 'INR');
  final _reason = TextEditingController();
  String _kind = 'bonus';
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _worker.dispose();
    _amount.dispose();
    _currency.dispose();
    _reason.dispose();
    super.dispose();
  }

  String? _validate() {
    if (_worker.text.trim().isEmpty) return 'Worker id is required';
    final amount = double.tryParse(_amount.text.trim());
    if (amount == null || amount == 0) return 'Amount must be a number other than zero';
    if (_kind == 'bonus' && amount < 0) return 'A bonus is positive; use a correction to take money back';
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(_currency.text.trim().toUpperCase())) return 'Currency is a three-letter code';
    if (_reason.text.trim().length < 5) return 'Say why, in at least 5 characters';
    return null;
  }

  Future<void> _send() async {
    final problem = _validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final scope = AppScope.of(context);
    final input = AdjustmentInput(
      workerId: _worker.text.trim(),
      amount: _amount.text.trim(),
      currency: _currency.text.trim().toUpperCase(),
      kind: _kind,
      reason: _reason.text.trim(),
    );
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final a = await withActionKey(
        scope.keys,
        'adjust:propose:${bodyTag(input.toJson())}',
        (key) => scope.finance.proposeAdjustment(input, key: key),
      );
      if (mounted) Navigator.of(context).pop(a);
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Propose an adjustment'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ErrorBanner(_error),
              Text('A different person approves it; approval creates a payable earning.', style: theme.textTheme.bodySmall),
              const SizedBox(height: Space.x12),
              TextField(
                key: const Key('adjust-worker'),
                controller: _worker,
                enabled: !_busy,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Worker id'),
              ),
              const SizedBox(height: Space.x12),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      key: const Key('adjust-amount'),
                      controller: _amount,
                      enabled: !_busy,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      decoration: const InputDecoration(labelText: 'Amount'),
                    ),
                  ),
                  const SizedBox(width: Space.x8),
                  Expanded(
                    child: TextField(
                      key: const Key('adjust-currency'),
                      controller: _currency,
                      enabled: !_busy,
                      decoration: const InputDecoration(labelText: 'Currency'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.x12),
              SegmentedButton<String>(
                key: const Key('adjust-kind'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'bonus', label: Text('Bonus')),
                  ButtonSegment(value: 'correction', label: Text('Correction')),
                ],
                selected: {_kind},
                onSelectionChanged: _busy ? null : (s) => setState(() => _kind = s.first),
              ),
              const SizedBox(height: Space.x12),
              TextField(
                key: const Key('adjust-reason'),
                controller: _reason,
                enabled: !_busy,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Reason'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('adjust-cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(key: const Key('adjust-send'), onPressed: _busy ? null : _send, child: const Text('Propose')),
      ],
    );
  }
}

// ── Margin ─────────────────────────────────────────────────────────────────

class _MarginTab extends StatelessWidget {
  const _MarginTab();

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('Margin per batch', subtitle: 'What the accepted units invoice against pay, review and audit'),
        LoadView<List<MarginRow>>(
          firstWait: LoadWait.brand,
          wrapInCard: true,
          load: () => AppScope.of(context).finance.margin(),
          isEmpty: (m) => m.isEmpty,
          emptyMessage: 'No margin yet. A batch appears once a verdict reaches the cost ledger.',
          builder: (context, rows, _) => PortalTable(
            minWidth: 960,
            columns: const [
              PortalColumn('Batch', flex: 2),
              PortalColumn('Currency', width: 90),
              PortalColumn('Judged', numeric: true, width: 80),
              PortalColumn('Accepted', numeric: true, width: 90),
              PortalColumn('Invoice', numeric: true, flex: 2),
              PortalColumn('Pay', numeric: true, flex: 2),
              PortalColumn('Review', numeric: true, flex: 2),
              PortalColumn('Audit', numeric: true, flex: 2),
              PortalColumn('Margin', numeric: true, flex: 2),
              PortalColumn('Margin %', numeric: true, width: 90),
            ],
            rows: [
              for (final r in rows)
                PortalRow(key: Key('margin-${r.batchId}'), [
                  _Mono(r.batchId),
                  Text(r.currency),
                  Text('${r.unitsJudged}'),
                  Text('${r.unitsAccepted}'),
                  Text(formatMoney(r.invoice, currency: r.currency)),
                  Text(formatMoney(r.costPay, currency: r.currency)),
                  Text(formatMoney(r.costReview, currency: r.currency)),
                  Text(formatMoney(r.costAudit, currency: r.currency)),
                  Text(
                    formatMoney(r.margin, currency: r.currency),
                    style: TextStyle(color: r.margin.startsWith('-') ? t.destText : t.successText),
                  ),
                  Text('${r.marginPercent}%', style: TextStyle(color: r.marginPercent < 0 ? t.destText : null)),
                ]),
            ],
          ),
        ),
      ],
    );
  }
}

/// Closing a window by hand: the currency is picked, never typed.
class _CloseDialog extends StatefulWidget {
  const _CloseDialog();

  @override
  State<_CloseDialog> createState() => _CloseDialogState();
}

class _CloseDialogState extends State<_CloseDialog> {
  String _currency = supportedCurrencies.first;
  bool _busy = false;
  String? _error;

  Future<void> _send() async {
    final scope = AppScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final w = await withActionKey(scope.keys, 'window:close:$_currency', (key) => scope.finance.closeWindow(_currency, key: key));
      if (mounted) Navigator.of(context).pop(w);
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Close the open window'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Every payable earning in the currency up to the last pay-week end rolls into one window. Nothing is paid yet.'),
            const SizedBox(height: Space.x16),
            KeyedSubtree(
              key: const Key('close-currency'),
              child: CurrencyField(value: _currency, onChanged: (c) => setState(() => _currency = c)),
            ),
            if (_error != null) ...[
              const SizedBox(height: Space.x12),
              StatusBanner(_error!, kind: StatusKind.dest, icon: Icons.error_outline),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const Key('close-window-send'), onPressed: _busy ? null : _send, child: const Text('Close window')),
      ],
    );
  }
}

/// The rail: which one pays, what is on it now, and when the jobs last ran.
class _RailCard extends StatelessWidget {
  const _RailCard();

  @override
  Widget build(BuildContext context) {
    return LoadView<RailState>(
      wrapInCard: true,
      load: () => AppScope.of(context).finance.rail(),
      builder: (context, r, _) {
        final theme = Theme.of(context);
        final t = PortalTokens.of(context);
        final stuck = r.count('failed') + r.count('returned');
        return PortalCard(
          key: const Key('rail-card'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text('Rail: ${_railLabel(r.rail)}', style: theme.textTheme.titleMedium)),
                  StatusChip(stuck == 0 ? 'Healthy' : '$stuck need finance', kind: stuck == 0 ? StatusKind.success : StatusKind.dest),
                ],
              ),
              const SizedBox(height: Space.x8),
              Wrap(
                spacing: Space.x16,
                runSpacing: Space.x8,
                children: [
                  for (final k in const ['queued', 'processing', 'failed', 'returned'])
                    Text('${humanize(k)} ${r.count(k)}', style: theme.textTheme.bodyMedium),
                  Text('Accounts verifying ${r.accountsVerifying}', style: theme.textTheme.bodyMedium),
                ],
              ),
              const SizedBox(height: Space.x8),
              Text(
                '${r.supportsPennyDrop ? 'Bank accounts are checked with a penny drop.' : 'This rail cannot check bank accounts; finance checks them.'}'
                ' Last sent ${r.lastDispatchAt == null ? 'never' : relative(r.lastDispatchAt!)}, last checked ${r.lastPollAt == null ? 'never' : relative(r.lastPollAt!)}.',
                style: theme.textTheme.bodySmall?.copyWith(color: t.textSecondary),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Asks before finance confirms a bank account the penny drop proved without a registered name.
Future<bool> confirmBankAccount(BuildContext context, String workerId) => confirm(
  context,
  title: 'Confirm this bank account?',
  body:
      'The bank proved the account is open but returned no name for it. Check the account name against '
      '${personLabel(context, workerId)}\'s legal name and documents first. Once confirmed, their held payouts go into it with the next window.',
  confirmLabel: 'Confirm account',
);

/// Accounts on a live hold: who, why, until when; an operator lifts one here.
class _HoldsTab extends StatefulWidget {
  const _HoldsTab();

  @override
  State<_HoldsTab> createState() => _HoldsTabState();
}

class _HoldsTabState extends State<_HoldsTab> {
  final _loader = GlobalKey<LoadViewState<({int total, List<HeldAccount> items})>>();
  final _awaiting = GlobalKey<LoadViewState<({int total, List<String> workerIds})>>();

  /// Finance confirms an account the penny drop proved without a name; nothing is paid into it before.
  Future<void> _confirm(String workerId) async {
    final scope = AppScope.of(context);
    final ok = await confirmBankAccount(context, workerId);
    if (!ok || !mounted) return;
    try {
      await withActionKey(scope.keys, 'account:confirm:$workerId', (key) => scope.finance.confirmAccount(workerId, key: key));
      if (!mounted) return;
      toast(context, 'Bank account confirmed');
      await _awaiting.currentState?.reload();
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e));
    }
  }

  Future<void> _lift(HeldAccount a) async {
    final scope = AppScope.of(context);
    final ok = await confirm(
      context,
      title: 'Lift this hold?',
      body: 'The worker\'s held earnings go into the next window that closes.',
      confirmLabel: 'Lift hold',
    );
    if (!ok || !mounted) return;
    try {
      await withActionKey(scope.keys, 'hold:lift:${a.workerId}', (key) => scope.ops.setHold(a.workerId, key: key));
      if (!mounted) return;
      toast(context, 'Hold lifted');
      await _loader.currentState?.reload();
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ops = AppScope.of(context).session.roles.contains('ops');
    final finance = _isFinance(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LoadView<({int total, List<String> workerIds})>(
          key: _awaiting,
          wrapInCard: true,
          load: () => AppScope.of(context).finance.accountsAwaitingConfirmation(),
          builder: (context, a, _) {
            if (a.total == 0) return const SizedBox.shrink();
            final more = a.total - a.workerIds.length;
            return Column(
              key: const Key('awaiting-confirmation'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionTitle(
                  'Bank accounts to confirm',
                  subtitle:
                      'The penny drop proved the account but the bank returned no name. Nothing is paid into it until finance confirms it.',
                ),
                if (a.workerIds.isNotEmpty)
                  PortalTable(
                    minWidth: 520,
                    columns: [const PortalColumn('Worker', flex: 3), if (finance) const PortalColumn('', width: 170)],
                    rows: [
                      for (final id in a.workerIds)
                        PortalRow(key: Key('awaiting-$id'), onTap: () => context.go(Paths.worker(id)), [
                          NameOf(id),
                          if (finance)
                            TextButton(
                              key: Key('confirm-account-$id'),
                              onPressed: () => _confirm(id),
                              child: Text('Confirm account', semanticsLabel: 'Confirm the bank account of ${personLabel(context, id)}'),
                            ),
                        ]),
                    ],
                  ),
                if (more > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.x8),
                    child: Text(
                      '$more more ${more == 1 ? 'waits' : 'wait'} with nothing in an open pay window yet; confirm from the worker\'s page (Payout card).',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: Space.x16),
              ],
            );
          },
        ),
        const SectionTitle('Holds', subtitle: 'First payouts, integrity holds, unverified or changed bank accounts'),
        LoadView<({int total, List<HeldAccount> items})>(
          key: _loader,
          wrapInCard: true,
          load: () => AppScope.of(context).finance.heldAccounts(limit: 200),
          isEmpty: (p) => p.items.isEmpty,
          emptyMessage: 'Nobody is on hold.',
          builder: (context, page, _) => PortalTable(
            minWidth: 640,
            columns: [
              const PortalColumn('Worker', flex: 3),
              const PortalColumn('Reason', flex: 2),
              const PortalColumn('Until', flex: 2),
              const PortalColumn('First paid', flex: 2),
              if (ops) const PortalColumn('', width: 110),
            ],
            rows: [
              for (final a in page.items)
                PortalRow(key: Key('hold-${a.workerId}'), onTap: () => context.go(Paths.worker(a.workerId)), [
                  NameOf(a.workerId, name: a.workerName),
                  Text(a.holdReason.isEmpty ? '—' : payoutReason(a.holdReason)),
                  Text(a.holdUntil == null ? 'Until lifted' : shortDate(a.holdUntil!)),
                  Text(a.firstPaidAt == null ? 'Never paid' : shortDate(a.firstPaidAt!)),
                  if (ops) TextButton(key: Key('hold-lift-${a.workerId}'), onPressed: () => _lift(a), child: const Text('Lift')),
                ]),
            ],
          ),
        ),
      ],
    );
  }
}
