import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/api/client_models.dart';
import 'package:yantra_app/api/finance_models.dart';
import 'package:yantra_app/api/quality_ops_models.dart';
import 'package:yantra_app/api/support_models.dart';

void main() {
  group('quality ops', () {
    test('QualityStats reads counts, a rate as a fraction or a percentage, reasons and the oldest pending', () {
      final s = QualityStats.fromJson({
        'pending': 3,
        'claimed': '2',
        'in_audit': 1,
        'accepted': 10,
        'rejected': 2,
        'needs_edits': 0,
        'acceptance_rate': 0.833,
        'oldest_pending_at': '2026-11-01T10:00:00Z',
        'reasons': [
          {'reason_code': 'guideline_miss', 'count': 4, 'billable': false},
          'junk',
        ],
      });
      expect(s.pending, 3);
      expect(s.claimed, 2);
      expect(s.acceptancePercent, 83);
      expect(s.reasons.single.reasonCode, 'guideline_miss');
      expect(s.oldestPendingAt, isNotNull);
      expect(s.isEmpty, isFalse);
      expect(QualityStats.fromJson({'acceptance_rate': '83'}).acceptancePercent, 83);
      expect(QualityStats.fromJson({}).isEmpty, isTrue);
      expect(percentOf(1), 100);
      expect(percentOf(0), 0);
    });

    test('flags, disputes and task pages tolerate missing fields', () {
      final f = QualityFlag.fromJson({'id': 'f', 'note': 'n', 'answer': null});
      expect(f.answer, '');
      expect(f.createdAt, isNull);
      final d = DisputeQueueItem.fromJson({'id': 'd', 'status': 'open', 'verdict': null, 'reason_code': 'low_quality'});
      expect(d.verdict, '');
      expect(d.reasonCode, 'low_quality');
      final p = QualityTaskPage.fromJson({
        'total': '7',
        'items': [
          {'id': 't', 'status': 'pending'},
          1,
        ],
      });
      expect(p.total, 7);
      expect(p.items.single.status, 'pending');
      expect(QualityTaskPage.fromJson({}).items, isEmpty);
    });
  });

  group('finance', () {
    test('PayoutOverview reads money maps, window counts and the open window', () {
      final o = PayoutOverview.fromJson({
        'payable_now': {'INR': '10.00', 'USD': 5},
        'paid_total': '99.00',
        'held_total': null,
        'open_window': {'starts_at': '2026-10-31T18:30:00Z', 'ends_at': '2026-11-07T18:30:00Z', 'closes_in_seconds': 100},
        'windows': {'closed': 1, 'approved': '2'},
        'margin_total': {'INR': '1.00'},
        'pending_adjustments': 3,
      });
      expect(o.payableNow, {'INR': '10.00', 'USD': '5'});
      expect(o.paidTotal, {'': '99.00'}, reason: 'a bare amount still shows');
      expect(o.heldTotal, isEmpty);
      expect(o.windows('approved'), 2);
      expect(o.windows('paid'), 0);
      expect(o.openWindow?.closesInSeconds, 100);
      expect(o.pendingAdjustments, 3);
      expect(PayoutOverview.fromJson({}).openWindow, isNull);
    });

    test('PayWindowRow reads status helpers and optional counts', () {
      final w = PayWindowRow.fromJson({
        'id': 'w',
        'status': 'approved',
        'gross_total': '1.00',
        'held_total': '0.00',
        'approvals': 2,
        'line_count': '3',
      });
      expect(w.isApproved, isTrue);
      expect(w.isClosed, isFalse);
      expect(w.approvals, 2);
      expect(w.lineCount, 3);
      final bare = PayWindowRow.fromJson({'id': 'w', 'status': 'closed', 'rail_reference': null});
      expect(bare.approvals, isNull);
      expect(bare.lineCount, isNull);
      expect(bare.railReference, '');
    });

    test('lines, reconcile, adjustments and margin rows read the router shapes', () {
      final l = WindowLineRow.fromJson({
        'id': 'l',
        'worker_id': 'w',
        'gross': '2.50',
        'earning_count': 2,
        'status': 'held',
        'hold_reason': 'first_payout',
      });
      expect(l.holdReason, 'first_payout');
      final r = ReconcileReport.fromJson({
        'window_id': 'w',
        'earnings_total': '1.00',
        'lines_total': '1.00',
        'delta': '0.00',
        'unpaid_earnings': 0,
        'balanced': true,
      });
      expect(r.balanced, isTrue);
      expect(ReconcileReport.fromJson({}).balanced, isFalse);
      final a = Adjustment.fromJson({'id': 'a', 'amount': '-5.00', 'kind': 'correction', 'status': 'pending', 'proposed_by': 'p'});
      expect(a.isPending, isTrue);
      expect(a.decidedBy, '');
      expect(const AdjustmentInput(workerId: 'w', amount: '5', currency: 'INR', kind: 'bonus', reason: 'r').toJson(), {
        'worker_id': 'w',
        'amount': '5',
        'currency': 'INR',
        'kind': 'bonus',
        'reason': 'r',
      });
      final m = MarginRow.fromJson({
        'batch_id': 'b',
        'invoice': '100.00',
        'margin': '40.00',
        'margin_fraction': '0.4000',
        'units_judged': 10,
      });
      expect(m.marginPercent, 40);
      expect(MarginRow.fromJson({'margin_fraction': 'x'}).marginPercent, 0);
    });
  });

  group('support', () {
    test('Ticket reads status helpers and context; TicketInput serialises', () {
      final t = Ticket.fromJson({
        'id': 't',
        'status': 'in_progress',
        'context': {'app': 'web'},
        'note': null,
      });
      expect(t.isInProgress, isTrue);
      expect(t.isOpen, isFalse);
      expect(t.context, {'app': 'web'});
      expect(t.note, '');
      expect(const TicketInput(category: 'bug', title: 'T', body: 'B', screen: 'Work', context: {'w': 1}).toJson(), {
        'category': 'bug',
        'title': 'T',
        'body': 'B',
        'screen': 'Work',
        'context': {'w': 1},
      });
      expect(ticketCategories, contains('payment'));
      expect(ticketStatuses, ['open', 'in_progress', 'resolved']);
    });
  });

  group('client', () {
    test('UnitCounts and ClientOverview read the counts block and the invoice map', () {
      final o = ClientOverview.fromJson({
        'orgs': [
          {'id': 'o', 'name': 'Acme'},
        ],
        'units': {'total': 10, 'claimed': 2, 'submitted': 1, 'in_review': 3, 'accepted': 4},
        'acceptance_rate': '0.8',
        'billable_rework': '2',
        'deliveries': 1,
        'invoice_total': {'INR': 500},
      });
      expect(o.orgs.single.name, 'Acme');
      expect(o.units.inProgress, 3);
      expect(o.units.available, 0);
      expect(o.acceptancePercent, 80);
      expect(o.billableRework, 2);
      expect(o.invoiceTotal, {'INR': '500'});
      expect(ClientOverview.fromJson({}).units.total, 0);
    });

    test('ClientProjectDetail reads batches with manifests, reasons, deliveries and feedback; falls back to batch manifests', () {
      final p = ClientProjectDetail.fromJson({
        'id': 'p',
        'name': 'N',
        'currency': 'INR',
        'status': 'active',
        'rubric_version': 'v2',
        'units': {'total': 5, 'accepted': 5},
        'acceptance_rate': 1,
        'invoice_total': '250.00',
        'batches': [
          {
            'id': 'b1',
            'title': 'B1',
            'status': 'open',
            'unit_price': '50.00',
            'units': {'total': 5},
            'manifest': {'id': 'm1', 'digest': 'sha', 'accepted_units': 5, 'total_price': '250.00'},
          },
          {'id': 'b2', 'title': 'B2', 'status': 'draft', 'unit_price': '40.00', 'units': {}, 'manifest': null},
        ],
        'reasons': [
          {'reason_code': 'client_glossary_change', 'count': 1, 'billable': true},
        ],
        'deliveries': [],
        'feedback': [
          {'id': 'f', 'author_id': 'c', 'body': 'hi', 'created_at': '2026-11-01T00:00:00Z'},
        ],
      });
      expect(p.acceptancePercent, 100);
      expect(p.batches.length, 2);
      expect(p.batches.first.manifest?.batchId, 'b1', reason: 'a nested manifest learns its batch');
      expect(p.batches.last.manifest, isNull);
      expect(p.deliveries.single.id, 'm1', reason: 'no listed deliveries: the batches\' manifests are the deliveries');
      expect(p.batchOf(p.deliveries.single)?.title, 'B1');
      expect(p.reasons.single.billable, isTrue);
      expect(p.feedback.single.body, 'hi');
      final listed = ClientProjectDetail.fromJson({
        'id': 'p',
        'deliveries': [
          {'id': 'm9', 'batch_id': 'b9'},
        ],
      });
      expect(listed.deliveries.single.id, 'm9');
      expect(listed.batchOf(listed.deliveries.single), isNull);
    });
  });

  test('a window carries who paid it over the cap, and why', () {
    final w = PayWindowRow.fromJson({
      'id': 'w',
      'status': 'paying',
      'cap_override_by': 'fin-2',
      'cap_override_reason': 'Diwali bonus week',
      'cap_override_at': '2026-11-04T09:00:00Z',
    });
    expect(w.capOverrideBy, 'fin-2');
    expect(w.capOverrideReason, 'Diwali bonus week');
    expect(w.capOverrideAt?.toUtc(), DateTime.utc(2026, 11, 4, 9));
    expect(PayWindowRow.fromJson({'id': 'w', 'status': 'paid'}).capOverrideAt, isNull);
  });

  test('a queued line that is not going out says why; attention counts what blocks money', () {
    final l = WindowLineRow.fromJson({'id': 'l', 'status': 'queued', 'rail_status': 'account_changed'});
    expect(l.railStatus, 'account_changed');
    expect(l.isBlocked, isTrue);
    expect(WindowLineRow.fromJson({'id': 'l', 'status': 'processing', 'rail_status': 'processing'}).isBlocked, isFalse);
    final a = PayoutAttention.fromJson({'lines_blocked': 3, 'erasures_pending': 1, 'accounts_awaiting_confirmation': 2});
    expect((a.linesBlocked, a.erasuresPending, a.accountsAwaitingConfirmation), (3, 1, 2));
  });

  test('payout reasons read as plain words for staff', () {
    for (final code in const [
      'held',
      'rail_mismatch',
      'account_missing',
      'account_changed',
      'account_unconfirmed',
      'consent_withdrawn',
      'over_cap',
      'account_unverified',
      'first_payout',
      'bank_change',
      'integrity',
    ]) {
      expect(payoutReason(code), isNot(contains('_')), reason: code);
      expect(payoutReason(code), isNot(equalsIgnoringCase(code.replaceAll('_', ' '))), reason: '$code has its own words');
    }
    expect(payoutReason('quality_review'), 'Quality review');
  });

  test('X-Skipped-Lines reads into line ids and reasons; a summary counts each reason', () {
    final skipped = readSkippedLines('l1:held,l2:account_changed, l3:held,bad');
    expect(skipped, [('l1', 'held'), ('l2', 'account_changed'), ('l3', 'held')]);
    expect(readSkippedLines(null), isEmpty);
    expect(skippedSummary(skipped), '3 lines were left out: 2 worker on hold, 1 bank account changed since dispatch.');
    expect(skippedSummary([('l1', 'account_missing')]), '1 line was left out: 1 bank account gone.');
  });
}
