import '../core/format.dart';
import '../core/json.dart';

/// Wire shapes of the operator's finance pages (docs/PRODUCT.md 5.5 and the payout router). Money stays a
/// decimal string; a missing field reads as empty, never as a throw.

/// `{currency: amount}`; a bare amount reads as one entry with an empty currency.
Map<String, String> readMoneyMap(Json m, String key) {
  final v = m[key];
  if (v is Map) return {for (final e in v.entries) e.key.toString(): e.value?.toString() ?? '0.00'};
  if (v is String && v.isNotEmpty) return {'': v};
  if (v is num) return {'': v.toString()};
  return const {};
}

/// An amount that may be missing: `0` rather than an empty string, so it formats as money.
String _amount(Json m, String key) {
  final v = readString(m, key);
  return v.isEmpty ? '0' : v;
}

double _double(Json m, String key) {
  final v = m[key];
  return v is num ? v.toDouble() : (v is String ? double.tryParse(v) ?? 0 : 0);
}

int? _intOrNull(Json m, String key) {
  final v = m[key];
  return v is int ? v : (v is num ? v.toInt() : (v is String ? int.tryParse(v) : null));
}

class OpenWindow {
  const OpenWindow({this.startsAt, this.endsAt, required this.closesInSeconds});

  final DateTime? startsAt;
  final DateTime? endsAt;
  final int closesInSeconds;

  factory OpenWindow.fromJson(Json m) => OpenWindow(
    startsAt: readDateTime(m, 'starts_at'),
    endsAt: readDateTime(m, 'ends_at'),
    closesInSeconds: readInt(m, 'closes_in_seconds'),
  );
}

/// `GET /v1/payout/overview`.
class PayoutOverview {
  const PayoutOverview({
    required this.payableNow,
    required this.paidTotal,
    required this.heldTotal,
    required this.marginTotal,
    required this.windowCounts,
    required this.pendingAdjustments,
    this.openWindow,
  });

  final Map<String, String> payableNow;
  final Map<String, String> paidTotal;
  final Map<String, String> heldTotal;
  final Map<String, String> marginTotal;

  /// status → count: `closed`, `approved`, `paid`.
  final Map<String, int> windowCounts;
  final int pendingAdjustments;
  final OpenWindow? openWindow;

  int windows(String status) => windowCounts[status] ?? 0;

  factory PayoutOverview.fromJson(Json m) => PayoutOverview(
    payableNow: readMoneyMap(m, 'payable_now'),
    paidTotal: readMoneyMap(m, 'paid_total'),
    heldTotal: readMoneyMap(m, 'held_total'),
    marginTotal: readMoneyMap(m, 'margin_total'),
    windowCounts: {for (final e in readMap(m, 'windows').entries) e.key: readInt(readMap(m, 'windows'), e.key)},
    pendingAdjustments: readInt(m, 'pending_adjustments'),
    openWindow: m['open_window'] is Map ? OpenWindow.fromJson(readMap(m, 'open_window')) : null,
  );
}

/// A pay window as finance sees it (`WindowOut`). `lines` and `approvals` are shown when the gateway sends them.
class PayWindowRow {
  const PayWindowRow({
    required this.id,
    this.startsAt,
    this.endsAt,
    required this.currency,
    required this.status,
    required this.grossTotal,
    required this.heldTotal,
    required this.railReference,
    this.paidAt,
    this.lineCount,
    this.approvals,
    this.rail = '',
    this.paidTotal = '0',
    this.reconciledAt,
    this.capOverrideBy = '',
    this.capOverrideReason = '',
    this.capOverrideAt,
  });

  final String id;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final String currency;

  /// `closed`, `approved`, `paying` (lines on the rail), `paid`.
  final String status;
  final String grossTotal;
  final String heldTotal;
  final String railReference;
  final DateTime? paidAt;
  final int? lineCount;
  final int? approvals;

  /// The rail the window was paid on (`razorpayx`, `file`, `fake`); empty before Pay.
  final String rail;
  final String paidTotal;

  /// Set by the first balanced reconciliation of a paid window; statements are released from then on.
  final DateTime? reconciledAt;

  /// Who paid the window above the per-window cap, why and when ('' and null when it was not).
  final String capOverrideBy;
  final String capOverrideReason;
  final DateTime? capOverrideAt;

  bool get isClosed => status == 'closed';
  bool get isApproved => status == 'approved';
  bool get isPaying => status == 'paying';
  bool get isPaid => status == 'paid';
  bool get onFileRail => rail == 'file';

  factory PayWindowRow.fromJson(Json m) => PayWindowRow(
    id: readString(m, 'id'),
    startsAt: readDateTime(m, 'starts_at'),
    endsAt: readDateTime(m, 'ends_at'),
    currency: readString(m, 'currency'),
    status: readString(m, 'status'),
    grossTotal: readString(m, 'gross_total'),
    heldTotal: readString(m, 'held_total'),
    railReference: readString(m, 'rail_reference'),
    paidAt: readDateTime(m, 'paid_at'),
    lineCount: _intOrNull(m, 'line_count') ?? _intOrNull(m, 'lines'),
    approvals: _intOrNull(m, 'approvals') ?? _intOrNull(m, 'approval_count'),
    rail: readString(m, 'rail'),
    paidTotal: _amount(m, 'paid_total'),
    reconciledAt: readDateTime(m, 'reconciled_at'),
    capOverrideBy: readString(m, 'cap_override_by'),
    capOverrideReason: readString(m, 'cap_override_reason'),
    capOverrideAt: readDateTime(m, 'cap_override_at'),
  );
}

/// One worker's line in a window (`LineOut`).
class WindowLineRow {
  const WindowLineRow({
    required this.id,
    required this.windowId,
    required this.workerId,
    required this.gross,
    required this.earningCount,
    required this.status,
    required this.holdReason,
    this.attempts = 0,
    this.railReference = '',
    this.utr = '',
    this.failureReason = '',
    this.submittedAt,
    this.settledAt,
    this.railStatus = '',
  });

  final String id;
  final String windowId;
  final String workerId;
  final String gross;
  final int earningCount;

  /// `payable`, `held`, then on the rail `queued`, `processing`, `paid`, `failed`, `returned`, or `released`
  /// (finance gave up on it; its earnings roll into the next window).
  final String status;
  final String holdReason;
  final int attempts;
  final String railReference;

  /// The bank's reference for a paid line.
  final String utr;
  final String failureReason;
  final DateTime? submittedAt;
  final DateTime? settledAt;

  /// What the rail says of the line; for a queued line that is not going out, why: `held`, `rail_mismatch`,
  /// `account_missing`, `account_changed`.
  final String railStatus;

  /// A line the rail could not deliver: finance retries or releases it.
  bool get isFailed => status == 'failed' || status == 'returned';

  /// Queued but not going out (see [railStatus]).
  bool get isBlocked => status == 'queued' && blockedRailStatuses.contains(railStatus);

  factory WindowLineRow.fromJson(Json m) => WindowLineRow(
    id: readString(m, 'id'),
    windowId: readString(m, 'window_id'),
    workerId: readString(m, 'worker_id'),
    gross: readString(m, 'gross'),
    earningCount: readInt(m, 'earning_count'),
    status: readString(m, 'status'),
    holdReason: readString(m, 'hold_reason'),
    attempts: readInt(m, 'attempts'),
    railReference: readString(m, 'rail_reference'),
    utr: readString(m, 'utr'),
    failureReason: readString(m, 'failure_reason'),
    submittedAt: readDateTime(m, 'submitted_at'),
    settledAt: readDateTime(m, 'settled_at'),
    railStatus: readString(m, 'rail_status'),
  );
}

/// The `rail_status` values of a queued line that is not going out.
const blockedRailStatuses = {'held', 'rail_mismatch', 'account_missing', 'account_changed'};

/// A payout hold reason or a blocked line's `rail_status`, in an operator's words.
String payoutReason(String code) => switch (code) {
  'held' => 'Worker on hold',
  'rail_mismatch' => 'Queued on another rail',
  'account_missing' => 'Bank account gone',
  'account_changed' => 'Bank account changed since dispatch',
  'account_unconfirmed' => 'Bank account waits for finance to confirm',
  'account_unverified' => 'No verified bank account',
  'consent_withdrawn' => 'Data consent withdrawn',
  'over_cap' => 'One earning above the per-worker cap',
  'first_payout' => 'First payout, 7-day hold',
  'bank_change' => 'Bank account changed, 72-hour hold',
  'integrity' => 'Integrity review open',
  _ => humanize(code),
};

/// `X-Skipped-Lines` of a bank file: `<line_id>:<reason>`, comma-separated. Malformed parts are dropped.
List<(String, String)> readSkippedLines(String? header) => [
  for (final part in (header ?? '').split(','))
    if (part.trim().split(':') case [final id, final reason] when id.isNotEmpty && reason.isNotEmpty) (id, reason),
];

/// `3 lines were left out: 2 worker on hold, 1 bank account gone.`
String skippedSummary(List<(String, String)> skipped) {
  final counts = <String, int>{};
  for (final (_, reason) in skipped) {
    counts[reason] = (counts[reason] ?? 0) + 1;
  }
  final n = skipped.length;
  final reasons = counts.entries.map((e) => '${e.value} ${payoutReason(e.key).toLowerCase()}').join(', ');
  return '$n ${n == 1 ? 'line was' : 'lines were'} left out: $reasons.';
}

/// `GET /v1/payout/windows/{id}/reconcile`: earnings against lines, to the paisa.
class ReconcileReport {
  const ReconcileReport({
    required this.windowId,
    required this.status,
    required this.earningsTotal,
    required this.linesTotal,
    required this.delta,
    required this.unpaidEarnings,
    required this.balanced,
    this.paidTotal = '0',
    this.railTotal = '0',
    this.deltaRail = '0',
    this.failedLines = 0,
    this.processingLines = 0,
    this.reconciledAt,
  });

  final String windowId;
  final String status;
  final String earningsTotal;
  final String linesTotal;
  final String delta;
  final int unpaidEarnings;
  final bool balanced;

  /// What the lines marked paid add up to, and what the rail says it moved for them.
  final String paidTotal;
  final String railTotal;
  final String deltaRail;
  final int failedLines;
  final int processingLines;
  final DateTime? reconciledAt;

  factory ReconcileReport.fromJson(Json m) => ReconcileReport(
    windowId: readString(m, 'window_id'),
    status: readString(m, 'status'),
    earningsTotal: readString(m, 'earnings_total'),
    linesTotal: readString(m, 'lines_total'),
    delta: readString(m, 'delta'),
    unpaidEarnings: readInt(m, 'unpaid_earnings'),
    balanced: readBool(m, 'balanced'),
    paidTotal: _amount(m, 'paid_total'),
    railTotal: _amount(m, 'rail_total'),
    deltaRail: _amount(m, 'delta_rail'),
    failedLines: readInt(m, 'failed_lines'),
    processingLines: readInt(m, 'processing_lines'),
    reconciledAt: readDateTime(m, 'reconciled_at'),
  );
}

/// One recorded reconciliation (`GET /v1/payout/reconciliation-runs`).
class ReconcileRun {
  const ReconcileRun({
    required this.id,
    required this.windowId,
    this.ranAt,
    required this.earningsTotal,
    required this.linesTotal,
    required this.paidTotal,
    required this.railTotal,
    required this.deltaLines,
    required this.deltaRail,
    required this.failedLines,
    required this.processingLines,
    required this.balanced,
  });

  final String id;
  final String windowId;
  final DateTime? ranAt;
  final String earningsTotal;
  final String linesTotal;
  final String paidTotal;
  final String railTotal;
  final String deltaLines;
  final String deltaRail;
  final int failedLines;
  final int processingLines;
  final bool balanced;

  factory ReconcileRun.fromJson(Json m) => ReconcileRun(
    id: readString(m, 'id'),
    windowId: readString(m, 'window_id'),
    ranAt: readDateTime(m, 'ran_at'),
    earningsTotal: _amount(m, 'earnings_total'),
    linesTotal: _amount(m, 'lines_total'),
    paidTotal: _amount(m, 'paid_total'),
    railTotal: _amount(m, 'rail_total'),
    deltaLines: _amount(m, 'delta_lines'),
    deltaRail: _amount(m, 'delta_rail'),
    failedLines: readInt(m, 'failed_lines'),
    processingLines: readInt(m, 'processing_lines'),
    balanced: readBool(m, 'balanced'),
  );
}

/// What a bank's return file did (`POST …/bank-file/reconcile`): rows applied and rows skipped with why.
class ReturnFileResult {
  const ReturnFileResult({required this.applied, required this.skipped});

  final int applied;

  /// `{row, reference, reason}` with reason `bad_status`, `unknown_reference` or `already_settled`.
  final List<Json> skipped;

  factory ReturnFileResult.fromJson(Json m) {
    final applied = m['applied'];
    return ReturnFileResult(
      applied: applied is List ? applied.length : (applied is num ? applied.toInt() : 0),
      skipped: readList(m, 'skipped').whereType<Map>().map((e) => Json.from(e)).toList(),
    );
  }
}

/// The payout rail as finance sees it (`GET /v1/payout/rail`).
class RailState {
  const RailState({
    required this.rail,
    required this.supportsPennyDrop,
    required this.lines,
    required this.accountsVerifying,
    this.lastDispatchAt,
    this.lastPollAt,
  });

  final String rail;
  final bool supportsPennyDrop;

  /// `queued`, `processing`, `failed`, `returned` → count across every window.
  final Map<String, int> lines;
  final int accountsVerifying;
  final DateTime? lastDispatchAt;
  final DateTime? lastPollAt;

  int count(String status) => lines[status] ?? 0;

  factory RailState.fromJson(Json m) {
    final lines = readMap(m, 'lines');
    return RailState(
      rail: readString(m, 'rail'),
      supportsPennyDrop: readBool(m, 'supports_penny_drop'),
      lines: {for (final k in lines.keys) k: readInt(lines, k)},
      accountsVerifying: readInt(m, 'accounts_verifying'),
      lastDispatchAt: readDateTime(m, 'last_dispatch_at'),
      lastPollAt: readDateTime(m, 'last_poll_at'),
    );
  }
}

/// An account on a live hold (`GET /v1/payout/accounts?held=true`).
class HeldAccount {
  const HeldAccount({required this.workerId, required this.holdReason, this.holdUntil, this.firstPaidAt, this.workerName = ''});

  final String workerId;
  final String holdReason;
  final DateTime? holdUntil;
  final DateTime? firstPaidAt;
  final String workerName;

  factory HeldAccount.fromJson(Json m) => HeldAccount(
    workerId: readString(m, 'worker_id'),
    holdReason: readString(m, 'hold_reason'),
    holdUntil: readDateTime(m, 'hold_until'),
    firstPaidAt: readDateTime(m, 'first_paid_at'),
    workerName: readString(m, 'worker_name'),
  );
}

/// What money needs from an operator now (`GET /v1/payout/attention`).
class PayoutAttention {
  const PayoutAttention({
    required this.windowsAwaitingSecondApproval,
    required this.reconciliationDeltas,
    required this.failedLines,
    required this.pendingAdjustments,
    required this.deadLetters,
    this.linesBlocked = 0,
    this.erasuresPending = 0,
    this.accountsAwaitingConfirmation = 0,
  });

  final int windowsAwaitingSecondApproval;
  final int reconciliationDeltas;
  final int failedLines;
  final int pendingAdjustments;
  final int deadLetters;

  /// Queued lines that cannot go out (a held worker, another rail, an account gone or changed).
  final int linesBlocked;

  /// Bank accounts waiting to be erased until the money owed is paid.
  final int erasuresPending;

  /// Penny-dropped accounts without a registered name, waiting for finance to confirm them.
  final int accountsAwaitingConfirmation;

  factory PayoutAttention.fromJson(Json m) {
    final dead = readMap(m, 'dead_letters');
    return PayoutAttention(
      windowsAwaitingSecondApproval: readInt(m, 'windows_awaiting_second_approval'),
      reconciliationDeltas: readInt(m, 'reconciliation_deltas'),
      failedLines: readInt(m, 'failed_lines'),
      pendingAdjustments: readInt(m, 'pending_adjustments'),
      deadLetters: dead.keys.fold(0, (a, k) => a + readInt(dead, k)),
      linesBlocked: readInt(m, 'lines_blocked'),
      erasuresPending: readInt(m, 'erasures_pending'),
      accountsAwaitingConfirmation: readInt(m, 'accounts_awaiting_confirmation'),
    );
  }
}

/// A bonus or correction one person proposes and another approves.
class Adjustment {
  const Adjustment({
    required this.id,
    required this.workerId,
    required this.amount,
    required this.currency,
    required this.kind,
    required this.reason,
    required this.status,
    required this.proposedBy,
    required this.decidedBy,
    this.createdAt,
    this.decidedAt,
  });

  final String id;
  final String workerId;
  final String amount;
  final String currency;

  /// `bonus` or `correction`.
  final String kind;
  final String reason;

  /// `pending`, `approved`, `rejected`.
  final String status;
  final String proposedBy;
  final String decidedBy;
  final DateTime? createdAt;
  final DateTime? decidedAt;

  bool get isPending => status == 'pending';

  factory Adjustment.fromJson(Json m) => Adjustment(
    id: readString(m, 'id'),
    workerId: readString(m, 'worker_id'),
    amount: readString(m, 'amount'),
    currency: readString(m, 'currency'),
    kind: readString(m, 'kind'),
    reason: readString(m, 'reason'),
    status: readString(m, 'status'),
    proposedBy: readString(m, 'proposed_by'),
    decidedBy: readString(m, 'decided_by'),
    createdAt: readDateTime(m, 'created_at'),
    decidedAt: readDateTime(m, 'decided_at'),
  );
}

/// What finance sends to propose an adjustment.
class AdjustmentInput {
  const AdjustmentInput({required this.workerId, required this.amount, required this.currency, required this.kind, required this.reason});

  final String workerId;
  final String amount;
  final String currency;
  final String kind;
  final String reason;

  Json toJson() => {'worker_id': workerId, 'amount': amount, 'currency': currency, 'kind': kind, 'reason': reason};
}

/// One batch in the margin report: what the accepted units invoice against every cost line.
class MarginRow {
  const MarginRow({
    required this.batchId,
    required this.currency,
    required this.unitsJudged,
    required this.unitsAccepted,
    required this.invoice,
    required this.costPay,
    required this.costReview,
    required this.costAudit,
    required this.billableReworkUnits,
    required this.margin,
    required this.marginFraction,
  });

  final String batchId;
  final String currency;
  final int unitsJudged;
  final int unitsAccepted;
  final String invoice;
  final String costPay;
  final String costReview;
  final String costAudit;
  final int billableReworkUnits;
  final String margin;
  final double marginFraction;

  int get marginPercent => (marginFraction * 100).round();

  factory MarginRow.fromJson(Json m) => MarginRow(
    batchId: readString(m, 'batch_id'),
    currency: readString(m, 'currency'),
    unitsJudged: readInt(m, 'units_judged'),
    unitsAccepted: readInt(m, 'units_accepted'),
    invoice: readString(m, 'invoice'),
    costPay: readString(m, 'cost_pay'),
    costReview: readString(m, 'cost_review'),
    costAudit: readString(m, 'cost_audit'),
    billableReworkUnits: readInt(m, 'billable_rework_units'),
    margin: readString(m, 'margin'),
    marginFraction: _double(m, 'margin_fraction'),
  );
}
