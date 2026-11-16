// THE BUG, as it reached stage: a draft carrying a quality warning could not be
// approved from any screen.
//
// The server refuses one unless the request says the warnings were reviewed
// (`/drafts/<id>/approve` answers 422 `warnings_unacknowledged` otherwise). The
// store held that acknowledgement in `acknowledged` and gated its own local
// decision on it, then called `approveDraft(id)` with the flag defaulted to
// false - so the tick unlocked the button and nothing else. The reviewer saw
// "Approved - ... is in the bank" and, beside it, "This draft has unresolved
// authoring warnings", because the success toast fired before the request.
//
// Only the socket is faked, so the real ApiClient serialises the real body.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';

class _Spy {
  final List<String> paths = <String>[];
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];

  /// Set to make the approve route refuse, the way the server does.
  http.Response? approveAnswer;

  /// Rows the LIST route answers with.
  ///
  /// `_act` re-reads in a `finally`, so without this the refresh that follows
  /// every decision empties `drafts` and a rolled-back draft looks deleted
  /// rather than restored - the state under test would be indistinguishable
  /// from the harness having no data.
  List<Map<String, dynamic>> draftRows = <Map<String, dynamic>>[];

  http.Client get client => MockClient((http.Request req) async {
    paths.add(req.url.path);
    try {
      bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
    } on FormatException {
      bodies.add(<String, dynamic>{});
    }
    if (approveAnswer != null && req.url.path.contains('/approve')) {
      return approveAnswer!;
    }
    if (req.url.path.endsWith('/drafts')) {
      return http.Response(
        jsonEncode(<String, dynamic>{'ok': true, 'data': draftRows}),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    return http.Response(
      jsonEncode(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}}),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });

  /// The body posted to the first path containing [fragment].
  Map<String, dynamic> bodyFor(String fragment) {
    for (int i = 0; i < paths.length; i++) {
      if (paths[i].contains(fragment)) return bodies[i];
    }
    return <String, dynamic>{};
  }

  bool hit(String fragment) => paths.any((String p) => p.contains(fragment));
}

/// The server's own refusal, verbatim in shape.
http.Response get _warningsRefusal => http.Response(
  jsonEncode(<String, dynamic>{
    'ok': false,
    'error': <String, dynamic>{
      'code': 'warnings_unacknowledged',
      'message':
          'This draft has unresolved authoring warnings. Re-send with '
          'acknowledge_warnings to approve it anyway.',
      'warnings': <String>['source_reference'],
    },
  }),
  422,
  headers: <String, String>{'content-type': 'application/json'},
);

AppStore _liveStore(_Spy spy) {
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', client: spy.client),
  );
  s.adoptSession(orgRole: 'admin', name: 'Aarav Mehta', uid: '2');
  return s;
}

/// A draft the server would flag: it cites the document the candidate never
/// sees, which is what `warnings.source_reference` reports.
Question _flaggedDraft({String id = '9'}) => Question(
  id: id,
  genId: '3',
  name: 'Describe an escalation',
  type: QType.subjectiveRubric,
  prompt: 'Per Section 4.2 of the SOP, escalate how?',
  rubric: const <String>['Names the first responder.'],
  citesSource: true,
);

/// The same draft as the LIST route sends it - still `draft`, still flagged,
/// which is what the server holds after refusing the approval.
Map<String, dynamic> get _flaggedRow => <String, dynamic>{
  'id': 9,
  'name': 'Describe an escalation',
  'state': 'draft',
  'question_type': 'subjective_rubric',
  'question_prompt': 'Per Section 4.2 of the SOP, escalate how?',
  'generator': <String, dynamic>{'id': 3, 'name': 'Warehouse SOP'},
  'warnings': <String, dynamic>{
    'revealing_option': false,
    'source_reference': true,
  },
};

void main() {
  group('The acknowledgement reaches the server', () {
    test('a flagged draft is refused locally until it is acknowledged', () {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.drafts = <Question>[_flaggedDraft()];

      final String? refused = store.decideDraft('9', DraftState.approved);

      expect(
        refused,
        '9',
        reason: 'the store must hand back the id so the preview can be opened',
      );
      expect(
        spy.hit('/approve'),
        isFalse,
        reason: 'no point spending a round trip on a request that must fail',
      );
    });

    test('approving after the tick posts acknowledge_warnings: true', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.drafts = <Question>[_flaggedDraft()];

      store.toggleAck('9');
      final String? refused = store.decideDraft('9', DraftState.approved);
      // `decideDraft` fires the request without awaiting it.
      await Future<void>.delayed(Duration.zero);

      expect(refused, isNull, reason: 'the tick must let the decision through');
      expect(spy.hit('/api/v1/drafts/9/approve'), isTrue);
      expect(
        spy.bodyFor('/approve')['acknowledge_warnings'],
        isTrue,
        reason:
            'THE BUG: this was hardcoded false, so the server refused every '
            'flagged draft however many times the box was ticked',
      );
    });

    test('a clean draft says the warnings were not acknowledged', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.drafts = <Question>[
        const Question(
          id: '11',
          genId: '3',
          name: 'Lift check',
          type: QType.subjectiveRubric,
          prompt: 'Describe the lift check.',
          rubric: <String>['Names the check.'],
        ),
      ];

      store.decideDraft('11', DraftState.approved);
      await Future<void>.delayed(Duration.zero);

      expect(
        spy.bodyFor('/approve')['acknowledge_warnings'],
        isFalse,
        reason:
            'the flag records a REVIEW that happened - sending it on a draft '
            'with nothing to review would make it meaningless',
      );
    });
  });

  group('A refused approval does not claim success', () {
    test('the refusal is toasted and no success is', () async {
      final _Spy spy = _Spy()..approveAnswer = _warningsRefusal;
      final AppStore store = _liveStore(spy);
      store.drafts = <Question>[_flaggedDraft()];

      store.toggleAck('9');
      store.decideDraft('9', DraftState.approved);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final List<String> messages = store.toaster.items
          .map((ToastMsg m) => m.message)
          .toList();
      expect(
        messages.any((String m) => m.contains('unresolved authoring warnings')),
        isTrue,
        reason: "the module's own words explain the refusal best",
      );
      expect(
        messages.any((String m) => m.contains('is in the bank')),
        isFalse,
        reason:
            'THE BUG: the success toast fired before the request, so a '
            'refusal put "Approved" on screen beside the reason it was not',
      );
    });

    test('the draft goes back to the queue and out of the bank', () async {
      final _Spy spy = _Spy()
        ..approveAnswer = _warningsRefusal
        ..draftRows = <Map<String, dynamic>>[_flaggedRow];
      final AppStore store = _liveStore(spy);
      store.drafts = <Question>[_flaggedDraft()];

      store.toggleAck('9');
      store.decideDraft('9', DraftState.approved);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        store.draftById('9')?.state,
        DraftState.draft,
        reason: 'a refused approval must leave the draft awaiting review',
      );
      expect(
        store.bank.any((Question q) => q.id == '9'),
        isFalse,
        reason:
            'the optimistic write put it in the bank; a refusal has to take '
            'it back out or the bank asserts a question it never approved',
      );
    });

    test('a successful approval toasts exactly once', () async {
      final _Spy spy = _Spy();
      final AppStore store = _liveStore(spy);
      store.drafts = <Question>[_flaggedDraft()];

      store.toggleAck('9');
      store.decideDraft('9', DraftState.approved);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final int claims = store.toaster.items
          .where((ToastMsg m) => m.message.contains('is in the bank'))
          .length;
      expect(
        claims,
        1,
        reason:
            'the toaster does not dedupe, and the local edit and the request '
            'each used to raise the same success',
      );
    });
  });
}
