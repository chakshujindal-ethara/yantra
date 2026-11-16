import '../core/json.dart';
import 'assess_models.dart';
import 'gateway_client.dart';

/// The worker's calls for papers (docs/PRODUCT.md 5.3): the brief, their sittings, and the signed-in links
/// into Assessment v2. Mutations take the caller's idempotency key.
class AssessRepository {
  const AssessRepository(this.gateway);

  final GatewayClient gateway;

  Future<PaperBrief> brief(String paperId) async =>
      PaperBrief.fromJson(decodeObject((await gateway.get('/v1/assess/papers/$paperId/brief')).body));

  Future<List<WorkerSitting>> mySittings() async =>
      decodeObjects((await gateway.get('/v1/assess/sittings/me')).body).map(WorkerSitting.fromJson).toList();

  /// Starts (or resumes) the paper: a fresh one-time link into the exam app.
  Future<LaunchTicket> launch(String paperId, {required String key}) async =>
      LaunchTicket.fromJson(decodeObject((await gateway.post('/v1/assess/papers/$paperId/launch', idempotencyKey: key)).body));

  /// "Continue with Yantra" from the exam app's sign-in: a fresh link for the exam behind [examToken].
  Future<LaunchTicket> launchByExam(String examToken, {required String key}) async => LaunchTicket.fromJson(
    decodeObject((await gateway.post('/v1/assess/launch-by-exam', idempotencyKey: key, body: {'exam_token': examToken})).body),
  );

  /// Staff: a signed-in link into the Assessment admin, opening [next] (an admin path like `/assessments/12`).
  Future<LaunchTicket> adminLaunch({String next = '/', required String key}) async =>
      LaunchTicket.fromJson(decodeObject((await gateway.post('/v1/assess/admin-launch', idempotencyKey: key, body: {'next': next})).body));
}
