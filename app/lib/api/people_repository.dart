import 'package:uuid/uuid.dart';

import '../core/json.dart';
import '../core/people.dart';
import 'gateway_client.dart';

/// Display names for ids (`GET /v1/people`, ops, finance, admin, and clients for their co-members) and
/// the caller's own registration (`PUT /v1/talent/people/me`).
class PeopleRepository {
  const PeopleRepository(this._gateway);
  final GatewayClient _gateway;

  Future<Map<String, Person>> lookup(List<String> ids) async {
    final body = decodeObject((await _gateway.get('/v1/people', query: {'ids': ids.join(',')})).body);
    return {
      for (final e in body.entries)
        if (e.value is Map) e.key: Person(name: readString(e.value as Json, 'name'), kind: readString(e.value as Json, 'kind')),
    };
  }

  Future<void> announceSelf() async {
    await _gateway.put('/v1/talent/people/me', idempotencyKey: const Uuid().v4());
  }
}
