// `_call` returns the UNWRAPPED payload, not the envelope.
//
// THE BUG THIS EXISTS FOR. `ApiClient._call` ends with:
//
//     final Object? data = body['data'];
//     return data is Map<String, dynamic> ? data : body;
//
// so a caller receives `data` itself. Reading `res['data']` on the result
// therefore finds nothing. In the store's generator-create path that made the
// new generator's id come back empty, the method returned early, and the SOP
// was never uploaded: a generator appeared with no document attached and no
// error shown anywhere. The user reported it as "the upload SOP does not work".
//
// This guards the shape rather than one call site, because the mistake is easy
// to repeat - `res['data']` reads as obviously correct.
//
// THIS FILE USED TO CARRY TWO MORE TESTS, both source scans pinned to
// `createGeneratorWithSop` - the create-and-upload method behind the "New
// generator" page. That page is gone: it asked for the SOP on the step before
// the corpus tab that already uploads one, so creating a generator now takes a
// name and nothing else. Both invariants those tests held are still held, and
// behaviourally rather than by string-matching the source:
//
//   * "the create returns a usable id" -> server_actions_test.dart, "New
//     generator returns the id the caller navigates to", which cans a real
//     envelope and asserts the parsed id. A source scan could only prove a
//     string was present, not that the id parses.
//   * "the SOP upload actually happens" -> server_actions_test.dart, "SOP
//     upload - the step everything else waits on", which is where the single
//     remaining upload path lives.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no caller re-unwraps a payload _call already unwrapped', () {
    final File store = File('lib/assessment/state/app_store.dart');
    expect(store.existsSync(), isTrue, reason: 'run from the package root');

    final List<String> lines = store.readAsLinesSync();
    final List<String> offenders = <String>[];

    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i];
      if (line.trimLeft().startsWith('//')) continue;
      // A read of ['data'] is only safe with an explicit fallback to the whole
      // response, which is how the settings payload is handled.
      if (line.contains("['data']") && !line.contains('??')) {
        offenders.add('app_store.dart:${i + 1}  ${line.trim()}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'ApiClient._call already returns `data`. Reading ["data"] '
          'again yields null and the call silently does nothing:\n'
          '${offenders.join('\n')}',
    );
  });

  test('the SOP has exactly one upload path', () {
    // The duplication that deleting the "New generator" page removed was TWO
    // create-and-upload routes through the product, one per screen. Deleting
    // the screen but leaving its store method behind would have kept the
    // duplication and only hidden it, so guard that it did not come back:
    // `_api.uploadResource` belongs to `uploadResource` and nowhere else.
    final String src = File(
      'lib/assessment/state/app_store.dart',
    ).readAsStringSync();

    expect(
      '_api.uploadResource('.allMatches(src).length,
      1,
      reason:
          'the corpus tab is the only place an SOP is attached - a second '
          'call site means a second upload path has reappeared',
    );
    expect(
      src.contains('createGeneratorWithSop'),
      isFalse,
      reason:
          'the create-and-upload wizard was deleted; a generator is created '
          'by name and the document is attached on its corpus tab',
    );
  });
}
