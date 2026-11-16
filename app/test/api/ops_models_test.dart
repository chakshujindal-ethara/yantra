import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/api/ops_models.dart';
import 'package:yantra_app/api/system_models.dart';

void main() {
  group('helpers', () {
    test('marginOf is (price - pay - review) / price, null without a price', () {
      expect(marginOf('60.00', '28.00', '4.00'), closeTo(0.4667, 0.0001));
      expect(marginOf('0', '28.00', '4.00'), isNull);
      expect(marginOf('', '28.00', ''), isNull);
      expect(marginOf('10', '12', '0'), -0.2);
    });

    test('percent, shortId, fraction and readDouble', () {
      expect(percent(0.4667), '47%');
      expect(percent(null), '—');
      expect(shortId('worker-1111-2222'), '111-2222');
      expect(shortId('short'), 'short');
      expect(fraction(0.3), '0.3000');
      expect(readDouble({'a': 0.3}, 'a'), 0.3);
      expect(readDouble({'a': '0.3000'}, 'a'), 0.3);
      expect(readDouble({'a': 'x'}, 'a'), isNull);
      expect(readDouble({}, 'a'), isNull);
    });
  });

  group('UnitCounts', () {
    test('reads every stage and sums', () {
      final a = UnitCounts.fromJson({
        'total': 10,
        'available': 4,
        'claimed': 1,
        'submitted': 2,
        'in_review': 1,
        'accepted': 2,
        'rejected': 0,
        'needs_edits': 0,
      });
      final b = UnitCounts.fromJson({'total': 5, 'available': 5});
      expect(a.reviewing, 3);
      final sum = UnitCounts.sum([a, b]);
      expect(sum.total, 15);
      expect(sum.available, 9);
      expect(sum.reviewing, 3);
      expect(UnitCounts.fromJson({}).total, 0);
    });
  });

  group('BatchSummary', () {
    final json = {
      'id': 'b1',
      'project_id': 'p1',
      'project_name': 'Hindi',
      'title': 'Signs',
      'mode': 'open',
      'status': 'open',
      'unit_pay': '28.000000',
      'unit_price': '60.000000',
      'review_pay': '4.000000',
      'currency': 'INR',
      'claim_ttl_minutes': 240,
      'rubric_version': 'v2',
      'floor_approved_by': null,
      'published_at': '2026-11-01T10:00:00Z',
      'units': {'total': 100, 'available': 40, 'claimed': 5, 'submitted': 3, 'in_review': 2, 'accepted': 50},
      'live_claims': 5,
      'manifest': {
        'id': 'm1',
        'digest': 'sha256:abcdef1234567890',
        'accepted_units': 100,
        'total_price': '6000.00',
        'created_at': '2026-11-02T10:00:00Z',
      },
    };

    test('reads pay, price, counts, claims and the manifest', () {
      final b = BatchSummary.fromJson(json);
      expect(b.margin, closeTo(0.4667, 0.0001));
      expect(b.underFloor(0.3), isFalse);
      expect(b.underFloor(0.5), isTrue);
      expect(b.underFloor(null), isFalse);
      expect(b.units.reviewing, 5);
      expect(b.liveClaims, 5);
      expect(b.manifest?.shortDigest, 'sha256:abcde');
      expect(b.manifest?.acceptedUnits, 100);
      expect(b.publishedAt, isNotNull);
      expect(b.floorApprovedBy, '');
    });

    test('a null manifest and a missing price are tolerated', () {
      final b = BatchSummary.fromJson({...json, 'manifest': null, 'unit_price': null});
      expect(b.manifest, isNull);
      expect(b.margin, isNull);
      expect(b.underFloor(0.3), isFalse);
    });
  });

  group('Project', () {
    final summary = {
      'id': 'p1',
      'name': 'Hindi',
      'currency': 'INR',
      'status': 'active',
      'cert_gate': 'transcription',
      'rubric_version': 'v2',
      'margin_floor': '0.3000',
      'client_org_id': 'org-1',
      'batch_count': 2,
      'units': {'total': 100, 'available': 40},
      'created_at': '2026-10-20T10:00:00Z',
    };

    test('summary reads the floor as a fraction and counts batches', () {
      final p = ProjectSummary.fromJson(summary);
      expect(p.marginFloor, 0.3);
      expect(p.batchCount, 2);
      expect(p.batches, isEmpty);
      expect(p.batchesUnderFloor, isEmpty);
      expect(ProjectSummary.fromJson({...summary, 'margin_floor': null}).marginFloor, isNull);
    });

    test('batches on a summary feed batchesUnderFloor; batch_count falls back to their number', () {
      final p = ProjectSummary.fromJson({
        ...summary,
        'batch_count': null,
        'batches': [
          {'id': 'b1', 'unit_pay': '28', 'unit_price': '60', 'review_pay': '4'},
          {'id': 'b2', 'unit_pay': '50', 'unit_price': '60', 'review_pay': '4'},
        ],
      });
      expect(p.batchCount, 2);
      expect(p.batchesUnderFloor.map((b) => b.id), ['b2']);
    });

    test('detail reads schemas, brief, reasons, feedback and the rubric log', () {
      final d = ProjectDetail.fromJson({
        ...summary,
        'payload_schema': {'type': 'object'},
        'answer_schema': null,
        'brief': 'Do it well',
        'llm_policy': 'None',
        'sensitive': true,
        'batches': [],
        'reasons': [
          {'reason_code': 'guideline_miss', 'count': 7, 'billable': false},
        ],
        'feedback': [
          {'id': 'f1', 'author_id': 'u1', 'body': 'Thanks', 'created_at': '2026-10-28T09:00:00Z'},
        ],
        'rubric_log': [
          {'version': 'v2', 'note': 'Diacritics', 'at': '2026-10-27T09:00:00Z'},
        ],
      });
      expect(d.payloadSchema, {'type': 'object'});
      expect(d.answerSchema, isEmpty);
      expect(d.sensitive, isTrue);
      expect(d.reasons.single.reasonCode, 'guideline_miss');
      expect(d.reasons.single.billable, isFalse);
      expect(d.feedback.single.body, 'Thanks');
      expect(d.feedback.single.createdAt, isNotNull);
      expect(d.rubricLog.single.version, 'v2');
      expect(d.name, 'Hindi');
    });

    test('ProjectInput splits creation from the patch and builds the edit body', () {
      const input = ProjectInput(
        name: 'Tamil',
        currency: 'INR',
        payloadSchema: {'type': 'object'},
        rubricVersion: 'v3',
        marginFloor: 0.25,
        certGate: 'ocr',
        brief: 'Read plates',
        sensitive: true,
        clientOrgId: 'org-1',
        status: 'closed',
      );
      expect(input.createBody, {
        'name': 'Tamil',
        'currency': 'INR',
        'payload_schema': {'type': 'object'},
        'answer_schema': null,
        'rubric_version': 'v3',
        'margin_floor': '0.2500',
        'cert_gate': 'ocr',
        'retention_days': 180,
      });
      expect(input.createPatchBody, {'brief': 'Read plates', 'sensitive': true, 'client_org_id': 'org-1'});
      expect(input.editBody['status'], 'closed');
      expect(input.editBody['llm_policy'], '');
      expect(input.editBody.containsKey('payload_schema'), isFalse);
      expect(input.editBody['retention_days'], 180);
      const plain = ProjectInput(name: 'P', currency: 'INR', payloadSchema: {});
      expect(plain.createPatchBody, isEmpty);
      expect(plain.createBody['margin_floor'], isNull);
      expect(plain.createBody['cert_gate'], isNull);
      expect(plain.editBody.containsKey('status'), isFalse);
    });

    test('BatchInput serialises and previews its margin', () {
      const b = BatchInput(title: 'T', unitPay: '50.00', unitPrice: '60.00', reviewPay: '4.00');
      expect(b.margin, closeTo(0.1, 0.0001));
      expect(b.toJson(), {
        'title': 'T',
        'mode': 'open',
        'unit_pay': '50.00',
        'unit_price': '60.00',
        'review_pay': '4.00',
        'claim_ttl_minutes': 240,
      });
    });
  });

  group('pages and reports', () {
    test('ListPage parses total and items', () {
      final page = ListPage.fromJson({
        'total': 3,
        'items': [
          {'id': 'u1', 'external_ref': 'r1', 'status': 'available', 'current_claim_id': null},
        ],
      }, UnitRow.fromJson);
      expect(page.total, 3);
      expect(page.items.single.externalRef, 'r1');
      expect(page.items.single.currentClaimId, '');
      expect(ListPage.fromJson({}, UnitRow.fromJson).items, isEmpty);
    });

    test('ImportReport is clean only with accepted lines and no errors', () {
      final bad = ImportReport.fromJson({
        'total': 3,
        'accepted': 1,
        'errors': [
          {'line': 2, 'external_ref': 'r2', 'reason': 'missing text'},
        ],
        'dry_run': true,
      });
      expect(bad.clean, isFalse);
      expect(bad.errors.single.line, 2);
      expect(bad.dryRun, isTrue);
      expect(ImportReport.fromJson({'total': 3, 'accepted': 3, 'errors': [], 'dry_run': false}).clean, isTrue);
      expect(ImportReport.fromJson({'total': 0, 'accepted': 0, 'errors': []}).clean, isFalse);
    });

    test('WorkerRow reads gates, availability and a missing status as unknown', () {
      final w = WorkerRow.fromJson({
        'id': 'w1',
        'cert_gates': ['a', 2, 'b'],
        'partner_ref': 7,
        'availability': {'weekly_hours': 20},
        'updated_at': '2026-11-01T10:00:00Z',
      });
      expect(w.status, 'unknown');
      expect(w.certGates, ['a', 'b']);
      expect(w.partnerRef, 7);
      expect(w.availability?.weeklyHours, 20);
      expect(WorkerRow.fromJson({'id': 'w2', 'status': 'active', 'availability': null}).availability, isNull);
    });

    test('ClientOrg and QualityStats', () {
      expect(
        ClientOrg.fromJson({
          'id': 'o',
          'name': 'Acme',
          'members': ['u'],
        }).members,
        ['u'],
      );
      final s = QualityStats.fromJson({
        'pending': 12,
        'accepted': 90,
        'rejected': 6,
        'acceptance_rate': '0.9',
        'oldest_pending_at': '2026-11-01T10:00:00Z',
        'reasons': [
          {'reason_code': 'x', 'count': 1, 'billable': true},
        ],
        'audit_disagreements': 1,
      });
      expect(s.acceptanceRate, 0.9);
      expect(s.oldestPendingAt, isNotNull);
      expect(s.reasons.single.billable, isTrue);
      expect(QualityStats.fromJson({}).acceptanceRate, isNull);
    });
  });

  group('payout', () {
    test('PayoutOverview reads payable per currency, windows and the open window', () {
      final p = PayoutOverview.fromJson({
        'payable_now': {'INR': '12500.00', 'USD': 40},
        'paid_total': {'INR': '1'},
        'held_total': {},
        'margin_total': '3',
        'pending_adjustments': 2,
        'open_window': {'starts_at': '2026-10-31T00:00:00Z', 'ends_at': '2026-11-07T00:00:00Z', 'closes_in_seconds': 100},
        'windows': {'closed': 1, 'approved': 0, 'paid': 4},
      });
      expect(p.payableNow, {'INR': '12500.00', 'USD': '40'});
      expect(p.windowsClosed, 1);
      expect(p.windowsPaid, 4);
      expect(p.openWindow?.closesInSeconds, 100);
      expect(PayoutOverview.fromJson({}).openWindow, isNull);
    });

    test('PayoutAccount reads the account and the totals; held when a reason is set', () {
      final a = PayoutAccount.fromJson({
        'account': {'worker_id': 'w', 'hold_reason': 'quality_review', 'hold_until': '2026-11-20T00:00:00Z', 'first_paid_at': null},
        'totals': {'payable': '1', 'paid': '2', 'held': '3'},
      });
      expect(a.isHeld, isTrue);
      expect(a.holdUntil, isNotNull);
      expect(a.firstPaidAt, isNull);
      expect(a.held, '3');
      expect(
        PayoutAccount.fromJson({
          'account': {'worker_id': 'w', 'hold_reason': null},
        }).isHeld,
        isFalse,
      );
    });
  });

  group('talent', () {
    test('Listing reads questions, requirements, counts and dates', () {
      final l = Listing.fromJson({
        'id': 'l1',
        'title': 'Pool',
        'pay_min': '20',
        'pay_max': '40',
        'currency': 'INR',
        'slots_total': 10,
        'slots_filled': 3,
        'requirements': ['a'],
        'questions': [
          {
            'key': 'k',
            'prompt': 'P',
            'kind': 'choice',
            'options': ['x', 'y'],
            'required': true,
          },
          {'key': 'k2', 'prompt': 'Q'},
        ],
        'status': 'open',
        'closes_at': '2026-11-30T00:00:00Z',
        'applications': {'applied': 4, 'screening': 2, 'offered': 1, 'accepted': 3, 'rejected': 1},
      });
      expect(l.questions.first.options, ['x', 'y']);
      expect(l.questions.last.kind, 'text');
      expect(l.questions.last.required, isFalse);
      expect(l.applications.screening, 2);
      expect(l.closesAt, isNotNull);
      expect(l.questions.first.toJson(), {
        'key': 'k',
        'prompt': 'P',
        'kind': 'choice',
        'options': ['x', 'y'],
        'required': true,
      });
      expect(l.questions.last.toJson().containsKey('options'), isFalse);
    });

    test('ListingInput serialises nulls for an empty gate, paper and date', () {
      const input = ListingInput(title: 'T', domain: 'D', payMin: '1.00', payMax: '2.00');
      final j = input.toJson();
      expect(j['cert_gate'], isNull);
      expect(j['paper_id'], isNull);
      expect(j['closes_at'], isNull);
      expect(j['pay_unit'], 'per_unit');
      expect(j['questions'], isEmpty);
      expect(
        ListingInput(title: 'T', domain: 'D', payMin: '1', payMax: '2', closesAt: DateTime.utc(2026, 12, 15)).toJson()['closes_at'],
        '2026-12-15T00:00:00.000Z',
      );
    });

    test('Application reads steps, answers and the offer expiry', () {
      final a = Application.fromJson({
        'id': 'a1',
        'listing_id': 'l1',
        'worker_id': 'w1',
        'status': 'offered',
        'steps': [
          {'kind': 'form', 'status': 'done'},
        ],
        'answers': {'exp': '3'},
        'note': null,
        'offer_expires_at': '2026-11-10T00:00:00Z',
      });
      expect(a.steps.single.kind, 'form');
      expect(a.answers, {'exp': '3'});
      expect(a.note, '');
      expect(a.offerExpiresAt, isNotNull);
      expect(a.decidedBy, '');
    });
  });

  group('assess', () {
    test('Paper reads the v2 exam snapshot, its cohorts and its stats', () {
      final p = Paper.fromJson({
        'id': 'p1',
        'gate': 'g',
        'title': 'T',
        'status': 'published',
        'engine': 'v2',
        'engine_assessment_id': 12,
        'release_policy': 'auto_objective',
        'max_attempts': 2,
        'assigned_ttl_days': 14,
        'snapshot': {
          'name': 'Hindi v3',
          'duration_minutes': 30,
          'question_count': 10,
          'pass_threshold': 70,
          'question_types': ['mcq', 'transcription'],
          'rules': {'webcam': true, 'seb': false},
        },
        'cohorts': [
          {'id': 'c1', 'attempt_no': 1, 'generation': 2, 'engine_assessment_id': 12, 'state': 'open'},
        ],
        'stats': {'total': 40, 'passed': 30, 'pass_rate': 0.75, 'awaiting_result': 3, 'held': 1},
      });
      expect(p.isPublished, isTrue);
      expect(p.autoRelease, isTrue);
      expect(p.engineBaseId, '12');
      expect(p.snapshot.passThreshold, 0.7);
      expect(p.snapshot.questionTypes, ['mcq', 'transcription']);
      expect(p.snapshot.proctoring.on, ['webcam']);
      expect(p.cohorts.single.engineAssessmentId, '12');
      expect(p.cohorts.single.generation, 2);
      expect(p.stats.awaitingResult, 3);
      final empty = Paper.fromJson({'id': 'p2'});
      expect((empty.status, empty.engine, empty.releasePolicy, empty.stats.total), ('draft', 'v2', 'manual', 0));
      expect(Paper.fromJson({'id': 'p3', 'status': 'retired', 'engine': 'quiz'}).isRetired, isTrue);
      expect(PaperSnapshot.fromJson({'pass_threshold': 0.65}).passThreshold, 0.65, reason: 'a fraction stays a fraction');
      expect(
        PaperSnapshot.fromJson({
          'proctoring': ['seb'],
        }).proctoring.on,
        ['seb'],
      );
      expect(PaperSnapshot.fromJson({}).passThreshold, isNull);
    });

    test('a sitting row reads its flags from a map or a list, and its score may be missing', () {
      final m = PaperSittingRow.fromJson({
        'id': 's',
        'status': 'awaiting_result',
        'flags': {'integrity_alert': true, 'score_outlier': false},
      });
      expect(m.flags, ['integrity_alert']);
      expect(m.awaitingResult, isTrue);
      expect(m.score, isNull);
      expect(
        PaperSittingRow.fromJson({
          'flags': ['violation_limit_breached'],
        }).flags,
        ['violation_limit_breached'],
      );
      expect(PaperSittingRow.fromJson({}).flags, isEmpty);
      expect(EngineAssessment.fromJson({'id': 7, 'name': 'X', 'question_count': 3}).id, '7');
    });

    test('PaperInput sends a linked assessment or a quick paper with a four-place pass mark', () {
      const linked = PaperInput(gate: 'g', title: 'T', maxAttempts: 2, source: LinkedAssessment('21'));
      expect(linked.toJson()['source'], {'kind': 'assessment', 'assessment_id': 21});
      expect(linked.toJson()['release_policy'], 'manual');
      expect(const LinkedAssessment('abc').toJson()['assessment_id'], 'abc');
      const quick = PaperInput(
        gate: 'g',
        title: 'T',
        maxAttempts: 3,
        releasePolicy: 'auto_objective',
        source: QuickPaper(
          durationMinutes: 20,
          passMark: 0.8,
          questions: [
            QuickQuestion(id: 'q1', prompt: 'P', kind: 'single', options: ['a', 'b'], answer: ['a']),
            QuickQuestion(id: 'q2', prompt: 'Q', kind: 'multi', options: ['a', 'b', 'c'], answer: ['a', 'c']),
          ],
        ),
      );
      final j = quick.toJson();
      final src = j['source'] as Map<String, Object?>;
      expect((j['release_policy'], j['assigned_ttl_days']), ('auto_objective', 14));
      expect((src['kind'], src['duration_minutes'], src['pass_mark']), ('quick', 20, '0.8000'));
      expect((src['questions'] as List)[0], {
        'id': 'q1',
        'prompt': 'P',
        'kind': 'single',
        'options': ['a', 'b'],
        'answer': 'a',
      });
      expect(((src['questions'] as List)[1] as Map)['answer'], ['a', 'c']);
    });
  });

  group('OpsOverview', () {
    test('sums units across projects and lists the batches under the floor', () {
      final o = OpsOverview(
        projects: [
          ProjectSummary.fromJson({
            'id': 'p1',
            'name': 'A',
            'margin_floor': '0.3',
            'units': {'available': 1, 'claimed': 2},
            'batches': [
              {'id': 'b1', 'title': 'Cheap', 'unit_pay': '50', 'unit_price': '60', 'review_pay': '4'},
            ],
          }),
          ProjectSummary.fromJson({
            'id': 'p2',
            'name': 'B',
            'units': {'available': 3},
          }),
        ],
      );
      expect(o.units.available, 4);
      expect(o.units.claimed, 2);
      expect(o.underFloor.single.$1.id, 'p1');
      expect(o.underFloor.single.$2.title, 'Cheap');
      expect(o.stats, isNull);
      expect(o.attention, isNull);
      expect(o.payoutAttention, isNull);
      expect(o.bench, isNull);
    });
  });

  test('a bank account the penny drop proved without a name waits for finance', () {
    final b = BankStatus.fromJson({'status': 'verified', 'awaiting_confirmation': true, 'confirmed_at': null});
    expect(b.awaitingConfirmation, isTrue);
    final done = BankStatus.fromJson({'status': 'verified', 'awaiting_confirmation': false, 'confirmed_at': '2026-11-04T09:00:00Z'});
    expect(done.awaitingConfirmation, isFalse);
    expect(done.confirmedAt?.toUtc(), DateTime.utc(2026, 11, 4, 9));
  });

  test('market attention counts units waiting days for one worker', () {
    expect(WorkAttention.fromJson({'stuck_assigned_units': 4}).stuckAssignedUnits, 4);
  });

  test('a unit waiting for one worker reads its batch, worker and days', () {
    final u = StuckAssignedUnit.fromJson({
      'unit_id': 'u1',
      'external_ref': 'clip-9',
      'batch_id': 'b1',
      'batch_title': 'Hindi batch',
      'project_id': 'p1',
      'project_name': 'Hindi ASR',
      'worker_id': 'w1',
      'worker_name': 'Asha',
      'assigned_at': '2026-10-30T00:00:00Z',
      'days_waiting': 6,
    });
    expect(
      (u.unitId, u.externalRef, u.batchTitle, u.projectName, u.workerId, u.workerName, u.daysWaiting),
      ('u1', 'clip-9', 'Hindi batch', 'Hindi ASR', 'w1', 'Asha', 6),
    );
    expect(u.assignedAt?.toUtc(), DateTime.utc(2026, 10, 30));
  });
}
