// A date a person can read, not a machine timestamp.
//
// THE BUG, AND WHY NO TEST CAUGHT IT. The API dates a generator with
// `create_date`, an ISO-8601 string, and the client passed it straight to the
// screen: the generator header read "updated 2026-08-12T08:57:14Z". Every seed
// fixture carries a pre-humanised string instead ('2 days ago', '5 hours ago'),
// so the whole suite and every design pass rendered a sentence the live app
// never produced. The fixture was hiding the defect rather than reproducing it.
//
// That is the reason the pass-through case below is tested as deliberately as
// the formatting: `humanWhen` is applied at PARSE time, so anything that is not
// a date has to survive it untouched or those fixtures start rendering
// differently from the app they stand in for.
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';

void main() {
  group('humanWhen formats what the wire actually sends', () {
    test('an ISO timestamp becomes a clock time, not "3 hours ago"', () {
      final String out = humanWhen(
        DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 3))
            .toIso8601String(),
      );
      expect(out, matches(RegExp(r'\d{1,2}:\d{2} [AP]M IST$')));
    });

    test('the exact string from the reported header no longer leaks', () {
      final String out = humanWhen('2026-08-12T08:57:14Z');
      // BETWEEN DIGITS, not anywhere: the "IST" label ends in a T too.
      expect(
        out,
        isNot(matches(RegExp(r'\dT\d'))),
        reason: 'an ISO "T" separator on screen is the whole defect',
      );
      expect(out, isNot(contains('Z')));
    });

    test('a date becomes the IST clock time, not "3 hours ago"', () {
      const String raw = '2026-08-12T08:57:14Z';
      expect(humanWhen(raw), istTimestamp(DateTime.parse(raw)));
      expect(humanWhen('2020-03-09T10:00:00Z'), '9 Mar 2020, 3:30 PM IST');
    });
  });

  group('Anything that is not a date survives untouched', () {
    test('the seed fixtures pass straight through', () {
      // Applied at parse time, so these must be identity - otherwise every
      // seeded screen starts disagreeing with the live one again.
      expect(humanWhen('2 days ago'), '2 days ago');
      expect(humanWhen('5 hours ago'), '5 hours ago');
      expect(humanWhen('3 weeks ago'), '3 weeks ago');
      expect(humanWhen('just now'), 'just now');
    });

    test('empty stays empty rather than becoming a date', () {
      expect(humanWhen(''), '');
      expect(humanWhen('   '), '');
    });
  });
}
