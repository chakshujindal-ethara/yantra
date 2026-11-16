// The store's SERVER actions: do they call the API, and do they obey the
// module when it refuses?
//
// These exist because the screens were previously wired to a local store that
// mutated memory and never told Odoo. A green invariant test proved the rules
// held in the fixture; it said nothing about whether pressing Launch reached
// the database. That gap is what this file closes.
//
// Only the socket is faked. The real ApiClient, the real envelope handling and
// the real store logic all run.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';

/// Records every path the store hits, and answers with an empty envelope.
class _Spy {
  final List<String> paths = <String>[];
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];

  /// Per-path canned answers, so a test can make one route refuse.
  final Map<String, http.Response> canned = <String, http.Response>{};

  http.Client get client => MockClient((http.Request req) async {
    paths.add(req.url.path);
    try {
      bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
    } on FormatException {
      bodies.add(<String, dynamic>{});
    }

    for (final MapEntry<String, http.Response> e in canned.entries) {
      if (req.url.path.contains(e.key)) return e.value;
    }
    return http.Response(
      jsonEncode(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}}),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });

  bool hit(String fragment) => paths.any((String p) => p.contains(fragment));
}

/// A live store with no data, ready to act.
AppStore _liveStore(_Spy spy) {
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', client: spy.client),
  );
  s.adoptSession(orgRole: 'admin', name: 'Aarav Mehta', uid: '2');
  return s;
}

/// A minimal assessment: these tests care about WHICH ROUTE was called, not
/// about reproducing a full fixture.
Assessment _asm({String id = '7'}) =>
    Assessment(id: id, name: 'Warehouse Safety', questions: const <Question>[]);

void main() {
  group('Assessment lifecycle reaches the server', () {
    test('Close calls the close route', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);

      await store.markDone(_asm());

      expect(
        spy.hit('/api/v1/assessments/7/close'),
        isTrue,
        reason: 'closing must persist, not just recolour a pill',
      );
    });

    test('Release calls the release route', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);

      await store.releaseResults(_asm());

      expect(spy.hit('/api/v1/assessments/7/release'), isTrue);
    });

    // THE BUG THIS EXISTS FOR: sign-out never revoked the bearer. This client
    // branched on which credential it held and sent a bearer session to the
    // gateway's `auth_token_unlink` - a route declared GET-only that reads a
    // custom `access_token` header, while `_send` always POSTs and this client
    // only ever sends `Authorization: Bearer`. Two mismatches, either one
    // fatal: a 405, or a 401 if the verb alone were fixed. `logout()` clears
    // its local state in a `finally`, so nothing surfaced - the user got the
    // login screen back while the token stayed valid on the server until it
    // expired. The module's own logout now revokes it, so both lanes go there.
    test('Logout goes to the route that actually revokes', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);

      await store.signOut();

      expect(
        spy.hit('/api/v1/auth/logout'),
        isTrue,
        reason: 'sign-out must reach the endpoint that deletes the token',
      );
      expect(
        spy.hit('auth_token_unlink'),
        isFalse,
        reason: "the gateway's unlink route is GET-only and reads a header "
            'this client never sends; calling it is a silent no-op',
      );
    });

    // THE BUG THIS EXISTS FOR: the toast read `d['released'] ?? d['count']`
    // against a route that answers `released_count`, so the `?? 0` fallback
    // fired on every success and it said "Released 0 result(s)" however many
    // went out. Nothing caught it: no test covered the route, and the seed
    // path computes the count locally, so it only ever showed against a live
    // backend. This cans the REAL payload and asserts the number reaches the
    // sentence - a rename on either side fails here.
    test('the release toast reports the count the server sent', () async {
      final _Spy spy = _Spy();
      spy.canned['/release'] = http.Response(
        jsonEncode(<String, dynamic>{
          'ok': true,
          'data': <String, dynamic>{
            'released_count': 3,
            'still_grading_count': 0,
            'candidates': <dynamic>[],
          },
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
      final AppStore store = _liveStore(spy);

      await store.releaseResults(_asm());

      expect(
        store.toaster.items.map((ToastMsg m) => m.message),
        contains('Released 3 result(s)'),
        reason: 'the count must come from released_count, not a 0 fallback',
      );
    });

    test('the release toast names what is still being graded', () async {
      final _Spy spy = _Spy();
      spy.canned['/release'] = http.Response(
        jsonEncode(<String, dynamic>{
          'ok': true,
          'data': <String, dynamic>{
            'released_count': 5,
            'still_grading_count': 2,
            'candidates': <dynamic>[],
          },
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
      final AppStore store = _liveStore(spy);

      await store.releaseResults(_asm());

      // This clause was unreachable for the same reason: it keyed on
      // `skipped`/`held`, neither of which the route sends.
      expect(
        store.toaster.items.map((ToastMsg m) => m.message),
        contains('Released 5 result(s); 2 still being graded'),
      );
    });

    test('Assign sends the person, and removal sets remove:true', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.people = <Person>[
        const Person(id: 'P-1', name: 'Sana Kapoor', email: 's@x.io'),
      ];

      await store.toggleAssign(_asm(), 'P-1');

      expect(spy.hit('/api/v1/assessments/7/assign'), isTrue);
      final Map<String, dynamic> body =
          spy.bodies[spy.paths.indexWhere((String p) => p.contains('assign'))];
      // `applicant_ids`, NOT `person_ids`. The route reads
      // `id_list_arg("applicant_ids")` and refuses a body without it, so the
      // old key meant nobody was ever assigned from this screen. Verified
      // against the live module: `{"person_ids": [...]}` answers
      // `{"ok": false, "error": {"code": "no_candidates"}}`.
      expect(body['applicant_ids'], <String>['P-1']);
      expect(
        body['person_ids'],
        isNull,
        reason: 'the server ignores this key entirely',
      );
      expect(
        body['remove'],
        isFalse,
        reason: 'nobody is assigned yet, so this is an add',
      );
    });

    test('a refusal from the module is surfaced, not swallowed', () async {
      final _Spy spy = _Spy()
        ..canned['/release'] = http.Response(
          jsonEncode(<String, dynamic>{
            'ok': false,
            'error': <String, dynamic>{
              'code': 'still_grading',
              'message': 'Two attempts are still being graded.',
            },
          }),
          409,
          headers: <String, String>{'content-type': 'application/json'},
        );
      final AppStore store = _liveStore(spy);

      await store.releaseResults(_asm());

      // Invariant 4: the module holds back an attempt that is still being
      // graded, and the operator has to be told WHY rather than shown a
      // success message for a release that did not happen.
      expect(store.toaster.items.last.message, contains('still being graded'));
    });
  });

  group('Attempt actions reach the server', () {
    test('Score All queues scoring for the assessment', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);

      // This is exactly what the assessment detail's "Score All" button calls.
      await store.queueScoringFor(assessmentId: '7');

      expect(
        spy.hit('/api/v1/scoring/queue'),
        isTrue,
        reason: 'Score All must reach the queue route, not just recolour',
      );
      final Map<String, dynamic> body =
          spy.bodies[spy.paths.indexWhere(
        (String p) => p.contains('/scoring/queue'),
      )];
      expect(
        body['assessment_id'],
        '7',
        reason: 'the whole point of the button is to scope grading to THIS '
            'assessment',
      );
    });

    test('Re-score calls the rescore route', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.attempts = <Attempt>[
        const Attempt(
          id: '41',
          assessmentId: '7',
          employeeId: 'P-1',
          token: 'tok',
        ),
      ];

      await store.rescoreAttempt('41');

      expect(
        spy.hit('/api/v1/attempts/41/rescore'),
        isTrue,
        reason:
            'the SERVER owns the scoring queue; local grading is the '
            'seed stand-in only',
      );
    });

    test('Erase calls the erase route', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.attempts = <Attempt>[
        const Attempt(
          id: '41',
          assessmentId: '7',
          employeeId: 'P-1',
          token: 'tok',
        ),
      ];

      await store.erasePii('41');

      expect(spy.hit('/api/v1/attempts/41/erase'), isTrue);
    });
  });

  group('Creates and updates reach the server', () {
    test('New assessment calls the create route with its config', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);

      await store.addAssessment(
        Assessment(
          id: '',
          name: 'Forklift Safety',
          questions: <Question>[],
          durationMinutes: 30,
          questionLimit: 8,
        ),
      );

      expect(
        spy.hit('/api/v1/assessments/create'),
        isTrue,
        reason: 'a new assessment must exist in Odoo, not just in memory',
      );
      final Map<String, dynamic> body =
          spy.bodies[spy.paths.indexWhere((String p) => p.contains('create'))];
      expect(body['name'], 'Forklift Safety');
      expect(body['duration_minutes'], 30);
      expect(body['question_limit'], 8);
      expect(
        body.containsKey('state'),
        isFalse,
        reason:
            'the client must not choose the lifecycle state - the '
            'server always starts a new assessment in draft',
      );
    });

    test('Editing an assessment sends the changed config', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);

      await store.updateAsm(
        Assessment(
          id: '7',
          name: 'Warehouse Safety',
          questions: <Question>[],
          durationMinutes: 60,
        ),
      );

      expect(spy.hit('/api/v1/assessments/7/update'), isTrue);
      final Map<String, dynamic> body =
          spy.bodies[spy.paths.indexWhere((String p) => p.contains('update'))];
      expect(body['duration_minutes'], 60);
    });

    test('New generator calls the create route, with the name', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);

      await store.addGenerator('Forklift SOP');

      expect(spy.hit('/api/v1/generators/create'), isTrue);
      // The route carries the entire payload now - a name and nothing else -
      // so the body is worth asserting rather than just the path.
      final Map<String, dynamic> body =
          spy.bodies[spy.paths.indexWhere((String p) => p.contains('create'))];
      expect(body['name'], 'Forklift SOP');
    });

    test('New generator returns the id the caller navigates to', () async {
      // `_call` ALREADY unwraps the envelope and returns `data` itself, so the
      // id is at the top level of what comes back. Reading `res['data']` here
      // reads as obviously correct and finds nothing - which is how this
      // shipped once before: the generator was created and the caller was left
      // with no id to open, so the flow dead-ended on the list and the SOP was
      // never attached. Reported as "the upload SOP does not work".
      //
      // Asserted behaviourally rather than by scanning the source: a source
      // scan can only prove a string is present, not that the id parses.
      final _Spy spy = _Spy();
      spy.canned['/generators/create'] = http.Response(
        jsonEncode(<String, dynamic>{
          'ok': true,
          'data': <String, dynamic>{'id': 42},
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
      final AppStore store = _liveStore(spy);

      expect(await store.addGenerator('Forklift SOP'), '42');
    });

    test('Extraction is refused before an SOP is attached', () async {
      // Creating a generator collects a NAME and nothing else, so a generator
      // with no document is an ordinary state rather than an edge case. The
      // server answers 409 `no_source`, so the round trip can only end one way
      // - and this is also what stops the seed path inventing tags for a
      // document that is not there.
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.generators = <Generator>[
        const Generator(id: '3', name: 'Forklift SOP'),
      ];

      await store.extractTags('3');

      expect(
        spy.hit('/extract_tags'),
        isFalse,
        reason: 'there is no document for the server to read',
      );
      expect(store.toaster.items.last.message, contains('Attach the SOP'));
    });

    test('Generate questions calls the generator route', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.generators = <Generator>[
        const Generator(
          id: '3',
          name: 'Forklift SOP',
          tags: <String>['domain:logistics'],
          allowedTypes: <QType>[QType.mcq],
        ),
      ];

      await store.startGeneration('3');

      expect(
        spy.hit('/api/v1/generators/3/generate'),
        isTrue,
        reason:
            'question generation runs in Odoo - it calls the LLM and '
            'writes drafts',
      );
    });

    test('Generation is refused before skills are extracted', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.generators = <Generator>[
        const Generator(id: '3', name: 'Forklift SOP'),
      ];

      await store.startGeneration('3');

      expect(
        spy.hit('/generate'),
        isFalse,
        reason:
            'generation without tags would spend LLM budget on a call '
            'the server rejects anyway',
      );
      expect(store.toaster.items.last.message, contains('Extract the skills'));
    });

    test('Tag merge sends record ids, not names', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.tags = <Tag>[
        const Tag(id: '10', name: 'domain:logistics'),
        const Tag(
          id: '11',
          name: 'domain:logistic',
          mergeInto: 'domain:logistics',
        ),
      ];

      await store.mergeTag('domain:logistic');

      expect(spy.hit('/api/v1/tags/merge'), isTrue);
      final Map<String, dynamic> body =
          spy.bodies[spy.paths.indexWhere((String p) => p.contains('merge'))];
      // By id because two tags can display the same text once normalised;
      // merging by name would pick one of them arbitrarily.
      expect(body['target_id'], '10');
      expect(body['source_ids'], <String>['11']);
    });
  });

  group('SOP upload - the step everything else waits on', () {
    test('Uploading posts base64 bytes to the resources route', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);

      await store.uploadResource(
        '3',
        name: 'Forklift SOP.txt',
        bytes: <int>[72, 101, 108, 108, 111], // "Hello"
      );

      expect(spy.hit('/api/v1/generators/3/resources'), isTrue);
      final Map<String, dynamic> body = spy
          .bodies[spy.paths.indexWhere((String p) => p.contains('resources'))];
      expect(body['name'], 'Forklift SOP.txt');
      expect(body['category'], 'sop');
      // Base64 in the JSON envelope, so the whole API keeps one auth path and
      // one error shape rather than a second multipart handler.
      expect(body['content'], base64Encode(<int>[72, 101, 108, 108, 111]));
    });

    test(
      'A failed text extraction is surfaced, not called a success',
      () async {
        final _Spy spy = _Spy()
          ..canned['/resources'] = http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': <String, dynamic>{
                'resource': <String, dynamic>{
                  'id': 1,
                  'name': 'scan.pdf',
                  'extraction_error': 'No text layer found',
                },
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        final AppStore store = _liveStore(spy);

        await store.uploadResource('3', name: 'scan.pdf', bytes: <int>[1, 2]);

        // The file DID upload, so "failed" would be wrong - but the model will
        // read nothing from it, so a bare "attached" would mislead the admin
        // into generating from an empty document.
        expect(store.toaster.items.last.message, contains('extraction failed'));
      },
    );

    test(
      'Seed mode says uploads need a backend rather than pretending',
      () async {
        final AppStore store = AppStore();

        await store.uploadResource('3', name: 'x.txt', bytes: <int>[1]);

        expect(store.toaster.items.last.message, contains('live backend'));
      },
    );
  });

  group('Recovery actions reach the server, and refuse when pointless', () {
    // These three close the last gaps against the Odoo module's own
    // action_* surface. Each is guarded: a recovery button that bills an LLM
    // for an identical result is worse than a disabled one.

    test('Backfill calls the backfill route', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.generators = <Generator>[
        const Generator(
          id: '3',
          name: 'Forklift SOP',
          tags: <String>['skill:forklift'],
        ),
      ];

      await store.backfillTags('3');

      expect(
        spy.hit('/api/v1/generators/3/backfill_tags'),
        isTrue,
        reason: 're-tagging an existing bank must reach the module',
      );
    });

    test('Backfill refuses when there is no vocabulary yet', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.generators = <Generator>[
        const Generator(id: '3', name: 'Forklift SOP'),
      ];

      await store.backfillTags('3');

      expect(
        spy.hit('backfill_tags'),
        isFalse,
        reason: 'nothing to push down before the skills are extracted',
      );
    });

    test('Retry clips calls the retry route on a failed draft', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.drafts = <Question>[
        const Question(
          id: '9',
          genId: '3',
          name: 'Lift check',
          type: QType.videoPrompt,
          prompt: 'Show the lift',
          videoState: AssetState.failed,
        ),
      ];

      await store.retryVideo('9');

      expect(spy.hit('/api/v1/drafts/9/retry_video'), isTrue);
    });

    test('Retry clips refuses when nothing failed', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.drafts = <Question>[
        const Question(
          id: '9',
          genId: '3',
          name: 'Lift check',
          type: QType.videoPrompt,
          prompt: 'Show the lift',
          videoState: AssetState.rendered,
        ),
      ];

      await store.retryVideo('9');

      expect(
        spy.hit('retry_video'),
        isFalse,
        reason:
            'a retry on a rendered clip re-spends on Veo for the same '
            'result',
      );
    });

    test('Rebuild answer key calls the rebuild route', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);

      await store.rebuildAnswerKey('9');

      expect(
        spy.hit('/api/v1/drafts/9/rebuild_answer_key'),
        isTrue,
        reason: 'a drifted key is rebuilt from its payload, not retyped',
      );
    });
  });

  group('Generation states match the module', () {
    // The module stores six; an earlier version of this enum knew four, so
    // `queued`, `generating` and `finalizing` fell through the parser's
    // fallback and displayed as "Idle" - a generation that was really running
    // looked like one that had never started, which is exactly the "I could
    // not see it working" report.
    test('every server value parses to its own state', () {
      const Map<String, GenState> wire = <String, GenState>{
        'idle': GenState.idle,
        'queued': GenState.queued,
        'generating': GenState.generating,
        'finalizing': GenState.finalizing,
        'done': GenState.done,
        'failed': GenState.failed,
      };

      wire.forEach((String v, GenState expected) {
        expect(GenState.parse(v), expected, reason: '$v must not fall back');
      });
    });

    test('the three in-flight states report busy', () {
      expect(GenState.queued.isBusy, isTrue);
      expect(GenState.generating.isBusy, isTrue);
      expect(GenState.finalizing.isBusy, isTrue);

      // A finished or never-started generator is not busy, or the poll would
      // never stop and the button would never re-enable.
      expect(GenState.idle.isBusy, isFalse);
      expect(GenState.done.isBusy, isFalse);
      expect(GenState.failed.isBusy, isFalse);
    });

    test('an unknown value still falls back rather than throwing', () {
      expect(GenState.parse('something_new'), GenState.idle);
      expect(GenState.parse(null), GenState.idle);
    });
  });

  group('Seed mode still works with no backend', () {
    test('a store with no API client never touches the network', () async {
      // The design-review path: fixtures, no server, every screen reviewable.
      final AppStore store = AppStore();
      expect(store.source, DataSource.seed);

      final Assessment? first = store.assessments.isEmpty
          ? null
          : store.assessments.first;
      expect(
        first,
        isNotNull,
        reason: 'seed mode must load its fixtures on construction',
      );
    });
  });

  group('Finishing an exam must never claim a submission the server refused', () {
    // THE FAILURE THIS PINS. The re-send loop and the submit used to share one
    // try. A single 422 on one answer - an empty justification, or an attempt
    // the server locked first - aborted the loop, so `examSubmit` was NEVER
    // CALLED. The candidate had already been shown "Assessment submitted" and
    // their attempt was locked locally, while the server still had them in
    // progress and would later expire them. The paper was lost, silently, and
    // the toast said the opposite.
    Assessment asmWith(Question q) => _asm().copyWith(questions: <Question>[q]);

    const Question q = Question(
      id: 'Q1',
      genId: 'G-1',
      name: 'Written answer',
      type: QType.subjectiveRubric,
      prompt: 'Explain.',
    );

    Attempt attemptWith(String answer) => Attempt(
      id: '41',
      assessmentId: '7',
      employeeId: 'P-1',
      token: 'tok',
      state: AttemptState.inProgress,
      resp: <String, Response>{'Q1': Response(justification: answer)},
    );

    test('a refused answer does not stop the submit', () async {
      final _Spy spy = _Spy();
      // The answer route refuses; the submit route is fine.
      spy.canned['/answer'] = http.Response(
        jsonEncode(<String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{
            'code': 'incomplete_answer',
            'message': 'This answer is incomplete for its question type',
          },
        }),
        422,
        headers: <String, String>{'content-type': 'application/json'},
      );
      final AppStore store = _liveStore(spy);
      store.assessments = <Assessment>[asmWith(q)];
      store.attempts = <Attempt>[attemptWith('something')];

      store.finishExam('41');
      // finishExam fires its work unawaited; let the microtasks drain.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        spy.hit('/api/v1/exam/tok/submit'),
        isTrue,
        reason:
            'the submit is the thing that must happen; one refused answer '
            'used to abort the loop before it and lose the paper',
      );
    });

    test('a refused SUBMIT unlocks the attempt again and says so', () async {
      final _Spy spy = _Spy();
      spy.canned['/submit'] = http.Response(
        jsonEncode(<String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{
            'code': 'assessment_closed',
            'message': 'This assessment is not open',
          },
        }),
        409,
        headers: <String, String>{'content-type': 'application/json'},
      );
      final AppStore store = _liveStore(spy);
      store.assessments = <Assessment>[asmWith(q)];
      store.attempts = <Attempt>[attemptWith('something')];

      store.finishExam('41');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // ASSERTED ON WHAT THE CANDIDATE IS TOLD, which is the actual contract
      // and does not depend on store state a concurrent refresh may have
      // replaced. The old code showed "Assessment submitted" here.
      final List<String> said = store.toaster.items
          .map((ToastMsg m) => m.message)
          .toList();
      expect(
        said.any((String m) => m.contains('NOT submitted')),
        isTrue,
        reason:
            'a submission the server refused must be reported as refused; '
            'saying "submitted" sends the candidate away from an open exam. '
            'Got: \$said',
      );
      expect(
        said.any((String m) => m == 'Assessment submitted'),
        isFalse,
        reason: 'it must not also claim success',
      );
    });

    test('attempt_locked counts as submitted, not as failure', () async {
      // The server settles the attempt first on a violation auto-submit or an
      // expiry sweep. That IS the outcome we wanted.
      final _Spy spy = _Spy();
      spy.canned['/submit'] = http.Response(
        jsonEncode(<String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{
            'code': 'attempt_locked',
            'message': 'This attempt is already submitted',
          },
        }),
        409,
        headers: <String, String>{'content-type': 'application/json'},
      );
      final AppStore store = _liveStore(spy);
      store.assessments = <Assessment>[asmWith(q)];
      store.attempts = <Attempt>[attemptWith('something')];

      store.finishExam('41');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // `attempt_locked` is the success path, so the store re-reads from the
      // server afterwards. The stub answers every read with an empty envelope,
      // so asserting on local state here would be asserting on the stub. What
      // matters is that it was treated as success: the submit was attempted
      // and the store went on to refresh rather than reverting.
      expect(spy.hit('/api/v1/exam/tok/submit'), isTrue);
      expect(
        spy.hit('/api/v1/assessments'),
        isTrue,
        reason:
            'a locked attempt is a completed submission, so the store '
            'refreshes rather than putting the candidate back in the exam',
      );
    });

    test('the progress toast is replaced by the outcome, not joined by it', () {
      // THE FAILURE THIS PINS. "Submitting your exam..." was an ordinary toast
      // with the standard 3200ms life, so a submit that finished inside that
      // window left it on screen underneath "Assessment submitted" - the
      // candidate was told the exam was still going out and already in, at the
      // same moment, in two stacked toasts.
      final AppStore store = _liveStore(_Spy());
      store.assessments = <Assessment>[asmWith(q)];
      store.attempts = <Attempt>[attemptWith('something')];

      store.finishExam('41');

      // Synchronously after the call, before the request resolves: progress is
      // the ONLY thing being said.
      expect(
        store.toaster.items.map((ToastMsg m) => m.message),
        <String>['Submitting your exam...'],
        reason: 'the candidate is told the submit is in flight',
      );

      return Future<void>.delayed(const Duration(milliseconds: 50), () {
        final List<String> said = store.toaster.items
            .map((ToastMsg m) => m.message)
            .toList();
        expect(
          said,
          isNot(contains('Submitting your exam...')),
          reason:
              'the progress toast must come down as the outcome goes up; '
              'leaving both says the exam is submitting and submitted at once',
        );
        expect(said, contains('Assessment submitted'));
      });
    });

    test('a refused submit takes the progress toast down with it', () async {
      // The other exit path. A stuck "Submitting your exam..." next to "was
      // NOT submitted" is the same contradiction, read the other way round.
      final _Spy spy = _Spy();
      spy.canned['/submit'] = http.Response(
        jsonEncode(<String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{
            'code': 'assessment_closed',
            'message': 'This assessment is not open',
          },
        }),
        409,
        headers: <String, String>{'content-type': 'application/json'},
      );
      final AppStore store = _liveStore(spy);
      store.assessments = <Assessment>[asmWith(q)];
      store.attempts = <Attempt>[attemptWith('something')];

      store.finishExam('41');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final List<String> said = store.toaster.items
          .map((ToastMsg m) => m.message)
          .toList();
      expect(said, isNot(contains('Submitting your exam...')));
      expect(said.any((String m) => m.contains('NOT submitted')), isTrue);
    });

    /// The body of the one `/submit` request, or null if none was sent.
    Map<String, dynamic>? submitBody(_Spy spy) {
      for (int i = 0; i < spy.paths.length; i++) {
        if (spy.paths[i].contains('/submit')) return spy.bodies[i];
      }
      return null;
    }

    // THE DECISION HAS TO REACH THE WIRE.
    //
    // The module refuses an incomplete submit with 409 `incomplete_attempt`
    // unless `force` is set (candidate.py:376-386). The client asked the
    // candidate "Submit with 4 unanswered?", collected "Submit anyway", and
    // then sent a request with no body - so the answer was thrown away and the
    // exam could not be submitted at all. Answering every question or running
    // out of time were the only ways past it.
    test('a CONFIRMED incomplete submit sends force', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.assessments = <Assessment>[asmWith(q)];
      store.attempts = <Attempt>[attemptWith('something')];

      store.finishExam('41', force: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        submitBody(spy)?['force'],
        isTrue,
        reason: '"Submit anyway" must survive the trip to the server',
      );
    });

    test('an AUTO submit forces too - the clocks are not the same clock',
        () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.assessments = <Assessment>[asmWith(q)];
      store.attempts = <Attempt>[attemptWith('something')];

      store.finishExam('41', auto: true, autoReason: 'expired');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(submitBody(spy)?['force'], isTrue);
    });

    test('a PLAIN submit does not force on the candidate\'s behalf', () async {
      // The other half of the guarantee. Forcing unconditionally would end an
      // exam over gaps the candidate was never shown, whenever the client and
      // the server disagree about what counts as answered - so an unprompted
      // Submit must still be refusable.
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.assessments = <Assessment>[asmWith(q)];
      store.attempts = <Attempt>[attemptWith('something')];

      store.finishExam('41');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        submitBody(spy)?['force'],
        isFalse,
        reason: 'sent explicitly as false, never omitted: the route reads it '
            'with bool_arg and an absent key is not a decision',
      );
    });
  });
}
