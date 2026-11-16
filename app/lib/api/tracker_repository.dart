import '../core/errors.dart';
import '../core/json.dart';
import '../screens/policies_screen.dart' show Policy;
import 'gateway_client.dart';
import 'tracker_models.dart';

/// Calls to the tracker (docs/PRODUCT.md 5.7): sessions and samples while a claim is open, the worker's
/// week, and the tracking policy.
class TrackerRepository {
  const TrackerRepository(this._gateway);
  final GatewayClient _gateway;

  /// Starts a session for [claimId]. A session already open answers 409 `session_open` naming it; that
  /// session is reused (its start unknown), so a reload never splits the time.
  Future<TrackerStart> start({required String claimId, required String device, required String key}) async {
    try {
      final r = await _gateway.post(
        '/v1/tracker/sessions',
        idempotencyKey: key,
        body: {'claim_id': claimId, 'source': 'web', 'device_hash': device},
      );
      final m = decodeObject(r.body);
      return TrackerStart(readString(m, 'id'), startedAt: readDateTime(m, 'started_at'));
    } on ApiException catch (e) {
      final open = e.context['session_id'];
      if (e.status == 409 && e.code == 'session_open' && open is String && open.isNotEmpty) return TrackerStart(open);
      rethrow;
    }
  }

  /// The first key for a batch: `<session>:<first at>`, so a retried flush counts once.
  static String sampleKey(String sessionId, List<ActivitySample> samples) => '$sessionId:${samples.first.at.toUtc().toIso8601String()}';

  /// Sends up to 500 samples under [key] (default [sampleKey]); a retry must send the same body and key.
  Future<TrackerWeek> samples(String sessionId, List<ActivitySample> samples, {String? key}) async {
    final r = await _gateway.post(
      '/v1/tracker/sessions/$sessionId/samples',
      idempotencyKey: key ?? sampleKey(sessionId, samples),
      body: {
        'samples': [for (final s in samples) s.toJson()],
      },
    );
    return TrackerWeek.fromJson(readMap(decodeObject(r.body), 'week'));
  }

  Future<void> end(String sessionId, {required String key}) async {
    await _gateway.post('/v1/tracker/sessions/$sessionId/end', idempotencyKey: key);
  }

  Future<MyActivity> mine() async => MyActivity.fromJson(decodeObject((await _gateway.get('/v1/tracker/sessions/me')).body));

  /// What is collected, as the tracker states it (with the live retention and cap figures).
  Future<Policy> policy() async => Policy.fromJson(decodeObject((await _gateway.get('/v1/tracker/policy')).body));
}
