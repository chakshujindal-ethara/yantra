// The Generators tile counts LIVE generators only. The store fetches with
// include_archived so the archive toggle has rows to reveal, which puts the
// archived ones in `generators` - and the tile read that list raw, so an
// archived SOP still counted as one you could generate from.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/generator_list_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';

void main() {
  testWidgets('an archived generator is not counted on the tile', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1600, 1400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final AppStore s = AppStore()
      ..generators = <Generator>[
        Generator.fromJson(<String, dynamic>{'id': 1, 'name': 'Forklift SOP'}),
        Generator.fromJson(<String, dynamic>{'id': 2, 'name': 'Dock SOP'}),
        Generator.fromJson(<String, dynamic>{
          'id': 3,
          'name': 'Retired SOP',
          'active': false,
        }),
      ];

    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: AssessmentNavScope(
            nav: AssessmentNav(),
            child: GeneratorListScreen(store: s),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    final Kpi tile = t.widget<Kpi>(
      find.byWidgetPredicate((Widget w) => w is Kpi && w.label == 'Generators'),
    );
    expect(tile.value, '2');
  });
}
