// A Yantra launch link carries a one-time ticket in the FRAGMENT (never sent to
// a server, so never in an access log). The app reads it once, trades it for a
// session, and remembers where "Back to Yantra" goes.
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/yantra_launch.dart';

void main() {
  group('launchTicketFrom', () {
    test('reads the ticket on the launch path only', () {
      expect(
        launchTicketFrom(
          Uri.parse('http://localhost:8096/yantra/launch#ticket=abc%2B1'),
        ),
        'abc+1',
      );
      expect(
        launchTicketFrom(Uri.parse('http://h/yantra/launch/#ticket=t')),
        't',
      );
      for (final String url in <String>[
        'http://h/exam/abc#ticket=t',
        'http://h/yantra/launch?ticket=t',
        'http://h/yantra/launch#ticket=',
        'http://h/yantra/launch#ticket=%20',
        'http://h/yantra/launch',
        'http://h/yantra/launch#%zz',
      ]) {
        expect(launchTicketFrom(Uri.parse(url)), isNull, reason: url);
      }
    });
  });

  group('safeReturnUrl', () {
    test('takes http(s) only, and only Yantra when Yantra is known', () {
      expect(safeReturnUrl('http://localhost:8095/work', yantraAppUrl: ''),
          'http://localhost:8095/work');
      expect(safeReturnUrl('javascript:alert(1)', yantraAppUrl: ''), isNull);
      expect(safeReturnUrl('//evil.example/x', yantraAppUrl: ''), isNull);
      expect(safeReturnUrl('', yantraAppUrl: ''), isNull);
      expect(safeReturnUrl(null, yantraAppUrl: ''), isNull);
      expect(
        safeReturnUrl(
          'http://localhost:8095/work',
          yantraAppUrl: 'http://localhost:8095',
        ),
        'http://localhost:8095/work',
      );
      expect(
        safeReturnUrl(
          'https://evil.example/x',
          yantraAppUrl: 'http://localhost:8095',
        ),
        isNull,
      );
    });

    test('a remembered return URL is read back, and cleared by null', () {
      rememberYantraReturn('http://localhost:8095/work/applications');
      expect(yantraReturnUrl(yantraAppUrl: ''),
          'http://localhost:8095/work/applications');
      rememberYantraReturn('javascript:alert(1)');
      expect(yantraReturnUrl(yantraAppUrl: ''), isNull);
      rememberYantraReturn('http://localhost:8095/x');
      rememberYantraReturn(null);
      expect(yantraReturnUrl(yantraAppUrl: ''), isNull);
    });
  });

  group('afterLaunchPath', () {
    test('an exam opens its sitting, staff open the path asked for', () {
      expect(afterLaunchPath(examToken: 'tok', next: '/admin'), '/exam/tok');
      expect(afterLaunchPath(next: '/assessments/1'), '/assessments/1');
      expect(afterLaunchPath(), '/');
      for (final String bad in <String>['//evil', 'https://e/x', 'x', '']) {
        expect(afterLaunchPath(next: bad), '/', reason: bad);
      }
    });
  });

  test('Continue with Yantra exists only when Yantra is configured', () {
    expect(continueWithYantraUri(yantraAppUrl: ''), isNull);
    expect(
      continueWithYantraUri(yantraAppUrl: 'http://localhost:8095'),
      Uri.parse('http://localhost:8095'),
    );
    expect(continueWithYantraUri(yantraAppUrl: 'ftp://x'), isNull);
  });
}
