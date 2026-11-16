import '../core/json.dart';
import 'finance_models.dart';
import 'gateway_client.dart';

/// Calls for the operator's finance pages. Shapes are in docs/PRODUCT.md 5.5 and
/// `services/payout/yantra_payout/router.py`. Mutations take the caller's idempotency key.
class FinanceRepository {
  const FinanceRepository(this.gateway);

  final GatewayClient gateway;

  Future<PayoutOverview> overview() async => PayoutOverview.fromJson(decodeObject((await gateway.get('/v1/payout/overview')).body));

  /// One window by id (a link to it); `GET /v1/payout/windows/{id}`.
  Future<PayWindowRow> window(String id) async => PayWindowRow.fromJson(decodeObject((await gateway.get('/v1/payout/windows/$id')).body));

  Future<List<PayWindowRow>> windows({String? status}) async =>
      decodeObjects((await gateway.get('/v1/payout/windows', query: {'status': ?status})).body).map(PayWindowRow.fromJson).toList();

  Future<List<WindowLineRow>> windowLines(String windowId) async =>
      decodeObjects((await gateway.get('/v1/payout/windows/$windowId/lines')).body).map(WindowLineRow.fromJson).toList();

  Future<PayWindowRow> closeWindow(String currency, {required String key}) async => PayWindowRow.fromJson(
    decodeObject((await gateway.post('/v1/payout/windows/close', idempotencyKey: key, body: {'currency': currency})).body),
  );

  Future<PayWindowRow> approveWindow(String windowId, {required String key}) async =>
      PayWindowRow.fromJson(decodeObject((await gateway.post('/v1/payout/windows/$windowId/approve', idempotencyKey: key)).body));

  /// Queue every payable line of an approved window on the rail (finance); the dispatch job sends them. Above
  /// the per-window cap it is 409 `window_over_cap` unless [overCapReason] is given: the override and its
  /// reason are recorded on the window with the caller.
  Future<PayWindowRow> payWindow(String windowId, {String? overCapReason, required String key}) async => PayWindowRow.fromJson(
    decodeObject(
      (await gateway.post(
        '/v1/payout/windows/$windowId/pay',
        idempotencyKey: key,
        body: overCapReason == null ? null : {'override_cap': true, 'reason': overCapReason},
      )).body,
    ),
  );

  /// Send a failed or returned line again (a new attempt on the rail).
  Future<WindowLineRow> retryLine(String windowId, String lineId, {required String key}) async => WindowLineRow.fromJson(
    decodeObject((await gateway.post('/v1/payout/windows/$windowId/lines/$lineId/retry', idempotencyKey: key)).body),
  );

  /// Give up on a failed line: its earnings return to payable and roll into the next window.
  Future<WindowLineRow> releaseLine(String windowId, String lineId, {required String key}) async => WindowLineRow.fromJson(
    decodeObject((await gateway.post('/v1/payout/windows/$windowId/lines/$lineId/release', idempotencyKey: key)).body),
  );

  /// The NEFT/IMPS bulk file of a window on the file rail: the bytes to save, and the lines left out of it
  /// (worker now held, account gone or changed; back in the queue) from `X-Skipped-Lines`.
  Future<({List<int> bytes, List<(String, String)> skipped})> bankFile(String windowId) async {
    final r = await gateway.get('/v1/payout/windows/$windowId/bank-file', accept: 'text/csv');
    final header = r.headers.entries.where((e) => e.key.toLowerCase() == 'x-skipped-lines').map((e) => e.value).firstOrNull;
    return (bytes: r.bodyBytes, skipped: readSkippedLines(header));
  }

  /// The bank's return file (`reference,status,utr,reason`) settles each line it names.
  Future<ReturnFileResult> uploadReturnFile(String windowId, String csv, {required String key}) async => ReturnFileResult.fromJson(
    decodeObject(
      (await gateway.post(
        '/v1/payout/windows/$windowId/bank-file/reconcile',
        idempotencyKey: key,
        body: RawBody(csv, contentType: 'text/csv'),
      )).body,
    ),
  );

  /// The live check, nothing recorded.
  Future<ReconcileReport> reconcile(String windowId) async =>
      ReconcileReport.fromJson(decodeObject((await gateway.get('/v1/payout/windows/$windowId/reconcile')).body));

  /// A recorded run (finance); the first balanced run of a paid window releases its statements.
  Future<ReconcileReport> recordReconcile(String windowId, {required String key}) async =>
      ReconcileReport.fromJson(decodeObject((await gateway.post('/v1/payout/windows/$windowId/reconcile', idempotencyKey: key)).body));

  Future<List<ReconcileRun>> reconciliationRuns({String? windowId}) async => decodeObjects(
    (await gateway.get('/v1/payout/reconciliation-runs', query: {'window_id': ?windowId})).body,
  ).map(ReconcileRun.fromJson).toList();

  /// The window's statement as CSV bytes (every line for finance and ops); 409 `not_reconciled` before.
  Future<List<int>> statementExport(String windowId) async =>
      (await gateway.get('/v1/payout/statements/$windowId/export', query: {'format': 'csv'}, accept: 'text/csv')).bodyBytes;

  Future<RailState> rail() async => RailState.fromJson(decodeObject((await gateway.get('/v1/payout/rail')).body));

  Future<PayoutAttention> attention() async => PayoutAttention.fromJson(decodeObject((await gateway.get('/v1/payout/attention')).body));

  Future<({int total, List<HeldAccount> items})> heldAccounts({int limit = 50, int offset = 0}) async {
    final m = decodeObject(
      (await gateway.get('/v1/payout/accounts', query: {'held': 'true', 'limit': '$limit', 'offset': '$offset'})).body,
    );
    return (
      total: readInt(m, 'total'),
      items: readList(m, 'items').whereType<Map>().map((e) => HeldAccount.fromJson(Json.from(e))).toList(),
    );
  }

  /// Finance confirms a bank account the penny drop proved without a registered name; never one's own (409
  /// `same_person`), 409 `not_awaiting_confirmation` when it no longer waits.
  Future<void> confirmAccount(String workerId, {required String key}) =>
      gateway.post('/v1/payout/accounts/$workerId/confirm', idempotencyKey: key);

  /// How many accounts wait for finance's confirmation (attention), and the workers among them who have a line
  /// held `account_unconfirmed` in a window not yet paid: there is no list endpoint, so those lines name them.
  Future<({int total, List<String> workerIds})> accountsAwaitingConfirmation() async {
    final total = (await attention()).accountsAwaitingConfirmation;
    if (total == 0) return (total: 0, workerIds: const <String>[]);
    final open = (await windows()).where((w) => !w.isPaid).toList();
    final lines = await Future.wait([for (final w in open) windowLines(w.id)]);
    final ids = {
      for (final l in lines.expand((l) => l))
        if (l.holdReason == 'account_unconfirmed') l.workerId,
    };
    return (total: total, workerIds: ids.toList());
  }

  Future<List<Adjustment>> adjustments({String? status}) async =>
      decodeObjects((await gateway.get('/v1/payout/adjustments', query: {'status': ?status})).body).map(Adjustment.fromJson).toList();

  Future<Adjustment> proposeAdjustment(AdjustmentInput input, {required String key}) async =>
      Adjustment.fromJson(decodeObject((await gateway.post('/v1/payout/adjustments', idempotencyKey: key, body: input.toJson())).body));

  Future<Adjustment> approveAdjustment(String id, {String note = '', required String key}) => _decide(id, 'approve', note, key);

  Future<Adjustment> rejectAdjustment(String id, {String note = '', required String key}) => _decide(id, 'reject', note, key);

  Future<Adjustment> _decide(String id, String verb, String note, String key) async => Adjustment.fromJson(
    decodeObject((await gateway.post('/v1/payout/adjustments/$id/$verb', idempotencyKey: key, body: {'note': note})).body),
  );

  Future<List<MarginRow>> margin() async => decodeObjects((await gateway.get('/v1/payout/margin')).body).map(MarginRow.fromJson).toList();
}
