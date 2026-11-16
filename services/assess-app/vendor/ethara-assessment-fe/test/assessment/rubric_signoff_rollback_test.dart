// A governance sign-off must never claim more than the server recorded.
//
// `signRubric` flipped `rubricReviewed` locally, then called the route, and
// never put the value back when the call failed. That was survivable while the
// only failure was invisible, and it stopped being survivable the day the
// review queue started sending DRAFT ids to a route that browses the BANK
// model: the response was `{"code": "not_found"}` and the pill still read
// "Marking guide approved" over a server holding nothing.
//
// The control has since moved to the bank, so that particular 404 is gone. This
// pins the other half - that a refused write is not reported as a sign-off -
// because the failure mode it guards is silent by construction: nobody looks
// for a value that already reads the way they wanted it to.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';

/// One approved subjective question, carrying an unsigned marking guide.
Question _bankQuestion() => Question.fromJson(<String, dynamic>{
  'id': '91',
  'name': 'Describe the escalation path',
  'question_type': 'subjective_rubric',
  'state': 'approved',
  'prompt': 'Describe the escalation path for a blocked pallet.',
  'subjective_rubric': <String>['Names the supervisor', 'Gives a time bound'],
  'rubric_reviewed': false,
});

/// Refuses the sign-off the way the module does, and fails everything else so
/// the trailing background refresh cannot quietly restore the value on its own.
/// The rollback has to be what puts it back, not luck.
MockClient _refusingServer() => MockClient((http.Request req) async {
  if (req.url.path.contains('review_rubric')) {
    return http.Response(
      '{"ok": false, "error": {"code": "not_found", '
      '"message": "Question not found"}}',
      404,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }
  return http.Response(
    '{"ok": false, "error": {"code": "server_error", "message": "no"}}',
    500,
    headers: <String, String>{'content-type': 'application/json'},
  );
});

AppStore _liveStore(MockClient client) {
  final AppStore store = AppStore(
    api: ApiClient(
      baseUrl: 'http://stub',
      client: client,
      bearer: 'access_token_stub',
    ),
  );
  store.source = DataSource.live;
  store.bank = <Question>[_bankQuestion()];
  return store;
}

/// An approved image_ab question, exactly as `/api/v1/bank` sends one: a
/// four-axis key, no rubric, and the module's own `has_subjective: false`.
Question _bankImageAb() => Question.fromJson(<String, dynamic>{
  'id': '204',
  'name': 'Task: Stylized Image Evaluation',
  'question_type': 'image_ab',
  'state': 'approved',
  'prompt': 'A 3D cartoon style rendering of a vintage typewriter.',
  'has_subjective': false,
  'rubric_reviewed': false,
  'official_reasoning': 'Response B is correct by construction.',
});

void main() {
  test('a refused sign-off leaves the guide unsigned', () async {
    final AppStore store = _liveStore(_refusingServer());
    addTearDown(store.dispose);

    expect(store.bankById('91')!.rubricReviewed, isFalse);

    await store.signRubric('91');

    // THE ASSERTION THAT MATTERS. Without the rollback this is `true`: the
    // optimistic flip stood, and the screen told a reviewer a human had
    // checked a key that nobody had.
    expect(
      store.bankById('91')!.rubricReviewed,
      isFalse,
      reason: 'a 404 from review_rubric must not leave the guide signed',
    );
    // And it SAYS so. A silent rollback is only half honest: the pill going
    // back with no explanation reads as a misclick.
    expect(
      store.toaster.items.map((ToastMsg m) => m.message),
      contains('Question not found'),
    );
  });

  test('signing does not touch drafts', () async {
    // The bank and the queue used to be flipped together, which is how a draft
    // id ever reached a bank-only route. A draft has no `rubric_reviewed`
    // column at all, so anything set here could only ever be a local fiction.
    final AppStore store = _liveStore(_refusingServer());
    addTearDown(store.dispose);
    final Question draft = Question.fromJson(<String, dynamic>{
      'id': '91',
      'name': 'A draft that happens to share an id',
      'question_type': 'subjective_rubric',
      'state': 'draft',
    });
    store.drafts = <Question>[draft];

    await store.signRubric('91');

    expect(store.draftById('91')!.rubricReviewed, isFalse);
  });

  test('no question carries a marking-guide warning any more', () {
    // APPROVING THE DRAFT IS THE SIGN-OFF. `action_approve` sets
    // `rubric_reviewed` on the question it creates, because the reviewer who
    // approves a draft is reading that draft's rubric when they do it. The
    // separate "Approve marking guide" control recorded no judgement the
    // approval had not already recorded, so it and its warning are gone.
    //
    // Both shapes are checked: the one that never had a rubric (image_ab) and
    // the one that genuinely does (subjective_rubric). Neither should nag.
    for (final Question q in <Question>[_bankImageAb(), _bankQuestion()]) {
      expect(
        q.warnings.map((QualityWarning w) => w.title),
        isNot(contains('Marking guide not approved')),
        reason: q.type.wire,
      );
    }
  });

  test('hasSubjective still mirrors the module, for the launch gate', () {
    // The FIELD and the server-side gate both remain - what changed is which
    // action satisfies them. This predicate is what the client gate reads, so
    // it has to keep matching the module's "carries a rubric, or IS the rubric
    // type" rather than the broader `type.isSubjective`.
    expect(_bankImageAb().type.isSubjective, isTrue);
    expect(_bankImageAb().hasSubjective, isFalse);
    expect(_bankQuestion().hasSubjective, isTrue);
  });
}
