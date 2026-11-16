// The three features added in this pass, at the seams where they broke.
//
// Each of these was found by comparing what the client sends to what the
// module actually reads, never by reading the client alone.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/gates.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/services/proctor_stub.dart';

/// Captures the request bodies an ApiClient produces.
class _Spy extends http.BaseClient {
  final List<String> paths = <String>[];
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    paths.add(request.url.path);
    final String body = (request as http.Request).body;
    bodies.add(
      body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(body) as Map<String, dynamic>,
    );
    return http.StreamedResponse(
      Stream<List<int>>.value(
        utf8.encode(jsonEncode(<String, dynamic>{'ok': true, 'data': {}})),
      ),
      200,
    );
  }

  Map<String, dynamic> bodyFor(String fragment) =>
      bodies[paths.indexWhere((String p) => p.contains(fragment))];
}

void main() {
  group('Invitations reach the module', () {
    test(
      'assign uses applicant_ids, the key the route actually reads',
      () async {
        // `person_ids` was silently wrong: the route reads
        // `id_list_arg("applicant_ids")` and answers
        // `{"ok": false, "error": {"code": "no_candidates"}}` without it, so
        // nobody could ever be assigned from the UI.
        final _Spy spy = _Spy();
        await ApiClient(
          client: spy,
          baseUrl: 'http://x',
        ).assign('7', personIds: <String>['3']);
        final Map<String, dynamic> b = spy.bodyFor('assign');
        expect(b['applicant_ids'], <String>['3']);
        expect(
          b.containsKey('person_ids'),
          isFalse,
          reason: 'the module ignores this key entirely',
        );
      },
    );

    test('a first-time invitee is sent as name and email', () async {
      // The roster is built from PAST attempts, so somebody being invited for
      // the first time is not in it and never will be. `candidates` is the
      // only path that can add them.
      final _Spy spy = _Spy();
      await ApiClient(client: spy, baseUrl: 'http://x').assign(
        '7',
        invites: <({String name, String email})>[
          (name: 'Sana Kapoor', email: 's@x.io'),
        ],
      );
      final Map<String, dynamic> b = spy.bodyFor('assign');
      expect(b['candidates'], <Map<String, String>>[
        <String, String>{'name': 'Sana Kapoor', 'email': 's@x.io'},
      ]);
    });

    test('no invites means no candidates key at all', () async {
      // Sending `"candidates": []` alongside real applicant_ids is harmless
      // but noisy; more importantly an empty list must never be mistaken for
      // "assign nobody".
      final _Spy spy = _Spy();
      await ApiClient(
        client: spy,
        baseUrl: 'http://x',
      ).assign('7', personIds: <String>['3']);
      expect(spy.bodyFor('assign').containsKey('candidates'), isFalse);
    });

    test('the invitation failure REASON survives parsing', () {
      // The API sends `invite_error` beside `invite_state: "failed"`. Dropping
      // it leaves the UI saying only "Failed", so an operator cannot tell a
      // wrong address from a mail server that is down - and presses Resend
      // forever on something a resend cannot fix.
      final Attempt a = Attempt.fromJson(<String, dynamic>{
        'id': 4,
        'invite_state': 'failed',
        'invite_error': 'Could not contact the mail server',
      });
      expect(a.inviteState, InviteState.failed);
      expect(a.inviteError, 'Could not contact the mail server');
    });
  });

  group('Threshold recompute', () {
    test('the pending flag is parsed from the wire', () {
      // The server recomputes inline for a small assessment and defers to a
      // cron for a large one. Without this an operator moves the threshold,
      // sees the OLD pass/fail, and concludes nothing happened.
      final Assessment a = Assessment.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'x',
        'threshold_recompute_pending': true,
      });
      expect(a.thresholdRecomputePending, isTrue);
    });

    test('it defaults to false when the server does not say', () {
      final Assessment a = Assessment.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'x',
      });
      expect(
        a.thresholdRecomputePending,
        isFalse,
        reason: 'a missing flag must not claim work is queued',
      );
    });

    test('subjective_threshold is what gets sent, as a float', () async {
      // A subjective edit alone never sends `pass_threshold`: the two are
      // separate settings on the server.
      final _Spy spy = _Spy();
      await ApiClient(
        client: spy,
        baseUrl: 'http://x',
      ).updateAssessment('7', subjectiveThreshold: 45);
      final Map<String, dynamic> b = spy.bodyFor('update');
      expect(b['subjective_threshold'], 45);
      expect(b.containsKey('pass_threshold'), isFalse);
    });

    test('an unchanged field is omitted, not resent', () async {
      // The route refuses ANY non-threshold field once the assessment leaves
      // draft. Sending the whole record meant a legal threshold change was
      // rejected because `duration_minutes` rode along unchanged beside it.
      final _Spy spy = _Spy();
      await ApiClient(
        client: spy,
        baseUrl: 'http://x',
      ).updateAssessment('7', subjectiveThreshold: 45);
      final Map<String, dynamic> b = spy.bodyFor('update');
      expect(b.containsKey('duration_minutes'), isFalse);
      expect(b.containsKey('name'), isFalse);
    });
  });

  group('Proctoring rules', () {
    test('a rule set with nothing on attaches no listeners', () {
      // `any` is what stops the watcher running at all. If it were wrong the
      // exam would attach browser listeners for rules an operator switched
      // off, and report violations nobody asked for.
      expect(const ProctorRules().any, isFalse);
    });

    test('one rule is enough to start watching', () {
      expect(const ProctorRules(tabSwitch: true).any, isTrue);
      expect(const ProctorRules(devtools: true).any, isTrue);
    });

    test('every rule defaults to OFF', () {
      // A rule must only ever be enforced because somebody turned it on. A
      // default of true would proctor an exam whose settings say not to.
      const ProctorRules r = ProctorRules();
      expect(<bool>[
        r.tabSwitch,
        r.copyPaste,
        r.rightClick,
        r.devtools,
        r.fullscreen,
      ], everyElement(isFalse));
    });
  });

  group('The draft roster reaches the screen', () {
    test('roster parses from the detail payload', () {
      // `/candidates` lists ATTEMPT records, which only exist after launch.
      // Before that the roster lives in `roster` (hr.applicant) and nowhere
      // else, so an invitation to a draft was stored correctly on the server
      // and displayed nowhere - the Assign tab read "Nobody is assigned yet".
      final Assessment a = Assessment.fromJson(<String, dynamic>{
        'id': 2,
        'name': 'Warehouse Safety',
        'candidate_count': 2,
        'roster': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 13,
            'name': 'Ravi Kumar',
            'email': 'ravi@example.com',
          },
          <String, dynamic>{
            'id': 2,
            'name': 'Priya Sharma',
            'email': 'priya@example.com',
          },
        ],
      });
      expect(a.roster.length, 2);
      expect(a.roster.first.name, 'Ravi Kumar');
      expect(a.roster.first.email, 'ravi@example.com');
    });

    test('a payload with no roster yields an empty list, never null', () {
      final Assessment a = Assessment.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'x',
      });
      expect(a.roster, isEmpty);
    });

    test('the launch gate counts the roster when there are no attempts', () {
      // This gate BLOCKED the launch that would have created the attempts it
      // was looking for: with a full roster and no attempts it reported
      // "Nobody is assigned", which is the one thing it exists to check.
      final Assessment a = Assessment.fromJson(<String, dynamic>{
        'id': 2,
        'name': 'x',
        'roster': <Map<String, dynamic>>[
          <String, dynamic>{'id': 13, 'name': 'Ravi', 'email': 'r@x.io'},
        ],
      });
      final List<GateResult> gates = Gates.launch(
        a,
        attempts: const <Attempt>[],
        generator: null,
        bank: const <Question>[],
      );
      final GateResult candidateGate = gates.firstWhere(
        (GateResult g) => g.name.contains('candidate is assigned'),
      );
      expect(
        candidateGate.ok,
        isTrue,
        reason:
            'a roster of 1 must satisfy the "at least one candidate" '
            'gate even before any attempt exists',
      );
      expect(candidateGate.why, contains('1 candidate'));
    });
  });

  group('List routes are not silently truncated', () {
    // DEFAULT_LIMIT is 40 and MAX_LIMIT is 200 on every list route. A caller
    // that sends no limit gets 40 rows and `meta.has_more: true`, which the
    // client never read - so item 41 onward simply vanished, with no error.
    // Proven live: with 66 bank questions the old call returned 40.
    test('every list call sends an explicit limit', () async {
      final _Spy spy = _Spy();
      final ApiClient api = ApiClient(client: spy, baseUrl: 'http://x');
      await api.assessments();
      await api.bank();
      await api.drafts();
      await api.tags();
      await api.generators();
      await api.candidates('7');
      await api.responses();
      for (int i = 0; i < spy.paths.length; i++) {
        expect(
          spy.bodies[i]['limit'],
          isNotNull,
          reason: '${spy.paths[i]} would be capped at 40 without a limit',
        );
        expect(
          spy.bodies[i]['limit'],
          greaterThan(40),
          reason: '${spy.paths[i]} must ask for more than the default',
        );
      }
    });

    test('candidates accepts an offset so pages can be followed', () async {
      final _Spy spy = _Spy();
      await ApiClient(
        client: spy,
        baseUrl: 'http://x',
      ).candidates('7', limit: 200, offset: 200);
      final Map<String, dynamic> b = spy.bodyFor('candidates');
      expect(b['limit'], 200);
      expect(b['offset'], 200);
    });
  });

  group('Detail routes carry what list routes omit', () {
    test('a bank question detail is fetched by id', () async {
      // The list row has 21 of 31 keys. The missing ten are images, videos,
      // dimensions, solution, solution_rationale and subjective_rubric -
      // everything the preview exists to show.
      final _Spy spy = _Spy();
      await ApiClient(client: spy, baseUrl: 'http://x').bankQuestion('8');
      expect(spy.paths.single, '/api/v1/bank/8');
    });

    test('an answer detail is fetched by attempt and question', () async {
      // The /responses list row omits lines, subscores, justification,
      // grading and correct_summary: the per-dimension marking an operator
      // opens the answer to read.
      final _Spy spy = _Spy();
      await ApiClient(client: spy, baseUrl: 'http://x').response('4', '10');
      expect(spy.paths.single, '/api/v1/responses/4/10');
    });
  });

  group('Launch sends the flag the route actually reads', () {
    test('a real launch sends confirm:true, never dry_run', () async {
      // The route reads bool_arg("confirm") and defaults to a DRY RUN. The
      // client used to send `dry_run: false`, which the server never looks
      // at, so every launch answered {"ok": true, "launched": false}: the
      // button reported success, no attempt was created, and the assessment
      // stayed in draft. Same class as person_ids / applicant_ids.
      final _Spy spy = _Spy();
      await ApiClient(client: spy, baseUrl: 'http://x').launch('7');
      final Map<String, dynamic> sent = spy.bodyFor('/launch');
      expect(sent['confirm'], isTrue, reason: 'a real launch must set confirm');
      expect(
        sent.containsKey('dry_run'),
        isFalse,
        reason: 'dry_run is not a key this route reads',
      );
    });

    test('a dry run sends confirm:false so nothing is written', () async {
      final _Spy spy = _Spy();
      await ApiClient(
        client: spy,
        baseUrl: 'http://x',
      ).launch('7', dryRun: true);
      expect(spy.bodyFor('/launch')['confirm'], isFalse);
    });
  });

  group('The exam runner sends the keys the route reads', () {
    test('an answer sends selected_option_ids, never option_ids', () async {
      // PROVEN LIVE against /api/v1/exam/<token>/answer:
      //   option_ids          -> 422 "This answer is incomplete for its
      //                          question type" (the route saw no selection)
      //   selected_option_ids -> ok: true
      // The client sent `option_ids`, so every multiple-choice answer a
      // candidate gave was refused or stored blank and scored zero.
      final _Spy spy = _Spy();
      await ApiClient(
        client: spy,
        baseUrl: 'http://x',
      ).examAnswer('tok-1', questionId: '9', optionIds: <String>['154']);
      final Map<String, dynamic> body = spy.bodyFor('/answer');
      expect(body['selected_option_ids'], <String>['154']);
      expect(
        body.containsKey('option_ids'),
        isFalse,
        reason: 'option_ids is not a key this route reads',
      );
    });

    test('labels are sent as label_answers', () async {
      // The route reads arg("label_answers"); `labels` was ignored, so an
      // image-labelling answer arrived empty.
      final _Spy spy = _Spy();
      await ApiClient(client: spy, baseUrl: 'http://x').examAnswer(
        'tok-1',
        questionId: '9',
        labels: <int, String>{1: 'forks', 2: 'mast'},
      );
      final Map<String, dynamic> body = spy.bodyFor('/answer');
      expect(body['label_answers'], <String, String>{
        '1': 'forks',
        '2': 'mast',
      });
      expect(body.containsKey('labels'), isFalse);
    });
  });

  group('The generator update route gets the names it allows', () {
    test('the image label ceiling is sent as image_label_count', () async {
      // The field is in the route's GENERATOR_FIELDS allow-list under this
      // exact name. Anything else is dropped silently on a 200 - the same
      // shape of failure as person_ids / applicant_ids above, where the save
      // reports success and the value never moves.
      final _Spy spy = _Spy();
      await ApiClient(
        client: spy,
        baseUrl: 'http://x',
      ).updateGenerator('59', imageLabelCount: 8);
      final Map<String, dynamic> body = spy.bodyFor('/generators/59/update');
      expect(body['image_label_count'], 8);
      expect(
        body.containsKey('imageLabelCount'),
        isFalse,
        reason: 'the route reads snake_case, not the client spelling',
      );
    });

    test('an unset ceiling is omitted, not sent as a zero', () async {
      // Null-aware map entries: an ABSENT key means "leave it alone". A 0
      // would be a value the module refuses, so a plain rename would start
      // failing on a field the operator never touched.
      final _Spy spy = _Spy();
      await ApiClient(
        client: spy,
        baseUrl: 'http://x',
      ).updateGenerator('59', name: 'renamed');
      final Map<String, dynamic> body = spy.bodyFor('/generators/59/update');
      expect(body['name'], 'renamed');
      expect(body.containsKey('image_label_count'), isFalse);
    });
  });

  group('Bank filtering uses the key the route reads', () {
    test('the type filter is sent as question_type', () async {
      // Verified live: type=mcq returned 35 rows (the whole bank),
      // question_type=mcq returned 9. Picking a type filtered nothing.
      final _Spy spy = _Spy();
      await ApiClient(client: spy, baseUrl: 'http://x').bank(type: 'mcq');
      final Map<String, dynamic> body = spy.bodyFor('/bank');
      expect(body['question_type'], 'mcq');
      expect(body.containsKey('type'), isFalse);
    });
  });
}
