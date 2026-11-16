import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../app_scope.dart';
import '../core/errors.dart';
import '../core/format.dart';
import '../core/money.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/portal_tokens.dart';
import '../core/widgets/bars.dart';
import '../core/widgets/cards.dart';
import '../core/widgets/portal_page.dart';
import '../core/widgets/tables.dart';
import '../widgets/load_view.dart';
import '../core/widgets/loader.dart';

/// The statement: what was paid, what the next window holds, every pay window and every earning.
class EarningsScreen extends StatelessWidget {
  const EarningsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return LoadView<Statement>(
      load: () => AppScope.of(context).payout.statement(),
      builder: (context, s, reload) {
        final empty = s.isEmpty && s.totals.isEmpty;
        return PortalPage(
          kicker: 'Money',
          title: 'Earnings',
          subtitle: 'Accepted units, pay windows, payouts',
          onRefresh: reload,
          children: [
            if (empty)
              const PortalCard(child: EmptyView(message: 'No earnings yet. Your first accepted unit appears here.'))
            else ...[
              _Kpis(s),
              if (s.hold.isNotEmpty)
                StatusBanner(
                  s.hold == 'consent_withdrawn'
                      ? 'Your payouts are held because you withdrew your data consent. Give consent again in Profile → Your data; '
                            'held earnings then go out with the next window.'
                      : 'A hold is in force: ${humanize(s.hold).toLowerCase()}. Held earnings roll into the next window; nothing is lost.',
                  kind: StatusKind.warn,
                  icon: Icons.pause_circle_outline,
                ),
              if (s.weeks.isNotEmpty) _WeeksCard(s),
              _Payouts(s),
              _Earnings(s.earnings, windows: s.windows),
            ],
            const SizedBox(height: Space.x8),
            Text(
              'Only an accepted unit creates an earning. Disputes never change pay; they clear your record.',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        );
      },
    );
  }
}

String _heldGross(Statement s) {
  var sum = 0.0;
  for (final w in s.windows) {
    if (w.lineStatus == 'held') sum += double.tryParse(w.gross) ?? 0;
  }
  return sum.toStringAsFixed(2);
}

String _units(int n) => '$n ${n == 1 ? 'unit' : 'units'}';

class _Kpis extends StatelessWidget {
  const _Kpis(this.s);
  final Statement s;

  @override
  Widget build(BuildContext context) {
    final currency = s.currency;
    final next = s.pendingNext;
    final closes = s.nextWindowClosesAt;
    final until = s.holdUntil;
    return KpiRow(
      children: [
        KpiTile(
          label: 'Paid to date',
          value: formatMoney(s.total('paid'), currency: currency),
          note: s.firstPaidAt == null ? 'No payout yet' : 'First paid ${shortDate(s.firstPaidAt!)}',
          kind: StatusKind.success,
          icon: Icons.account_balance_outlined,
        ),
        KpiTile(
          label: 'In the next payout',
          value: formatMoney(next.amount, currency: next.currency.isEmpty ? currency : next.currency),
          note: closes == null ? _units(next.count) : '${_units(next.count)} · closes ${untilShort(closes)}',
          kind: next.count == 0 ? null : StatusKind.info,
          icon: Icons.account_balance_wallet_outlined,
        ),
        KpiTile(
          label: 'In a closed window',
          value: formatMoney(s.total('windowed'), currency: currency),
          note: 'Being checked and approved',
          icon: Icons.lock_clock_outlined,
        ),
        if (s.hold.isNotEmpty)
          KpiTile(
            label: 'Held',
            value: formatMoney(_heldGross(s), currency: currency),
            // consent has no end date: it lasts until the worker gives consent again
            note: s.hold == 'consent_withdrawn'
                ? 'Until you give consent again'
                : until == null
                ? humanize(s.hold)
                : '${humanize(s.hold)} until ${shortDate(until)}',
            kind: StatusKind.warn,
            icon: Icons.pause_circle_outline,
          ),
      ],
    );
  }
}

class _WeeksCard extends StatelessWidget {
  const _WeeksCard(this.s);
  final Statement s;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Last 12 weeks', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x12),
          WeeklyBars.fromWeeks([for (final w in s.weeks) (w.startsAt, w.value)], currency: s.currency),
          const SizedBox(height: Space.x8),
          Text('Pay week: Saturday 00:00 to Friday 23:59 IST', style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

StatusKind _stageKind(String stage) => switch (stage) {
  'Paid' => StatusKind.success,
  'Held' || 'Moved' => StatusKind.warn,
  'Failed' => StatusKind.dest,
  _ => StatusKind.info,
};

String _period(PayoutWindow w) {
  final starts = w.startsAt;
  final ends = w.endsAt;
  return starts != null && ends != null ? payWindowRange(starts, ends) : 'Pay window';
}

class _Payouts extends StatelessWidget {
  const _Payouts(this.s);
  final Statement s;

  /// Everything on this page as one CSV, built on the device. Saved as a file where the browser can; shown
  /// in a copyable box where it cannot.
  void _downloadAll(BuildContext context) {
    final downloader = AppScope.of(context).downloader;
    final csv = statementCsv(s);
    if (!downloader.supported) {
      showDialog<void>(context: context, builder: (_) => _CsvDialog(csv));
      return;
    }
    downloader.save('yantra-earnings.csv', utf8.encode(csv), 'text/csv');
    toast(context, 'Saved yantra-earnings.csv');
  }

  @override
  Widget build(BuildContext context) {
    final copyCsv = OutlinedButton.icon(
      key: const Key('download-csv'),
      onPressed: () => _downloadAll(context),
      icon: const Icon(Icons.download_outlined, size: Sizes.iconSm),
      label: const Text('Download all (CSV)'),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // the button sits beside the title where it fits, under it on a phone
        LayoutBuilder(
          builder: (context, c) => c.maxWidth < Layout.sm
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionTitle('Payouts', subtitle: 'One line per pay window'),
                    Padding(
                      padding: const EdgeInsets.only(bottom: Space.x12),
                      child: copyCsv,
                    ),
                  ],
                )
              : SectionTitle('Payouts', subtitle: 'One line per pay window', trailing: copyCsv),
        ),
        if (s.windows.isEmpty)
          const PortalCard(child: EmptyView(message: 'No pay window has closed yet. Windows close every Friday 23:59 IST.'))
        else
          for (final w in s.windows) _WindowRow(w),
      ],
    );
  }
}

class _WindowRow extends StatefulWidget {
  const _WindowRow(this.w);
  final PayoutWindow w;

  @override
  State<_WindowRow> createState() => _WindowRowState();
}

class _WindowRowState extends State<_WindowRow> {
  bool _busy = false;

  PayoutWindow get w => widget.w;

  /// The window's statement as the payout service writes it, once the window reconciled.
  Future<void> _statement() async {
    final scope = AppScope.of(context);
    setState(() => _busy = true);
    try {
      final bytes = await scope.payout.statementCsv(w.windowId);
      final name = 'statement-${w.windowId.length > 8 ? w.windowId.substring(0, 8) : w.windowId}.csv';
      if (!mounted) return;
      if (scope.downloader.supported) {
        scope.downloader.save(name, bytes, 'text/csv');
        toast(context, 'Saved $name');
      } else {
        await showDialog<void>(context: context, builder: (_) => _CsvDialog(utf8.decode(bytes)));
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      toast(
        context,
        e.code == 'not_reconciled'
            ? 'The statement is ready once this window is reconciled, usually the day after payout.'
            : describeError(e),
      );
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
    final paid = w.paidAt;
    final showStatement = w.lineStatus == 'paid' || w.windowStatus == 'paid';
    return PortalCard(
      key: Key('window-${w.windowId}'),
      padding: const EdgeInsets.symmetric(horizontal: Space.x16, vertical: Space.x12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Space.x16,
            runSpacing: Space.x8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(_period(w), style: theme.textTheme.titleSmall),
              Text(formatMoney(w.gross, currency: w.currency), style: AppTheme.figure(context, fontSize: 14)),
              Text(_units(w.earningCount), style: theme.textTheme.bodySmall),
              StatusChip(w.stageLabel, kind: _stageKind(w.stageLabel)),
              if (w.holdReason.isNotEmpty) Text(holdLabel(w.holdReason), style: theme.textTheme.bodySmall?.copyWith(color: t.warnText)),
              if (w.utr.isNotEmpty)
                Semantics(
                  label: 'Bank reference ${w.utr}',
                  excludeSemantics: true,
                  child: Tooltip(
                    message: 'Bank reference (UTR): quote it to your bank',
                    child: Text(
                      'UTR ${w.utr}',
                      key: const Key('window-utr'),
                      style: AppTheme.mono(context, fontSize: 12, color: t.textSecondary),
                    ),
                  ),
                ),
              if (paid != null) Text('Paid ${shortDate(paid)}', style: theme.textTheme.bodySmall),
              if (showStatement)
                TextButton.icon(
                  key: Key('statement-${w.windowId}'),
                  onPressed: _busy ? null : _statement,
                  icon: const Icon(Icons.download_outlined, size: Sizes.iconSm),
                  label: const Text('Statement'),
                ),
            ],
          ),
          if (w.failed || w.lineStatus == 'released')
            Padding(
              padding: const EdgeInsets.only(top: Space.x8),
              child: Text(
                w.failureText,
                key: const Key('window-failure'),
                style: theme.textTheme.bodySmall?.copyWith(color: t.destText),
              ),
            ),
        ],
      ),
    );
  }
}

/// Why a payout line is held, in the worker's words.
String holdLabel(String reason) => switch (reason) {
  'first_payout' => 'First payout: held 7 days while your account is confirmed',
  'account_unverified' => 'Held until your bank account is verified',
  'bank_change' => 'Held 72 hours after a bank account change',
  'over_cap' => 'Held: above the weekly payout limit; finance reviews it',
  'integrity' => 'Held while a review is open',
  'consent_withdrawn' => 'Held while your data consent is withdrawn',
  'account_unconfirmed' => 'Held until finance confirms your bank account; the bank returned no name for it',
  _ => humanize(reason),
};

(String, StatusKind) _earningStatus(String status) => switch (status) {
  'paid' => ('Paid', StatusKind.success),
  'windowed' => ('In window', StatusKind.info),
  'payable' => ('Payable', StatusKind.info),
  _ => (humanize(status), StatusKind.info),
};

String _short(String id) => id.length > 8 ? id.substring(0, 8) : id;

class _Earnings extends StatefulWidget {
  const _Earnings(this.earnings, {this.windows = const []});
  final List<Earning> earnings;
  final List<PayoutWindow> windows;

  @override
  State<_Earnings> createState() => _EarningsState();
}

class _EarningsState extends State<_Earnings> {
  static const page = 20;
  int _shown = page;

  /// `payable`, `windowed`, `paid`, or null for all.
  String? _status;

  /// A pay window id, or null for all.
  String? _window;

  @override
  Widget build(BuildContext context) {
    final all = [
      for (final e in widget.earnings)
        if ((_status == null || e.status == _status) && (_window == null || e.windowId == _window)) e,
    ];
    final shown = all.take(_shown).toList();
    final windows = [
      for (final w in widget.windows)
        if (widget.earnings.any((e) => e.windowId == w.windowId)) w,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle('Earnings', subtitle: 'One line per accepted unit, review or audit'),
        if (widget.earnings.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.x12),
            child: Wrap(
              spacing: Space.x12,
              runSpacing: Space.x8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilterChips<String>(
                  values: const {'All': null, 'Payable': 'payable', 'In window': 'windowed', 'Paid': 'paid'},
                  selected: _status,
                  onSelected: (v) => setState(() {
                    _status = v;
                    _shown = page;
                  }),
                ),
                if (windows.isNotEmpty)
                  SizedBox(
                    width: 240,
                    child: DropdownButtonFormField<String?>(
                      key: const Key('earnings-window'),
                      initialValue: _window,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Pay window', isDense: true),
                      items: [
                        const DropdownMenuItem<String?>(value: null, child: Text('All windows')),
                        for (final w in windows) DropdownMenuItem<String?>(value: w.windowId, child: Text(_period(w))),
                      ],
                      onChanged: (v) => setState(() {
                        _window = v;
                        _shown = page;
                      }),
                    ),
                  ),
              ],
            ),
          ),
        if (widget.earnings.isEmpty)
          const PortalCard(child: EmptyView(message: 'No earnings yet.'))
        else if (all.isEmpty)
          const PortalCard(child: EmptyView(message: 'Nothing matches these filters.'))
        else
          PortalCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < shown.length; i++) _EarningRow(shown[i], striped: i.isOdd),
                if (all.length > _shown)
                  Padding(
                    padding: const EdgeInsets.all(Space.x8),
                    child: TextButton(
                      key: const Key('earnings-more'),
                      onPressed: () => setState(() => _shown += page),
                      child: Text('Show more (${all.length - _shown} left)'),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _EarningRow extends StatelessWidget {
  const _EarningRow(this.e, {required this.striped});
  final Earning e;
  final bool striped;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final (label, kind) = _earningStatus(e.status);
    final created = e.createdAt;
    return Container(
      color: striped ? t.zebra : null,
      padding: const EdgeInsets.symmetric(horizontal: Space.x12, vertical: Space.x8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: Space.x8,
                  runSpacing: Space.x4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    StatusChip(humanize(e.kind), kind: StatusKind.info),
                    Semantics(
                      label: 'Unit ${e.unitId}',
                      container: true,
                      excludeSemantics: true,
                      child: Tooltip(
                        message: e.unitId,
                        child: Text(_short(e.unitId), style: AppTheme.mono(context, fontSize: 13)),
                      ),
                    ),
                  ],
                ),
                if (created != null) Text(relative(created), style: theme.textTheme.labelSmall),
              ],
            ),
          ),
          const SizedBox(width: Space.x10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(formatMoney(e.amount, currency: e.currency), style: AppTheme.figure(context, fontSize: 13)),
              const SizedBox(height: Space.x4),
              StatusChip(label, kind: kind),
            ],
          ),
        ],
      ),
    );
  }
}

/// The statement as CSV, built on the device: one `window` line per pay window, one `earning` line per earning.
String statementCsv(Statement s) {
  String cell(Object? v) {
    final text = v == null ? '' : (v is DateTime ? v.toUtc().toIso8601String() : v.toString());
    return text.contains(RegExp(r'[",\n]')) ? '"${text.replaceAll('"', '""')}"' : text;
  }

  String line(List<Object?> cells) => cells.map(cell).join(',');

  final out = StringBuffer()
    ..writeln(line(['type', 'id', 'starts_at', 'ends_at', 'amount', 'currency', 'count', 'status', 'reference', 'at']));
  for (final w in s.windows) {
    out.writeln(
      line([
        'window',
        w.windowId,
        w.startsAt,
        w.endsAt,
        w.gross,
        w.currency,
        w.earningCount,
        w.stageLabel,
        w.utr.isNotEmpty ? w.utr : w.railReference,
        w.paidAt,
      ]),
    );
  }
  for (final e in s.earnings) {
    out.writeln(line(['earning', e.id, null, null, e.amount, e.currency, 1, e.status, e.unitId, e.createdAt]));
  }
  return out.toString();
}

class _CsvDialog extends StatelessWidget {
  const _CsvDialog(this.csv);
  final String csv;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return AlertDialog(
      title: const Text('Statement (CSV)'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 360),
        child: SingleChildScrollView(
          child: SelectableText(
            csv,
            key: const Key('csv-text'),
            style: AppTheme.mono(context, fontSize: 12, color: t.textSecondary),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
        FilledButton(
          key: const Key('csv-copy'),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: csv));
            if (context.mounted) toast(context, 'Copied');
          },
          child: const Text('Copy'),
        ),
      ],
    );
  }
}
