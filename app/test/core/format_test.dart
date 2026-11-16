import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/format.dart';

void main() {
  test('a pay window reads in IST whatever the device zone, and says so', () {
    // Monday 00:00 IST to the next Monday 00:00 IST, as the payout service sends them (UTC)
    final starts = DateTime.utc(2026, 10, 25, 18, 30);
    final ends = DateTime.utc(2026, 11, 1, 18, 30);
    expect(payWindowRange(starts, ends, now: DateTime.utc(2026, 11, 4)), '26 Oct – 1 Nov IST');
    // the same instants written with another offset read the same
    expect(payWindowRange(starts.toLocal(), ends.toLocal(), now: DateTime.utc(2026, 11, 4)), '26 Oct – 1 Nov IST');
    expect(
      payWindowRange(DateTime.utc(2026, 11, 1, 18, 30), DateTime.utc(2026, 11, 8, 18, 30), now: DateTime.utc(2026, 11, 4)),
      '2 – 8 Nov IST',
    );
    expect(
      payWindowRange(DateTime.utc(2025, 12, 28, 18, 30), DateTime.utc(2026, 1, 4, 18, 30), now: DateTime.utc(2026, 11, 4)),
      '29 Dec 2025 – 4 Jan IST',
    );
  });

  test('an IST date and time for a single instant', () {
    expect(istDate(DateTime.utc(2026, 11, 1, 18, 30), now: DateTime.utc(2026, 11, 4)), '2 Nov IST');
  });
}
