import '../core/json.dart';
import 'gateway_client.dart';
import 'support_models.dart';

/// Calls for support tickets (docs/PRODUCT.md 5.6). Anyone opens and lists their own; ops list and move all.
class SupportRepository {
  const SupportRepository(this.gateway);

  final GatewayClient gateway;

  Future<Ticket> create(TicketInput input, {required String key}) async =>
      Ticket.fromJson(decodeObject((await gateway.post('/v1/notify/tickets', idempotencyKey: key, body: input.toJson())).body));

  Future<List<Ticket>> mine() async => decodeObjects((await gateway.get('/v1/notify/tickets/me')).body).map(Ticket.fromJson).toList();

  Future<List<Ticket>> all({String? status}) async =>
      decodeObjects((await gateway.get('/v1/notify/tickets', query: {'status': ?status})).body).map(Ticket.fromJson).toList();

  Future<Ticket> setStatus(String id, {required String status, String note = '', required String key}) async => Ticket.fromJson(
    decodeObject((await gateway.post('/v1/notify/tickets/$id/status', idempotencyKey: key, body: {'status': status, 'note': note})).body),
  );
}
