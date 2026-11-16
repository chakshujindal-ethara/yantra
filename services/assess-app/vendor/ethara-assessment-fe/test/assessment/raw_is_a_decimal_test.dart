/// Raw scores are decimals from 0 to 1, on every surface.
///
/// THE DEFECT. The grader returns a 0-100 integer - that is its prompt
/// contract, and what the pass threshold is expressed in - and the console
/// printed that number straight out under labels like "Subjective raw". So the
/// same answer read `0.93` on the attempt screen and `93` in the grader audit,
/// with nothing on either saying which scale it was on.
///
/// The grader's scale is unchanged. What is pinned here is the boundary: the
/// moment a raw is shown to a person it is a 0-1 decimal.
library;

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('The formatter is the convention', () {
    test('the grader 0-100 becomes a two-place decimal', () {
      expect(rawFromHundred(93), '0.93');
      expect(rawFromHundred(100), '1.00');
      expect(rawFromHundred(0), '0.00');
      expect(rawFromHundred(60), '0.60');
    });

    test('a missing score reads as zero, never as blank or NaN', () {
      // The audit payload omits a field the grader did not populate, and a
      // meter fed a NaN renders as an empty bar that looks like a broken
      // render rather than a zero.
      expect(rawFromHundred(null), '0.00');
      expect(rawDecimal(null), '0.00');
    });

    test('a value already 0-1 formats identically', () {
      // Two entry points, one output shape - so a surface holding the 0-1
      // twin and one holding the grader's number cannot disagree.
      expect(rawDecimal(0.93), '0.93');
      expect(rawDecimal(1), '1.00');
    });

    test('it rounds rather than truncating', () {
      expect(rawFromHundred(93.5), '0.94');
      expect(rawFromHundred(0.4), '0.00');
    });
  });

}
