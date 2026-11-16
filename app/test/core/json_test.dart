import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/errors.dart';
import 'package:yantra_app/core/json.dart';

void main() {
  test('an object body decodes; an empty body is an empty object', () {
    expect(decodeObject('{"a":1}'), {'a': 1});
    expect(decodeObject(''), isEmpty);
    expect(decodeObjects(''), isEmpty);
    expect(decodeObjects('[{"a":1},2]'), [
      {'a': 1},
    ]);
  });

  test('a malformed or wrong-shaped body is a ShapeError, not silent empty data', () {
    expect(() => decodeObject('<html>502</html>'), throwsA(isA<ShapeError>().having((e) => e.expected, 'expected', 'an object')));
    expect(() => decodeObject('[]'), throwsA(isA<ShapeError>()));
    expect(() => decodeObjects('{"items":[]}'), throwsA(isA<ShapeError>().having((e) => e.expected, 'expected', 'a list')));
    expect(() => decodeObjects('nope'), throwsA(isA<ShapeError>()));
  });

  test('the excerpt is short so a huge HTML page never lands in a message', () {
    final e = ShapeError('an object', 'x' * 500);
    expect(e.excerpt.length, lessThanOrEqualTo(80));
  });

  test('envelopes and tokens decode leniently', () {
    expect(decodeObjectOrEmpty('<html>'), isEmpty);
    expect(decodeObjectOrEmpty('[1]'), isEmpty);
    expect(decodeObjectOrEmpty('{"code":"x"}'), {'code': 'x'});
  });
}
