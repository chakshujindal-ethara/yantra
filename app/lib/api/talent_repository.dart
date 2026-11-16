import '../core/json.dart';
import '../screens/policies_screen.dart' show Policy;
import 'gateway_client.dart';
import 'talent_models.dart';

/// Calls for listings, applications, offers, onboarding. Shapes are in docs/PRODUCT.md 5.2. Mutations take
/// the caller's idempotency key.
class TalentRepository {
  const TalentRepository(this.gateway);

  final GatewayClient gateway;

  Future<List<Listing>> listings() async => decodeObjects((await gateway.get('/v1/talent/listings')).body).map(Listing.fromJson).toList();

  Future<Listing> listing(String id) async => Listing.fromJson(decodeObject((await gateway.get('/v1/talent/listings/$id')).body));

  Future<Application> apply(String listingId, Json answers, {required String key}) async => Application.fromJson(
    decodeObject((await gateway.post('/v1/talent/listings/$listingId/applications', idempotencyKey: key, body: {'answers': answers})).body),
  );

  Future<List<Application>> myApplications() async =>
      decodeObjects((await gateway.get('/v1/talent/applications/me')).body).map(Application.fromJson).toList();

  Future<Application> withdraw(String id, {required String key}) async =>
      Application.fromJson(decodeObject((await gateway.post('/v1/talent/applications/$id/withdraw', idempotencyKey: key)).body));

  Future<Application> answerOffer(String id, {required bool accept, required String key}) async => Application.fromJson(
    decodeObject((await gateway.post('/v1/talent/applications/$id/offer', idempotencyKey: key, body: {'accept': accept})).body),
  );

  Future<Onboarding> onboarding() async => Onboarding.fromJson(decodeObject((await gateway.get('/v1/talent/workers/me/onboarding')).body));

  Future<Onboarding> putOnboardingStep(String step, Json body, {required String key}) async => Onboarding.fromJson(
    decodeObject((await gateway.put('/v1/talent/workers/me/onboarding/$step', idempotencyKey: key, body: body)).body),
  );

  /// The policies as the server holds them: the agreement and consent a worker accepts carry the version label
  /// that onboarding must send back.
  Future<List<Policy>> policies() async =>
      decodeObjects((await gateway.get('/v1/talent/policies')).body).map(Policy.fromJson).where((p) => p.slug.isNotEmpty).toList();

  /// A presigned upload for one identity document (`{key, url, method, headers, expires_at, max_bytes}`).
  Future<Json> presignDocument(String kind, {required String contentType, required int size, required String key}) async => decodeObject(
    (await gateway.post(
      '/v1/talent/workers/me/documents/presign',
      idempotencyKey: key,
      body: {'kind': kind, 'content_type': contentType, 'size_bytes': size},
    )).body,
  );

  /// Records an uploaded document; the server checks the object exists and its size matches.
  Future<void> registerDocument(
    String kind, {
    required String objectKey,
    required String sha256,
    required int size,
    required String key,
  }) async {
    await gateway.put(
      '/v1/talent/workers/me/documents/$kind',
      idempotencyKey: key,
      body: {'key': objectKey, 'sha256': sha256, 'size_bytes': size},
    );
  }

  /// Asks for the worker's personal data to be erased; done within 30 days unless ops bring it forward.
  Future<Erasure> requestErasure({required String key}) async =>
      Erasure.fromJson(decodeObject((await gateway.post('/v1/talent/workers/me/erasure', idempotencyKey: key)).body));
}
