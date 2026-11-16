// Does a controlled SearchField follow its parent?
//
// THE BUG THIS EXISTS FOR: `SearchField` was stateless and used
// `initialValue`, which Flutter reads ONCE at construction. A parent that
// cleared its query - the new "Clear filters" button on an empty result, a
// reset after navigating - updated its own state while the box kept showing
// the old text. The list would repopulate under a search term still visible
// in the field, which reads as the filter being broken.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/widgets/controls.dart';

void main() {
  group('SearchField is controlled by its parent', () {
    testWidgets('clearing the parent value clears the box', (
      WidgetTester tester,
    ) async {
      String query = 'forklift';
      late StateSetter setOuter;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                setOuter = setState;
                return SearchField(
                  value: query,
                  onChanged: (String v) => setState(() => query = v),
                );
              },
            ),
          ),
        ),
      );

      expect(find.text('forklift'), findsOneWidget);

      // What "Clear filters" does.
      setOuter(() => query = '');
      await tester.pump();

      expect(
        find.text('forklift'),
        findsNothing,
        reason: 'the field kept text the parent had already cleared',
      );
    });

    testWidgets('typing still reaches the parent', (WidgetTester tester) async {
      String query = '';

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                return SearchField(
                  value: query,
                  onChanged: (String v) => setState(() => query = v),
                );
              },
            ),
          ),
        ),
      );

      await tester.enterText(find.byType(TextFormField), 'safety');
      await tester.pump();

      // The round trip matters: a naive fix that assigns the controller on
      // every rebuild would fight the keystroke and drop or reorder text.
      expect(query, 'safety');
      expect(find.text('safety'), findsOneWidget);
    });
  });
}
