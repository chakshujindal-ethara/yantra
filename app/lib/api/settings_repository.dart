import '../core/json.dart';
import 'gateway_client.dart';
import 'settings_models.dart';

/// Calls behind the Settings page (ops): client organisations and members, policy versions, reason
/// codes, tracker hour caps and erasure requests.
class SettingsRepository {
  const SettingsRepository(this.gateway);

  final GatewayClient gateway;

  Future<List<OrgRow>> orgs() async => decodeObjects((await gateway.get('/v1/client-orgs')).body).map(OrgRow.fromJson).toList();

  Future<OrgRow> createOrg(String name, {required String key}) async =>
      OrgRow.fromJson(decodeObject((await gateway.post('/v1/client-orgs', idempotencyKey: key, body: {'name': name})).body));

  Future<void> addMember(String orgId, String userId, {required String key}) =>
      gateway.put('/v1/client-orgs/$orgId/members/$userId', idempotencyKey: key);

  Future<void> removeMember(String orgId, String userId, {required String key}) =>
      gateway.delete('/v1/client-orgs/$orgId/members/$userId', idempotencyKey: key);

  Future<List<PolicyDoc>> policies() async =>
      decodeObjects((await gateway.get('/v1/talent/policies')).body).map(PolicyDoc.fromJson).toList();

  /// Publishes a new revision of [slug]; workers accept the new [label] on their next onboarding step.
  Future<PolicyDoc> publishPolicy(
    String slug, {
    required String title,
    required String summary,
    required List<PolicyPart> sections,
    String? label,
    required String key,
  }) async => PolicyDoc.fromJson(
    decodeObject(
      (await gateway.put(
        '/v1/talent/policies/$slug',
        idempotencyKey: key,
        body: {
          'title': title,
          'summary': summary,
          'sections': [for (final s in sections) s.toJson()],
          'label': ?label,
        },
      )).body,
    ),
  );

  Future<List<ReasonRow>> reasons() async =>
      decodeObjects((await gateway.get('/v1/quality/reasons', query: {'all': 'true'})).body).map(ReasonRow.fromJson).toList();

  Future<ReasonRow> putReason(String code, ReasonRow row, {required String key}) async =>
      ReasonRow.fromJson(decodeObject((await gateway.put('/v1/quality/reasons/$code', idempotencyKey: key, body: row.toJson())).body));

  Future<List<CapRow>> caps() async => decodeObjects((await gateway.get('/v1/tracker/caps')).body).map(CapRow.fromJson).toList();

  Future<CapRow> putCap(String scope, String scopeId, String hours, {required String key}) async => CapRow.fromJson(
    decodeObject((await gateway.put('/v1/tracker/caps/$scope/$scopeId', idempotencyKey: key, body: {'weekly_cap_hours': hours})).body),
  );

  Future<List<ErasureRow>> erasures() async =>
      decodeObjects((await gateway.get('/v1/talent/erasures')).body).map(ErasureRow.fromJson).toList();

  Future<ErasureRow> approveErasure(String workerId, {required String key}) async =>
      ErasureRow.fromJson(decodeObject((await gateway.post('/v1/talent/erasures/$workerId/approve', idempotencyKey: key)).body));
}
