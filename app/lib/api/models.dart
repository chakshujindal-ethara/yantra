import '../core/format.dart';
import '../core/json.dart';

/// Wire shapes, read with type tests. Money stays a decimal string. A missing field reads as empty, never
/// as a throw, so an older gateway still renders.

/// A pool of units a worker can claim. Never carries the client's price.
class Batch {
  const Batch({
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.title,
    required this.mode,
    required this.unitPay,
    required this.reviewPay,
    required this.currency,
    required this.claimTtlMinutes,
    required this.rubricVersion,
    required this.status,
    required this.availableUnits,
    required this.answerSchema,
  });

  final String id;
  final String projectId;
  final String projectName;
  final String title;
  final String mode;
  final String unitPay;
  final String reviewPay;
  final String currency;
  final int claimTtlMinutes;
  final String rubricVersion;
  final String status;
  final int availableUnits;

  /// JSON Schema for the answer, when the project declares one; the Work screen builds its form from it.
  final Json answerSchema;

  bool get hasAnswerSchema => answerSchema.isNotEmpty;

  factory Batch.fromJson(Json m) => Batch(
    id: readString(m, 'id'),
    projectId: readString(m, 'project_id'),
    projectName: readString(m, 'project_name'),
    title: readString(m, 'title'),
    mode: readString(m, 'mode'),
    unitPay: readString(m, 'unit_pay'),
    reviewPay: readString(m, 'review_pay'),
    currency: readString(m, 'currency'),
    claimTtlMinutes: readInt(m, 'claim_ttl_minutes'),
    rubricVersion: readString(m, 'rubric_version'),
    status: readString(m, 'status'),
    availableUnits: readInt(m, 'available_units'),
    answerSchema: readMap(m, 'answer_schema'),
  );
}

class Claim {
  const Claim({required this.id, required this.unitId, required this.workerId, required this.status, this.expiresAt});

  final String id;
  final String unitId;
  final String workerId;
  final String status;
  final DateTime? expiresAt;

  factory Claim.fromJson(Json m) => Claim(
    id: readString(m, 'id'),
    unitId: readString(m, 'unit_id'),
    workerId: readString(m, 'worker_id'),
    status: readString(m, 'status'),
    expiresAt: readDateTime(m, 'expires_at'),
  );
}

class Unit {
  const Unit({
    required this.id,
    required this.batchId,
    required this.externalRef,
    required this.payload,
    required this.unitPay,
    required this.currency,
    required this.rubricVersion,
    required this.status,
    required this.currentClaimId,
  });

  final String id;
  final String batchId;
  final String externalRef;
  final Json payload;
  final String unitPay;

  /// Empty from the gateway (`UnitOut` has no currency); the Work screen takes the batch's currency.
  final String currency;
  final String rubricVersion;
  final String status;
  final String currentClaimId;

  String get ref => externalRef.isEmpty ? id : externalRef;

  factory Unit.fromJson(Json m) => Unit(
    id: readString(m, 'id'),
    batchId: readString(m, 'batch_id'),
    externalRef: readString(m, 'external_ref'),
    payload: readMap(m, 'payload'),
    unitPay: readString(m, 'unit_pay'),
    currency: readString(m, 'currency'),
    rubricVersion: readString(m, 'rubric_version'),
    status: readString(m, 'status'),
    currentClaimId: readString(m, 'current_claim_id'),
  );
}

/// The worker's live claim, its unit and the batch it came from; all absent when there is none.
class ActiveWork {
  const ActiveWork({this.claim, this.unit, this.batch});

  final Claim? claim;
  final Unit? unit;
  final Batch? batch;

  bool get isLive => claim != null && unit != null;

  factory ActiveWork.fromJson(Json m) => ActiveWork(
    claim: m['claim'] is Map ? Claim.fromJson(readMap(m, 'claim')) : null,
    unit: m['unit'] is Map ? Unit.fromJson(readMap(m, 'unit')) : null,
    batch: m['batch'] is Map ? Batch.fromJson(readMap(m, 'batch')) : null,
  );
}

class Submission {
  const Submission({required this.id, required this.claimId, required this.unitId, required this.rubricVersion, this.submittedAt});

  final String id;
  final String claimId;
  final String unitId;
  final String rubricVersion;
  final DateTime? submittedAt;

  factory Submission.fromJson(Json m) => Submission(
    id: readString(m, 'id'),
    claimId: readString(m, 'claim_id'),
    unitId: readString(m, 'unit_id'),
    rubricVersion: readString(m, 'rubric_version'),
    submittedAt: readDateTime(m, 'submitted_at'),
  );
}

/// The worker as the market knows them: eligibility, certifications and their own availability.
class WorkerMe {
  const WorkerMe({required this.id, required this.status, required this.certGates, this.availability, this.updatedAt});

  final String id;

  /// `eligible`, `active`, `suspended`, `offboarded`, or `unknown` before Odoo has marked them eligible.
  final String status;
  final List<String> certGates;
  final Availability? availability;
  final DateTime? updatedAt;

  bool get isEligible => status == 'eligible' || status == 'active';
  bool get isOnboarded => status != 'unknown' && status.isNotEmpty;

  factory WorkerMe.fromJson(Json m) => WorkerMe(
    id: readString(m, 'id'),
    status: readString(m, 'status').isEmpty ? 'unknown' : readString(m, 'status'),
    certGates: readList(m, 'cert_gates').whereType<String>().toList(),
    availability: m['availability'] is Map ? Availability.fromJson(readMap(m, 'availability')) : null,
    updatedAt: readDateTime(m, 'updated_at'),
  );
}

class Availability {
  const Availability({required this.weeklyHours, this.pausedUntil, this.updatedAt});

  final int weeklyHours;
  final DateTime? pausedUntil;
  final DateTime? updatedAt;

  bool isPaused({DateTime? now}) => pausedUntil != null && pausedUntil!.isAfter(now ?? DateTime.now());

  factory Availability.fromJson(Json m) => Availability(
    weeklyHours: readInt(m, 'weekly_hours'),
    pausedUntil: readDateTime(m, 'paused_until'),
    updatedAt: readDateTime(m, 'updated_at'),
  );

  Json toJson() => {'weekly_hours': weeklyHours, 'paused_until': pausedUntil?.toUtc().toIso8601String()};
}

class ReviewTask {
  const ReviewTask({
    required this.id,
    required this.unitId,
    required this.batchId,
    required this.submissionId,
    required this.rubricVersion,
    required this.status,
    this.claimExpiresAt,
    required this.canonicalVerdict,
  });

  final String id;
  final String unitId;
  final String batchId;
  final String submissionId;
  final String rubricVersion;
  final String status;
  final DateTime? claimExpiresAt;
  final String canonicalVerdict;

  factory ReviewTask.fromJson(Json m) => ReviewTask(
    id: readString(m, 'id'),
    unitId: readString(m, 'unit_id'),
    batchId: readString(m, 'batch_id'),
    submissionId: readString(m, 'submission_id'),
    rubricVersion: readString(m, 'rubric_version'),
    status: readString(m, 'status'),
    claimExpiresAt: readDateTime(m, 'claim_expires_at'),
    canonicalVerdict: readString(m, 'canonical_verdict'),
  );
}

/// What the reviewer reads: the unit's payload and the author's answer (quality's own copy).
class ReviewTaskDetail extends ReviewTask {
  const ReviewTaskDetail({
    required super.id,
    required super.unitId,
    required super.batchId,
    required super.submissionId,
    required super.rubricVersion,
    required super.status,
    super.claimExpiresAt,
    required super.canonicalVerdict,
    required this.payload,
    required this.answer,
    required this.sampledForAudit,
  });

  final Json payload;
  final Json answer;
  final bool sampledForAudit;

  factory ReviewTaskDetail.fromJson(Json m) {
    final base = ReviewTask.fromJson(m);
    return ReviewTaskDetail(
      id: base.id,
      unitId: base.unitId,
      batchId: base.batchId,
      submissionId: base.submissionId,
      rubricVersion: base.rubricVersion,
      status: base.status,
      claimExpiresAt: base.claimExpiresAt,
      canonicalVerdict: base.canonicalVerdict,
      payload: readMap(m, 'payload'),
      answer: readMap(m, 'answer'),
      sampledForAudit: readBool(m, 'sampled_for_audit'),
    );
  }
}

enum Verdict { accept, needsEdits, reject }

extension VerdictWire on Verdict {
  String get wire => switch (this) {
    Verdict.accept => 'accept',
    Verdict.needsEdits => 'needs_edits',
    Verdict.reject => 'reject',
  };

  String get label => switch (this) {
    Verdict.accept => 'Accept',
    Verdict.needsEdits => 'Needs edits',
    Verdict.reject => 'Reject',
  };
}

/// A reason code as the quality service defines it, with who it blames. Client-caused codes are billable
/// rework: the worker is not at fault and the unit is redone at the client's cost.
class ReasonCode {
  const ReasonCode(this.code, this.label, this.detail, {required this.clientCaused, this.appliesTo = const {'needs_edits', 'reject'}});

  final String code;
  final String label;
  final String detail;

  /// Billable rework: the client caused it, the worker is not at fault.
  final bool clientCaused;

  /// The verdicts (wire names) this reason may be given with.
  final Set<String> appliesTo;

  factory ReasonCode.fromJson(Json m) {
    final applies = readList(m, 'applies_to').map((e) => '$e').toSet();
    return ReasonCode(
      readString(m, 'code'),
      readString(m, 'label').isEmpty ? humanize(readString(m, 'code')) : readString(m, 'label'),
      readString(m, 'detail'),
      clientCaused: readBool(m, 'billable'),
      appliesTo: applies.isEmpty ? const {'needs_edits', 'reject'} : applies,
    );
  }

  /// The codes the app knows without asking: the catalogue as shipped, used until (or when) the quality
  /// service's list cannot be read.
  static const builtIn = [
    ReasonCode('guideline_miss', 'Guideline miss', 'The answer ignores a rule in the guidelines.', clientCaused: false),
    ReasonCode('incomplete', 'Incomplete', 'A required part of the answer is missing.', clientCaused: false),
    ReasonCode('wrong_language', 'Wrong language', 'The answer is not in the language the unit asks for.', clientCaused: false),
    ReasonCode('low_quality', 'Low quality', 'Complete, but below the bar the rubric sets.', clientCaused: false),
    ReasonCode(
      'client_glossary_change',
      'Client changed the glossary',
      'Correct when written; the client moved the target.',
      clientCaused: true,
    ),
    ReasonCode('client_ambiguous_instruction', 'Client instruction was ambiguous', 'The brief allowed this reading.', clientCaused: true),
  ];

  /// The catalogue in use: [builtIn] until the shell reads the quality service's list ([adopt]).
  static List<ReasonCode> all = builtIn;

  /// Takes the served catalogue; an empty answer keeps the one in use.
  static void adopt(List<ReasonCode> served) {
    if (served.isNotEmpty) all = List.unmodifiable(served);
  }

  static ReasonCode? byCode(String code) {
    for (final r in all) {
      if (r.code == code) return r;
    }
    for (final r in builtIn) {
      if (r.code == code) return r;
    }
    return null;
  }
}

/// A review claim's answer: the task, or none, with how many tasks wait for a certification or a
/// sensitive-content clearance this reviewer does not hold.
class ReviewClaim {
  const ReviewClaim({this.task, this.waitingForGate = 0, this.waitingForClearance = 0});
  final ReviewTask? task;
  final int waitingForGate;
  final int waitingForClearance;
}

class ReviewInput {
  const ReviewInput({required this.verdict, this.reasonCode, this.rubricUnclear = false, this.note});

  final Verdict verdict;
  final String? reasonCode;
  final bool rubricUnclear;
  final String? note;

  Json toJson() => {
    'verdict': verdict.wire,
    'reason_code': reasonCode,
    'rubric_unclear': rubricUnclear,
    'note': note,
    'feedback': <String, dynamic>{},
  };
}

/// A dispute the author raised on a verdict: open until a person decides; the decision is final.
class Dispute {
  const Dispute({required this.id, required this.status, required this.reason, required this.answer, this.createdAt, this.resolvedAt});

  final String id;

  /// `open`, `upheld` or `dismissed`.
  final String status;
  final String reason;
  final String answer;
  final DateTime? createdAt;
  final DateTime? resolvedAt;

  bool get isOpen => status == 'open';

  factory Dispute.fromJson(Json m) => Dispute(
    id: readString(m, 'id'),
    status: readString(m, 'status'),
    reason: readString(m, 'reason'),
    answer: readString(m, 'answer'),
    createdAt: readDateTime(m, 'created_at'),
    resolvedAt: readDateTime(m, 'resolved_at'),
  );
}

/// One of the worker's submissions as review sees it: in review, or decided with a verdict and reason.
class MyWorkItem {
  const MyWorkItem({
    required this.taskId,
    required this.unitId,
    required this.batchId,
    required this.submissionId,
    required this.rubricVersion,
    required this.stage,
    required this.canonicalVerdict,
    required this.reasonCode,
    required this.billable,
    required this.reviewerNote,
    required this.feedback,
    this.createdAt,
    this.decidedAt,
    this.dispute,
  });

  final String taskId;
  final String unitId;
  final String batchId;
  final String submissionId;
  final String rubricVersion;

  /// `in_review` or `decided`.
  final String stage;
  final String canonicalVerdict;
  final String reasonCode;
  final bool billable;
  final String reviewerNote;
  final Json feedback;
  final DateTime? createdAt;
  final DateTime? decidedAt;
  final Dispute? dispute;

  bool get isDecided => stage == 'decided';
  bool get isAccepted => canonicalVerdict == 'accept';

  /// `needs_edits` or `reject` without a dispute yet, inside the dispute window.
  bool canDispute({DateTime? now, Duration window = const Duration(days: 14)}) {
    if (!isDecided || isAccepted || dispute != null) return false;
    final at = decidedAt;
    return at == null || (now ?? DateTime.now()).difference(at) <= window;
  }

  /// The status word the worker sees for this unit.
  String get statusLabel => switch ((stage, canonicalVerdict)) {
    ('decided', 'accept') => 'Accepted',
    ('decided', 'needs_edits') => 'Needs edits',
    ('decided', 'reject') => 'Rejected',
    _ => 'In review',
  };

  factory MyWorkItem.fromJson(Json m) => MyWorkItem(
    taskId: readString(m, 'task_id'),
    unitId: readString(m, 'unit_id'),
    batchId: readString(m, 'batch_id'),
    submissionId: readString(m, 'submission_id'),
    rubricVersion: readString(m, 'rubric_version'),
    stage: readString(m, 'stage'),
    canonicalVerdict: readString(m, 'canonical_verdict'),
    reasonCode: readString(m, 'reason_code'),
    billable: readBool(m, 'billable'),
    reviewerNote: readString(m, 'reviewer_note'),
    feedback: readMap(m, 'feedback'),
    createdAt: readDateTime(m, 'created_at'),
    decidedAt: readDateTime(m, 'decided_at'),
    dispute: m['dispute'] is Map ? Dispute.fromJson(readMap(m, 'dispute')) : null,
  );
}

/// One earning: created by an accepted verdict and nothing else.
class Earning {
  const Earning({
    required this.id,
    required this.kind,
    required this.unitId,
    required this.amount,
    required this.currency,
    required this.status,
    required this.windowId,
    this.createdAt,
  });

  final String id;

  /// `unit`, `review` or `audit`.
  final String kind;
  final String unitId;
  final String amount;
  final String currency;

  /// `payable` (waiting for the next window), `windowed` (in a closed window), `paid`.
  final String status;
  final String windowId;
  final DateTime? createdAt;

  factory Earning.fromJson(Json m) => Earning(
    id: readString(m, 'id'),
    kind: readString(m, 'kind'),
    unitId: readString(m, 'unit_id'),
    amount: readString(m, 'amount'),
    currency: readString(m, 'currency'),
    status: readString(m, 'status'),
    windowId: readString(m, 'window_id'),
    createdAt: readDateTime(m, 'created_at'),
  );
}

/// The worker's line in one pay window: what the week paid, and whether it was held or paid out.
class PayoutWindow {
  const PayoutWindow({
    required this.windowId,
    this.startsAt,
    this.endsAt,
    required this.currency,
    required this.windowStatus,
    required this.lineStatus,
    required this.gross,
    required this.earningCount,
    required this.holdReason,
    this.paidAt,
    required this.railReference,
    this.closedAt,
    this.utr = '',
    this.failureReason = '',
  });

  final String windowId;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final String currency;

  /// `closed`, `approved`, `paid`.
  final String windowStatus;

  /// `payable`, `held`, `queued`, `processing`, `paid`, `failed`, `returned`, `released`.
  final String lineStatus;
  final String gross;
  final int earningCount;
  final String holdReason;
  final DateTime? paidAt;
  final String railReference;
  final DateTime? closedAt;

  /// The bank's transfer reference (UTR) once the payout landed: what to quote to the bank.
  final String utr;

  /// Why the transfer did not land (`insufficient_funds`, `beneficiary_account_closed`, ...).
  final String failureReason;

  bool get failed => lineStatus == 'failed' || lineStatus == 'returned';

  /// The one word the worker needs: Paid, Sending, Failed, Moved (to the next window), Held, Approved
  /// (money is on its way) or Closed (being checked).
  String get stageLabel => switch ((lineStatus, windowStatus)) {
    ('paid', _) => 'Paid',
    ('held', _) => 'Held',
    ('queued' || 'processing', _) => 'Sending',
    ('failed' || 'returned', _) => 'Failed',
    ('released', _) => 'Moved',
    (_, 'approved' || 'paying') => 'Approved',
    (_, 'paid') => 'Paid',
    _ => 'Closed',
  };

  /// What a failed or moved line means, in plain words.
  String get failureText => switch (failureReason) {
    _ when lineStatus == 'released' => 'The transfer could not be made; these earnings move to the next pay window.',
    'insufficient_funds' => 'The transfer did not go through on our side. It is retried; you do not need to do anything.',
    'beneficiary_account_closed' ||
    'invalid_account' => 'Your bank returned the transfer: the account looks closed. Check it in onboarding.',
    '' => 'The transfer did not land. Finance retries it; nothing is lost.',
    _ => 'The transfer did not land (${humanize(failureReason).toLowerCase()}). Finance retries it; nothing is lost.',
  };

  factory PayoutWindow.fromJson(Json m) => PayoutWindow(
    windowId: readString(m, 'window_id'),
    startsAt: readDateTime(m, 'starts_at'),
    endsAt: readDateTime(m, 'ends_at'),
    currency: readString(m, 'currency'),
    windowStatus: readString(m, 'window_status'),
    lineStatus: readString(m, 'line_status'),
    gross: readString(m, 'gross'),
    earningCount: readInt(m, 'earning_count'),
    holdReason: readString(m, 'hold_reason'),
    paidAt: readDateTime(m, 'paid_at'),
    railReference: readString(m, 'rail_reference'),
    closedAt: readDateTime(m, 'closed_at'),
    utr: readString(m, 'utr'),
    failureReason: readString(m, 'failure_reason'),
  );
}

class WeekTotal {
  const WeekTotal({this.startsAt, this.endsAt, required this.currency, required this.amount, required this.count});

  final DateTime? startsAt;
  final DateTime? endsAt;
  final String currency;
  final String amount;
  final int count;

  double get value => double.tryParse(amount) ?? 0;

  factory WeekTotal.fromJson(Json m) => WeekTotal(
    startsAt: readDateTime(m, 'starts_at'),
    endsAt: readDateTime(m, 'ends_at'),
    currency: readString(m, 'currency'),
    amount: readString(m, 'amount'),
    count: readInt(m, 'count'),
  );
}

class MoneySum {
  const MoneySum({required this.currency, required this.amount, required this.count});

  final String currency;
  final String amount;
  final int count;

  factory MoneySum.fromJson(Json m) =>
      MoneySum(currency: readString(m, 'currency'), amount: readString(m, 'amount'), count: readInt(m, 'count'));

  static const none = MoneySum(currency: 'INR', amount: '0.00', count: 0);
}

/// The payout statement: totals by status, the hold, every earning, the windows, the weekly series.
class Statement {
  const Statement({
    required this.workerId,
    required this.totals,
    required this.hold,
    required this.earnings,
    required this.windows,
    required this.weeks,
    required this.pendingNext,
    this.holdUntil,
    this.firstPaidAt,
    this.nextWindowClosesAt,
  });

  final String workerId;

  /// status → amount (decimal string): `payable`, `windowed`, `paid`.
  final Map<String, String> totals;

  /// The hold reason when a hold is in force, else empty.
  final String hold;
  final List<Earning> earnings;
  final List<PayoutWindow> windows;
  final List<WeekTotal> weeks;
  final MoneySum pendingNext;
  final DateTime? holdUntil;
  final DateTime? firstPaidAt;
  final DateTime? nextWindowClosesAt;

  String total(String status) => totals[status] ?? '0.00';
  bool get isEmpty => earnings.isEmpty && windows.isEmpty;

  /// The currency the worker is paid in: the latest earning's, else the pending sum's.
  String get currency => earnings.isNotEmpty ? earnings.first.currency : pendingNext.currency;

  factory Statement.fromJson(Json m) {
    final totals = <String, String>{};
    for (final e in readMap(m, 'totals').entries) {
      totals[e.key] = e.value?.toString() ?? '0.00';
    }
    final account = readMap(m, 'account');
    final hold = m['hold'];
    return Statement(
      workerId: readString(m, 'worker_id'),
      totals: totals,
      hold: hold is String ? hold : '',
      earnings: readList(m, 'earnings').whereType<Map>().map((x) => Earning.fromJson(Map<String, dynamic>.from(x))).toList(),
      windows: readList(m, 'windows').whereType<Map>().map((x) => PayoutWindow.fromJson(Map<String, dynamic>.from(x))).toList(),
      weeks: readList(m, 'weeks').whereType<Map>().map((x) => WeekTotal.fromJson(Map<String, dynamic>.from(x))).toList(),
      pendingNext: m['pending_next'] is Map ? MoneySum.fromJson(readMap(m, 'pending_next')) : MoneySum.none,
      holdUntil: readDateTime(account, 'hold_until'),
      firstPaidAt: readDateTime(account, 'first_paid_at'),
      nextWindowClosesAt: readDateTime(m, 'next_window_closes_at'),
    );
  }
}

class InboxItem {
  const InboxItem({required this.id, required this.kind, required this.subject, required this.body, this.createdAt, this.readAt});

  final String id;
  final String kind;
  final String subject;
  final String body;
  final DateTime? createdAt;
  final DateTime? readAt;

  bool get isRead => readAt != null;

  InboxItem asRead(DateTime at) => InboxItem(id: id, kind: kind, subject: subject, body: body, createdAt: createdAt, readAt: at);

  factory InboxItem.fromJson(Json m) => InboxItem(
    id: readString(m, 'id'),
    kind: readString(m, 'kind'),
    subject: readString(m, 'subject'),
    body: readString(m, 'body'),
    createdAt: readDateTime(m, 'created_at'),
    readAt: readDateTime(m, 'read_at'),
  );
}

/// Where notices are mailed. [email] is the verified address, the only one mail goes to ('' when none);
/// [pendingEmail] waits for the six-digit code mailed to it (valid 15 minutes, five tries).
class Channel {
  const Channel({
    required this.workerId,
    required this.email,
    this.updatedAt,
    this.emailVerifiedAt,
    this.pendingEmail = '',
    this.verifyExpiresAt,
    this.verifySentAt,
    this.verifyError = '',
  });

  final String workerId;
  final String email;
  final DateTime? updatedAt;
  final DateTime? emailVerifiedAt;
  final String pendingEmail;
  final DateTime? verifyExpiresAt;

  /// When the code went out; null while the mail job has not sent it yet.
  final DateTime? verifySentAt;

  /// Why the code could not be mailed ('' when it was, or not yet tried): ask for a new one.
  final String verifyError;

  bool get isPending => pendingEmail.isNotEmpty;

  factory Channel.fromJson(Json m) => Channel(
    workerId: readString(m, 'worker_id'),
    email: readString(m, 'email'),
    updatedAt: readDateTime(m, 'updated_at'),
    emailVerifiedAt: readDateTime(m, 'email_verified_at'),
    pendingEmail: readString(m, 'pending_email'),
    verifyExpiresAt: readDateTime(m, 'verify_expires_at'),
    verifySentAt: readDateTime(m, 'verify_sent_at'),
    verifyError: readString(m, 'verify_error'),
  );
}
