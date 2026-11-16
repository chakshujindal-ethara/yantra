// Settings shows what scoring REALLY runs with, not only what is stored.
//
// Two gaps, one screen. `Parallel calls` showed the stored value while the
// module lowers it at runtime to fit the DB pool - 6 stored could be 4 in
// force - and the only model shown under Models was the scoring OVERRIDE,
// usually blank, never the model every fallback resolves to. An operator
// swapping the scoring model had no way to see that the catalog could not
// price it or knew nothing of its limits.
//
// `/api/v1/settings` now reports both (`scoring.parallel_calls_effective`,
// `scoring.resolved_model`). The box still shows the STORED value: it is
// posted back on every Save, and the lowered one would overwrite the setting.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/screens/admin/settings_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';

/// `scoring` as the route answers it, with [extra] merged in.
Map<String, dynamic> _settings(Map<String, dynamic> extra) => <String, dynamic>{
  'models': <String, dynamic>{'scoring': ''},
  'scoring': <String, dynamic>{
    'shards': 4,
    'tick_limit': 20,
    'batch_size': 8,
    'llm_max_attempts': 3,
    'parallel_calls': 6,
    ...extra,
  },
};

/// `model_catalog.describe(...)`.
Map<String, dynamic> _model(
  String name, {
  bool price = true,
  bool caps = true,
}) => <String, dynamic>{
  'model': name,
  'price_known': price,
  'capabilities_known': caps,
  'max_output_tokens': caps ? 65536 : null,
  'cache_min_tokens': caps ? 4096 : null,
  'cache_storage_per_mtok_hour': caps ? 4.5 : null,
};

Future<void> _open(WidgetTester t, Map<String, dynamic> settings) async {
  t.view.physicalSize = const Size(1600, 4000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final AppStore s = AppStore()..settings = settings;
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: SettingsScreen(store: s)),
    ),
  );
  await t.pumpAndSettle();
}

String _box(WidgetTester t, String label) => t
    .widget<TextField>(
      find.descendant(
        of: find
            .ancestor(
              of: find.text(label.toUpperCase()),
              matching: find.byType(Field),
            )
            .first,
        matching: find.byType(TextField),
      ),
    )
    .controller!
    .text;

void main() {
  group('parallel calls per lane', () {
    testWidgets('a lowered value is shown beside the stored one', (
      WidgetTester t,
    ) async {
      await _open(
        t,
        _settings(<String, dynamic>{'parallel_calls_effective': 4}),
      );

      expect(find.textContaining('In use per lane: 4'), findsOneWidget);
      expect(
        _box(t, 'Parallel calls'),
        '6',
        reason:
            'the box is posted back on Save, so it must hold what is '
            'stored, not what the pool allows',
      );
    });

    testWidgets('nothing extra when what is stored is what runs', (
      WidgetTester t,
    ) async {
      await _open(
        t,
        _settings(<String, dynamic>{'parallel_calls_effective': 6}),
      );
      expect(find.textContaining('In use per lane'), findsNothing);
    });

    testWidgets('a server that does not report it claims nothing', (
      WidgetTester t,
    ) async {
      await _open(t, _settings(<String, dynamic>{}));
      expect(find.textContaining('In use per lane'), findsNothing);
      expect(_box(t, 'Parallel calls'), '6');
    });
  });

  group('the scoring model in use', () {
    testWidgets('is named, read-only, with no warning when the catalog knows '
        'it', (WidgetTester t) async {
      await _open(
        t,
        _settings(<String, dynamic>{
          'resolved_model': _model('gemini-2.5-flash'),
        }),
      );

      // Not a name any box on this screen uses as its hint, so the one match
      // is the read-only line.
      expect(find.text('SCORING MODEL IN USE'), findsOneWidget);
      expect(find.text('gemini-2.5-flash'), findsOneWidget);
      expect(find.textContaining('No price'), findsNothing);
      expect(find.textContaining('No capability'), findsNothing);
    });

    testWidgets('warns when the catalog has neither price nor limits', (
      WidgetTester t,
    ) async {
      await _open(
        t,
        _settings(<String, dynamic>{
          'resolved_model': _model('gemini-9-ultra', price: false, caps: false),
        }),
      );

      expect(find.text('gemini-9-ultra'), findsOneWidget);
      expect(
        find.textContaining('No price or capability data for gemini-9-ultra.'),
        findsOneWidget,
      );
      expect(find.textContaining('default rate'), findsOneWidget);
      expect(find.textContaining('output limit is unknown'), findsOneWidget);
    });

    testWidgets('names only what is missing', (WidgetTester t) async {
      await _open(
        t,
        _settings(<String, dynamic>{
          'resolved_model': _model('gemini-9-flash', price: false),
        }),
      );

      expect(
        find.textContaining('No price data for gemini-9-flash.'),
        findsOneWidget,
      );
      expect(find.textContaining('output limit is unknown'), findsNothing);
    });

    testWidgets('a server that does not report it claims nothing', (
      WidgetTester t,
    ) async {
      await _open(t, _settings(<String, dynamic>{}));
      expect(find.text('SCORING MODEL IN USE'), findsNothing);
    });
  });
}
