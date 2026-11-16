import '../core/people.dart' as people;
import '../core/json.dart';
import 'feedback.dart';
import 'finance_models.dart' as fin;
import '../core/money.dart';
import '../core/upload.dart';
import 'assess_models.dart';
import 'models.dart';

/// Wire shapes of the operator console (docs/PRODUCT.md §5). Read with type tests: a missing field is
/// empty, never a throw. Money stays a decimal string; percentages are fractions (0.3 = 30%).

double? readDouble(Json m, String key) {
  final v = m[key];
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

List<String> readStrings(Json m, String key) => readList(m, key).whereType<String>().toList();

List<Json> readObjects(Json m, String key) => readList(m, key).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();

/// `(unit_price - unit_pay - review_pay) / unit_price`, or null when there is no price.
double? marginOf(String unitPrice, String unitPay, String reviewPay) {
  final price = double.tryParse(unitPrice) ?? 0;
  if (price <= 0) return null;
  final pay = double.tryParse(unitPay) ?? 0;
  final review = double.tryParse(reviewPay) ?? 0;
  return (price - pay - review) / price;
}

/// `53%` from a fraction; `—` when unknown.
String percent(double? fraction) => fraction == null ? '—' : '${(fraction * 100).round()}%';

/// An id shortened for a table cell: the same rule as the people widgets (`core/people.dart`).
String shortId(String id) => people.shortId(id);

/// Units of a project or a batch by stage.
class UnitCounts {
  const UnitCounts({
    this.total = 0,
    this.available = 0,
    this.claimed = 0,
    this.submitted = 0,
    this.inReview = 0,
    this.accepted = 0,
    this.rejected = 0,
    this.needsEdits = 0,
  });

  final int total;
  final int available;
  final int claimed;
  final int submitted;
  final int inReview;
  final int accepted;
  final int rejected;
  final int needsEdits;

  /// Submitted plus in review: the review backlog.
  int get reviewing => submitted + inReview;

  factory UnitCounts.fromJson(Json m) => UnitCounts(
    total: readInt(m, 'total'),
    available: readInt(m, 'available'),
    claimed: readInt(m, 'claimed'),
    submitted: readInt(m, 'submitted'),
    inReview: readInt(m, 'in_review'),
    accepted: readInt(m, 'accepted'),
    rejected: readInt(m, 'rejected'),
    needsEdits: readInt(m, 'needs_edits'),
  );

  static UnitCounts sum(Iterable<UnitCounts> all) {
    var out = const UnitCounts();
    for (final c in all) {
      out = UnitCounts(
        total: out.total + c.total,
        available: out.available + c.available,
        claimed: out.claimed + c.claimed,
        submitted: out.submitted + c.submitted,
        inReview: out.inReview + c.inReview,
        accepted: out.accepted + c.accepted,
        rejected: out.rejected + c.rejected,
        needsEdits: out.needsEdits + c.needsEdits,
      );
    }
    return out;
  }
}

class Manifest {
  const Manifest({required this.id, required this.digest, required this.acceptedUnits, required this.totalPrice, this.createdAt});
  final String id;
  final String digest;
  final int acceptedUnits;
  final String totalPrice;
  final DateTime? createdAt;

  String get shortDigest => digest.length > 12 ? digest.substring(0, 12) : digest;

  factory Manifest.fromJson(Json m) => Manifest(
    id: readString(m, 'id'),
    digest: readString(m, 'digest'),
    acceptedUnits: readInt(m, 'accepted_units'),
    totalPrice: readString(m, 'total_price'),
    createdAt: readDateTime(m, 'created_at'),
  );
}

/// A batch as ops see it: pay and price side by side, the counts, the live claims, the manifest.
class BatchSummary {
  const BatchSummary({
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.title,
    required this.mode,
    required this.status,
    required this.unitPay,
    required this.unitPrice,
    required this.reviewPay,
    required this.currency,
    required this.claimTtlMinutes,
    required this.rubricVersion,
    required this.floorApprovedBy,
    required this.units,
    required this.liveClaims,
    this.publishedAt,
    this.manifest,
    this.dueAt,
    this.purgedAt,
  });

  final String id;
  final String projectId;
  final String projectName;
  final String title;
  final String mode;
  final String status;
  final String unitPay;
  final String unitPrice;
  final String reviewPay;
  final String currency;
  final int claimTtlMinutes;
  final String rubricVersion;
  final String floorApprovedBy;
  final DateTime? publishedAt;
  final UnitCounts units;
  final int liveClaims;
  final Manifest? manifest;

  /// When the client expects the delivery; null when nobody set one.
  final DateTime? dueAt;

  /// When retention removed the payloads and answers (counts and the manifest digest stay).
  final DateTime? purgedAt;

  double? get margin => marginOf(unitPrice, unitPay, reviewPay);

  /// Below the project's floor; false when either side is unknown.
  bool underFloor(double? floor) {
    final m = margin;
    return floor != null && m != null && m < floor;
  }

  factory BatchSummary.fromJson(Json m) => BatchSummary(
    id: readString(m, 'id'),
    projectId: readString(m, 'project_id'),
    projectName: readString(m, 'project_name'),
    title: readString(m, 'title'),
    mode: readString(m, 'mode'),
    status: readString(m, 'status'),
    unitPay: readString(m, 'unit_pay'),
    unitPrice: readString(m, 'unit_price'),
    reviewPay: readString(m, 'review_pay'),
    currency: readString(m, 'currency'),
    claimTtlMinutes: readInt(m, 'claim_ttl_minutes'),
    rubricVersion: readString(m, 'rubric_version'),
    floorApprovedBy: readString(m, 'floor_approved_by'),
    publishedAt: readDateTime(m, 'published_at'),
    units: UnitCounts.fromJson(readMap(m, 'units')),
    liveClaims: readInt(m, 'live_claims'),
    manifest: m['manifest'] is Map ? Manifest.fromJson(readMap(m, 'manifest')) : null,
    dueAt: readDateTime(m, 'due_at'),
    purgedAt: readDateTime(m, 'purged_at'),
  );
}

/// One media file handed a presigned upload (`POST /v1/batches/{id}/payload-uploads`): PUT the bytes to
/// [target], then put [ref] in the unit's payload.
class MediaUpload {
  const MediaUpload({required this.name, required this.ref, required this.target});
  final String name;
  final String ref;
  final PresignedUpload target;

  factory MediaUpload.fromJson(Json m) =>
      MediaUpload(name: readString(m, 'name'), ref: readString(m, 'ref'), target: PresignedUpload.fromJson(m));
}

/// A delivered batch as files (`GET /v1/batches/{id}/deliverable`): five-minute links to the JSONL and the
/// manifest, with the JSONL's digest and size.
class Deliverable {
  const Deliverable({
    required this.digest,
    required this.jsonlUrl,
    required this.jsonlSha256,
    required this.bytes,
    required this.lineCount,
    required this.manifestUrl,
  });
  final String digest;
  final String jsonlUrl;
  final String jsonlSha256;
  final int bytes;
  final int lineCount;
  final String manifestUrl;

  factory Deliverable.fromJson(Json m) {
    final jsonl = readMap(m, 'jsonl');
    return Deliverable(
      digest: readString(m, 'digest'),
      jsonlUrl: readString(jsonl, 'url'),
      jsonlSha256: readString(jsonl, 'sha256'),
      bytes: readInt(jsonl, 'bytes'),
      lineCount: readInt(jsonl, 'line_count'),
      manifestUrl: readString(readMap(m, 'manifest'), 'url'),
    );
  }
}

class ProjectSummary {
  const ProjectSummary({
    required this.id,
    required this.name,
    required this.currency,
    required this.status,
    required this.certGate,
    required this.rubricVersion,
    required this.marginFloor,
    required this.clientOrgId,
    required this.batchCount,
    required this.units,
    required this.batches,
    this.createdAt,
    this.retentionDays = 180,
    this.closedAt,
  });

  final String id;
  final String name;
  final String currency;
  final String status;
  final String certGate;
  final String rubricVersion;

  /// A fraction (0.3 = 30%), or null when the project has no floor.
  final double? marginFloor;
  final String clientOrgId;
  final int batchCount;
  final UnitCounts units;

  /// Present on the detail; a summary carries it only when the gateway chooses to send it.
  final List<BatchSummary> batches;
  final DateTime? createdAt;

  /// Days after delivery (or close) before unit payloads and answers are purged; counts and digests stay.
  final int retentionDays;
  final DateTime? closedAt;

  List<BatchSummary> get batchesUnderFloor => [
    for (final b in batches)
      if (b.underFloor(marginFloor)) b,
  ];

  factory ProjectSummary.fromJson(Json m) => ProjectSummary(
    id: readString(m, 'id'),
    name: readString(m, 'name'),
    currency: readString(m, 'currency'),
    status: readString(m, 'status'),
    certGate: readString(m, 'cert_gate'),
    rubricVersion: readString(m, 'rubric_version'),
    marginFloor: readDouble(m, 'margin_floor'),
    clientOrgId: readString(m, 'client_org_id'),
    batchCount: m['batch_count'] == null ? readList(m, 'batches').length : readInt(m, 'batch_count'),
    units: UnitCounts.fromJson(readMap(m, 'units')),
    batches: readObjects(m, 'batches').map(BatchSummary.fromJson).toList(),
    createdAt: readDateTime(m, 'created_at'),
    retentionDays: m['retention_days'] == null ? 180 : readInt(m, 'retention_days'),
    closedAt: readDateTime(m, 'closed_at'),
  );
}

/// One day of a project's 30-day trend (`GET /v1/analytics/projects/{id}/trend`).
class TrendDay {
  const TrendDay({
    required this.day,
    required this.published,
    required this.claimed,
    required this.submitted,
    required this.accepted,
    required this.rejected,
    required this.firstPassRate,
    required this.pay,
    required this.price,
    required this.reviewCost,
    required this.margin,
  });
  final DateTime? day;
  final int published;
  final int claimed;
  final int submitted;
  final int accepted;
  final int rejected;
  final double? firstPassRate;
  final String pay;
  final String price;
  final String reviewCost;
  final String margin;

  factory TrendDay.fromJson(Json m) => TrendDay(
    day: DateTime.tryParse(readString(m, 'day')),
    published: readInt(m, 'published'),
    claimed: readInt(m, 'claimed'),
    submitted: readInt(m, 'submitted'),
    accepted: readInt(m, 'accepted'),
    rejected: readInt(m, 'rejected'),
    firstPassRate: readDouble(m, 'first_pass_rate'),
    pay: readString(m, 'pay'),
    price: readString(m, 'price'),
    reviewCost: readString(m, 'review_cost'),
    margin: readString(m, 'margin'),
  );
}

class ProjectTrend {
  const ProjectTrend({required this.currency, required this.days});
  final String currency;
  final List<TrendDay> days;

  int get accepted => days.fold(0, (a, d) => a + d.accepted);
  int get rejected => days.fold(0, (a, d) => a + d.rejected);
  double get margin => days.fold(0.0, (a, d) => a + (double.tryParse(d.margin) ?? 0));

  factory ProjectTrend.fromJson(Json m) =>
      ProjectTrend(currency: readString(m, 'currency'), days: readObjects(m, 'days').map(TrendDay.fromJson).toList());
}

class ReasonRow {
  const ReasonRow({required this.reasonCode, required this.count, required this.billable});
  final String reasonCode;
  final int count;
  final bool billable;

  factory ReasonRow.fromJson(Json m) =>
      ReasonRow(reasonCode: readString(m, 'reason_code'), count: readInt(m, 'count'), billable: readBool(m, 'billable'));
}

class RubricLogEntry {
  const RubricLogEntry({required this.version, required this.note, this.at});
  final String version;
  final String note;
  final DateTime? at;

  factory RubricLogEntry.fromJson(Json m) =>
      RubricLogEntry(version: readString(m, 'version'), note: readString(m, 'note'), at: readDateTime(m, 'at'));
}

class ProjectDetail extends ProjectSummary {
  const ProjectDetail({
    required super.id,
    required super.name,
    required super.currency,
    required super.status,
    required super.certGate,
    required super.rubricVersion,
    required super.marginFloor,
    required super.clientOrgId,
    required super.batchCount,
    required super.units,
    required super.batches,
    super.createdAt,
    required this.payloadSchema,
    required this.answerSchema,
    required this.brief,
    required this.llmPolicy,
    required this.sensitive,
    required this.reasons,
    required this.feedback,
    required this.rubricLog,
  });

  final Json payloadSchema;
  final Json answerSchema;
  final String brief;
  final String llmPolicy;
  final bool sensitive;
  final List<ReasonRow> reasons;
  final List<FeedbackEntry> feedback;
  final List<RubricLogEntry> rubricLog;

  factory ProjectDetail.fromJson(Json m) {
    final s = ProjectSummary.fromJson(m);
    return ProjectDetail(
      id: s.id,
      name: s.name,
      currency: s.currency,
      status: s.status,
      certGate: s.certGate,
      rubricVersion: s.rubricVersion,
      marginFloor: s.marginFloor,
      clientOrgId: s.clientOrgId,
      batchCount: s.batchCount,
      units: s.units,
      batches: s.batches,
      createdAt: s.createdAt,
      payloadSchema: readMap(m, 'payload_schema'),
      answerSchema: readMap(m, 'answer_schema'),
      brief: readString(m, 'brief'),
      llmPolicy: readString(m, 'llm_policy'),
      sensitive: readBool(m, 'sensitive'),
      reasons: readObjects(m, 'reasons').map(ReasonRow.fromJson).toList(),
      feedback: readObjects(m, 'feedback').map(FeedbackEntry.fromJson).toList(),
      rubricLog: readObjects(m, 'rubric_log').map(RubricLogEntry.fromJson).toList(),
    );
  }
}

/// `{total, items}` of any row type.
class ListPage<T> {
  const ListPage({required this.total, required this.items});
  final int total;
  final List<T> items;

  factory ListPage.fromJson(Json m, T Function(Json) parse) =>
      ListPage(total: readInt(m, 'total'), items: readObjects(m, 'items').map(parse).toList());
}

class UnitRow {
  const UnitRow({
    required this.id,
    required this.externalRef,
    required this.status,
    required this.assignedWorkerId,
    required this.currentClaimId,
    this.createdAt,
  });
  final String id;
  final String externalRef;
  final String status;
  final String assignedWorkerId;
  final String currentClaimId;
  final DateTime? createdAt;

  factory UnitRow.fromJson(Json m) => UnitRow(
    id: readString(m, 'id'),
    externalRef: readString(m, 'external_ref'),
    status: readString(m, 'status'),
    assignedWorkerId: readString(m, 'assigned_worker_id'),
    currentClaimId: readString(m, 'current_claim_id'),
    createdAt: readDateTime(m, 'created_at'),
  );
}

class ImportLineError {
  const ImportLineError({required this.line, required this.externalRef, required this.reason});
  final int line;
  final String externalRef;
  final String reason;

  factory ImportLineError.fromJson(Json m) =>
      ImportLineError(line: readInt(m, 'line'), externalRef: readString(m, 'external_ref'), reason: readString(m, 'reason'));
}

/// The dry-run (or real) import report: how many lines, how many would land, every bad line and why.
class ImportReport {
  const ImportReport({required this.total, required this.accepted, required this.errors, required this.dryRun});
  final int total;
  final int accepted;
  final List<ImportLineError> errors;
  final bool dryRun;

  bool get clean => errors.isEmpty && accepted > 0;

  factory ImportReport.fromJson(Json m) => ImportReport(
    total: readInt(m, 'total'),
    accepted: readInt(m, 'accepted'),
    errors: readObjects(m, 'errors').map(ImportLineError.fromJson).toList(),
    dryRun: readBool(m, 'dry_run'),
  );
}

/// A worker on the bench.
class WorkerRow {
  const WorkerRow({
    required this.id,
    required this.status,
    required this.certGates,
    this.partnerRef,
    this.availability,
    this.updatedAt,
    this.name = '',
    this.onboarded = false,
    this.held = false,
    this.holdUntil,
  });
  final String id;
  final String status;
  final List<String> certGates;
  final int? partnerRef;
  final Availability? availability;
  final DateTime? updatedAt;

  /// The worker's legal name once talent has seen them; empty until then.
  final String name;

  /// Past `unknown`: onboarding finished (or an operator set a status).
  final bool onboarded;

  /// On a payout hold (from payout's hold events), with its end when it has one.
  final bool held;
  final DateTime? holdUntil;

  factory WorkerRow.fromJson(Json m) => WorkerRow(
    id: readString(m, 'id'),
    status: readString(m, 'status').isEmpty ? 'unknown' : readString(m, 'status'),
    certGates: readStrings(m, 'cert_gates'),
    partnerRef: m['partner_ref'] is num ? (m['partner_ref'] as num).toInt() : null,
    availability: m['availability'] is Map ? Availability.fromJson(readMap(m, 'availability')) : null,
    updatedAt: readDateTime(m, 'updated_at'),
    name: readString(m, 'name'),
    onboarded: readBool(m, 'onboarded'),
    held: readBool(m, 'held'),
    holdUntil: readDateTime(m, 'hold_until'),
  );
}

/// One identity or agreement file a worker uploaded (`GET /v1/talent/workers/{id}/documents`).
class WorkerDocument {
  const WorkerDocument({required this.kind, required this.sha256, required this.sizeBytes, required this.contentType, this.uploadedAt});
  final String kind;
  final String sha256;
  final int sizeBytes;
  final String contentType;
  final DateTime? uploadedAt;

  factory WorkerDocument.fromJson(Json m) => WorkerDocument(
    kind: readString(m, 'kind'),
    sha256: readString(m, 'sha256'),
    sizeBytes: readInt(m, 'size_bytes'),
    contentType: readString(m, 'content_type'),
    uploadedAt: readDateTime(m, 'uploaded_at'),
  );
}

/// What quality knows of a reviewer: the gates they hold and whether they may review sensitive projects.
class ReviewerProfile {
  const ReviewerProfile({required this.workerId, required this.sensitiveCleared, required this.gates, this.updatedAt});
  final String workerId;
  final bool sensitiveCleared;
  final List<String> gates;
  final DateTime? updatedAt;

  factory ReviewerProfile.fromJson(Json m) => ReviewerProfile(
    workerId: readString(m, 'worker_id'),
    sensitiveCleared: readBool(m, 'sensitive_cleared'),
    gates: readStrings(m, 'gates'),
    updatedAt: readDateTime(m, 'updated_at'),
  );
}

/// The bank account payout pays into, as finance may see it: never the number.
class BankStatus {
  const BankStatus({
    required this.status,
    required this.verification,
    required this.accountName,
    required this.last4,
    required this.ifsc,
    this.nameMatch,
    this.verifiedAt,
    this.failureReason = '',
    this.awaitingConfirmation = false,
    this.confirmedAt,
  });

  /// `verifying`, `verified`, `failed`.
  final String status;

  /// `penny_drop` or `none` (a rail that cannot check).
  final String verification;
  final String accountName;
  final String last4;
  final String ifsc;
  final bool? nameMatch;
  final DateTime? verifiedAt;
  final String failureReason;

  /// Verified by a penny drop that returned no registered name: nothing is paid into it until finance confirms.
  final bool awaitingConfirmation;
  final DateTime? confirmedAt;

  factory BankStatus.fromJson(Json m) => BankStatus(
    status: readString(m, 'status'),
    verification: readString(m, 'verification'),
    accountName: readString(m, 'account_name'),
    last4: readString(m, 'account_last4'),
    ifsc: readString(m, 'ifsc'),
    nameMatch: m['registered_name_match'] is bool ? m['registered_name_match'] as bool : null,
    verifiedAt: readDateTime(m, 'verified_at'),
    failureReason: readString(m, 'failure_reason'),
    awaitingConfirmation: m['awaiting_confirmation'] == true,
    confirmedAt: readDateTime(m, 'confirmed_at'),
  );
}

/// A tracked work session (`GET /v1/tracker/sessions?worker_id=`).
class TrackerSession {
  const TrackerSession({
    required this.id,
    required this.workerId,
    required this.source,
    required this.activeSeconds,
    required this.idleSeconds,
    this.claimId = '',
    this.startedAt,
    this.endedAt,
    this.overCapAt,
    this.endReason = '',
  });
  final String id;
  final String workerId;
  final String source;
  final int activeSeconds;
  final int idleSeconds;
  final String claimId;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final DateTime? overCapAt;
  final String endReason;

  factory TrackerSession.fromJson(Json m) => TrackerSession(
    id: readString(m, 'id'),
    workerId: readString(m, 'worker_id'),
    source: readString(m, 'source'),
    activeSeconds: readInt(m, 'active_seconds'),
    idleSeconds: readInt(m, 'idle_seconds'),
    claimId: readString(m, 'claim_id'),
    startedAt: readDateTime(m, 'started_at'),
    endedAt: readDateTime(m, 'ended_at'),
    overCapAt: readDateTime(m, 'over_cap_at'),
    endReason: readString(m, 'end_reason'),
  );
}

/// Something the tracker found odd (`GET /v1/tracker/anomalies`): an operator dismisses or upholds it; an
/// upheld anomaly puts the worker's payouts on an integrity hold.
class Anomaly {
  const Anomaly({
    required this.id,
    required this.workerId,
    required this.kind,
    required this.detail,
    required this.status,
    this.sessionId = '',
    this.note = '',
    this.decidedBy = '',
    this.createdAt,
    this.decidedAt,
  });
  final String id;
  final String workerId;

  /// `impossible_activity`, `over_cap`, `no_live_claim`, `duplicate_device`.
  final String kind;
  final Json detail;

  /// `open`, `dismissed`, `upheld`.
  final String status;
  final String sessionId;
  final String note;
  final String decidedBy;
  final DateTime? createdAt;
  final DateTime? decidedAt;

  bool get isOpen => status == 'open';

  factory Anomaly.fromJson(Json m) => Anomaly(
    id: readString(m, 'id'),
    workerId: readString(m, 'worker_id'),
    kind: readString(m, 'kind'),
    detail: readMap(m, 'detail'),
    status: readString(m, 'status'),
    sessionId: readString(m, 'session_id'),
    note: readString(m, 'note'),
    decidedBy: readString(m, 'decided_by'),
    createdAt: readDateTime(m, 'created_at'),
    decidedAt: readDateTime(m, 'decided_at'),
  );
}

class ClientOrg {
  const ClientOrg({required this.id, required this.name, required this.members});
  final String id;
  final String name;
  final List<String> members;

  factory ClientOrg.fromJson(Json m) => ClientOrg(id: readString(m, 'id'), name: readString(m, 'name'), members: readStrings(m, 'members'));
}

class QualityStats {
  const QualityStats({
    required this.pending,
    required this.claimed,
    required this.inAudit,
    required this.accepted,
    required this.rejected,
    required this.needsEdits,
    required this.acceptanceRate,
    required this.reasons,
    required this.auditDisagreements,
    this.oldestPendingAt,
  });
  final int pending;
  final int claimed;
  final int inAudit;
  final int accepted;
  final int rejected;
  final int needsEdits;
  final double? acceptanceRate;
  final DateTime? oldestPendingAt;
  final List<ReasonRow> reasons;
  final int auditDisagreements;

  factory QualityStats.fromJson(Json m) => QualityStats(
    pending: readInt(m, 'pending'),
    claimed: readInt(m, 'claimed'),
    inAudit: readInt(m, 'in_audit'),
    accepted: readInt(m, 'accepted'),
    rejected: readInt(m, 'rejected'),
    needsEdits: readInt(m, 'needs_edits'),
    acceptanceRate: readDouble(m, 'acceptance_rate'),
    oldestPendingAt: readDateTime(m, 'oldest_pending_at'),
    reasons: readObjects(m, 'reasons').map(ReasonRow.fromJson).toList(),
    auditDisagreements: readInt(m, 'audit_disagreements'),
  );
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

class PayoutOverview {
  const PayoutOverview({
    required this.payableNow,
    required this.paidTotal,
    required this.heldTotal,
    required this.marginTotal,
    required this.pendingAdjustments,
    required this.windowsClosed,
    required this.windowsApproved,
    required this.windowsPaid,
    this.openWindow,
  });

  /// currency → amount, each.
  final Map<String, String> payableNow;
  final Map<String, String> paidTotal;
  final Map<String, String> heldTotal;
  final Map<String, String> marginTotal;
  final int pendingAdjustments;
  final int windowsClosed;
  final int windowsApproved;
  final int windowsPaid;
  final OpenWindow? openWindow;

  factory PayoutOverview.fromJson(Json m) {
    final windows = readMap(m, 'windows');
    return PayoutOverview(
      payableNow: _money(m, 'payable_now'),
      paidTotal: _money(m, 'paid_total'),
      heldTotal: _money(m, 'held_total'),
      marginTotal: _money(m, 'margin_total'),
      pendingAdjustments: readInt(m, 'pending_adjustments'),
      windowsClosed: readInt(windows, 'closed'),
      windowsApproved: readInt(windows, 'approved'),
      windowsPaid: readInt(windows, 'paid'),
      openWindow: m['open_window'] is Map ? OpenWindow.fromJson(readMap(m, 'open_window')) : null,
    );
  }
}

/// A `{currency: amount}` map; a bare string (an older shape) reads as one unnamed currency.
Map<String, String> _money(Json m, String key) {
  final v = m[key];
  if (v is Map) return {for (final e in v.entries) e.key.toString(): e.value?.toString() ?? ''};
  if (v is String && v.isNotEmpty) return {'': v};
  return const {};
}

/// "INR 1,200.00 · USD 3.00", or a dash when empty.
String moneyList(Map<String, String> money, {String dash = '—'}) {
  if (money.isEmpty) return dash;
  final keys = money.keys.toList()..sort();
  return keys.map((k) => formatMoney(money[k] ?? '', currency: k)).join(' · ');
}

class PayoutAccount {
  const PayoutAccount({
    required this.workerId,
    required this.holdReason,
    required this.payable,
    required this.paid,
    required this.held,
    this.holdUntil,
    this.firstPaidAt,
    this.bank,
  });
  final String workerId;
  final String holdReason;
  final DateTime? holdUntil;
  final DateTime? firstPaidAt;
  final String payable;
  final String paid;
  final String held;

  /// The account payout pays into; null until the worker registers one.
  final BankStatus? bank;

  bool get isHeld => holdReason.isNotEmpty;

  factory PayoutAccount.fromJson(Json m) {
    final account = readMap(m, 'account');
    final totals = readMap(m, 'totals');
    return PayoutAccount(
      workerId: readString(account, 'worker_id'),
      holdReason: readString(account, 'hold_reason'),
      holdUntil: readDateTime(account, 'hold_until'),
      firstPaidAt: readDateTime(account, 'first_paid_at'),
      payable: readString(totals, 'payable'),
      paid: readString(totals, 'paid'),
      held: readString(totals, 'held'),
      bank: m['bank'] is Map ? BankStatus.fromJson(readMap(m, 'bank')) : null,
    );
  }
}

/// `GET /v1/attention`: what waits on an operator across market, quality, talent and notify, plus dead
/// letters per module.
class WorkAttention {
  const WorkAttention({
    this.reviewBacklog = 0,
    this.oldestPendingAt,
    this.flagsOpen = 0,
    this.flagsOverdue = 0,
    this.disputesOpen = 0,
    this.expiredReviews = 0,
    this.expiredClaims = 0,
    this.batchesUnderFloor = 0,
    this.applicationsScreening = 0,
    this.erasuresPending = 0,
    this.erasuresDue = 0,
    this.ticketsOpen = 0,
    this.ticketsInProgress = 0,
    this.deadLetters = const {},
    this.stuckAssignedUnits = 0,
  });

  final int reviewBacklog;
  final DateTime? oldestPendingAt;
  final int flagsOpen;
  final int flagsOverdue;
  final int disputesOpen;
  final int expiredReviews;
  final int expiredClaims;
  final int batchesUnderFloor;
  final int applicationsScreening;
  final int erasuresPending;
  final int erasuresDue;
  final int ticketsOpen;
  final int ticketsInProgress;
  final Map<String, int> deadLetters;

  /// Available units waiting more than three days for the one worker they are assigned to.
  final int stuckAssignedUnits;

  int get deadLetterTotal => deadLetters.values.fold(0, (a, b) => a + b);

  factory WorkAttention.fromJson(Json m) {
    final dead = readMap(m, 'dead_letters');
    return WorkAttention(
      reviewBacklog: readInt(m, 'review_backlog'),
      oldestPendingAt: readDateTime(m, 'oldest_pending_at'),
      flagsOpen: readInt(m, 'flags_open'),
      flagsOverdue: readInt(m, 'flags_overdue'),
      disputesOpen: readInt(m, 'disputes_open'),
      expiredReviews: readInt(m, 'expired_reviews'),
      expiredClaims: readInt(m, 'expired_claims'),
      batchesUnderFloor: readInt(m, 'batches_under_floor'),
      applicationsScreening: readInt(m, 'applications_screening'),
      erasuresPending: readInt(m, 'erasures_pending'),
      erasuresDue: readInt(m, 'erasures_due'),
      ticketsOpen: readInt(m, 'tickets_open'),
      ticketsInProgress: readInt(m, 'tickets_in_progress'),
      deadLetters: {for (final k in dead.keys) k: readInt(dead, k)},
      stuckAssignedUnits: readInt(m, 'stuck_assigned_units'),
    );
  }
}

/// `GET /v1/workers/summary`: the bench by status.
class WorkersSummary {
  const WorkersSummary({
    this.total = 0,
    this.unknown = 0,
    this.eligible = 0,
    this.active = 0,
    this.suspended = 0,
    this.offboarded = 0,
    this.paused = 0,
    this.held = 0,
  });

  final int total;
  final int unknown;
  final int eligible;
  final int active;
  final int suspended;
  final int offboarded;
  final int paused;
  final int held;

  /// Workers who can claim: eligible or active.
  int get bench => eligible + active;

  factory WorkersSummary.fromJson(Json m) => WorkersSummary(
    total: readInt(m, 'total'),
    unknown: readInt(m, 'unknown'),
    eligible: readInt(m, 'eligible'),
    active: readInt(m, 'active'),
    suspended: readInt(m, 'suspended'),
    offboarded: readInt(m, 'offboarded'),
    paused: readInt(m, 'paused'),
    held: readInt(m, 'held'),
  );
}

/// What the ops home needs, in one object. Modules that are empty (404) read as null and paint "—".
class OpsOverview {
  const OpsOverview({required this.projects, this.stats, this.payout, this.attention, this.payoutAttention, this.bench});
  final List<ProjectSummary> projects;
  final QualityStats? stats;
  final PayoutOverview? payout;

  /// Null when the work deployable has no attention route yet (404); the page then shows no list.
  final WorkAttention? attention;
  final fin.PayoutAttention? payoutAttention;
  final WorkersSummary? bench;

  UnitCounts get units => UnitCounts.sum(projects.map((p) => p.units));
  List<(ProjectSummary, BatchSummary)> get underFloor => [
    for (final p in projects)
      for (final b in p.batchesUnderFloor) (p, b),
  ];
}

// ── talent ───────────────────────────────────────────────────────────────────

class ListingQuestion {
  const ListingQuestion({required this.key, required this.prompt, required this.kind, required this.options, required this.required});
  final String key;
  final String prompt;
  final String kind;
  final List<String> options;
  final bool required;

  factory ListingQuestion.fromJson(Json m) => ListingQuestion(
    key: readString(m, 'key'),
    prompt: readString(m, 'prompt'),
    kind: readString(m, 'kind').isEmpty ? 'text' : readString(m, 'kind'),
    options: readStrings(m, 'options'),
    required: readBool(m, 'required'),
  );

  Json toJson() => {'key': key, 'prompt': prompt, 'kind': kind, if (kind == 'choice') 'options': options, 'required': required};
}

class ApplicationCounts {
  const ApplicationCounts({
    this.applied = 0,
    this.assessment = 0,
    this.screening = 0,
    this.offered = 0,
    this.accepted = 0,
    this.rejected = 0,
  });
  final int applied;

  /// Applicants sitting the paper; shown with `applied` on the ops table.
  final int assessment;
  final int screening;
  final int offered;
  final int accepted;
  final int rejected;

  factory ApplicationCounts.fromJson(Json m) => ApplicationCounts(
    applied: readInt(m, 'applied'),
    assessment: readInt(m, 'assessment'),
    screening: readInt(m, 'screening'),
    offered: readInt(m, 'offered'),
    accepted: readInt(m, 'accepted'),
    rejected: readInt(m, 'rejected'),
  );
}

class Listing {
  const Listing({
    required this.id,
    required this.title,
    required this.domain,
    required this.summary,
    required this.description,
    required this.payMin,
    required this.payMax,
    required this.payUnit,
    required this.currency,
    required this.commitment,
    required this.hoursPerWeek,
    required this.slotsTotal,
    required this.slotsFilled,
    required this.certGate,
    required this.paperId,
    required this.requirements,
    required this.questions,
    required this.llmPolicy,
    required this.sensitive,
    required this.status,
    required this.applications,
    this.postedAt,
    this.closesAt,
    this.createdAt,
    this.steps = const [],
    this.hiredThisWeek = 0,
  });

  final String id;
  final String title;
  final String domain;
  final String summary;
  final String description;
  final String payMin;
  final String payMax;
  final String payUnit;
  final String currency;
  final String commitment;
  final int hoursPerWeek;
  final int slotsTotal;
  final int slotsFilled;
  final String certGate;
  final String paperId;
  final List<String> requirements;
  final List<ListingQuestion> questions;
  final String llmPolicy;
  final bool sensitive;
  final String status;
  final ApplicationCounts applications;
  final DateTime? postedAt;
  final DateTime? closesAt;
  final DateTime? createdAt;

  /// What applying involves, in order: `form`, then `paper` when there is one, then `availability`.
  final List<String> steps;

  /// Offers accepted in the last seven days.
  final int hiredThisWeek;

  factory Listing.fromJson(Json m) => Listing(
    id: readString(m, 'id'),
    title: readString(m, 'title'),
    domain: readString(m, 'domain'),
    summary: readString(m, 'summary'),
    description: readString(m, 'description'),
    payMin: readString(m, 'pay_min'),
    payMax: readString(m, 'pay_max'),
    payUnit: readString(m, 'pay_unit'),
    currency: readString(m, 'currency'),
    commitment: readString(m, 'commitment'),
    hoursPerWeek: readInt(m, 'hours_per_week'),
    slotsTotal: readInt(m, 'slots_total'),
    slotsFilled: readInt(m, 'slots_filled'),
    certGate: readString(m, 'cert_gate'),
    paperId: readString(m, 'paper_id'),
    requirements: readStrings(m, 'requirements'),
    questions: readObjects(m, 'questions').map(ListingQuestion.fromJson).toList(),
    llmPolicy: readString(m, 'llm_policy'),
    sensitive: readBool(m, 'sensitive'),
    status: readString(m, 'status'),
    applications: ApplicationCounts.fromJson(readMap(m, 'applications')),
    postedAt: readDateTime(m, 'posted_at'),
    closesAt: readDateTime(m, 'closes_at'),
    createdAt: readDateTime(m, 'created_at'),
    steps: readStrings(m, 'steps'),
    hiredThisWeek: readInt(m, 'hired_this_week'),
  );
}

/// The latest paper outcome behind an application.
class PaperResult {
  const PaperResult({required this.status, required this.score, this.at, this.attemptsLeft});

  /// `passed` or `failed`.
  final String status;
  final double? score;
  final DateTime? at;
  final int? attemptsLeft;

  factory PaperResult.fromJson(Json m) => PaperResult(
    status: readString(m, 'status'),
    score: readDouble(m, 'score'),
    at: readDateTime(m, 'at'),
    attemptsLeft: m['attempts_left'] is num ? (m['attempts_left'] as num).toInt() : null,
  );
}

class ApplicationStep {
  const ApplicationStep({required this.kind, required this.status});
  final String kind;
  final String status;

  factory ApplicationStep.fromJson(Json m) => ApplicationStep(kind: readString(m, 'kind'), status: readString(m, 'status'));
}

class Application {
  const Application({
    required this.id,
    required this.listingId,
    required this.listingTitle,
    required this.workerId,
    required this.status,
    required this.steps,
    required this.answers,
    required this.note,
    required this.decidedBy,
    this.offerExpiresAt,
    this.createdAt,
    this.updatedAt,
    this.workerName = '',
    this.paper,
  });

  final String id;
  final String listingId;
  final String listingTitle;
  final String workerId;

  /// The applicant's name once talent knows it.
  final String workerName;
  final PaperResult? paper;
  final String status;
  final List<ApplicationStep> steps;
  final Json answers;
  final String note;
  final String decidedBy;
  final DateTime? offerExpiresAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory Application.fromJson(Json m) => Application(
    id: readString(m, 'id'),
    listingId: readString(m, 'listing_id'),
    listingTitle: readString(m, 'listing_title'),
    workerId: readString(m, 'worker_id'),
    status: readString(m, 'status'),
    steps: readObjects(m, 'steps').map(ApplicationStep.fromJson).toList(),
    answers: readMap(m, 'answers'),
    note: readString(m, 'note'),
    decidedBy: readString(m, 'decided_by'),
    workerName: readString(m, 'worker_name'),
    paper: m['paper'] is Map ? PaperResult.fromJson(readMap(m, 'paper')) : null,
    offerExpiresAt: readDateTime(m, 'offer_expires_at'),
    createdAt: readDateTime(m, 'created_at'),
    updatedAt: readDateTime(m, 'updated_at'),
  );
}

// ── assess ───────────────────────────────────────────────────────────────────

/// A question of a quick paper (Yantra's own editor): single or multiple choice, with its answer key. Any other
/// kind (written, audio, image, video) is authored in Assessment v2 and linked instead.
class QuickQuestion {
  const QuickQuestion({required this.id, required this.prompt, required this.kind, required this.options, required this.answer});
  final String id;
  final String prompt;

  /// `single` or `multi`.
  final String kind;
  final List<String> options;

  /// One entry for single, one or more for multi.
  final List<String> answer;

  Json toJson() => {'id': id, 'prompt': prompt, 'kind': kind, 'options': options, 'answer': kind == 'multi' ? answer : answer.first};
}

/// What Assessment v2 says about the paper's exam: refreshed by the adapter, read-only here.
class PaperSnapshot {
  const PaperSnapshot({
    required this.name,
    required this.durationMinutes,
    required this.questionCount,
    required this.passThreshold,
    required this.questionTypes,
    required this.proctoring,
  });
  final String name;
  final int durationMinutes;
  final int questionCount;

  /// A fraction; null when the engine has not reported one.
  final double? passThreshold;
  final List<String> questionTypes;
  final Proctoring proctoring;

  factory PaperSnapshot.fromJson(Json m) => PaperSnapshot(
    name: readString(m, 'name'),
    durationMinutes: readInt(m, 'duration_minutes'),
    questionCount: readInt(m, 'question_count'),
    passThreshold: _fractionOf(readDouble(m, 'pass_threshold') ?? readDouble(m, 'pass_mark')),
    questionTypes: readStrings(m, 'question_types'),
    // Assessment v2 calls its proctoring switches `rules`
    proctoring: Proctoring.fromJson(m['rules'] ?? m['proctoring']),
  );
}

/// Assessment v2 states pass thresholds as a percentage (70); Yantra as a fraction (0.7).
double? _fractionOf(double? v) => v == null ? null : (v > 1 ? v / 100 : v);

/// One v2 assessment behind a paper: attempt 1 sits the base, every retake number its own copy.
class PaperCohort {
  const PaperCohort({
    required this.id,
    required this.attemptNo,
    required this.generation,
    required this.engineAssessmentId,
    required this.state,
  });
  final String id;
  final int attemptNo;
  final int generation;
  final String engineAssessmentId;

  /// `draft`, `open`, `closed`.
  final String state;

  factory PaperCohort.fromJson(Json m) => PaperCohort(
    id: readString(m, 'id'),
    attemptNo: readInt(m, 'attempt_no'),
    generation: readInt(m, 'generation'),
    engineAssessmentId: '${m['engine_assessment_id'] ?? ''}',
    state: readString(m, 'state'),
  );
}

class PaperStats {
  const PaperStats({required this.total, required this.passed, required this.passRate, required this.awaitingResult, required this.held});
  final int total;
  final int passed;
  final double? passRate;
  final int awaitingResult;
  final int held;

  factory PaperStats.fromJson(Json m) => PaperStats(
    total: readInt(m, 'total'),
    passed: readInt(m, 'passed'),
    passRate: readDouble(m, 'pass_rate'),
    awaitingResult: readInt(m, 'awaiting_result'),
    held: readInt(m, 'held'),
  );
}

/// A Yantra paper: a gate earned by passing an Assessment v2 exam. Ops see it here; the exam itself (questions,
/// proctoring, marking) lives in the Assessment admin.
class Paper {
  const Paper({
    required this.id,
    required this.gate,
    required this.title,
    required this.description,
    required this.status,
    required this.engine,
    required this.engineBaseId,
    required this.releasePolicy,
    required this.maxAttempts,
    required this.assignedTtlDays,
    required this.snapshot,
    required this.cohorts,
    required this.stats,
    this.createdAt,
  });
  final String id;
  final String gate;
  final String title;
  final String description;

  /// `draft`, `published`, `retired`.
  final String status;

  /// `v2` (or `quiz` for a paper from before Assessment v2, now retired).
  final String engine;

  /// The v2 assessment the paper was built on.
  final String engineBaseId;

  /// `manual` (ops release results) or `auto_objective` (objective-only results release themselves).
  final String releasePolicy;
  final int maxAttempts;
  final int assignedTtlDays;
  final PaperSnapshot snapshot;
  final List<PaperCohort> cohorts;
  final PaperStats stats;
  final DateTime? createdAt;

  bool get isPublished => status == 'published';
  bool get isRetired => status == 'retired';
  bool get autoRelease => releasePolicy == 'auto_objective';

  factory Paper.fromJson(Json m) => Paper(
    id: readString(m, 'id'),
    gate: readString(m, 'gate'),
    title: readString(m, 'title'),
    description: readString(m, 'description'),
    status: readString(m, 'status').isEmpty ? 'draft' : readString(m, 'status'),
    engine: readString(m, 'engine').isEmpty ? 'v2' : readString(m, 'engine'),
    engineBaseId: '${m['engine_assessment_id'] ?? m['engine_base_id'] ?? ''}',
    releasePolicy: readString(m, 'release_policy').isEmpty ? 'manual' : readString(m, 'release_policy'),
    maxAttempts: readInt(m, 'max_attempts'),
    assignedTtlDays: readInt(m, 'assigned_ttl_days'),
    snapshot: PaperSnapshot.fromJson(readMap(m, 'snapshot')),
    cohorts: readObjects(m, 'cohorts').map(PaperCohort.fromJson).toList(),
    stats: PaperStats.fromJson(readMap(m, 'stats')),
    createdAt: readDateTime(m, 'created_at'),
  );
}

/// One attempt at a paper, as ops see it.
class PaperSittingRow {
  const PaperSittingRow({
    required this.id,
    required this.workerId,
    required this.workerName,
    required this.attemptNo,
    required this.status,
    required this.score,
    required this.released,
    required this.heldReason,
    required this.flags,
    this.submittedAt,
  });
  final String id;
  final String workerId;
  final String workerName;
  final int attemptNo;

  /// `assigned`, `in_progress`, `awaiting_result`, `passed`, `failed`, `void`.
  final String status;

  /// A fraction; null before the result is decided.
  final double? score;
  final bool released;
  final String heldReason;

  /// Integrity notes from the exam (`integrity_alert`, `violation_limit_breached`, `score_outlier`, ...).
  final List<String> flags;
  final DateTime? submittedAt;

  bool get awaitingResult => status == 'awaiting_result';

  factory PaperSittingRow.fromJson(Json m) {
    final f = m['flags'];
    return PaperSittingRow(
      id: readString(m, 'id'),
      workerId: readString(m, 'worker_id'),
      workerName: readString(m, 'worker_name'),
      attemptNo: readInt(m, 'attempt_no'),
      status: readString(m, 'status'),
      score: readDouble(m, 'score'),
      released: readBool(m, 'released'),
      heldReason: readString(m, 'held_reason'),
      flags: f is Map
          ? [
              for (final e in f.entries)
                if (e.value == true) '${e.key}',
            ]
          : (f is List ? [for (final x in f) '$x'] : const []),
      submittedAt: readDateTime(m, 'submitted_at'),
    );
  }
}

/// A draft assessment in Assessment v2 that a new paper can be built on.
class EngineAssessment {
  const EngineAssessment({
    required this.id,
    required this.name,
    required this.state,
    required this.questionCount,
    required this.durationMinutes,
  });
  final String id;
  final String name;
  final String state;
  final int questionCount;
  final int durationMinutes;

  factory EngineAssessment.fromJson(Json m) => EngineAssessment(
    id: '${m['id'] ?? ''}',
    name: readString(m, 'name'),
    state: readString(m, 'state'),
    questionCount: readInt(m, 'question_count'),
    durationMinutes: readInt(m, 'duration_minutes'),
  );
}

/// What sits behind a new paper.
sealed class PaperSource {
  const PaperSource();
  Json toJson();
}

/// An assessment already built in Assessment v2 (any question type, SOP-generated, Form Studio, proctoring).
class LinkedAssessment extends PaperSource {
  const LinkedAssessment(this.assessmentId);
  final String assessmentId;

  @override
  Json toJson() => {'kind': 'assessment', 'assessment_id': int.tryParse(assessmentId) ?? assessmentId};
}

/// Single and multiple choice questions typed here; Yantra builds the v2 assessment from them.
class QuickPaper extends PaperSource {
  const QuickPaper({required this.durationMinutes, required this.passMark, required this.questions});
  final int durationMinutes;
  final double passMark;
  final List<QuickQuestion> questions;

  @override
  Json toJson() => {
    'kind': 'quick',
    'duration_minutes': durationMinutes,
    'pass_mark': fraction(passMark),
    'questions': [for (final q in questions) q.toJson()],
  };
}

// ── form inputs ──────────────────────────────────────────────────────────────

/// A fraction as the gateway reads it: four places, as a string like every other decimal.
String fraction(double v) => v.toStringAsFixed(4);

/// The project form. `POST /v1/projects` takes what `ProjectIn` accepts; the rest goes in a PATCH.
class ProjectInput {
  const ProjectInput({
    required this.name,
    required this.currency,
    required this.payloadSchema,
    this.answerSchema,
    this.rubricVersion = 'v1',
    this.marginFloor,
    this.certGate = '',
    this.brief = '',
    this.llmPolicy = '',
    this.sensitive = false,
    this.clientOrgId = '',
    this.status = '',
    this.retentionDays = 180,
  });

  final String name;
  final String currency;
  final Json payloadSchema;
  final Json? answerSchema;
  final String rubricVersion;
  final double? marginFloor;
  final String certGate;
  final String brief;
  final String llmPolicy;
  final bool sensitive;
  final String clientOrgId;
  final String status;

  /// Days after delivery before payloads and answers are purged (1 to 3650).
  final int retentionDays;

  /// What `ProjectIn` accepts on creation.
  Json get createBody => {
    'name': name,
    'currency': currency,
    'payload_schema': payloadSchema,
    'answer_schema': answerSchema,
    'rubric_version': rubricVersion,
    'margin_floor': marginFloor == null ? null : fraction(marginFloor!),
    'cert_gate': certGate.isEmpty ? null : certGate,
    'retention_days': retentionDays,
  };

  /// What creation does not accept and a PATCH right after does; empty when nothing was set.
  Json get createPatchBody => {
    if (brief.isNotEmpty) 'brief': brief,
    if (llmPolicy.isNotEmpty) 'llm_policy': llmPolicy,
    if (sensitive) 'sensitive': true,
    if (clientOrgId.isNotEmpty) 'client_org_id': clientOrgId,
  };

  /// Everything a PATCH may change, for the edit form.
  Json get editBody => {
    'name': name,
    if (status.isNotEmpty) 'status': status,
    'rubric_version': rubricVersion,
    'margin_floor': marginFloor == null ? null : fraction(marginFloor!),
    'cert_gate': certGate.isEmpty ? null : certGate,
    'brief': brief,
    'llm_policy': llmPolicy,
    'sensitive': sensitive,
    'client_org_id': clientOrgId.isEmpty ? null : clientOrgId,
    'answer_schema': answerSchema,
    'retention_days': retentionDays,
  };
}

class BatchInput {
  const BatchInput({
    required this.title,
    this.mode = 'open',
    required this.unitPay,
    required this.unitPrice,
    this.reviewPay = '0',
    this.claimTtlMinutes = 240,
  });
  final String title;
  final String mode;
  final String unitPay;
  final String unitPrice;
  final String reviewPay;
  final int claimTtlMinutes;

  double? get margin => marginOf(unitPrice, unitPay, reviewPay);

  Json toJson() => {
    'title': title,
    'mode': mode,
    'unit_pay': unitPay,
    'unit_price': unitPrice,
    'review_pay': reviewPay,
    'claim_ttl_minutes': claimTtlMinutes,
  };
}

class ListingInput {
  const ListingInput({
    required this.title,
    required this.domain,
    this.summary = '',
    this.description = '',
    required this.payMin,
    required this.payMax,
    this.currency = 'INR',
    this.commitment = 'task_based',
    this.hoursPerWeek = 0,
    this.slotsTotal = 0,
    this.certGate = '',
    this.paperId = '',
    this.requirements = const [],
    this.questions = const [],
    this.llmPolicy = '',
    this.sensitive = false,
    this.closesAt,
    this.askAvailability = false,
  });
  final String title;
  final String domain;
  final String summary;
  final String description;
  final String payMin;
  final String payMax;
  final String currency;
  final String commitment;
  final int hoursPerWeek;
  final int slotsTotal;
  final String certGate;
  final String paperId;
  final List<String> requirements;
  final List<ListingQuestion> questions;
  final String llmPolicy;
  final bool sensitive;
  final DateTime? closesAt;

  /// Adds the availability step (the form is always a step; the paper is one when a paper is chosen).
  final bool askAvailability;

  List<String> get steps => ['form', if (paperId.isNotEmpty) 'paper', if (askAvailability) 'availability'];

  Json toJson() => {
    'title': title,
    'domain': domain,
    'summary': summary,
    'description': description,
    'pay_min': payMin,
    'pay_max': payMax,
    'pay_unit': 'per_unit',
    'currency': currency,
    'commitment': commitment,
    'hours_per_week': hoursPerWeek,
    'slots_total': slotsTotal,
    'cert_gate': certGate.isEmpty ? null : certGate,
    'paper_id': paperId.isEmpty ? null : paperId,
    'requirements': requirements,
    'questions': [for (final q in questions) q.toJson()],
    'llm_policy': llmPolicy,
    'sensitive': sensitive,
    'closes_at': closesAt?.toUtc().toIso8601String(),
    'steps': steps,
  };
}

class PaperInput {
  const PaperInput({
    required this.gate,
    required this.title,
    this.description = '',
    required this.maxAttempts,
    this.releasePolicy = 'manual',
    this.assignedTtlDays = 14,
    required this.source,
  });
  final String gate;
  final String title;
  final String description;
  final int maxAttempts;

  /// `manual` or `auto_objective`.
  final String releasePolicy;
  final int assignedTtlDays;
  final PaperSource source;

  Json toJson() => {
    'gate': gate,
    'title': title,
    'description': description,
    'max_attempts': maxAttempts,
    'release_policy': releasePolicy,
    'assigned_ttl_days': assignedTtlDays,
    'source': source.toJson(),
  };
}
