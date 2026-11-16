// The roster importer, against the bytes a spreadsheet actually writes.
//
// THE REPORTED BUG. A three-candidate CSV imported all three and then warned
// "1 row(s) skipped - a row needs a name and an email address". The file was
// fine; the skipped row was its own HEADER. Excel and Google Sheets prefix a
// UTF-8 BOM, the importer decodes byte-for-byte so that arrives as the three
// characters 'ï»¿' glued to the first cell, and the header test compared the
// first cell to the literal 'name'. 'ï»¿name' != 'name', so the header fell
// through to the malformed-row branch and was counted at the operator.
//
// This pins the PARSE, which is the half that was wrong. It calls the
// importer's own `parseCandidateCsv` - it used to test a hand-kept copy of the
// widget's parse, which drifted: the copy still imported the good rows around
// a bad one after the owner ruled that one bad row refuses the file (A-222).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

({List<({String name, String email})> ok, List<String> bad}) parseRoster(
  List<int> bytes,
) => parseCandidateCsv(bytes);

/// The reported file, byte for byte: a UTF-8 BOM, then a header, then three
/// candidates.
List<int> _reportedFile() => <int>[
  0xEF,
  0xBB,
  0xBF,
  ...'name,email\n'
          'Chakshu Jindal P,chakshujindal247@gmail.com\n'
          'Chakshu Jindal E,chakshu.jindal@ethara.ai\n'
          'Utkarsh Jain E,utkarsh.jain@ethara.ai\n'
      .codeUnits,
];

void main() {
  test('a BOM-prefixed export imports cleanly, with nothing skipped', () {
    final ({List<({String name, String email})> ok, List<String> bad}) r =
        parseRoster(_reportedFile());

    expect(r.ok.length, 3);
    expect(r.ok.first.name, 'Chakshu Jindal P');
    expect(r.ok.first.email, 'chakshujindal247@gmail.com');
    // THE ASSERTION THAT MATTERS. This was 1 - the header, counted as a
    // malformed row and reported as a problem with a file that had none.
    expect(r.bad, isEmpty, reason: 'the header is not a skipped row');
  });

  test('a header under any name is recognised by position and shape', () {
    // Matching the literal words meant a differently-labelled export was
    // reported as broken. The first row whose email cell holds no '@' is the
    // header, whatever it happens to be called.
    final ({List<({String name, String email})> ok, List<String> bad}) r =
        parseRoster(
          'Full name,Email address\nAsha Rao,asha@example.com\n'.codeUnits,
        );
    expect(r.ok.length, 1);
    expect(r.bad, isEmpty);
  });

  test('ONE BAD ROW REFUSES THE WHOLE FILE, naming the row (A-222)', () {
    // It used to drop the bad rows and import the rest ("1 row(s) skipped.
    // The rest are imported"), so a typo quietly left a candidate off the
    // roster. Nothing is importable now, and each bad row is named by the row
    // number a spreadsheet shows.
    final ({List<({String name, String email})> ok, List<String> bad}) r =
        parseRoster(
          'name,email\n'
                  'Asha Rao,asha@example.com\n'
                  'Vikram Shah,not-an-address\n'
                  'no-comma-at-all\n'
              .codeUnits,
        );
    expect(r.ok, isEmpty, reason: 'nothing may be sent');
    expect(r.bad, <String>[
      'Row 3: "not-an-address" is not a valid email address',
      'Row 4: needs a name and an email address, comma separated',
    ]);
  });

  test('a real address check, not just an "@"', () {
    for (final String e in <String>[
      'asha@example',
      'asha@example.c',
      'asha@example.c0m',
      'asha rao@example.com',
      'asha@@example.com',
      'a@b.com;c@d.com',
      '<asha@example.com>',
    ]) {
      expect(
        parseRoster('name,email\nAsha Rao,$e\n'.codeUnits).bad,
        hasLength(1),
        reason: e,
      );
    }
    expect(
      parseRoster(
        'name,email\nAsha Rao,asha.rao@mail.example.co.in\n'.codeUnits,
      ).ok,
      hasLength(1),
    );
  });

  test('a file with no header at all still imports its first row', () {
    final ({List<({String name, String email})> ok, List<String> bad}) r =
        parseRoster('Asha Rao,asha@example.com\n'.codeUnits);
    expect(r.ok.length, 1);
    expect(r.bad, isEmpty);
  });

  test('the downloaded template round-trips through the importer', () {
    // THE TEMPLATE IS AN INPUT TO THIS PARSER, so it is worth asserting that
    // the two agree. Byte-for-byte what services/export_api.py emits: a UTF-8
    // BOM, csv.writer's \r\n terminators, and sample rows carrying neither a
    // comma (which the naive split would break on) nor a deliverable address.
    final List<int> template = <int>[
      0xEF,
      0xBB,
      0xBF,
      ...'name,email\r\n'
              'Replace this row with your first candidate,first@example.com\r\n'
              'Add one row per candidate,second@example.com\r\n'
          .codeUnits,
    ];

    final ({List<({String name, String email})> ok, List<String> bad}) r =
        parseRoster(template);

    expect(r.ok.length, 2);
    expect(r.bad, isEmpty, reason: 'the template must not warn about itself');
    // Reserved by RFC 2606: filling in a roster underneath the samples and
    // importing the file whole can never mail a real person.
    for (final ({String name, String email}) c in r.ok) {
      expect(c.email, endsWith('@example.com'));
    }
  });

  test('a mixed-case address is lower-cased on import', () {
    // THE DUPLICATE-APPLICANT BUG. `Foo.Bar@Example.COM` typed one place and
    // `foo.bar@example.com` imported another minted two records for one
    // mailbox, because Odoo matched the address verbatim. Both paths now share
    // one rule.
    final ({List<({String name, String email})> ok, List<String> bad}) r =
        parseRoster('name,email\nFoo Bar,Foo.Bar@Example.COM\n'.codeUnits);
    expect(r.ok.length, 1);
    expect(r.ok.first.email, 'foo.bar@example.com');
    // The NAME is left exactly as typed - only the address is normalised.
    expect(r.ok.first.name, 'Foo Bar');
  });

  group('inviteByEmail shares the same lowering rule', () {
    // A spy that records the assign body, so the address that reaches the wire
    // can be read back.
    List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];
    List<String> paths = <String>[];

    AppStore live() {
      bodies = <Map<String, dynamic>>[];
      paths = <String>[];
      final http.Client client = MockClient((http.Request req) async {
        paths.add(req.url.path);
        try {
          bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        } on FormatException {
          bodies.add(<String, dynamic>{});
        }
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{},
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final AppStore s = AppStore(
        api: ApiClient(baseUrl: 'http://stub', client: client),
      );
      s.adoptSession(orgRole: 'admin', name: 'Aarav Mehta', uid: '2');
      return s;
    }

    test(
      'a typed address is trimmed and lower-cased before it is sent',
      () async {
        final AppStore s = live();
        await s.inviteByEmail(
          Assessment(id: '7', name: 'Warehouse Safety'),
          name: 'Foo Bar',
          email: '  Foo.Bar@Example.COM ',
        );

        final int i = paths.indexWhere((String p) => p.contains('/assign'));
        expect(i, isNot(-1), reason: 'the invite must reach the assign route');
        final List<dynamic> invites =
            (bodies[i]['candidates'] ?? const <dynamic>[]) as List<dynamic>;
        expect(invites, isNotEmpty);
        expect(
          (invites.first as Map<String, dynamic>)['email'],
          'foo.bar@example.com',
        );
      },
    );
  });
}
