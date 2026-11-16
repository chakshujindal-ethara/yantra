import '../core/errors.dart';
import '../core/json.dart';
import 'gateway_client.dart';
import 'system_models.dart';

/// Calls behind the System page (admin and ops): stuck work with its release buttons, the dead letters and
/// jobs of every module. The scheduler releases expired claims within a minute; these are for looking and
/// for not waiting.
class SystemRepository {
  const SystemRepository(this.gateway);

  final GatewayClient gateway;

  Future<List<ExpiredClaim>> expiredClaims() async =>
      decodeObjects((await gateway.get('/v1/claims/expired')).body).map(ExpiredClaim.fromJson).toList();

  /// Available units waiting more than three days for the one worker they are assigned to, longest first.
  Future<List<StuckAssignedUnit>> stuckAssigned() async =>
      decodeObjects((await gateway.get('/v1/units/stuck-assigned')).body).map(StuckAssignedUnit.fromJson).toList();

  Future<List<ExpiredReview>> expiredReviews() async =>
      decodeObjects((await gateway.get('/v1/quality/reviews/expired')).body).map(ExpiredReview.fromJson).toList();

  /// What ended without an answer in the last [days], work claims and review claims together, newest first.
  Future<List<Released>> released({int days = 7}) async {
    final q = {'days': '$days'};
    final results = await Future.wait([
      gateway.get('/v1/claims/released', query: q),
      gateway.get('/v1/quality/reviews/released', query: q),
    ]);
    final rows = [...decodeObjects(results[0].body).map(Released.claim), ...decodeObjects(results[1].body).map(Released.review)];
    rows.sort((a, b) => (b.releasedAt ?? DateTime(0)).compareTo(a.releasedAt ?? DateTime(0)));
    return rows;
  }

  Future<void> releaseClaim(String claimId, {required String key}) =>
      gateway.post('/v1/claims/$claimId/release-expired', idempotencyKey: key);

  Future<void> releaseReview(String taskId, {required String key}) =>
      gateway.post('/v1/quality/reviews/$taskId/release-expired', idempotencyKey: key);

  /// Most passes of Release all: the server releases a bounded number per call and says `more`.
  static const maxPasses = 20;

  /// Releases every expired claim and review claim now, pass after pass while the server says `more` (at
  /// most [maxPasses] each); returns how many in all and whether some remain. Pass n has its own key
  /// (`<key>:claims:<n>`), so retrying the whole action replays the passes that landed.
  Future<({int released, bool more})> releaseAll({required String key}) async {
    final claims = await _drain('/v1/claims/release-expired', '$key:claims');
    final reviews = await _drain('/v1/quality/reviews/release-expired', '$key:reviews');
    return (released: claims.released + reviews.released, more: claims.more || reviews.more);
  }

  Future<({int released, bool more})> _drain(String path, String key) async {
    var released = 0;
    var more = true;
    for (var pass = 0; more && pass < maxPasses; pass++) {
      final body = decodeObject((await gateway.post(path, idempotencyKey: '$key:$pass')).body);
      released += readInt(body, 'released');
      more = readBool(body, 'more');
    }
    return (released: released, more: more);
  }

  /// Every module's dead letters; a module that cannot answer says why instead of failing the page.
  Future<List<ModuleDead>> deadLetters() => Future.wait([
    for (final m in systemModules)
      gateway
          .get('/v1/$m/dead-letters')
          .then((r) => ModuleDead(m, decodeObjects(r.body).map(DeadLetter.fromJson).toList()))
          .catchError((Object e) => ModuleDead(m, const [], error: describeError(e))),
  ]);

  Future<void> replay(String module, String id, {required String key}) =>
      gateway.post('/v1/$module/dead-letters/$id/replay', idempotencyKey: key);

  Future<List<ModuleJobs>> jobs() => Future.wait([
    for (final m in systemModules)
      gateway
          .get('/v1/$m/jobs')
          .then((r) => ModuleJobs(m, decodeObjects(r.body).map(JobRow.fromJson).toList()))
          .catchError((Object e) => ModuleJobs(m, const [], error: describeError(e))),
  ]);
}
