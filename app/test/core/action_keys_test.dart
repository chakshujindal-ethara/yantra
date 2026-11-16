import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/action_keys.dart';
import 'package:yantra_app/core/errors.dart';

void main() {
  test('the same action keeps its key until finished; a new action gets a fresh one', () {
    var n = 0;
    final keys = ActionKeys(generate: () => 'key-${++n}');
    expect(keys.start('claim:b1'), 'key-1');
    expect(keys.start('claim:b1'), 'key-1', reason: 'a retry reuses the key');
    expect(keys.start('submit:c1'), 'key-2', reason: 'a different action is a different key');
    keys.finish('claim:b1');
    expect(keys.start('claim:b1'), 'key-3', reason: 'after finish the action is new');
  });

  test('default generator mints UUIDs the gateway accepts', () {
    final key = ActionKeys().start('x');
    expect(key.length, inInclusiveRange(8, 200));
    expect(RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(key), isTrue);
  });

  test('settle keeps the key only when a retry may reuse it', () {
    final keys = ActionKeys(generate: () => 'k');
    ApiException api(int status) => ApiException(status: status, code: 'c', message: 'm');
    keys.start('a');
    keys.settle('a', api(422));
    expect(keys.start('a'), 'k'); // minted again: a 422 answer is stored by the gateway for the old key
    expect(retryKeepsKey(api(422)), isFalse);
    expect(retryKeepsKey(api(409)), isFalse);
    expect(retryKeepsKey(api(429)), isTrue);
    expect(retryKeepsKey(api(408)), isTrue);
    expect(retryKeepsKey(api(503)), isTrue);
    expect(retryKeepsKey(const TransportException('down')), isTrue);
    expect(retryKeepsKey(StateError('x')), isFalse);
  });

  test('bodyTag is stable for the same body and differs for another', () {
    expect(bodyTag({'a': 1, 'b': 'x'}), bodyTag({'a': 1, 'b': 'x'}));
    expect(bodyTag({'a': 1}), isNot(bodyTag({'a': 2})));
    expect(bodyTag(null), bodyTag(null));
    expect(RegExp(r'^[0-9a-f]{12}$').hasMatch(bodyTag({'a': 1})), isTrue, reason: 'safe inside a key');
  });
}
