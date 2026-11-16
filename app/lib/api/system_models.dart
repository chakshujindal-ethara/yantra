import '../core/json.dart';

/// Wire shapes of the System page: stuck work (`/v1/claims/...`, `/v1/quality/reviews/...`), dead letters
/// and jobs (`/v1/<module>/dead-letters`, `/v1/<module>/jobs`). A missing field is empty, never a throw.

String? _maybe(Json m, String key) => m[key] == null ? null : '${m[key]}';

/// Every module with dead letters and jobs, in the order the System page lists them.
const systemModules = ['market', 'talent', 'assess', 'quality', 'notify', 'tracker', 'analytics', 'payout'];

/// A claim past its time that nobody has released yet.
class ExpiredClaim {
  const ExpiredClaim({
    required this.claimId,
    required this.unitId,
    required this.externalRef,
    required this.batchId,
    required this.batchTitle,
    required this.projectId,
    required this.projectName,
    required this.workerId,
    required this.workerName,
    required this.minutesOverdue,
    this.expiresAt,
  });

  final String claimId;
  final String unitId;
  final String externalRef;
  final String batchId;
  final String batchTitle;
  final String projectId;
  final String projectName;
  final String workerId;
  final String workerName;
  final int minutesOverdue;
  final DateTime? expiresAt;

  factory ExpiredClaim.fromJson(Json m) => ExpiredClaim(
    claimId: readString(m, 'claim_id'),
    unitId: readString(m, 'unit_id'),
    externalRef: readString(m, 'external_ref'),
    batchId: readString(m, 'batch_id'),
    batchTitle: readString(m, 'batch_title'),
    projectId: readString(m, 'project_id'),
    projectName: readString(m, 'project_name'),
    workerId: readString(m, 'worker_id'),
    workerName: readString(m, 'worker_name'),
    minutesOverdue: readInt(m, 'minutes_overdue'),
    expiresAt: readDateTime(m, 'expires_at'),
  );
}

/// An available unit waiting days for the one worker it is assigned to (a rework author who left, is held
/// or paused): `GET /v1/units/stuck-assigned`.
class StuckAssignedUnit {
  const StuckAssignedUnit({
    required this.unitId,
    required this.externalRef,
    required this.batchId,
    required this.batchTitle,
    required this.projectId,
    required this.projectName,
    required this.workerId,
    required this.workerName,
    required this.daysWaiting,
    this.assignedAt,
  });

  final String unitId;
  final String externalRef;
  final String batchId;
  final String batchTitle;
  final String projectId;
  final String projectName;
  final String workerId;
  final String workerName;
  final int daysWaiting;
  final DateTime? assignedAt;

  factory StuckAssignedUnit.fromJson(Json m) => StuckAssignedUnit(
    unitId: readString(m, 'unit_id'),
    externalRef: readString(m, 'external_ref'),
    batchId: readString(m, 'batch_id'),
    batchTitle: readString(m, 'batch_title'),
    projectId: readString(m, 'project_id'),
    projectName: readString(m, 'project_name'),
    workerId: readString(m, 'worker_id'),
    workerName: readString(m, 'worker_name'),
    daysWaiting: readInt(m, 'days_waiting'),
    assignedAt: readDateTime(m, 'assigned_at'),
  );
}

/// A review or audit claim past its time.
class ExpiredReview {
  const ExpiredReview({
    required this.taskId,
    required this.unitId,
    required this.batchId,
    required this.kind,
    required this.holderId,
    required this.minutesOverdue,
    this.expiresAt,
  });

  final String taskId;
  final String unitId;
  final String batchId;

  /// `review` or `audit`.
  final String kind;
  final String holderId;
  final int minutesOverdue;
  final DateTime? expiresAt;

  factory ExpiredReview.fromJson(Json m) => ExpiredReview(
    taskId: readString(m, 'task_id'),
    unitId: readString(m, 'unit_id'),
    batchId: readString(m, 'batch_id'),
    kind: readString(m, 'kind'),
    holderId: readString(m, 'holder_id'),
    minutesOverdue: readInt(m, 'minutes_overdue'),
    expiresAt: readDateTime(m, 'claim_expires_at'),
  );
}

/// A claim (work or review) that ended without an answer, from the release history. [releasedBy] empty is
/// the expiry job; [byHolder] is the person giving it back.
class Released {
  const Released({
    required this.id,
    required this.kind,
    required this.holderId,
    required this.holderName,
    required this.releasedBy,
    required this.releasedByName,
    required this.byHolder,
    this.releasedAt,
  });

  final String id;

  /// `claim`, `review` or `audit`.
  final String kind;
  final String holderId;
  final String holderName;
  final String releasedBy;
  final String releasedByName;
  final bool byHolder;
  final DateTime? releasedAt;

  bool get byJob => releasedBy.isEmpty && !byHolder;

  factory Released.claim(Json m) => Released(
    id: readString(m, 'claim_id'),
    kind: 'claim',
    holderId: readString(m, 'worker_id'),
    holderName: readString(m, 'worker_name'),
    releasedBy: readString(m, 'released_by'),
    releasedByName: readString(m, 'released_by_name'),
    byHolder: readString(m, 'status') == 'released',
    releasedAt: readDateTime(m, 'released_at'),
  );

  factory Released.review(Json m) => Released(
    id: readString(m, 'task_id'),
    kind: readString(m, 'kind').isEmpty ? 'review' : readString(m, 'kind'),
    holderId: readString(m, 'holder_id'),
    holderName: '',
    releasedBy: readString(m, 'released_by'),
    releasedByName: '',
    byHolder: readString(m, 'reason') == 'holder',
    releasedAt: readDateTime(m, 'released_at'),
  );
}

/// A message a consumer gave up on after its deliveries ran out.
class DeadLetter {
  const DeadLetter({
    required this.id,
    required this.consumer,
    required this.deliveries,
    required this.reason,
    this.type,
    this.subject,
    this.deadAt,
  });

  final String id;
  final String consumer;
  final String? type;
  final String? subject;
  final int deliveries;
  final String reason;
  final DateTime? deadAt;

  factory DeadLetter.fromJson(Json m) => DeadLetter(
    id: readString(m, 'id'),
    consumer: readString(m, 'consumer'),
    type: _maybe(m, 'type'),
    subject: _maybe(m, 'subject'),
    deliveries: readInt(m, 'deliveries'),
    reason: readString(m, 'reason'),
    deadAt: readDateTime(m, 'dead_at'),
  );
}

/// One scheduled job of a module: when it runs next, how the last run went.
class JobRow {
  const JobRow({
    required this.name,
    this.nextRunAt,
    this.lastRunAt,
    this.lastFinishedAt,
    this.lastResult,
    this.lastError,
    this.lockedUntil,
  });

  final String name;
  final DateTime? nextRunAt;
  final DateTime? lastRunAt;
  final DateTime? lastFinishedAt;
  final int? lastResult;
  final String? lastError;
  final DateTime? lockedUntil;

  /// Due more than five minutes ago and not running: the scheduler is behind or stopped.
  bool overdue(DateTime now) {
    final next = nextRunAt;
    final running = lockedUntil != null && lockedUntil!.isAfter(now);
    return next != null && !running && now.difference(next) > const Duration(minutes: 5);
  }

  factory JobRow.fromJson(Json m) => JobRow(
    name: readString(m, 'name'),
    nextRunAt: readDateTime(m, 'next_run_at'),
    lastRunAt: readDateTime(m, 'last_run_at'),
    lastFinishedAt: readDateTime(m, 'last_finished_at'),
    lastResult: m['last_result'] is int ? m['last_result'] as int : null,
    lastError: _maybe(m, 'last_error'),
    lockedUntil: readDateTime(m, 'locked_until'),
  );
}

/// A module's dead letters, or why they could not be read.
class ModuleDead {
  const ModuleDead(this.module, this.letters, {this.error});
  final String module;
  final List<DeadLetter> letters;
  final String? error;
}

/// A module's jobs, or why they could not be read.
class ModuleJobs {
  const ModuleJobs(this.module, this.jobs, {this.error});
  final String module;
  final List<JobRow> jobs;
  final String? error;
}
