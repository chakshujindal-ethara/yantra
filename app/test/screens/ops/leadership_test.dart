import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/screens/ops/leadership_screen.dart';

import '../../support/fake_backend.dart';

Map<String, Object?> tile(
  String key, {
  String label = 'A number',
  String? value = '4.5',
  String? baseline = '6',
  String unit = 'days',
  String better = 'lower',
  String href = 'projects',
  Map<String, Object?> basis = const {'batches': 3, 'reached': 2},
  String? note,
}) => {
  'key': key,
  'label': label,
  'value': value,
  'baseline': baseline,
  'unit': unit,
  'better': better,
  'currency': 'INR',
  'basis': basis,
  'href': href,
  'note': ?note,
};

Map<String, Object?> leadership() => {
  'as_of': '2026-11-04T10:00:00Z',
  'window_days': 30,
  'currency': 'INR',
  'baseline_set_at': '2026-11-01T10:00:00Z',
  'numbers': [
    tile('days_to_staff', label: 'Days to staff a batch'),
    tile('idle_cost', label: 'Idle bench cost a week', value: '1200.00', baseline: '800.00', unit: 'money', href: 'workers'),
    tile(
      'first_pass_acceptance',
      label: 'First-pass acceptance',
      value: '0.6667',
      baseline: null,
      unit: 'ratio',
      better: 'higher',
      href: 'quality',
    ),
    tile('cost_per_accepted_unit', label: 'Cost per accepted unit', value: '36.00', baseline: '40.00', unit: 'money', href: 'finance'),
  ],
  'margin': [
    {
      'project_id': 'p1',
      'currency': 'INR',
      'accepted': 10,
      'price': '600.00',
      'pay': '280.00',
      'review': '60.00',
      'audit': '6.00',
      'margin': '254.00',
      'margin_per_unit': '25.40',
      'margin_fraction': '0.4233',
    },
    {
      'project_id': 'p-unknown-123456',
      'currency': 'INR',
      'accepted': 0,
      'price': '0',
      'pay': '0',
      'review': '0',
      'audit': '0',
      'margin': '0',
      'margin_per_unit': null,
      'margin_fraction': null,
    },
  ],
  'watch': [
    tile('on_time_payout', label: 'Payouts on time', value: '1', baseline: '0.95', unit: 'ratio', better: 'higher', href: 'finance'),
    tile(
      'incidents',
      label: 'Incidents',
      value: '2',
      baseline: null,
      unit: 'count',
      href: 'system',
      note: 'Dead letters counted in the work deployable.',
    ),
  ],
};

Map<String, Handler> routes({bool baseline = true}) => {
  'GET /v1/analytics/leadership': (_) => json(leadership()),
  'GET /v1/projects': (_) => json([
    {'id': 'p1', 'name': 'Hindi transcription', 'currency': 'INR', 'status': 'active', 'units': <String, Object>{}},
  ]),
  'GET /v1/analytics/funnel': (_) => json({
    'listing_id': null,
    'window_days': 30,
    'stages_available': ['applied', 'screening', 'offered', 'accepted'],
    'stages': {'applied': 12, 'screening': 6, 'offered': 3, 'accepted': 2},
    'by_day': <Object>[],
  }),
  'GET /v1/analytics/workforce': (_) => json({
    'week_start': '2026-11-02',
    'workers': [
      {
        'worker_id': 'w-1',
        'active_hours': '6.5',
        'units_accepted': 9,
        'units_judged': 10,
        'acceptance_rate': '0.9',
        'earnings': {'INR': '252.00'},
      },
    ],
    'totals': <String, Object>{},
  }),
  'GET /v1/analytics/baselines': (_) => baseline
      ? json({
          'id': 'b1',
          'set_by': 'ops-1',
          'set_at': '2026-11-01T10:00:00Z',
          'currency': 'INR',
          'days_to_staff': '6',
          'idle_cost_weekly': '800.00',
          'first_pass_acceptance': null,
          'cost_per_accepted_unit': '40.00',
          'idle_hourly_cost': '50',
          'idle_hours_per_week': 10,
          'staffing_workers': 5,
          'rail_fee_per_payout': '0',
          'levy_rate': '0',
          'payout_sla_days': 7,
          'note': 'From the Q3 spreadsheet',
        })
      : envelope(404, 'not_found', message: 'no baseline has been set'),
  'GET /v1/analytics/rebuild': (_) => json({'generation': 2, 'status': 'done', 'mode': 'repair', 'events': 140}),
  'GET /v1/people': (_) => json({
    'w-1': {'name': 'Asha Rao', 'kind': 'worker'},
  }),
};

Future<TestHarness> open(
  WidgetTester tester,
  FakeBackend backend, {
  List<String> roles = const ['ops', 'finance'],
  Size? size,
  bool dark = false,
}) => pumpApp(tester, backend, size: size ?? const Size(1280, 3200), roles: roles, at: '/ops/leadership', dark: dark);

void main() {
  testWidgets('the four numbers show value, baseline, verdict and basis; the watch list and margin follow', (tester) async {
    final backend = FakeBackend(routes());
    await open(tester, backend);
    expect(find.text('INSIGHT · LEADERSHIP'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('tile-days_to_staff')), matching: find.text('4.5 d')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('tile-days_to_staff')), matching: find.text('On target')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('tile-days_to_staff')), matching: find.text('batches 3 · reached 2')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('tile-idle_cost')), matching: find.text('₹1,200.00')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('tile-idle_cost')), matching: find.text('Off target')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('tile-first_pass_acceptance')), matching: find.text('66.7%')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('tile-first_pass_acceptance')), matching: find.text('No baseline')), findsOneWidget);
    expect(find.text('Dead letters counted in the work deployable.'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('margin-p1')), matching: find.text('Hindi transcription')), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const Key('margin-p1')), matching: find.text('₹66.00')),
      findsOneWidget,
      reason: 'review + audit',
    );
    expect(find.descendant(of: find.byKey(const Key('margin-p1')), matching: find.text('42.3%')), findsOneWidget);
    expect(find.byKey(const Key('funnel-applied')), findsOneWidget);
    expect(find.byKey(const Key('funnel-assessment')), findsNothing, reason: 'a stage the platform cannot count is not shown');
    expect(find.text('Asha Rao'), findsOneWidget);
    expect(find.textContaining('From the Q3 spreadsheet'), findsOneWidget);
    expect(find.byKey(const Key('rebuild-repair')), findsNothing, reason: 'only admin rebuilds');
    await expectAccessible(tester);
  });

  testWidgets('a tile opens the page that explains it', (tester) async {
    final backend = FakeBackend(routes());
    await open(tester, backend);
    await tester.tap(find.byKey(const Key('tile-idle_cost')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/ops/workers');
  });

  testWidgets('a screen reader can open a tile too', (tester) async {
    final backend = FakeBackend(routes());
    await open(tester, backend);
    final handle = tester.ensureSemantics();
    await tester.pump();
    final node = tester.getSemantics(find.bySemanticsLabel(RegExp(r'Opens Workers$')).first);
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    tester.semantics.tap(find.semantics.byLabel(RegExp(r'Opens Workers$')).first);
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/ops/workers');
    handle.dispose();
  });

  testWidgets('finance sees the numbers, cannot edit the baseline and gets no dead link to an ops page', (tester) async {
    final backend = FakeBackend(routes());
    await open(tester, backend, roles: ['finance']);
    expect(backend.sent('GET', '/v1/projects'), isEmpty, reason: 'project names are an ops read');
    expect(find.byKey(const Key('baseline-edit')), findsNothing);
    await tester.tap(find.byKey(const Key('tile-days_to_staff')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/ops/leadership', reason: 'Projects is not a finance page');
  });

  testWidgets('ops set the baseline: validated, PUT, reloaded', (tester) async {
    final backend = FakeBackend({
      ...routes(baseline: false),
      'PUT /v1/analytics/baselines': (r) =>
          json({...jsonDecode(r.body) as Map<String, Object?>, 'id': 'b2', 'set_by': 'ops-1', 'set_at': '2026-11-04T10:00:00Z'}),
    });
    await open(tester, backend);
    expect(find.textContaining('No baseline yet.'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('baseline-edit')));
    await tester.tap(find.byKey(const Key('baseline-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('baseline-fp')), '82');
    await tester.tap(find.byKey(const Key('baseline-save')));
    await tester.pumpAndSettle();
    expect(find.text('First-pass acceptance is a share between 0 and 1, like 0.82'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('baseline-fp')), 'x');
    await tester.tap(find.byKey(const Key('baseline-save')));
    await tester.pumpAndSettle();
    expect(find.text('Numbers only, like 4.5 or 0.82'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('baseline-fp')), '0.82');
    await tester.enterText(find.byKey(const Key('baseline-staffing')), '0');
    await tester.tap(find.byKey(const Key('baseline-save')));
    await tester.pumpAndSettle();
    expect(find.text('Workers to call a batch staffed is a whole number, 1 or more'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('baseline-staffing')), '4');
    await tester.enterText(find.byKey(const Key('baseline-days')), '5.5');
    await tester.enterText(find.byKey(const Key('baseline-note')), 'Measured in October');
    await tester.tap(find.byKey(const Key('baseline-save')));
    await tester.pumpAndSettle();
    final sent = jsonDecode(backend.sent('PUT', '/v1/analytics/baselines').single.body) as Map<String, Object?>;
    expect(sent['first_pass_acceptance'], '0.82');
    expect(sent['days_to_staff'], '5.5');
    expect(sent['staffing_workers'], 4);
    expect(sent['note'], 'Measured in October');
    expect(find.text('Baseline saved'), findsOneWidget);
    expect(backend.sent('GET', '/v1/analytics/leadership'), hasLength(2));
  });

  testWidgets('a failed save keeps the form open with the reason', (tester) async {
    final backend = FakeBackend({...routes(), 'PUT /v1/analytics/baselines': (_) => envelope(422, 'invalid', message: 'levy too high')});
    await open(tester, backend);
    await tester.ensureVisible(find.byKey(const Key('baseline-edit')));
    await tester.tap(find.byKey(const Key('baseline-edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('baseline-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Details: levy too high'), findsOneWidget);
  });

  testWidgets('admin asks for a repair or a purge after confirming; the window filter reloads', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'POST /v1/analytics/rebuild': (r) =>
          json({'generation': 3, 'status': 'requested', 'mode': r.url.queryParameters['mode']}, status: 202),
    });
    await open(tester, backend, roles: ['admin']);
    await tester.ensureVisible(find.byKey(const Key('rebuild-purge')));
    await tester.tap(find.byKey(const Key('rebuild-purge')));
    await tester.pumpAndSettle();
    expect(find.text('Purge and rebuild the warehouse?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/analytics/rebuild'), isEmpty);
    await tester.tap(find.byKey(const Key('rebuild-repair')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Repair'));
    await tester.pumpAndSettle();
    expect(backend.sent('POST', '/v1/analytics/rebuild').single.url.queryParameters['mode'], 'repair');
    expect(find.text('Rebuild requested'), findsOneWidget);
    await tester.drag(find.byType(Scrollable).last, const Offset(0, 3000));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-7-days')));
    await tester.pumpAndSettle();
    expect(backend.sent('GET', '/v1/analytics/leadership').last.url.queryParameters['days'], '7');
  });

  testWidgets('a failed rebuild request is a toast', (tester) async {
    final backend = FakeBackend({
      ...routes(),
      'POST /v1/analytics/rebuild': (_) => envelope(409, 'rebuild_running', message: 'already running'),
    });
    await open(tester, backend, roles: ['admin']);
    await tester.ensureVisible(find.byKey(const Key('rebuild-repair')));
    await tester.tap(find.byKey(const Key('rebuild-repair')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Repair'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Details: already running'), findsOneWidget);
  });

  testWidgets('side panels that fail hide; the numbers still show; a failed main load offers Retry', (tester) async {
    var fail = true;
    final backend = FakeBackend({
      'GET /v1/analytics/leadership': (_) => fail
          ? envelope(503, 'upstream_unavailable', headers: {'retry-after': '3'})
          : json({...leadership(), 'margin': <Object>[], 'numbers': <Object>[]}),
    });
    await open(tester, backend);
    expect(find.text('Service is away. Retry in 3s.'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('No numbers yet. They appear once work flows.'), findsOneWidget);
    expect(find.text('No accepted units in this window yet.'), findsOneWidget);
    expect(find.text('The hiring funnel could not be read.'), findsOneWidget);
    expect(find.text('The bench could not be read.'), findsOneWidget);
    expect(find.byKey(const Key('rebuild')), findsNothing);
  });

  testWidgets('renders at phone width and in dark mode without overflow', (tester) async {
    await open(tester, FakeBackend(routes()), size: const Size(390, 4000));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('tile-days_to_staff')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await open(tester, FakeBackend(routes()), dark: true);
    expect(tester.takeException(), isNull);
  });

  test('values read in their unit', () {
    expect(tileValue(null, 'money', 'INR'), '—');
    expect(tileValue('2.5', 'per_1000', null), '2.5 / 1,000');
    expect(tileValue('x', 'ratio', null), 'x');
    expect(tileValue('x', 'days', null), 'x');
    expect(tileValue('x', 'per_1000', null), 'x');
    expect(tileValue('7', 'count', null), '7');
    expect(
      basisLine({
        'batches': 3,
        'list': <int>[1],
      }),
      'batches 3',
    );
    expect(basisLine({'hourly_cost': '150.000000', 'pay': '102.50', 'code': 'v1.0x'}), 'hourly cost 150 · pay 102.5 · code v1.0x');
  });
}
