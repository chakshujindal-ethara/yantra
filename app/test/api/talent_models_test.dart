import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/api/talent_models.dart';

void main() {
  test('Listing reads the wire shape, the viewer and the derived labels', () {
    final l = Listing.fromJson({
      'id': 'l1',
      'title': 'Hindi audio',
      'domain': 'transcription',
      'pay_min': '28.00',
      'pay_max': '40',
      'pay_unit': 'per_unit',
      'currency': 'INR',
      'commitment': 'task_based',
      'hours_per_week': 10,
      'slots_total': 10,
      'slots_filled': 8,
      'cert_gate': 'transcription',
      'paper_id': 'pp1',
      'requirements': ['Native Hindi', 7],
      'questions': [
        {'key': 'why', 'prompt': 'Why you?', 'kind': 'text', 'required': true},
        {
          'key': 'shift',
          'prompt': 'Shift',
          'kind': 'choice',
          'options': ['day', 'night'],
        },
        'junk',
      ],
      'sensitive': true,
      'status': 'open',
      'viewer': {
        'prequalified': true,
        'application_id': 'a1',
        'application_status': 'screening',
        'redirect': {'id': 'l9', 'title': 'Evergreen'},
      },
    });
    expect(l.slotsLeft, 2);
    expect(l.isFull, isFalse);
    expect(l.payLabel, '₹28–40 per accepted unit');
    expect(l.commitmentLabel, 'Task-based');
    expect(l.requirements, ['Native Hindi', '7']);
    expect(l.questions, hasLength(2));
    expect(l.questions[0].required, isTrue);
    expect(l.questions[1].isChoice, isTrue);
    expect(l.questions[1].options, ['day', 'night']);
    expect(l.viewer.prequalified, isTrue);
    expect(l.viewer.hasApplied, isTrue);
    expect(l.viewer.redirect?.title, 'Evergreen');
    expect(l.hasPaper, isTrue);
    expect(l.sensitive, isTrue);
  });

  test('Listing tolerates missing fields and over-filled slots', () {
    final l = Listing.fromJson({'id': 'l2', 'slots_total': 3, 'slots_filled': 5});
    expect(l.slotsLeft, 0);
    expect(l.isFull, isTrue);
    expect(l.viewer.hasApplied, isFalse);
    expect(l.viewer.redirect, isNull);
    expect(l.questions, isEmpty);
    expect(l.payLabel, 'per accepted unit');
    expect(Listing.fromJson(const {}).slotsLeft, 0);
  });

  test('Application knows its group and its steps', () {
    final offered = Application.fromJson({
      'id': 'a1',
      'listing_id': 'l1',
      'listing_title': 'Hindi audio',
      'status': 'offered',
      'steps': [
        {'kind': 'form', 'status': 'done'},
        {'kind': 'paper', 'status': 'done'},
        {'kind': 'availability', 'status': 'pending'},
      ],
      'offer_expires_at': '2026-11-10T00:00:00Z',
    });
    expect(offered.isOffered, isTrue);
    expect(offered.isInProgress, isFalse);
    expect(offered.isHistory, isFalse);
    expect(offered.stepsDone, 2);
    expect(offered.steps[1].title, 'Assessment paper');
    expect(offered.offerExpiresAt, isNotNull);
    expect(offered.copyWith(status: 'expired').isHistory, isTrue);
    final assessment = Application.fromJson({'id': 'a2', 'status': 'assessment'});
    expect(assessment.needsPaper, isTrue);
    expect(assessment.canWithdraw, isTrue);
    expect(assessment.isInProgress, isTrue);
    for (final s in ['accepted', 'declined', 'rejected', 'withdrawn', 'expired']) {
      final a = Application.fromJson({'id': 'x', 'status': s});
      expect(a.isHistory, isTrue, reason: s);
      expect(a.canWithdraw, isFalse, reason: s);
    }
  });

  test('Onboarding always has the six steps in order, grouped, and counts what is left', () {
    final o = Onboarding.fromJson({
      'complete': false,
      'steps': [
        {'key': 'bank', 'status': 'pending', 'group': 'Payment'},
        {'key': 'profile', 'status': 'done', 'done_at': '2026-11-01T10:00:00Z', 'group': 'Profile'},
        {'key': 'consent', 'status': 'done'},
      ],
    });
    expect(o.steps.map((s) => s.key), onboardingStepOrder);
    expect(o.done, 2);
    expect(o.left, 4);
    expect(o.isDone('profile'), isTrue);
    expect(o.isDone('bank'), isFalse);
    expect(o.step('consent')?.group, 'Documents', reason: 'group inferred when absent');
    expect(o.step('payout_ack')?.group, 'Payment');
    expect(o.pending.map((s) => s.key), ['agreement', 'identity', 'bank', 'payout_ack']);
    expect(o.steps[0].title, 'Legal name, phone and city');
    expect(Onboarding.notStarted.done, 0);
    expect(Onboarding.notStarted.total, 6);
    expect(Onboarding.fromJson({'complete': true, 'eligible_sent_at': '2026-11-02T00:00:00Z'}).eligibleSentAt, isNotNull);
  });
}
