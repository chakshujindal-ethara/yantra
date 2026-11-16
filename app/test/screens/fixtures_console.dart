/// Wire fixtures and openers for the operator's Quality, Finance and Support pages, the client console and
/// the support ticket card on Profile. Shapes follow docs/PRODUCT.md 5.1, 5.4, 5.5, 5.6 and the routers.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_backend.dart';

// ── quality ────────────────────────────────────────────────────────────────

Map<String, Object?> flag(String id, {String note = 'Does "street sign" include shop boards?'}) => {
  'id': id,
  'task_id': 'task-$id-0000',
  'batch_id': 'batch-aaaa-1111',
  'reviewer_id': 'reviewer-7777-1',
  'note': note,
  'answer': null,
  'answered_at': null,
  'created_at': DateTime.now().subtract(const Duration(hours: 3)).toUtc().toIso8601String(),
};

Map<String, Object?> disputeRow(String id, {String verdict = 'reject', String reason = 'guideline_miss'}) => {
  'id': id,
  'status': 'open',
  'reason': 'The glossary changed after I submitted; my answer matched the old one.',
  'answer': null,
  'created_at': DateTime.now().subtract(const Duration(days: 2)).toUtc().toIso8601String(),
  'resolved_at': null,
  'resolved_by': null,
  'task_id': 'task-$id-0000',
  'unit_id': 'unit-$id-0000',
  'batch_id': 'batch-aaaa-1111',
  'worker_id': 'worker-5555-1',
  'verdict': verdict,
  'reason_code': reason,
};

Map<String, Object?> stats({int pending = 12, String rate = '0.83'}) => {
  'pending': pending,
  'claimed': 3,
  'in_audit': 1,
  'canonical': 40,
  'accepted': 33,
  'rejected': 4,
  'needs_edits': 3,
  'acceptance_rate': rate,
  'oldest_pending_at': DateTime.now().subtract(const Duration(hours: 30)).toUtc().toIso8601String(),
  'audit_disagreements': 2,
  'reasons': [
    {'reason_code': 'guideline_miss', 'count': 5, 'billable': false},
    {'reason_code': 'client_glossary_change', 'count': 2, 'billable': true},
  ],
};

Map<String, Object?> taskRow(String id, {String status = 'pending', String? verdict}) => {
  'id': id,
  'unit_id': 'unit-$id-0000',
  'batch_id': 'batch-aaaa-1111',
  'worker_id': 'worker-5555-1',
  'status': status,
  'reviewer_id': status == 'pending' ? null : 'reviewer-7777-1',
  'canonical_verdict': verdict,
  'created_at': '2026-11-01T10:00:00Z',
  'canonical_at': verdict == null ? null : '2026-11-02T10:00:00Z',
};

Map<String, Object?> taskPage(List<Object?> items, {int? total}) => {'total': total ?? items.length, 'items': items};

// ── finance ────────────────────────────────────────────────────────────────

Map<String, Object?> payoutOverview({int pendingAdjustments = 2}) => {
  'payable_now': {'INR': '1250.00'},
  'paid_total': {'INR': '98000.00'},
  'held_total': {'INR': '300.00'},
  'open_window': {
    'starts_at': '2026-10-31T18:30:00Z',
    'ends_at': DateTime.now().add(const Duration(days: 2, hours: 3)).toUtc().toIso8601String(),
    'closes_in_seconds': 183600,
  },
  'windows': {'closed': 1, 'approved': 1, 'paid': 4},
  'margin_total': {'INR': '21000.00'},
  'pending_adjustments': pendingAdjustments,
};

Map<String, Object?> window(
  String id, {
  String status = 'closed',
  int? approvals,
  String currency = 'INR',
  String? rail,
  String? reconciledAt,
}) => {
  'id': id,
  'starts_at': '2026-10-24T18:30:00Z',
  'ends_at': '2026-10-31T18:30:00Z',
  'currency': currency,
  'status': status,
  'gross_total': '4200.00',
  'held_total': '300.00',
  'paid_at': status == 'paid' ? '2026-11-02T09:00:00Z' : null,
  'rail_reference': status == 'paid' ? 'UTR999' : null,
  'line_count': 3,
  'approvals': ?approvals,
  'rail': rail ?? (status == 'paying' || status == 'paid' ? 'razorpayx' : null),
  'paid_total': status == 'paid' ? '3900.00' : '0',
  'reconciled_at': reconciledAt,
};

Map<String, Object?> line(
  String id,
  String worker,
  String gross, {
  String status = 'payable',
  String? hold,
  int attempts = 0,
  String? utr,
  String? reason,
}) => {
  'id': id,
  'window_id': 'w1',
  'worker_id': worker,
  'gross': gross,
  'earning_count': 4,
  'status': status,
  'hold_reason': hold,
  'attempts': attempts,
  'utr': utr,
  'failure_reason': reason,
};

Map<String, Object?> adjustment(String id, {String status = 'pending', String kind = 'bonus', String amount = '150.00'}) => {
  'id': id,
  'worker_id': 'worker-5555-1',
  'amount': amount,
  'currency': 'INR',
  'kind': kind,
  'reason': 'Weekend push on the Hindi batch',
  'status': status,
  'proposed_by': 'ops-1111-aaaa',
  'decided_by': status == 'pending' ? null : 'ops-2222-bbbb',
  'created_at': '2026-11-01T10:00:00Z',
  'decided_at': status == 'pending' ? null : '2026-11-02T10:00:00Z',
};

Map<String, Object?> marginRow(String batch) => {
  'batch_id': batch,
  'currency': 'INR',
  'units_judged': 120,
  'units_accepted': 100,
  'invoice': '5000.00',
  'cost_pay': '2500.00',
  'cost_review': '400.00',
  'cost_audit': '100.00',
  'billable_rework_units': 3,
  'margin': '2000.00',
  'margin_fraction': '0.4000',
};

// ── support ────────────────────────────────────────────────────────────────

Map<String, Object?> ticket(
  String id, {
  String status = 'open',
  String category = 'bug',
  String title = 'Submit button does nothing',
  String note = '',
}) => {
  'id': id,
  'author_id': 'worker-5555-1',
  'category': category,
  'title': title,
  'body': 'I filled the form and nothing happened after Submit.',
  'screen': 'Work',
  'context': {'app': 'web', 'theme': 'light', 'width': 1280},
  'status': status,
  'note': note.isEmpty ? null : note,
  'created_at': DateTime.now().subtract(const Duration(hours: 5)).toUtc().toIso8601String(),
  'updated_at': DateTime.now().subtract(const Duration(hours: 1)).toUtc().toIso8601String(),
};

// ── client ─────────────────────────────────────────────────────────────────

Map<String, Object?> unitCounts({
  int total = 100,
  int available = 20,
  int claimed = 5,
  int submitted = 5,
  int inReview = 10,
  int accepted = 55,
  int rejected = 3,
  int needsEdits = 2,
}) => {
  'total': total,
  'available': available,
  'claimed': claimed,
  'submitted': submitted,
  'in_review': inReview,
  'accepted': accepted,
  'rejected': rejected,
  'needs_edits': needsEdits,
};

Map<String, Object?> clientOverview({Map<String, Object?>? nextDelivery}) => {
  'orgs': [
    {'id': 'org-1', 'name': 'Acme Maps'},
  ],
  'units': unitCounts(),
  'acceptance_rate': '0.917',
  'billable_rework': 4,
  'deliveries': 2,
  'invoice_total': {'INR': '12500.00'},
  'next_delivery': ?nextDelivery,
};

/// The client's deliverable for [batch]: files behind presigned links the fake backend also serves.
Map<String, Object?> deliverable({String batch = 'batch-aaaa-1111'}) => {
  'manifest_id': 'm1',
  'batch_id': batch,
  'digest': 'sha256:9f8e',
  'jsonl': {
    'url': 'http://minio.test/deliv/units.jsonl',
    'expires_at': '2026-11-04T10:05:00Z',
    'sha256': 'abc',
    'bytes': 40,
    'line_count': 2,
  },
  'manifest': {'url': 'http://minio.test/deliv/manifest.json', 'expires_at': '2026-11-04T10:05:00Z'},
};

Map<String, Object?> manifest(String id, {String batch = 'batch-aaaa-1111'}) => {
  'id': id,
  'batch_id': batch,
  'digest': 'sha256:9f8e7d6c5b4a39281706f5e4d3c2b1a0',
  'accepted_units': 55,
  'total_price': '2750.00',
  'created_at': '2026-11-01T10:00:00Z',
};

Map<String, Object?> clientProject(String id, {String name = 'Hindi street signs', String status = 'active'}) => {
  'id': id,
  'name': name,
  'currency': 'INR',
  'status': status,
  'rubric_version': 'v3',
  'units': unitCounts(),
  'acceptance_rate': '0.917',
  'invoice_total': '12500.00',
};

Map<String, Object?> clientProjectDetail(
  String id, {
  String name = 'Hindi street signs',
  List<Object?>? feedback,
  List<Object?>? deliveries,
}) => {
  ...clientProject(id, name: name),
  'batches': [
    {
      'id': 'batch-aaaa-1111',
      'title': 'Label street signs',
      'status': 'open',
      'unit_price': '50.00',
      'units': unitCounts(),
      'manifest': manifest('m1'),
    },
    {
      'id': 'batch-bbbb-2222',
      'title': 'Shop boards',
      'status': 'draft',
      'unit_price': '45.00',
      'units': unitCounts(total: 40, available: 40, claimed: 0, submitted: 0, inReview: 0, accepted: 0, rejected: 0, needsEdits: 0),
      'manifest': null,
    },
  ],
  'reasons': [
    {'reason_code': 'client_glossary_change', 'count': 4, 'billable': true},
    {'reason_code': 'guideline_miss', 'count': 3, 'billable': false},
  ],
  'deliveries': deliveries ?? [manifest('m1')],
  'feedback':
      feedback ??
      [
        {'id': 'f1', 'author_id': 'client-9999-1', 'body': 'Please prioritise the Delhi set.', 'created_at': '2026-11-01T09:00:00Z'},
      ],
};

// ── openers ────────────────────────────────────────────────────────────────

/// The ops shell opens on Overview (a placeholder with no requests); [navKey] picks the page from the sidebar
/// (wide) or the bottom bar label [label] (narrow).
Future<void> openOps(
  WidgetTester tester,
  FakeBackend backend, {
  required String navKey,
  required String label,
  bool wide = true,
  Size? size,
}) async {
  await pumpApp(tester, backend, size: size ?? (wide ? const Size(1280, 2400) : const Size(390, 3000)), roles: ['ops', 'finance']);
  if (wide) {
    await tester.tap(find.byKey(Key(navKey)));
  } else {
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
  }
  await tester.pumpAndSettle();
}

/// The client shell opens on Overview; [navKey] picks another page the same way.
Future<void> openClient(WidgetTester tester, FakeBackend backend, {String? navKey, String? label, bool wide = true, Size? size}) async {
  await pumpApp(tester, backend, size: size ?? (wide ? const Size(1280, 2400) : const Size(390, 3000)), roles: ['client']);
  if (navKey == null) return;
  if (wide) {
    await tester.tap(find.byKey(Key(navKey)));
  } else {
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label!)));
  }
  await tester.pumpAndSettle();
}
