import '../core/json.dart';

/// Wire shapes of the operator's quality pages (docs/PRODUCT.md 5.4 and the quality router). Read with
/// type tests: a missing field is empty, never a throw.

double _double(Json m, String key) {
  final v = m[key];
  return v is num ? v.toDouble() : (v is String ? double.tryParse(v) ?? 0 : 0);
}

/// `0.83` or `83` both read as 83 percent.
int percentOf(double v) => (v <= 1 ? v * 100 : v).round();

/// A reviewer's "the rubric is unclear here" note, waiting for an answer.
class QualityFlag {
  const QualityFlag({
    required this.id,
    required this.taskId,
    required this.batchId,
    required this.reviewerId,
    required this.note,
    required this.answer,
    this.answeredAt,
    this.createdAt,
    this.overdue = false,
  });

  final String id;
  final String taskId;
  final String batchId;
  final String reviewerId;
  final String note;
  final String answer;
  final DateTime? answeredAt;
  final DateTime? createdAt;

  /// Unanswered past the two-day answer the plan promises reviewers.
  final bool overdue;

  factory QualityFlag.fromJson(Json m) => QualityFlag(
    id: readString(m, 'id'),
    taskId: readString(m, 'task_id'),
    batchId: readString(m, 'batch_id'),
    reviewerId: readString(m, 'reviewer_id'),
    note: readString(m, 'note'),
    answer: readString(m, 'answer'),
    answeredAt: readDateTime(m, 'answered_at'),
    createdAt: readDateTime(m, 'created_at'),
    overdue: readBool(m, 'overdue'),
  );
}

/// An open dispute as ops see it: the worker's reason beside the verdict they contest.
class DisputeQueueItem {
  const DisputeQueueItem({
    required this.id,
    required this.status,
    required this.reason,
    required this.answer,
    required this.taskId,
    required this.unitId,
    required this.batchId,
    required this.workerId,
    required this.verdict,
    required this.reasonCode,
    required this.resolvedBy,
    this.createdAt,
    this.resolvedAt,
  });

  final String id;

  /// `open`, `upheld` or `dismissed`.
  final String status;
  final String reason;
  final String answer;
  final String taskId;
  final String unitId;
  final String batchId;
  final String workerId;
  final String verdict;
  final String reasonCode;
  final String resolvedBy;
  final DateTime? createdAt;
  final DateTime? resolvedAt;

  factory DisputeQueueItem.fromJson(Json m) => DisputeQueueItem(
    id: readString(m, 'id'),
    status: readString(m, 'status'),
    reason: readString(m, 'reason'),
    answer: readString(m, 'answer'),
    taskId: readString(m, 'task_id'),
    unitId: readString(m, 'unit_id'),
    batchId: readString(m, 'batch_id'),
    workerId: readString(m, 'worker_id'),
    verdict: readString(m, 'verdict'),
    reasonCode: readString(m, 'reason_code'),
    resolvedBy: readString(m, 'resolved_by'),
    createdAt: readDateTime(m, 'created_at'),
    resolvedAt: readDateTime(m, 'resolved_at'),
  );
}

/// A reason code's count in a distribution, and whether that reason bills the client.
class ReasonCount {
  const ReasonCount({required this.reasonCode, required this.count, required this.billable});

  final String reasonCode;
  final int count;
  final bool billable;

  factory ReasonCount.fromJson(Json m) =>
      ReasonCount(reasonCode: readString(m, 'reason_code'), count: readInt(m, 'count'), billable: readBool(m, 'billable'));
}

/// The queue's numbers (`GET /v1/quality/stats`).
class QualityStats {
  const QualityStats({
    required this.pending,
    required this.claimed,
    required this.inAudit,
    required this.canonical,
    required this.accepted,
    required this.rejected,
    required this.needsEdits,
    required this.acceptanceRate,
    required this.auditDisagreements,
    required this.reasons,
    this.oldestPendingAt,
  });

  final int pending;
  final int claimed;
  final int inAudit;
  final int canonical;
  final int accepted;
  final int rejected;
  final int needsEdits;

  /// A fraction (`0.83`) or a percentage (`83`); see [acceptancePercent].
  final double acceptanceRate;
  final int auditDisagreements;
  final List<ReasonCount> reasons;
  final DateTime? oldestPendingAt;

  int get acceptancePercent => percentOf(acceptanceRate);
  bool get isEmpty => pending + claimed + inAudit + canonical == 0 && reasons.isEmpty;

  factory QualityStats.fromJson(Json m) => QualityStats(
    pending: readInt(m, 'pending'),
    claimed: readInt(m, 'claimed'),
    inAudit: readInt(m, 'in_audit'),
    canonical: readInt(m, 'canonical'),
    accepted: readInt(m, 'accepted'),
    rejected: readInt(m, 'rejected'),
    needsEdits: readInt(m, 'needs_edits'),
    acceptanceRate: _double(m, 'acceptance_rate'),
    auditDisagreements: readInt(m, 'audit_disagreements'),
    reasons: readList(m, 'reasons').whereType<Map>().map((x) => ReasonCount.fromJson(Map<String, dynamic>.from(x))).toList(),
    oldestPendingAt: readDateTime(m, 'oldest_pending_at'),
  );
}

/// One review task in the queue table.
class QualityTaskRow {
  const QualityTaskRow({
    required this.id,
    required this.unitId,
    required this.batchId,
    required this.workerId,
    required this.status,
    required this.reviewerId,
    required this.canonicalVerdict,
    this.createdAt,
    this.canonicalAt,
  });

  final String id;
  final String unitId;
  final String batchId;
  final String workerId;

  /// `pending`, `claimed`, `audit_pending`, `audit_claimed`, `canonical`.
  final String status;
  final String reviewerId;
  final String canonicalVerdict;
  final DateTime? createdAt;
  final DateTime? canonicalAt;

  factory QualityTaskRow.fromJson(Json m) => QualityTaskRow(
    id: readString(m, 'id'),
    unitId: readString(m, 'unit_id'),
    batchId: readString(m, 'batch_id'),
    workerId: readString(m, 'worker_id'),
    status: readString(m, 'status'),
    reviewerId: readString(m, 'reviewer_id'),
    canonicalVerdict: readString(m, 'canonical_verdict'),
    createdAt: readDateTime(m, 'created_at'),
    canonicalAt: readDateTime(m, 'canonical_at'),
  );
}

/// A page of the tasks table: `{total, items}`.
class QualityTaskPage {
  const QualityTaskPage({required this.total, required this.items});

  final int total;
  final List<QualityTaskRow> items;

  factory QualityTaskPage.fromJson(Json m) => QualityTaskPage(
    total: readInt(m, 'total'),
    items: readList(m, 'items').whereType<Map>().map((x) => QualityTaskRow.fromJson(Map<String, dynamic>.from(x))).toList(),
  );
}
