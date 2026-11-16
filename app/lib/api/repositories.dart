import '../core/errors.dart';
import '../core/json.dart';
import 'gateway_client.dart';
import 'models.dart';
import 'talent_models.dart' show BankAccount;

/// Thin typed wrappers over the gateway paths. Mutations take the caller's idempotency key.
class WorkRepository {
  const WorkRepository(this._gateway);
  final GatewayClient _gateway;

  Future<List<Batch>> openBatches() async => decodeObjects((await _gateway.get('/v1/batches')).body).map(Batch.fromJson).toList();

  Future<ActiveWork> activeWork() async => ActiveWork.fromJson(decodeObject((await _gateway.get('/v1/claims/active')).body));

  Future<Claim> claim(String batchId, {required String key}) async =>
      Claim.fromJson(decodeObject((await _gateway.post('/v1/batches/$batchId/claims', idempotencyKey: key)).body));

  Future<Unit> unit(String unitId) async => Unit.fromJson(decodeObject((await _gateway.get('/v1/units/$unitId')).body));

  /// A five-minute link to the unit's stored media (`audio_ref`), for the claim holder.
  Future<String> payloadUrl(String unitId) async =>
      readString(decodeObject((await _gateway.get('/v1/units/$unitId/payload-url')).body), 'url');

  Future<Submission> submit(String claimId, Json answer, {required String key}) async => Submission.fromJson(
    decodeObject((await _gateway.post('/v1/claims/$claimId/submission', idempotencyKey: key, body: {'answer': answer})).body),
  );

  /// Gives the worker's own live claim back: the unit returns to the pool. 409 `claim_not_live` when the
  /// claim was submitted, released or expired meanwhile.
  Future<void> release(String claimId, {required String key}) async {
    await _gateway.post('/v1/claims/$claimId/release', idempotencyKey: key);
  }

  Future<WorkerMe> me() async => WorkerMe.fromJson(decodeObject((await _gateway.get('/v1/workers/me')).body));

  Future<Availability> setAvailability(Availability a, {required String key}) async =>
      Availability.fromJson(decodeObject((await _gateway.put('/v1/workers/me/availability', idempotencyKey: key, body: a.toJson())).body));
}

class ReviewRepository {
  const ReviewRepository(this._gateway);
  final GatewayClient _gateway;

  /// The next review task, or none when nothing waits for this reviewer (404). The 404 may say how many
  /// tasks wait for a certification or a sensitive-content clearance the reviewer lacks. A 409
  /// propagates: `one_live_review` means the caller still holds a task (see [activeReview]).
  Future<ReviewClaim> claimReview({required String key, String kind = 'review'}) async {
    try {
      final r = await _gateway.post('/v1/quality/reviews/claim', idempotencyKey: key, query: {'kind': kind});
      return ReviewClaim(task: ReviewTask.fromJson(decodeObject(r.body)));
    } on ApiException catch (e) {
      if (e.status != 404) rethrow;
      int count(String k) => switch (e.context[k]) {
        final int n => n,
        final String v => int.tryParse(v) ?? 0,
        _ => 0,
      };
      return ReviewClaim(waitingForGate: count('waiting_for_gate'), waitingForClearance: count('waiting_for_clearance'));
    }
  }

  /// The reason codes reviewers pick from (`GET /v1/quality/reasons`): label, whether it is billable
  /// rework, which verdicts it applies to.
  Future<List<ReasonCode>> reasons() async =>
      decodeObjects((await _gateway.get('/v1/quality/reasons')).body).map(ReasonCode.fromJson).where((r) => r.code.isNotEmpty).toList();

  /// The task the caller currently holds (claimed or audit_claimed), or null when there is none (404).
  Future<ReviewTaskDetail?> activeReview() async {
    try {
      return ReviewTaskDetail.fromJson(decodeObject((await _gateway.get('/v1/quality/reviews/active')).body));
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  Future<ReviewTaskDetail> task(String taskId) async =>
      ReviewTaskDetail.fromJson(decodeObject((await _gateway.get('/v1/quality/tasks/$taskId')).body));

  /// A five-minute link to the task's stored media, for the reviewer holding it.
  Future<String> taskPayloadUrl(String taskId) async =>
      readString(decodeObject((await _gateway.get('/v1/quality/tasks/$taskId/payload-url')).body), 'url');

  Future<ReviewTask> record(String taskId, ReviewInput input, {required String key}) async => ReviewTask.fromJson(
    decodeObject((await _gateway.post('/v1/quality/tasks/$taskId/review', idempotencyKey: key, body: input.toJson())).body),
  );

  Future<List<MyWorkItem>> myWork() async =>
      decodeObjects((await _gateway.get('/v1/quality/my-work')).body).map(MyWorkItem.fromJson).toList();

  Future<Dispute> dispute(String taskId, String reason, {required String key}) async => Dispute.fromJson(
    decodeObject((await _gateway.post('/v1/quality/tasks/$taskId/dispute', idempotencyKey: key, body: {'reason': reason})).body),
  );
}

class PayoutRepository {
  const PayoutRepository(this._gateway);
  final GatewayClient _gateway;

  Future<Statement> statement() async => Statement.fromJson(decodeObject((await _gateway.get('/v1/payout/statement')).body));

  /// The bank account payouts go to, or null when none is registered yet (404).
  Future<BankAccount?> bankAccount() async {
    try {
      return BankAccount.fromJson(decodeObject((await _gateway.get('/v1/payout/accounts/me')).body));
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  /// Registers (or replaces) the account and starts the penny drop; the answer is usually `verifying`.
  Future<BankAccount> registerBank({required String name, required String number, required String ifsc, required String key}) async =>
      BankAccount.fromJson(
        decodeObject(
          (await _gateway.put(
            '/v1/payout/accounts/me',
            idempotencyKey: key,
            body: {'account_name': name, 'account_number': number, 'ifsc': ifsc},
          )).body,
        ),
      );

  /// One window's statement as CSV, once the window reconciled (409 `not_reconciled` before).
  Future<List<int>> statementCsv(String windowId) async =>
      (await _gateway.get('/v1/payout/statements/$windowId/export', query: {'format': 'csv'}, accept: 'text/csv')).bodyBytes;
}

class NotifyRepository {
  const NotifyRepository(this._gateway);
  final GatewayClient _gateway;

  Future<List<InboxItem>> inbox() async => decodeObjects((await _gateway.get('/v1/notify/inbox')).body).map(InboxItem.fromJson).toList();

  Future<InboxItem> markRead(String id, {required String key}) async =>
      InboxItem.fromJson(decodeObject((await _gateway.post('/v1/notify/inbox/$id/read', idempotencyKey: key)).body));

  /// How many inbox items are unread; the shell's bell polls it.
  Future<int> unreadCount() async => readInt(decodeObject((await _gateway.get('/v1/notify/inbox/unread-count')).body), 'unread');

  /// The worker's notification channel. notify keeps none until the first address is saved and answers 404
  /// not_found: that is an empty channel ("not set"), not a failure.
  Future<Channel> channel() async {
    try {
      return Channel.fromJson(decodeObject((await _gateway.get('/v1/notify/channel')).body));
    } on ApiException catch (e) {
      if (e.status == 404 && e.code == 'not_found') return Channel.fromJson(const {'email': ''});
      rethrow;
    }
  }

  /// A new address waits as `pending_email` and is mailed a code; the same address again sends a new code.
  Future<Channel> setEmail(String email, {required String key}) async =>
      Channel.fromJson(decodeObject((await _gateway.put('/v1/notify/channel', idempotencyKey: key, body: {'email': email})).body));

  /// The six-digit code mailed to the pending address; on success that address becomes `email`.
  Future<Channel> verifyEmail(String code, {required String key}) async =>
      Channel.fromJson(decodeObject((await _gateway.post('/v1/notify/channel/verify', idempotencyKey: key, body: {'code': code})).body));
}
