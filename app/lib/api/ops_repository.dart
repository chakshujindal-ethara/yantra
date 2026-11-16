import '../core/errors.dart';
import '../core/json.dart';
import 'finance_models.dart' as fin;
import 'gateway_client.dart';
import 'ops_models.dart';

/// Calls for the operator console: projects, batches, workers, client orgs, listings, papers, and the
/// quality, payout and notify figures the Overview reads. Shapes are in docs/PRODUCT.md §5. Mutations
/// take the caller's idempotency key.
class OpsRepository {
  const OpsRepository(this.gateway);

  final GatewayClient gateway;

  // ── projects and batches ──────────────────────────────────────────────────

  Future<List<ProjectSummary>> projects() async =>
      decodeObjects((await gateway.get('/v1/projects')).body).map(ProjectSummary.fromJson).toList();

  Future<ProjectDetail> project(String id) async => ProjectDetail.fromJson(decodeObject((await gateway.get('/v1/projects/$id')).body));

  /// `POST /v1/projects` with what creation accepts. The rest (`ProjectInput.createPatchBody`) goes in
  /// a [patchProject] of its own, under its own key, so a failed PATCH never leads to a second POST.
  Future<ProjectDetail> createProject(ProjectInput input, {required String key}) async =>
      ProjectDetail.fromJson(decodeObject((await gateway.post('/v1/projects', idempotencyKey: key, body: input.createBody)).body));

  Future<ProjectDetail> patchProject(String id, Json patch, {required String key}) async =>
      ProjectDetail.fromJson(decodeObject((await gateway.patch('/v1/projects/$id', idempotencyKey: key, body: patch)).body));

  /// An operator's answer on the project's client feedback thread.
  Future<void> sendFeedback(String projectId, String body, {required String key}) async =>
      gateway.post('/v1/projects/$projectId/feedback', idempotencyKey: key, body: {'body': body});

  /// The last [days] days of the project from the analytics marts.
  Future<ProjectTrend> projectTrend(String projectId, {int days = 30}) async =>
      ProjectTrend.fromJson(decodeObject((await gateway.get('/v1/analytics/projects/$projectId/trend', query: {'days': '$days'})).body));

  Future<BatchSummary> batch(String id) async => BatchSummary.fromJson(decodeObject((await gateway.get('/v1/batches/$id')).body));

  /// `PATCH /v1/batches/{id}`: the title and the due date (null clears it).
  Future<BatchSummary> patchBatch(String id, {String? title, DateTime? dueAt, bool clearDue = false, required String key}) async =>
      BatchSummary.fromJson(
        decodeObject(
          (await gateway.patch(
            '/v1/batches/$id',
            idempotencyKey: key,
            body: {'title': ?title, if (dueAt != null || clearDue) 'due_at': dueAt?.toUtc().toIso8601String()},
          )).body,
        ),
      );

  /// Presigned uploads for media files of a draft batch.
  Future<List<MediaUpload>> payloadUploads(
    String batchId,
    List<({String name, String contentType, int size})> files, {
    required String key,
  }) async {
    final m = decodeObject(
      (await gateway.post(
        '/v1/batches/$batchId/payload-uploads',
        idempotencyKey: key,
        body: {
          'files': [
            for (final f in files) {'name': f.name, 'content_type': f.contentType, 'size_bytes': f.size},
          ],
        },
      )).body,
    );
    return readObjects(m, 'uploads').map(MediaUpload.fromJson).toList();
  }

  /// The delivered batch as files; 409 `batch_held` until the manifest exists.
  Future<Deliverable> deliverable(String batchId) async =>
      Deliverable.fromJson(decodeObject((await gateway.get('/v1/batches/$batchId/deliverable')).body));

  Future<BatchSummary> createBatch(String projectId, BatchInput input, {required String key}) async => BatchSummary.fromJson(
    decodeObject((await gateway.post('/v1/projects/$projectId/batches', idempotencyKey: key, body: input.toJson())).body),
  );

  Future<ImportReport> importUnits(String batchId, List<Json> lines, {required bool dryRun, required String key}) async =>
      ImportReport.fromJson(
        decodeObject(
          (await gateway.post(
            '/v1/batches/$batchId/units/import',
            idempotencyKey: key,
            body: {'lines': lines},
            query: {'dry_run': '$dryRun'},
          )).body,
        ),
      );

  Future<BatchSummary> publishBatch(String id, {String? approvedBy, String? note, required String key}) async => BatchSummary.fromJson(
    decodeObject(
      (await gateway.post('/v1/batches/$id/publish', idempotencyKey: key, body: {'approved_by': approvedBy, 'approval_note': note})).body,
    ),
  );

  /// `pause`, `resume` or `cancel`.
  Future<BatchSummary> batchAction(String id, String action, {required String key}) async =>
      BatchSummary.fromJson(decodeObject((await gateway.post('/v1/batches/$id/$action', idempotencyKey: key)).body));

  Future<ListPage<UnitRow>> units(String batchId, {String? status, int limit = 50, int offset = 0}) async => ListPage.fromJson(
    decodeObject(
      (await gateway.get(
        '/v1/batches/$batchId/units',
        query: {if (status != null && status.isNotEmpty) 'status': status, 'limit': '$limit', 'offset': '$offset'},
      )).body,
    ),
    UnitRow.fromJson,
  );

  /// An available unit waiting for its one assigned worker goes back to the pool, signed by the caller.
  /// 409 `unit_not_assigned`; 409 `assignment_required` in an assigned-mode batch (it has no pool).
  Future<void> unassignUnit(String unitId, {required String key}) => gateway.post('/v1/units/$unitId/unassign', idempotencyKey: key);

  /// The delivery gate: a 409 `batch_held` (with "N units still open") propagates until every unit is accepted.
  Future<Manifest> manifest(String batchId) async =>
      Manifest.fromJson(decodeObject((await gateway.get('/v1/batches/$batchId/manifest')).body));

  Future<List<ClientOrg>> clientOrgs() async => decodeObjects((await gateway.get('/v1/client-orgs')).body).map(ClientOrg.fromJson).toList();

  // ── workers ───────────────────────────────────────────────────────────────

  Future<ListPage<WorkerRow>> workers({String? status, String? gate, String? q, int limit = 50, int offset = 0}) async => ListPage.fromJson(
    decodeObject(
      (await gateway.get(
        '/v1/workers',
        query: {
          if (status != null && status.isNotEmpty) 'status': status,
          if (gate != null && gate.isNotEmpty) 'gate': gate,
          if (q != null && q.isNotEmpty) 'q': q,
          'limit': '$limit',
          'offset': '$offset',
        },
      )).body,
    ),
    WorkerRow.fromJson,
  );

  /// One worker. Market answers 404 not_found for someone payout or tracker knows but Odoo has not sent yet; that
  /// worker reads as `unknown` (as `/v1/workers/me` does), and a PUT creates the record.
  Future<WorkerRow> worker(String id) async {
    try {
      return WorkerRow.fromJson(decodeObject((await gateway.get('/v1/workers/$id')).body));
    } on ApiException catch (e) {
      if (e.status == 404 && e.code == 'not_found') return WorkerRow.fromJson({'id': id, 'status': 'unknown'});
      rethrow;
    }
  }

  /// `PUT /v1/workers/{id}` per `WorkerIn`: the whole record, every time.
  Future<WorkerRow> putWorker(
    String id, {
    required String status,
    required List<String> certGates,
    int? partnerRef,
    required String key,
  }) async => WorkerRow.fromJson(
    decodeObject(
      (await gateway.put(
        '/v1/workers/$id',
        idempotencyKey: key,
        body: {'status': status, 'cert_gates': certGates, 'partner_ref': partnerRef},
      )).body,
    ),
  );

  Future<PayoutAccount> payoutAccount(String workerId) async =>
      PayoutAccount.fromJson(decodeObject((await gateway.get('/v1/payout/accounts/$workerId')).body));

  /// `PUT /v1/payout/accounts/{id}/hold` per `HoldIn`; a null reason lifts the hold.
  Future<PayoutAccount> setHold(String workerId, {String? reason, DateTime? until, required String key}) async {
    final r = await gateway.put(
      '/v1/payout/accounts/$workerId/hold',
      idempotencyKey: key,
      body: {'reason': reason, 'until': until?.toUtc().toIso8601String()},
    );
    // HoldIn answers with the bare account; wrap it the way the account read does.
    final m = decodeObject(r.body);
    return PayoutAccount.fromJson(m.containsKey('account') ? m : {'account': m, 'totals': const {}});
  }

  Future<List<WorkerDocument>> documents(String workerId) async =>
      decodeObjects((await gateway.get('/v1/talent/workers/$workerId/documents')).body).map(WorkerDocument.fromJson).toList();

  /// A five-minute link to one document, for an operator checking identity.
  Future<String> documentUrl(String workerId, String kind) async =>
      readString(decodeObject((await gateway.get('/v1/talent/workers/$workerId/documents/$kind/url')).body), 'url');

  Future<ReviewerProfile> reviewer(String workerId) async =>
      ReviewerProfile.fromJson(decodeObject((await gateway.get('/v1/quality/reviewers/$workerId')).body));

  Future<ReviewerProfile> setSensitiveCleared(String workerId, bool cleared, {required String key}) async => ReviewerProfile.fromJson(
    decodeObject((await gateway.put('/v1/quality/reviewers/$workerId', idempotencyKey: key, body: {'sensitive_cleared': cleared})).body),
  );

  Future<List<TrackerSession>> trackerSessions(String workerId, {int limit = 20}) async => decodeObjects(
    (await gateway.get('/v1/tracker/sessions', query: {'worker_id': workerId, 'limit': '$limit'})).body,
  ).map(TrackerSession.fromJson).toList();

  Future<List<Anomaly>> anomalies({String? status}) async =>
      decodeObjects((await gateway.get('/v1/tracker/anomalies', query: {'status': ?status})).body).map(Anomaly.fromJson).toList();

  /// [outcome] is `dismiss` or `uphold`; upholding holds the worker's payouts.
  Future<Anomaly> decideAnomaly(String id, String outcome, {String note = '', required String key}) async => Anomaly.fromJson(
    decodeObject((await gateway.post('/v1/tracker/anomalies/$id/$outcome', idempotencyKey: key, body: {'note': note})).body),
  );

  // ── listings and applications ─────────────────────────────────────────────

  Future<List<Listing>> listings() async =>
      decodeObjects((await gateway.get('/v1/talent/listings', query: {'all': 'true'})).body).map(Listing.fromJson).toList();

  /// One listing. The single read is the worker's (closed listings 404 there), so a miss falls back to the
  /// full ops list.
  Future<Listing> listing(String id) async {
    try {
      return Listing.fromJson(decodeObject((await gateway.get('/v1/talent/listings/$id')).body));
    } on ApiException catch (e) {
      if (e.status != 404) rethrow;
      final all = await listings();
      return all.firstWhere((l) => l.id == id, orElse: () => throw e);
    }
  }

  Future<Listing> createListing(ListingInput input, {required String key}) async =>
      Listing.fromJson(decodeObject((await gateway.post('/v1/talent/listings', idempotencyKey: key, body: input.toJson())).body));

  Future<Listing> patchListing(String id, Json patch, {required String key}) async =>
      Listing.fromJson(decodeObject((await gateway.patch('/v1/talent/listings/$id', idempotencyKey: key, body: patch)).body));

  Future<List<Application>> applications(String listingId, {String? status}) async => decodeObjects(
    (await gateway.get(
      '/v1/talent/listings/$listingId/applications',
      query: {if (status != null && status.isNotEmpty) 'status': status},
    )).body,
  ).map(Application.fromJson).toList();

  Future<Application> decide(
    String applicationId, {
    required String decision,
    String note = '',
    int? offerDays,
    required String key,
  }) async => Application.fromJson(
    decodeObject(
      (await gateway.post(
        '/v1/talent/applications/$applicationId/decide',
        idempotencyKey: key,
        body: {'decision': decision, 'note': note, 'offer_days': ?offerDays},
      )).body,
    ),
  );

  // ── papers ────────────────────────────────────────────────────────────────

  Future<List<Paper>> papers() async => decodeObjects((await gateway.get('/v1/assess/papers')).body).map(Paper.fromJson).toList();

  Future<Paper> paper(String id) async => Paper.fromJson(decodeObject((await gateway.get('/v1/assess/papers/$id')).body));

  Future<Paper> createPaper(PaperInput input, {required String key}) async =>
      Paper.fromJson(decodeObject((await gateway.post('/v1/assess/papers', idempotencyKey: key, body: input.toJson())).body));

  Future<Paper> publishPaper(String id, {required String key}) async =>
      Paper.fromJson(decodeObject((await gateway.post('/v1/assess/papers/$id/publish', idempotencyKey: key)).body));

  /// Every attempt at the paper: worker, attempt number, status, score, released, held reason, flags.
  Future<List<PaperSittingRow>> paperSittings(String id) async =>
      decodeObjects((await gateway.get('/v1/assess/papers/$id/sittings')).body).map(PaperSittingRow.fromJson).toList();

  /// Releases the decided results of [sittingIds], or of every sitting waiting for release when empty.
  /// Returns how many were released.
  Future<int> releasePaper(String id, {List<String> sittingIds = const [], required String key}) async {
    // no ids: every sitting of this paper waiting for release
    final body = sittingIds.isEmpty ? <String, Object>{} : <String, Object>{'sitting_ids': sittingIds};
    final res = decodeObject((await gateway.post('/v1/assess/papers/$id/release', idempotencyKey: key, body: body)).body);
    return readInt(res, 'released');
  }

  /// Closes the paper's open cohorts: the next attempt draws a new set of questions.
  Future<Paper> rotatePaper(String id, {required String key}) async =>
      Paper.fromJson(decodeObject((await gateway.post('/v1/assess/papers/$id/rotate', idempotencyKey: key)).body));

  /// Reads the latest attempts from Assessment v2 now instead of at the next 15-second pass.
  Future<void> syncAssess({required String key}) async => gateway.post('/v1/assess/sync', idempotencyKey: key);

  /// Assessments built in Assessment v2 that a paper can be linked to.
  Future<List<EngineAssessment>> engineAssessments({String state = 'draft'}) async => decodeObjects(
    (await gateway.get('/v1/assess/engine/assessments?state=${Uri.encodeQueryComponent(state)}')).body,
  ).map(EngineAssessment.fromJson).toList();

  // ── overview ──────────────────────────────────────────────────────────────

  /// The ops home. Projects must answer; every other figure comes from a module that may still be empty
  /// (404) and then reads as null. Two attention calls (work and money) replace counting whole lists.
  Future<OpsOverview> overview() async {
    // Every call runs at once; the page waits for all of them so a failing one never leaks an
    // unhandled error while the others are still in flight.
    final results = await Future.wait<Object?>([
      projects(),
      _optional(() async => QualityStats.fromJson(decodeObject((await gateway.get('/v1/quality/stats')).body))),
      _optional(() async => PayoutOverview.fromJson(decodeObject((await gateway.get('/v1/payout/overview')).body))),
      _optional(() async => WorkAttention.fromJson(decodeObject((await gateway.get('/v1/attention')).body))),
      _optional(() async => fin.PayoutAttention.fromJson(decodeObject((await gateway.get('/v1/payout/attention')).body))),
      _optional(workersSummary),
    ], eagerError: false);
    return OpsOverview(
      projects: results[0] as List<ProjectSummary>,
      stats: results[1] as QualityStats?,
      payout: results[2] as PayoutOverview?,
      attention: results[3] as WorkAttention?,
      payoutAttention: results[4] as fin.PayoutAttention?,
      bench: results[5] as WorkersSummary?,
    );
  }

  Future<WorkersSummary> workersSummary() async => WorkersSummary.fromJson(decodeObject((await gateway.get('/v1/workers/summary')).body));

  static Future<T?> _optional<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }
}
