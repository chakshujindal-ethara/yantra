import '../core/json.dart';
import 'gateway_client.dart';
import 'quality_ops_models.dart';

/// Calls for the operator's quality pages: flags, disputes, the queue. Shapes are in docs/PRODUCT.md 5.4
/// and `services/quality/yantra_quality/router.py`. Mutations take the caller's idempotency key.
class QualityOpsRepository {
  const QualityOpsRepository(this.gateway);

  final GatewayClient gateway;

  Future<List<QualityFlag>> flags() async =>
      decodeObjects((await gateway.get('/v1/quality/flags')).body).map(QualityFlag.fromJson).toList();

  Future<QualityFlag> answerFlag(String flagId, String answer, {required String key}) async => QualityFlag.fromJson(
    decodeObject((await gateway.post('/v1/quality/flags/$flagId/answer', idempotencyKey: key, body: {'answer': answer})).body),
  );

  Future<List<DisputeQueueItem>> disputes() async =>
      decodeObjects((await gateway.get('/v1/quality/disputes')).body).map(DisputeQueueItem.fromJson).toList();

  /// [outcome] is `upheld` (the worker was right) or `dismissed` (the verdict stands); [answer] is the note.
  Future<DisputeQueueItem> resolveDispute(String disputeId, {required String outcome, required String answer, required String key}) async =>
      DisputeQueueItem.fromJson(
        decodeObject(
          (await gateway.post(
            '/v1/quality/disputes/$disputeId/resolve',
            idempotencyKey: key,
            body: {'outcome': outcome, 'answer': answer},
          )).body,
        ),
      );

  Future<QualityStats> stats({String? batchId}) async =>
      QualityStats.fromJson(decodeObject((await gateway.get('/v1/quality/stats', query: {'batch_id': ?batchId})).body));

  Future<QualityTaskPage> tasks({String? status, String? batchId, int limit = 50, int offset = 0}) async => QualityTaskPage.fromJson(
    decodeObject(
      (await gateway.get(
        '/v1/quality/tasks',
        query: {'status': ?status, 'batch_id': ?batchId, 'limit': '$limit', 'offset': '$offset'},
      )).body,
    ),
  );
}
