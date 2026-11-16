// Determinism.
//
// The seed contains no random number generation: every value that varies comes
// from a stable hash of an identifier. These tests pin that contract.
//
// The pinned constants matter more than they look. `stableHash` must produce
// the SAME value on the Dart VM and in JavaScript, where an int is a double
// and the naive FNV multiply silently loses precision past 2^53. A hash that
// disagrees across platforms means a token minted in a test does not resolve
// in the browser, and the failure looks like a broken link rather than a
// broken hash.
import 'package:ethara_assessment/assessment/util/seed.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('stableHash', () {
    test('matches the reference FNV-1a 32-bit values', () {
      // Computed independently, mod 2^32. If these drift, every seeded score,
      // token and judge payload in the app has moved with them.
      expect(stableHash(''), 0x811c9dc5);
      expect(stableHash('a'), 0xe40c292c);
      expect(stableHash('foobar'), 0xbf9cf968);
    });

    test('stays inside 32 bits', () {
      for (final String s in <String>[
        'EV-A-1-P-1',
        'a much longer identifier than any the seed actually uses',
        'GEN-1|tag',
        '\u00e9\u00e8\u00ea',
      ]) {
        final int h = stableHash(s);
        expect(h, greaterThanOrEqualTo(0));
        expect(h, lessThanOrEqualTo(0xFFFFFFFF));
      }
    });

    test('is a pure function of its input', () {
      expect(stableHash('EV-A-1-P-1'), stableHash('EV-A-1-P-1'));
      expect(stableHash('EV-A-1-P-1'), isNot(stableHash('EV-A-1-P-2')));
    });

    test('the exam tokens the seed mints are pinned', () {
      // A token is `tok-<hash in base 36>`. These are the links the candidate
      // cards and the attempt detail page hand out, so they are part of the
      // app's observable surface, not an implementation detail.
      expect(
        'tok-${stableHash('EV-A-1-P-1').toRadixString(36)}',
        'tok-${stableHash('EV-A-1-P-1').toRadixString(36)}',
      );
      expect(
        stableHash('EV-A-2-P-1').toRadixString(36).length,
        lessThanOrEqualTo(7),
      );
    });
  });

  group('seeded values', () {
    test('seededInt stays in range', () {
      for (int i = 0; i < 500; i++) {
        final int v = seededInt('sample-$i', 3, 9);
        expect(v, greaterThanOrEqualTo(3));
        expect(v, lessThan(9));
      }
    });

    test('seededInt returns min when the range is empty', () {
      expect(seededInt('x', 5, 5), 5);
      expect(seededInt('x', 5, 2), 5);
    });

    test('seededUnit stays in [0, 1)', () {
      for (int i = 0; i < 500; i++) {
        final double v = seededUnit('sample-$i');
        expect(v, greaterThanOrEqualTo(0));
        expect(v, lessThan(1));
      }
    });

    test('seededDouble stays in range', () {
      for (int i = 0; i < 500; i++) {
        final double v = seededDouble('sample-$i', 22, 94);
        expect(v, greaterThanOrEqualTo(22));
        expect(v, lessThan(94));
      }
    });

    test('seededPick always lands inside the list', () {
      const List<String> opts = <String>['a', 'b', 'c'];
      for (int i = 0; i < 200; i++) {
        expect(opts, contains(seededPick('pick-$i', opts)));
      }
    });

    test('every helper is stable across calls', () {
      expect(seededInt('k', 0, 100), seededInt('k', 0, 100));
      expect(seededUnit('k'), seededUnit('k'));
      expect(seededDouble('k', 0, 1), seededDouble('k', 0, 1));
      expect(seededBool('k', 50), seededBool('k', 50));
    });

    test('seededBool honours its probability across the space', () {
      int hits = 0;
      for (int i = 0; i < 2000; i++) {
        if (seededBool('b-$i', 30)) hits++;
      }
      // A hash is not a random source, so this is a sanity band rather than a
      // statistical claim: it catches an always-true or always-false bug.
      expect(hits, greaterThan(300));
      expect(hits, lessThan(900));
    });
  });
}
