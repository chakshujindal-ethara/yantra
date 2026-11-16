// An action button says what it does before it is pressed.
//
// WHY THIS IS A TEST AND NOT A CONVENTION. Most of this console's actions run
// against the server, several spend real money one LLM call at a time, and a
// few cannot be undone - releasing a result, erasing a candidate's answers.
// A verb on a button is not informed consent for any of those, and the person
// pressing it is usually not the person who wrote it.
//
// The mechanism is `Btn.tooltip`, on the button rather than a `Tooltip` at
// each call site, so the width and the delay are decided once: a paragraph in
// a default tooltip wraps into a column two words across.
//
// The coverage check below is the part that earns its keep. It walks the real
// admin screens for `Btn(` calls and fails on any consequential one carrying
// no tooltip, so a button added next month is caught here rather than shipping
// mute.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/widgets/buttons.dart';

Widget host(Widget child) =>
    MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

void main() {
  group('Btn carries its own explanation', () {
    testWidgets('a tooltip is attached when one is given', (
      WidgetTester t,
    ) async {
      await t.pumpWidget(
        host(Btn('Re-score all', tooltip: 'Costs one LLM call per answer.',
            onPressed: () {})),
      );

      final Tooltip tip = t.widget<Tooltip>(find.byType(Tooltip));
      expect(tip.message, 'Costs one LLM call per answer.');
      // Wide enough for prose, or the sentence becomes a vertical strip.
      expect(tip.constraints?.maxWidth, greaterThanOrEqualTo(300));
    });

    testWidgets('a button without one is not wrapped', (WidgetTester t) async {
      await t.pumpWidget(host(Btn('Cancel', onPressed: () {})));
      expect(find.byType(Tooltip), findsNothing);
    });

    testWidgets('a DISABLED button still explains itself', (
      WidgetTester t,
    ) async {
      // The moment the explanation is most wanted is "why can I not press
      // this" - so the tooltip sits outside the Opacity and the gesture
      // detector, not inside them.
      await t.pumpWidget(
        host(const Btn('Wait for scoring', tooltip: 'Every answer must be '
            'resolved first.')),
      );

      expect(find.byType(Tooltip), findsOneWidget);
      expect(t.widget<Btn>(find.byType(Btn)).enabled, isFalse);
    });
  });

  test('every consequential admin action carries a tooltip', () {
    // Navigation and dismissal are exempt: "Cancel" explains itself, and a
    // tooltip on it is noise that trains people to ignore the ones that
    // matter.
    // TITLE CASE, matching the labels themselves. This list is compared
    // against the SOURCE string, so it has to be re-cased whenever they are -
    // which is the one thing a Title Case pass over the console is guaranteed
    // to break, and the reason this comment says so.
    const Set<String> exempt = <String>{
      'Cancel', 'Close', 'Clear', 'Clear Filters', 'Clear Search', 'Save',
      'Undo', 'Skip', 'Open', 'Manual', 'Auto', '+', '-', 'Refresh', 'Done',
      'Leave It Open', 'See All Checks', 'Resend', 'Manage Vocabulary',
      'Ledger', 'LLM Budget', 'New Assessment', 'New Generator',
      'Go to Stages', 'Go to Assessments', 'Open Assessments', 'Compare',
      'Go to Dashboard', 'Go to Generators', 'Go to Resources', 'Capture',
      'Go to Review Queue', 'Open Review Queue', 'Open Generator',
      'Open Attempt', 'Open the Full Attempt', 'Choose a CSV File',
      // Form Studio: navigation, dismissal, and add-the-thing-named buttons.
      'Back', 'Back to Form Studio', 'Fill in Again', 'Add File',
      'Add Section', 'Add Question', 'Add Option', 'New Form',
    };

    // The review queue's generator chips are a FILTER, and their label is the
    // generator's own name and count. A tooltip on each would repeat the row
    // it sits on.
    final RegExp filterChip = RegExp(r'^(All  \$total|\$\{g\.name\})');

    final RegExp call = RegExp(
      r"\bBtn(?:\.(?:primary|danger))?\(\s*\n?\s*'([^']*)',",
    );
    final List<String> mute = <String>[];

    for (final FileSystemEntity f
        in Directory('lib/assessment/screens/admin').listSync()) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final String src = f.readAsStringSync();
      for (final RegExpMatch m in call.allMatches(src)) {
        final String label = m.group(1)!;
        if (exempt.contains(label)) continue;
        if (filterChip.hasMatch(label)) continue;
        // The rest of this call, up to the line that closes it.
        final int end = m.end;
        final String tail = src.substring(
          end,
          (end + 1200).clamp(0, src.length),
        );
        final String body = tail.split('\n),').first;
        if (!body.contains('tooltip:')) {
          mute.add('${f.uri.pathSegments.last}: $label');
        }
      }
    }

    expect(
      mute,
      isEmpty,
      reason:
          'these admin actions do not say what they do. Add `tooltip:` to '
          'the Btn, or add the label to `exempt` above if it really is '
          'self-explanatory:\n  ${mute.join('\n  ')}',
    );
  });
}
