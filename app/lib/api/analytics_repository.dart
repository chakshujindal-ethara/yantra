import '../core/errors.dart';
import '../core/json.dart';
import 'analytics_models.dart';
import 'gateway_client.dart';

/// Calls behind the leadership page (docs/PRODUCT.md 5.8): ops, finance and admin read; ops set the
/// baseline; admin asks for a rebuild.
class AnalyticsRepository {
  const AnalyticsRepository(this.gateway);

  final GatewayClient gateway;

  Future<Leadership> leadership({int days = 30}) async =>
      Leadership.fromJson(decodeObject((await gateway.get('/v1/analytics/leadership', query: {'days': '$days'})).body));

  Future<Funnel> funnel({String? listingId, int days = 30}) async =>
      Funnel.fromJson(decodeObject((await gateway.get('/v1/analytics/funnel', query: {'days': '$days', 'listing_id': ?listingId})).body));

  Future<Workforce> workforce() async => Workforce.fromJson(decodeObject((await gateway.get('/v1/analytics/workforce')).body));

  /// The latest baseline, or null before anyone has set one (404).
  Future<LeadBaseline?> baseline() async {
    try {
      return LeadBaseline.fromJson(decodeObject((await gateway.get('/v1/analytics/baselines')).body));
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  Future<LeadBaseline> setBaseline(LeadBaseline b, {required String key}) async =>
      LeadBaseline.fromJson(decodeObject((await gateway.put('/v1/analytics/baselines', idempotencyKey: key, body: b.toJson())).body));

  Future<RebuildState> rebuild() async => RebuildState.fromJson(decodeObject((await gateway.get('/v1/analytics/rebuild')).body));

  Future<RebuildState> requestRebuild(String mode, {required String key}) async =>
      RebuildState.fromJson(decodeObject((await gateway.post('/v1/analytics/rebuild', idempotencyKey: key, query: {'mode': mode})).body));
}
