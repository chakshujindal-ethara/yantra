// History and Emails show the clock time in IST, not "25m ago".
//
// The wire sends UTC (`serializers.iso` appends `Z`), so every case below
// starts from a UTC instant and asserts the India wall clock it lands on -
// and every one of them ends in "IST". A bare "10:03 AM" reads as the
// reader's own clock to a candidate outside India, so the zone is part of the
// value, not decoration a screen may drop.
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';

void main() {
  // 10:15 AM IST on 21 Sep 2026.
  final DateTime now = DateTime.utc(2026, 9, 21, 4, 45);

  group('istTimestamp', () {
    test('today reads as the time alone', () {
      final DateTime at = DateTime.parse('2026-09-21T04:33:00Z');
      expect(istTimestamp(at, now: now), '10:03 AM IST');
    });

    test('the +05:30 offset moves a late UTC evening to the next IST day', () {
      // 20 Sep 18:40 UTC is 21 Sep 00:10 IST - today, and past midnight.
      final DateTime at = DateTime.utc(2026, 9, 20, 18, 40);
      expect(istTimestamp(at, now: now), '12:10 AM IST');
    });

    test('noon is PM and single-digit hours are not padded', () {
      expect(istTimestamp(DateTime.utc(2026, 9, 21, 6, 30), now: now),
          '12:00 PM IST');
      expect(istTimestamp(DateTime.utc(2026, 9, 20, 15, 35), now: now),
          '20 Sep, 9:05 PM IST');
    });

    test('an earlier year names the year, judged in IST', () {
      // 31 Dec 2025 in UTC, but already 1 Jan 2026 in India: this year.
      expect(istTimestamp(DateTime.utc(2025, 12, 31, 20, 0), now: now),
          '1 Jan, 1:30 AM IST');
      expect(istTimestamp(DateTime.utc(2025, 6, 1, 3, 0), now: now),
          '1 Jun 2025, 8:30 AM IST');
    });

    test('a local DateTime is converted, not read as IST', () {
      final DateTime local = DateTime.utc(2026, 9, 21, 4, 33).toLocal();
      expect(istTimestamp(local, now: now), '10:03 AM IST');
    });
  });

  group('istDateAtTime', () {
    test('reads the way the finished-run line is written', () {
      expect(istDateAtTime(DateTime.utc(2026, 9, 21, 16, 34)),
          'Sep 21, 2026 at 10:04pm IST');
      expect(istDateAtTime(DateTime.utc(2026, 9, 21, 3, 5)),
          'Sep 21, 2026 at 8:35am IST');
    });

    test('a late UTC evening is already the next IST day', () {
      expect(istDateAtTime(DateTime.utc(2026, 9, 20, 18, 40)),
          'Sep 21, 2026 at 12:10am IST');
    });
  });
}
