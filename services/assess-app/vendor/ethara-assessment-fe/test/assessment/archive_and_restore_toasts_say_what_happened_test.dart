// Archive and Restore on the bank and the generator list (Q11).
//
// Pinned here:
//   - on the offline demo data (no server), archiving questions or generators
//     changes nothing and says it needs a live server, rather than pretending;
//   - against a server, restoring archived questions sends `archive: false`
//     and the toast says they are back, in the singular or the plural.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Every toast message the store has raised, oldest first.
List<String> _toasts(AppStore s) =>
    s.toaster.items.map((ToastMsg m) => m.message).toList();

void main() {
  group('offline (demo data)', () {
    test(
      'archiving questions changes nothing and says it needs a server',
      () async {
        final AppStore s = AppStore();
        addTearDown(s.dispose);
        expect(s.isLive, isFalse);
        final Question first = s.bank.first;

        await s.archiveQuestions(<String>[first.id]);

        expect(_toasts(s), <String>['Archiving runs against a live server']);
        expect(s.bank.first.id, first.id);
        expect(s.bank.first.retired, first.retired);
      },
    );

    test(
      'archiving generators changes nothing and says it needs a server',
      () async {
        final AppStore s = AppStore();
        addTearDown(s.dispose);
        final Generator first = s.generators.first;

        await s.archiveGenerators(<String>[first.id]);

        expect(_toasts(s), <String>['Archiving runs against a live server']);
        expect(s.generators.first.id, first.id);
        expect(s.generators.first.active, first.active);
      },
    );
  });

  group('against a server', () {
    late List<Map<String, dynamic>> archiveBodies;

    AppStore live() {
      archiveBodies = <Map<String, dynamic>>[];
      final AppStore s = AppStore(
        api: ApiClient(
          baseUrl: 'http://x',
          client: MockClient((http.Request req) async {
            if (req.url.path.endsWith('/bank/archive')) {
              archiveBodies.add(jsonDecode(req.body) as Map<String, dynamic>);
            }
            final bool list =
                !req.url.path.endsWith('/archive') &&
                !req.url.path.endsWith('/settings');
            return http.Response(
              jsonEncode(<String, dynamic>{
                'ok': true,
                'data': list ? <dynamic>[] : <String, dynamic>{},
                if (list) 'meta': <String, dynamic>{'total': 0},
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }),
        ),
      );
      addTearDown(s.dispose);
      return s;
    }

    test(
      'restoring several sends archive false and says they are back',
      () async {
        final AppStore s = live();

        await s.archiveQuestions(<String>['4', '5'], archive: false);

        expect(archiveBodies, <Map<String, dynamic>>[
          <String, dynamic>{
            'ids': <dynamic>['4', '5'],
            'archive': false,
          },
        ]);
        expect(_toasts(s), contains('2 questions back in the bank'));
      },
    );

    test('restoring one says it in the singular', () async {
      final AppStore s = live();

      await s.archiveQuestions(<String>['4'], archive: false);

      expect(archiveBodies.single['archive'], isFalse);
      expect(_toasts(s), contains('1 question back in the bank'));
    });
  });
}
