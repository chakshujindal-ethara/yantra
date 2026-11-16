// A roster import: the dry run that checks it first, and the toasts that say
// what the real import did.
//
// THE INCIDENT (stage, 19 Oct 2026). An 874-row CSV went to the assign route,
// which spent about eight minutes provisioning logins and then refused the
// whole file over 8 accounts that cannot sign in. The sheet had closed, nothing
// said a request was running, and the admin reloaded and never saw the refusal.
// The server now skips those people instead, and answers a `dry_run` in about a
// second - which the sheet asks before anything is written. The real import
// then goes in batches with a progress bar (main, 20 Oct 2026).
//
// Only the socket is faked; the real ApiClient and store run.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

http.Response _ok(Map<String, dynamic> data) =>
    _json(<String, dynamic>{'ok': true, 'data': data});

class _Rig {
  /// Every body the assign route received, in order.
  final List<Map<String, dynamic>> assigns = <Map<String, dynamic>>[];

  /// How the assign route answers. A test swaps it.
  Future<http.Response> Function() answer = () async =>
      _ok(<String, dynamic>{'assigned_count': 0});

  late final AppStore store = AppStore(
    api: ApiClient(
      baseUrl: 'http://stub',
      client: MockClient((http.Request req) async {
        if (req.url.path.endsWith('/assign')) {
          assigns.add(jsonDecode(req.body) as Map<String, dynamic>);
          return answer();
        }
        return _ok(<String, dynamic>{});
      }),
    ),
  );

  _Rig() {
    store.adoptSession(orgRole: 'admin', name: 'Aarav Mehta', uid: '2');
  }
}

Assessment _asm() => Assessment(
  id: '7',
  name: 'Warehouse Safety',
  questions: const <Question>[],
);

const List<({String name, String email})> _rows =
    <({String name, String email})>[
      (name: 'Anita Rao', email: 'anita@x.io'),
      (name: 'Bo Chen', email: 'bo@x.io'),
    ];

Map<String, dynamic> _skip(String name, String email, String reason) =>
    <String, dynamic>{'name': name, 'email': email, 'reason': reason};

void main() {
  group('the dry run', () {
    test('sends dry_run only when asked, with the same candidates', () async {
      final _Rig r = _Rig();

      await r.store.checkImport(_asm(), _rows);
      await r.store.inviteMany(_asm(), _rows);

      expect(r.assigns, hasLength(2));
      expect(r.assigns[0]['dry_run'], isTrue);
      expect(
        r.assigns[1].containsKey('dry_run'),
        isFalse,
        reason: 'the real import must not carry the flag at all',
      );
      expect(r.assigns[0]['candidates'], r.assigns[1]['candidates']);
    });

    test('reads the counts and every skipped person off the answer', () async {
      final _Rig r = _Rig();
      r.answer = () async => _ok(<String, dynamic>{
        'dry_run': true,
        'assigned_count': 5,
        'already_assigned': 2,
        'skipped': <dynamic>[
          _skip('Bo Chen', 'bo@x.io', 'account is archived'),
          'not a record',
        ],
      });

      final ImportCheck c = await r.store.checkImport(_asm(), _rows);

      expect(c.added, 5);
      expect(c.already, 2);
      expect(c.error, isNull);
      expect(c.skipped, hasLength(1));
      expect(c.skipped.single.name, 'Bo Chen');
      expect(c.skipped.single.email, 'bo@x.io');
      expect(c.skipped.single.reason, 'account is archived');
    });

    test('a refused check comes back as its message, with no toast', () async {
      final _Rig r = _Rig();
      r.answer = () async => _json(<String, dynamic>{
        'ok': false,
        'error': <String, dynamic>{
          'code': 'invalid',
          'message': 'Row 4 is not an email address',
        },
      }, 422);
      final int toastsBefore = r.store.toaster.items.length;

      final ImportCheck c = await r.store.checkImport(_asm(), _rows);

      expect(c.error, 'Row 4 is not an email address');
      expect(c.skipped, isEmpty);
      expect(r.store.toaster.items.length, toastsBefore);
    });

    test(
      'a garbled answer is an error too, not a check stuck forever',
      () async {
        final _Rig r = _Rig();
        // A JSON list where the envelope should be: the client's own cast
        // throws a TypeError rather than an ApiError.
        r.answer = () async => _json(<dynamic>[]);

        final ImportCheck c = await r.store.checkImport(_asm(), _rows);

        expect(c.error, isNotNull);
        expect(c.skipped, isEmpty);
      },
    );

    test('offline there is nothing to check and nothing is sent', () async {
      final AppStore seed = AppStore();

      final ImportCheck c = await seed.checkImport(_asm(), _rows);

      expect(c.skipped, isEmpty);
      expect(c.error, isNull);
    });
  });

  group('the real import', () {
    // MAIN SENDS THE IMPORT IN BATCHES (`AppStore.inviteBatch`) and shows a
    // progress bar (`importProgress`) instead of stage's busy toast.
    test('shows its progress for as long as it runs, then stops', () async {
      final _Rig r = _Rig();
      final Completer<http.Response> held = Completer<http.Response>();
      r.answer = () => held.future;

      final Future<void> done = r.store.inviteMany(_asm(), _rows);
      await pumpEventQueue();

      expect(r.store.importProgress, (done: 0, total: 2));

      held.complete(_ok(<String, dynamic>{'assigned_count': 2}));
      await done;

      expect(r.store.importProgress, isNull);
      expect(r.store.toaster.items.last.message, '2 invited');
      expect(r.store.toaster.items.last.tone, Tone.ok);
    });

    test('a refused import clears the progress too', () async {
      final _Rig r = _Rig();
      r.answer = () async => _json(<String, dynamic>{
        'ok': false,
        'error': <String, dynamic>{'message': 'Row 4 is not an email address'},
      }, 422);

      await r.store.inviteMany(_asm(), _rows);

      expect(r.store.importProgress, isNull);
      expect(
        r.store.toaster.items.map((ToastMsg m) => m.message),
        contains('Row 4 is not an email address'),
      );
    });

    test(
      'anybody skipped turns the summary into a warning that says why',
      () async {
        final _Rig r = _Rig();
        r.answer = () async => _ok(<String, dynamic>{
          'assigned_count': 800,
          'already_assigned': 8,
          'skipped': <dynamic>[
            _skip('Bo Chen', 'bo@x.io', 'account is archived'),
            _skip('Cy Dee', 'cy@x.io', 'login is disabled'),
            _skip('Di Eve', 'di@x.io', 'third reason'),
          ],
        });

        await r.store.inviteMany(_asm(), _rows);

        final ToastMsg last = r.store.toaster.items.last;
        expect(last.tone, Tone.warn);
        expect(
          last.message,
          '800 invited, 8 already assigned, 3 skipped (e.g. Bo Chen <bo@x.io>: '
          'account is archived; Cy Dee <cy@x.io>: login is disabled)',
        );
      },
    );

    test('who every batch skipped is added up and named', () async {
      final _Rig r = _Rig();
      final List<({String name, String email})> rows =
          <({String name, String email})>[
            for (int i = 0; i < AppStore.inviteBatch + 10; i++)
              (name: 'P$i', email: 'p$i@x.io'),
          ];
      // Each batch's first person is refused while provisioning.
      r.answer = () async {
        final List<dynamic> sent =
            r.assigns.last['candidates'] as List<dynamic>;
        final Map<String, dynamic> first = sent.first as Map<String, dynamic>;
        return _ok(<String, dynamic>{
          'assigned_count': sent.length - 1,
          'skipped': <dynamic>[
            _skip(
              first['name'] as String,
              first['email'] as String,
              'login refused',
            ),
          ],
        });
      };

      await r.store.inviteMany(_asm(), rows);

      expect(r.assigns, hasLength(2));
      final ToastMsg last = r.store.toaster.items.last;
      expect(last.tone, Tone.warn);
      expect(
        last.message,
        '${rows.length - 2} invited, 2 skipped (e.g. P0 <p0@x.io>: login '
        'refused; P${AppStore.inviteBatch} <p${AppStore.inviteBatch}@x.io>: '
        'login refused)',
      );
    });
  });
}
