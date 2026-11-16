import '../core/json.dart';
import 'client_models.dart';
import 'gateway_client.dart';

/// Calls for the client console (docs/PRODUCT.md 5.1, `/v1/client/...`). Prices only, never pay.
class ClientRepository {
  const ClientRepository(this.gateway);

  final GatewayClient gateway;

  Future<ClientOverview> overview() async => ClientOverview.fromJson(decodeObject((await gateway.get('/v1/client/overview')).body));

  Future<List<ClientProject>> projects() async =>
      decodeObjects((await gateway.get('/v1/client/projects')).body).map(ClientProject.fromJson).toList();

  Future<ClientProjectDetail> project(String id) async =>
      ClientProjectDetail.fromJson(decodeObject((await gateway.get('/v1/client/projects/$id')).body));

  Future<FeedbackItem> sendFeedback(String projectId, String body, {required String key}) async => FeedbackItem.fromJson(
    decodeObject((await gateway.post('/v1/client/projects/$projectId/feedback', idempotencyKey: key, body: {'body': body})).body),
  );

  /// The batch's delivery files (409 `batch_held` until every unit is accepted).
  Future<Deliverable> deliverable(String batchId) async =>
      Deliverable.fromJson(decodeObject((await gateway.get('/v1/client/batches/$batchId/deliverable')).body));

  /// The manifest as the gateway sends it, saved as a JSON file.
  Future<Json> manifest(String batchId) async => decodeObject((await gateway.get('/v1/client/batches/$batchId/manifest')).body);

  /// Every manifest across the org's projects, newest first.
  Future<List<Delivery>> deliveries() async {
    final rows = await projects();
    final details = await Future.wait(rows.map((p) => project(p.id)));
    final out = <Delivery>[
      for (final d in details)
        for (final m in d.deliveries)
          Delivery(projectId: d.id, projectName: d.name, batchTitle: d.batchOf(m)?.title ?? '', currency: d.currency, manifest: m),
    ];
    out.sort((a, b) {
      final x = a.manifest.createdAt, y = b.manifest.createdAt;
      if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1;
      return y.compareTo(x);
    });
    return out;
  }
}
