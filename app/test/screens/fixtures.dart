/// Shared wire fixtures for screen tests.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The title the shell's top bar shows.
String pageTitle(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('page-title'))).data ?? '';

final batch = {
  'id': 'b1',
  'project_id': 'p1',
  'project_name': 'Hindi transcription',
  'title': 'Label street signs',
  'mode': 'open',
  'unit_pay': '12.50',
  'review_pay': '2.00',
  'currency': 'INR',
  'claim_ttl_minutes': 240,
  'rubric_version': 'v1',
  'status': 'open',
  'available_units': 42,
  'answer_schema': null,
};

Map<String, Object?> claim({String expires = ''}) => {
  'id': 'c1',
  'unit_id': 'u1',
  'worker_id': 'worker-1',
  'status': 'live',
  'expires_at': expires.isEmpty ? DateTime.now().add(const Duration(hours: 2)).toUtc().toIso8601String() : expires,
};

final unit = {
  'id': 'u1',
  'batch_id': 'b1',
  'external_ref': 'row-17',
  'payload': {
    'text': 'Stop sign at 5th',
    'meta': {'lang': 'en'},
  },
  'unit_pay': '12.50',
  'rubric_version': 'v1',
  'status': 'claimed',
  'current_claim_id': 'c1',
};

Map<String, Object?> me({String status = 'eligible', List<String> gates = const ['transcription'], Map<String, Object?>? availability}) => {
  'id': 'worker-1',
  'status': status,
  'cert_gates': gates,
  'partner_ref': 7,
  'updated_at': '2026-11-01T10:00:00Z',
  'availability': availability,
};

Map<String, Object?> statement({String pending = '25.00', int pendingCount = 2}) => {
  'worker_id': 'worker-1',
  'totals': {'payable': pending, 'paid': '100.00'},
  'hold': null,
  'account': {'first_paid_at': '2026-10-20T10:00:00Z', 'hold_until': null, 'hold_reason': null},
  'earnings': [
    {
      'id': 'e1',
      'kind': 'unit',
      'unit_id': 'u1',
      'amount': '12.50',
      'currency': 'INR',
      'status': 'payable',
      'window_id': null,
      'created_at': '2026-11-02T10:00:00Z',
    },
  ],
  'windows': [],
  'weeks': [],
  'pending_next': {'currency': 'INR', 'amount': pending, 'count': pendingCount},
  'next_window_closes_at': DateTime.now().add(const Duration(days: 2)).toUtc().toIso8601String(),
};

final channel = {'worker_id': 'worker-1', 'email': 'asha@example.com', 'updated_at': '2026-11-01T10:00:00Z'};

final emptyActive = {'claim': null, 'unit': null, 'batch': null};
