import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/api/models.dart';

void main() {
  test('Batch reads the wire shape and tolerates missing or mistyped fields', () {
    final b = Batch.fromJson({'id': 'b1', 'title': 'T', 'unit_pay': '12.500000', 'available_units': '7', 'claim_ttl_minutes': 240});
    expect(b.unitPay, '12.500000');
    expect(b.availableUnits, 7);
    expect(b.currency, '');
    expect(b.hasAnswerSchema, isFalse);
    expect(Batch.fromJson({'id': 1, 'available_units': null}).availableUnits, 0);
    final guided = Batch.fromJson({
      'id': 'b2',
      'project_name': 'Hindi',
      'answer_schema': {'type': 'object'},
    });
    expect(guided.hasAnswerSchema, isTrue);
    expect(guided.projectName, 'Hindi');
  });

  test('ActiveWork is not live when claim or unit is null, and carries the batch brief', () {
    expect(ActiveWork.fromJson({'claim': null, 'unit': null, 'batch': null}).isLive, isFalse);
    final live = ActiveWork.fromJson({
      'claim': {'id': 'c'},
      'unit': {
        'id': 'u',
        'payload': {'k': 'v'},
      },
      'batch': {'id': 'b', 'title': 'T'},
    });
    expect(live.isLive, isTrue);
    expect(live.batch?.title, 'T');
  });

  test('Statement reads totals, hold, account, windows, weeks and the pending sum', () {
    final s = Statement.fromJson({
      'worker_id': 'w1',
      'totals': {'payable': '10.00', 'paid': '5.00'},
      'hold': 'first_payout',
      'account': {'hold_until': '2026-11-10T00:00:00Z', 'first_paid_at': null},
      'earnings': [
        {'id': 'e1', 'amount': '10.00', 'currency': 'INR', 'status': 'payable'},
        'junk',
      ],
      'windows': [
        {'window_id': 'w', 'gross': '5.00', 'window_status': 'paid', 'line_status': 'paid', 'rail_reference': 'RZP-1'},
      ],
      'weeks': [
        {'starts_at': '2026-10-31T18:30:00Z', 'amount': '10.00', 'count': 1, 'currency': 'INR'},
      ],
      'pending_next': {'currency': 'INR', 'amount': '10.00', 'count': 1},
      'next_window_closes_at': '2026-11-06T18:29:59Z',
    });
    expect(s.total('payable'), '10.00');
    expect(s.total('windowed'), '0.00');
    expect(s.hold, 'first_payout');
    expect(s.holdUntil, isNotNull);
    expect(s.earnings, hasLength(1));
    expect(s.windows.single.stageLabel, 'Paid');
    expect(s.weeks.single.value, 10);
    expect(s.pendingNext.count, 1);
    expect(s.currency, 'INR');
    expect(s.isEmpty, isFalse);
    final empty = Statement.fromJson({'worker_id': 'w', 'totals': {}, 'hold': null, 'earnings': []});
    expect(empty.isEmpty, isTrue);
    expect(empty.pendingNext.amount, '0.00');
  });

  test('PayoutWindow reads the worker-facing stage', () {
    PayoutWindow w(String line, String window) => PayoutWindow.fromJson({'line_status': line, 'window_status': window});
    expect(w('held', 'closed').stageLabel, 'Held');
    expect(w('payable', 'approved').stageLabel, 'Approved');
    expect(w('payable', 'closed').stageLabel, 'Closed');
    expect(w('payable', 'paid').stageLabel, 'Paid');
  });

  test('MyWorkItem labels the stage and knows when a dispute is possible', () {
    final decided = DateTime.now().subtract(const Duration(days: 3)).toUtc().toIso8601String();
    final rejected = MyWorkItem.fromJson({
      'task_id': 't',
      'stage': 'decided',
      'canonical_verdict': 'reject',
      'reason_code': 'incomplete',
      'decided_at': decided,
    });
    expect(rejected.statusLabel, 'Rejected');
    expect(rejected.canDispute(), isTrue);
    final old = MyWorkItem.fromJson({
      'task_id': 't',
      'stage': 'decided',
      'canonical_verdict': 'reject',
      'decided_at': '2020-01-01T00:00:00Z',
    });
    expect(old.canDispute(), isFalse);
    final accepted = MyWorkItem.fromJson({'task_id': 't', 'stage': 'decided', 'canonical_verdict': 'accept'});
    expect(accepted.statusLabel, 'Accepted');
    expect(accepted.canDispute(), isFalse);
    final pending = MyWorkItem.fromJson({'task_id': 't', 'stage': 'in_review'});
    expect(pending.statusLabel, 'In review');
    final disputed = MyWorkItem.fromJson({
      'task_id': 't',
      'stage': 'decided',
      'canonical_verdict': 'needs_edits',
      'decided_at': decided,
      'dispute': {'id': 'd', 'status': 'open'},
    });
    expect(disputed.canDispute(), isFalse);
    expect(disputed.dispute?.isOpen, isTrue);
  });

  test('Availability knows whether it is paused and serialises for the gateway', () {
    final paused = Availability(weeklyHours: 20, pausedUntil: DateTime.now().add(const Duration(days: 2)));
    expect(paused.isPaused(), isTrue);
    expect(const Availability(weeklyHours: 20).isPaused(), isFalse);
    expect(const Availability(weeklyHours: 20).toJson(), {'weekly_hours': 20, 'paused_until': null});
    final me = WorkerMe.fromJson({
      'id': 'w',
      'status': 'eligible',
      'cert_gates': ['transcription'],
      'availability': {'weekly_hours': 20},
    });
    expect(me.isEligible, isTrue);
    expect(me.availability?.weeklyHours, 20);
    expect(WorkerMe.fromJson({'id': 'w'}).status, 'unknown');
    expect(WorkerMe.fromJson({'id': 'w'}).isOnboarded, isFalse);
  });

  test('ReasonCode knows who is at fault', () {
    expect(ReasonCode.byCode('client_glossary_change')?.clientCaused, isTrue);
    expect(ReasonCode.byCode('incomplete')?.clientCaused, isFalse);
    expect(ReasonCode.byCode('nope'), isNull);
  });

  test('ReviewInput serialises the verdict on the wire', () {
    final j = const ReviewInput(verdict: Verdict.needsEdits, reasonCode: 'incomplete', rubricUnclear: true, note: 'n').toJson();
    expect(j, {'verdict': 'needs_edits', 'reason_code': 'incomplete', 'rubric_unclear': true, 'note': 'n', 'feedback': {}});
  });

  test('InboxItem can be marked read locally', () {
    final n = InboxItem.fromJson({'id': 'n1', 'subject': 's', 'body': 'b'});
    expect(n.isRead, isFalse);
    expect(n.asRead(DateTime(2026)).isRead, isTrue);
  });

  test('Channel reads the verified address apart from the one waiting for its code', () {
    final c = Channel.fromJson({
      'worker_id': 'w1',
      'email': null,
      'email_verified_at': null,
      'pending_email': 'new@example.com',
      'verify_expires_at': '2026-11-05T10:15:00Z',
      'verify_sent_at': '2026-11-05T10:00:00Z',
      'verify_error': null,
      'updated_at': '2026-11-05T10:00:00Z',
    });
    expect(c.email, '');
    expect(c.pendingEmail, 'new@example.com');
    expect(c.isPending, isTrue);
    expect(c.verifyExpiresAt?.toUtc(), DateTime.utc(2026, 11, 5, 10, 15));
    expect(c.verifySentAt?.toUtc(), DateTime.utc(2026, 11, 5, 10));
    expect(c.verifyError, '');
    final verified = Channel.fromJson({'worker_id': 'w1', 'email': 'a@b.co', 'email_verified_at': '2026-11-05T10:01:00Z'});
    expect(verified.isPending, isFalse);
    expect(verified.emailVerifiedAt?.toUtc(), DateTime.utc(2026, 11, 5, 10, 1));
  });
}
