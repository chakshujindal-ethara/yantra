/// Wire fixtures and helpers for the operator console's screen tests.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/theme/app_theme.dart';
import 'package:yantra_app/core/widgets/portal_page.dart';

import '../../support/fake_backend.dart';

const wide = Size(1280, 900);
const phone = Size(390, 844);

Map<String, Object?> units({
  int available = 40,
  int claimed = 5,
  int submitted = 3,
  int inReview = 2,
  int accepted = 50,
  int rejected = 0,
  int needsEdits = 0,
}) => {
  'total': available + claimed + submitted + inReview + accepted + rejected + needsEdits,
  'available': available,
  'claimed': claimed,
  'submitted': submitted,
  'in_review': inReview,
  'accepted': accepted,
  'rejected': rejected,
  'needs_edits': needsEdits,
};

Map<String, Object?> batchSummary({
  String id = 'b1',
  String title = 'Label street signs',
  String status = 'open',
  String unitPay = '28.00',
  String unitPrice = '60.00',
  String reviewPay = '4.00',
  int liveClaims = 5,
  Map<String, Object?>? manifest,
  Map<String, Object?>? counts,
}) => {
  'id': id,
  'project_id': 'p1',
  'project_name': 'Hindi transcription',
  'title': title,
  'mode': 'open',
  'status': status,
  'unit_pay': unitPay,
  'unit_price': unitPrice,
  'review_pay': reviewPay,
  'currency': 'INR',
  'claim_ttl_minutes': 240,
  'rubric_version': 'v2',
  'floor_approved_by': null,
  'published_at': status == 'draft' ? null : '2026-11-01T10:00:00Z',
  'units': counts ?? units(),
  'live_claims': liveClaims,
  'manifest': manifest,
};

final manifestJson = {
  'id': 'm1',
  'digest': 'sha256:abcdef1234567890',
  'accepted_units': 100,
  'total_price': '6000.00',
  'created_at': '2026-11-02T10:00:00Z',
};

Map<String, Object?> projectSummary({
  String id = 'p1',
  String name = 'Hindi transcription',
  String status = 'active',
  String? marginFloor = '0.3000',
  List<Object?>? batches,
  Map<String, Object?>? counts,
  String createdAt = '2026-10-20T10:00:00Z',
}) => {
  'id': id,
  'name': name,
  'currency': 'INR',
  'status': status,
  'cert_gate': 'transcription',
  'rubric_version': 'v2',
  'margin_floor': marginFloor,
  'client_org_id': 'org-1',
  'batch_count': batches?.length ?? 2,
  'units': counts ?? units(),
  'batches': ?batches,
  'created_at': createdAt,
};

Map<String, Object?> projectDetail({List<Object?>? batches, String? marginFloor = '0.3000', bool sensitive = false}) => {
  ...projectSummary(marginFloor: marginFloor),
  'payload_schema': {
    'type': 'object',
    'properties': {
      'text': {'type': 'string'},
    },
  },
  'answer_schema': {
    'type': 'object',
    'properties': {
      'label': {'type': 'string'},
    },
  },
  'brief': 'Transcribe the audio exactly as spoken.',
  'llm_policy': 'No LLM assistance.',
  'sensitive': sensitive,
  'batches': batches ?? [batchSummary(), batchSummary(id: 'b2', title: 'Draft batch', status: 'draft', unitPay: '50.00', liveClaims: 0)],
  'reasons': [
    {'reason_code': 'guideline_miss', 'count': 7, 'billable': false},
    {'reason_code': 'client_change', 'count': 2, 'billable': true},
  ],
  'feedback': [
    {'id': 'f1', 'author_id': 'client-user-1', 'body': 'Please keep the diacritics.', 'created_at': '2026-10-28T09:00:00Z'},
  ],
  'rubric_log': [
    {'version': 'v2', 'note': 'Diacritics required', 'at': '2026-10-27T09:00:00Z'},
  ],
};

Map<String, Object?> unitRow(int i, {String status = 'available'}) => {
  'id': 'unit-${i.toString().padLeft(4, '0')}-ffff',
  'external_ref': 'row-$i',
  'status': status,
  'assigned_worker_id': null,
  'current_claim_id': status == 'claimed' ? 'claim-$i' : null,
  'created_at': '2026-11-01T10:00:00Z',
};

Map<String, Object?> unitsPage({int total = 3, int count = 3, String status = 'available'}) => {
  'total': total,
  'items': [for (var i = 1; i <= count; i++) unitRow(i, status: status)],
};

Map<String, Object?> importReport({int total = 3, int accepted = 3, List<Object?> errors = const [], bool dryRun = true}) => {
  'total': total,
  'accepted': accepted,
  'errors': errors,
  'dry_run': dryRun,
};

Map<String, Object?> workerRow({
  String id = 'worker-1111-2222',
  String status = 'eligible',
  List<String> gates = const ['transcription', 'labelling'],
  Map<String, Object?>? availability = const {'weekly_hours': 20, 'paused_until': null},
  String? name,
  bool onboarded = true,
  bool held = false,
  String? holdUntil,
}) => {
  'id': id,
  'status': status,
  'cert_gates': gates,
  'partner_ref': 7,
  'availability': availability,
  'updated_at': '2026-11-01T10:00:00Z',
  'name': name,
  'onboarded': onboarded,
  'held': held,
  'hold_until': holdUntil,
};

Map<String, Object?> workersPage({int total = 2}) => {
  'total': total,
  'items': [
    workerRow(name: 'Asha Verma'),
    workerRow(
      id: 'worker-3333-4444',
      onboarded: false,
      held: true,
      holdUntil: '2026-11-20T00:00:00Z',
      status: 'suspended',
      gates: const ['labelling'],
      availability: {'weekly_hours': 10, 'paused_until': DateTime.now().add(const Duration(days: 3)).toUtc().toIso8601String()},
    ),
  ],
};

final clientOrgs = [
  {
    'id': 'org-1',
    'name': 'Acme Labs',
    'members': ['u1'],
  },
  {'id': 'org-2', 'name': 'Globex', 'members': []},
];

Map<String, Object?> qualityStats({String? oldestPendingAt}) => {
  'pending': 12,
  'claimed': 3,
  'in_audit': 1,
  'canonical': 0,
  'accepted': 90,
  'rejected': 6,
  'needs_edits': 4,
  'acceptance_rate': 0.9,
  'oldest_pending_at': oldestPendingAt ?? DateTime.now().subtract(const Duration(hours: 3, minutes: 10)).toUtc().toIso8601String(),
  'reasons': [
    {'reason_code': 'guideline_miss', 'count': 5, 'billable': false},
  ],
  'audit_disagreements': 1,
};

final payoutOverview = {
  'payable_now': {'INR': '12500.00', 'USD': '40.00'},
  'paid_total': {'INR': '100000.00'},
  'held_total': {'INR': '500.00'},
  'open_window': {'starts_at': '2026-10-31T00:00:00Z', 'ends_at': '2026-11-07T00:00:00Z', 'closes_in_seconds': 3 * 24 * 3600},
  'windows': {'closed': 1, 'approved': 0, 'paid': 4},
  'margin_total': {'INR': '32000.00'},
  'pending_adjustments': 2,
};

Map<String, Object?> payoutAccount({String? holdReason, String? holdUntil, Map<String, Object?>? bank}) => {
  'account': {'worker_id': 'worker-1111-2222', 'first_paid_at': '2026-10-20T10:00:00Z', 'hold_until': holdUntil, 'hold_reason': holdReason},
  'totals': {'payable': '250.00', 'paid': '1000.00', 'held': holdReason == null ? '0.00' : '250.00'},
  'bank': bank,
};

Map<String, Object?> bankStatus({String status = 'verified', bool? nameMatch = true, String verification = 'penny_drop'}) => {
  'status': status,
  'verification': verification,
  'account_name': 'Asha Verma',
  'account_last4': '4321',
  'ifsc': 'HDFC0001234',
  'registered_name_match': nameMatch,
  'verified_at': '2026-11-01T10:00:00Z',
  'failure_reason': status == 'failed' ? 'invalid_account' : null,
};

Map<String, Object?> listing({
  String id = 'l1',
  String title = 'Hindi transcription pool',
  String status = 'open',
  int slotsFilled = 3,
  Map<String, Object?>? applications,
}) => {
  'id': id,
  'title': title,
  'domain': 'Transcription',
  'summary': 'Transcribe short Hindi clips.',
  'description': 'Longer description.',
  'pay_min': '20.00',
  'pay_max': '40.00',
  'pay_unit': 'per_unit',
  'currency': 'INR',
  'commitment': 'task_based',
  'hours_per_week': 10,
  'slots_total': 10,
  'slots_filled': slotsFilled,
  'cert_gate': 'transcription',
  'paper_id': 'paper-1',
  'requirements': ['Native Hindi', 'A quiet room'],
  'questions': [
    {'key': 'exp', 'prompt': 'Years of experience?', 'kind': 'text', 'required': true},
    {
      'key': 'shift',
      'prompt': 'Preferred shift',
      'kind': 'choice',
      'options': ['day', 'night'],
      'required': false,
    },
  ],
  'llm_policy': 'None',
  'sensitive': false,
  'status': status,
  'posted_at': '2026-10-25T09:00:00Z',
  'closes_at': '2026-11-30T00:00:00Z',
  'created_at': '2026-10-25T09:00:00Z',
  'applications': applications ?? {'applied': 4, 'screening': 2, 'offered': 1, 'accepted': 3, 'rejected': 1},
};

Map<String, Object?> application(String id, String status, {String worker = 'worker-aaaa-bbbb', String? offerExpiresAt}) => {
  'id': id,
  'listing_id': 'l1',
  'listing_title': 'Hindi transcription pool',
  'worker_id': worker,
  'status': status,
  'steps': [
    {'kind': 'form', 'status': 'done'},
    {'kind': 'paper', 'status': status == 'assessment' ? 'pending' : 'done'},
  ],
  'answers': {'exp': '3'},
  'note': '',
  'offer_expires_at':
      offerExpiresAt ?? (status == 'offered' ? DateTime.now().add(const Duration(days: 5)).toUtc().toIso8601String() : null),
  'decided_by': null,
  'created_at': '2026-10-26T09:00:00Z',
  'updated_at': '2026-10-27T09:00:00Z',
};

Map<String, Object?> paper({
  String id = 'paper-1',
  String title = 'Transcription basics',
  String status = 'published',
  String releasePolicy = 'manual',
  int awaiting = 2,
}) => {
  'id': id,
  'gate': 'transcription',
  'title': title,
  'description': 'Ten questions on the house style.',
  'status': status,
  'engine': 'v2',
  'engine_assessment_id': 12,
  'generation': 1,
  'release_policy': releasePolicy,
  'max_attempts': 2,
  'assigned_ttl_days': 14,
  'snapshot': {
    'name': 'Hindi transcription v3',
    'duration_minutes': 30,
    'question_count': 10,
    'state': 'in_progress',
    'pass_threshold': 70,
    'question_types': ['mcq', 'transcription'],
    'rules': {'webcam': true, 'ai_proctor': true, 'fullscreen': false},
  },
  'cohorts': [
    {'id': 'c1', 'attempt_no': 1, 'generation': 1, 'engine_assessment_id': 12, 'state': 'open'},
    {'id': 'c2', 'attempt_no': 2, 'generation': 1, 'engine_assessment_id': 15, 'state': 'draft'},
  ],
  'stats': {'total': 40, 'passed': 30, 'pass_rate': 0.75, 'awaiting_result': awaiting, 'held': 1},
  'created_at': '2026-10-20T10:00:00Z',
};

/// One row of `GET /v1/assess/papers/{id}/sittings`.
Map<String, Object?> paperSitting({
  String id = 'ps1',
  String workerId = 'w-0000-0001',
  String workerName = 'Asha Rao',
  String status = 'awaiting_result',
  double? score = 0.8,
  bool released = false,
  String heldReason = 'needs_release',
  Object? flags,
}) => {
  'id': id,
  'worker_id': workerId,
  'worker_name': workerName,
  'attempt_no': 1,
  'status': status,
  'score': score,
  'released': released,
  'held_reason': heldReason,
  'flags': flags ?? <String, Object?>{'integrity_alert': false, 'violation_limit_breached': false},
  'result': status == 'passed' ? 'pass' : 'pending',
  'submitted_at': '2026-11-10T09:18:00Z',
};

/// A draft assessment in Assessment v2 (`GET /v1/assess/engine/assessments?state=draft`).
Map<String, Object?> engineAssessment({int id = 21, String name = 'Captions QA v1'}) => {
  'id': id,
  'name': name,
  'state': 'draft',
  'question_count': 8,
  'duration_minutes': 25,
  'pass_threshold': 70,
  'question_types': ['mcq'],
};

/// The routes the Overview (the first ops page) reads, so a test of any other ops page starts clean.
Map<String, Handler> overviewRoutes({List<Object?>? projects}) => {
  'GET /v1/projects': (_) => json(projects ?? [projectSummary()]),
  'GET /v1/quality/stats': (_) => json(qualityStats()),
  'GET /v1/payout/overview': (_) => json(payoutOverview),
  'GET /v1/attention': (_) => json({
    'review_backlog': 10,
    'oldest_pending_at': null,
    'flags_open': 3,
    'flags_overdue': 1,
    'disputes_open': 1,
    'expired_reviews': 1,
    'expired_claims': 1,
    'batches_under_floor': 1,
    'applications_screening': 2,
    'erasures_pending': 0,
    'erasures_due': 0,
    'tickets_open': 3,
    'tickets_in_progress': 1,
    'dead_letters': {'market': 0, 'quality': 0},
  }),
  'GET /v1/payout/attention': (_) => json({
    'windows_awaiting_second_approval': 1,
    'reconciliation_deltas': 0,
    'failed_lines': 2,
    'pending_adjustments': 0,
    'dead_letters': {'payout': 0},
  }),
  'GET /v1/workers/summary': (_) =>
      json({'unknown': 1, 'eligible': 30, 'active': 12, 'suspended': 2, 'offboarded': 1, 'total': 46, 'paused': 4, 'held': 3}),
};

/// Pumps the app as an operator and opens [navKey] (`nav-projects`, ...): by the sidebar at desktop
/// width, by the drawer on a phone.
Future<TestHarness> pumpOps(WidgetTester tester, FakeBackend backend, {Size size = wide, String? navKey}) async {
  final harness = await pumpApp(tester, backend, size: size, roles: const ['ops', 'finance']);
  if (navKey != null) {
    if (size.width >= Layout.wide) {
      await tester.tap(find.byKey(Key(navKey)));
      await tester.pumpAndSettle();
    } else {
      await openFromDrawer(tester, navKey);
    }
  }
  return harness;
}

Finder chip(String label) => find.widgetWithText(StatusChip, label);

/// Scrolls the nearest scrollable until [finder] is visible, then settles.
Future<void> reveal(WidgetTester tester, Finder finder, {Finder? scrollable}) async {
  // the page's own list, never the sidebar's (which comes first in tree order)
  final page = find.descendant(of: find.byType(PortalPage), matching: find.byType(Scrollable)).first;
  await tester.scrollUntilVisible(finder, 200, scrollable: scrollable ?? page);
  await tester.pumpAndSettle();
}
