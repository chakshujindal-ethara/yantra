// A filter that lists DATA has to show enough of it, and say the rest.
//
// The assessment scope filter on the dashboard lists names an operator typed.
// At `SelectField`'s stock 200px cap a real title - "Q7r + Grade & Fix -
// Quality Assessment (Sprint 2) (copy)" - ellipsised before it said anything
// that distinguished it from its neighbour, and there was no tooltip to
// recover it from.
//
// Two rules, and the second is the one that is easy to get wrong: the tooltip
// exists ONLY when the text is actually cut. An always-on tooltip on a label
// that already fits trains the reader to ignore tooltips.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/dashboard_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/controls.dart';

const String kLong =
    'Q7r + Grade & Fix - Quality Assessment (Sprint 2) (copy) - second pass';

/// Short enough to fit a filter at some widths and not at others, which is what
/// the sweeps below need: a name that is always cut proves nothing about the
/// rule, only about the name.
const String kBorderline = 'Safety Check';

Widget host(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: Align(alignment: Alignment.topLeft, child: child)),
);

Future<void> pumpSelect(
  WidgetTester t,
  String label, {
  double? maxWidth,
  double? box,
  double scale = 1.0,
}) async {
  final Widget field = SelectField<String>(
    value: 'x',
    maxWidth: maxWidth ?? kSelectFieldWidth,
    options: <(String, String)>[('x', label)],
    onChanged: (String _) {},
  );
  await t.pumpWidget(
    host(
      Builder(
        builder: (BuildContext c) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          // BOX, NOT CAP. `maxWidth` is only a ceiling; a toolbar hands the
          // control whatever share it has, and that is the width the label is
          // really painted into.
          child: box == null ? field : SizedBox(width: box, child: field),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

/// The tooltip wrapping the closed control's label, if there is one.
Finder labelTooltip() => find.byType(Tooltip);

/// Did this label's own paragraph really get ellipsised?
///
/// THE ONLY HONEST ORACLE. Every rule below is "a tooltip iff the text is
/// actually cut", and the only thing that knows whether it was cut is the
/// paragraph that painted it - not a width constant, and not a font metric a
/// test can restate.
bool wasCut(WidgetTester t, Finder text) =>
    t.renderObject<RenderParagraph>(text).didExceedMaxLines;

void main() {
  group('The closed filter explains itself only when it has to', () {
    testWidgets('a label that fits carries no tooltip', (
      WidgetTester t,
    ) async {
      await pumpSelect(t, 'Any date');
      expect(
        labelTooltip(),
        findsNothing,
        reason: 'a tooltip on a label that is fully visible is noise, and '
            'noise is how a reader learns to ignore the ones that matter',
      );
    });

    testWidgets('a label that is cut carries one', (WidgetTester t) async {
      await pumpSelect(t, kLong);
      expect(labelTooltip(), findsOneWidget);
      expect(t.widget<Tooltip>(labelTooltip()).message, kLong,
          reason: 'the tooltip must carry the WHOLE name, which is the only '
              'reason it exists');
    });

    testWidgets('widening never adds a tooltip, and can remove one', (
      WidgetTester t,
    ) async {
      // A RELATIONSHIP, NOT A PIXEL CLAIM. `ThemeData.dark()` renders this text
      // about twice the size the app's own type scale does, so "does a
      // realistic assessment name fit at 320" is not a question a widget test
      // can answer honestly - it is answered in a browser against the real
      // theme. What IS invariant across any metrics is the direction: more
      // room can only ever remove the need for a tooltip.
      const String medium = 'Warehouse Safety - Induction';

      await pumpSelect(t, medium, maxWidth: kSelectFieldWidth);
      final bool cutAtStock = labelTooltip().evaluate().isNotEmpty;

      await pumpSelect(t, medium, maxWidth: kSelectFieldWideWidth);
      final bool cutAtWide = labelTooltip().evaluate().isNotEmpty;

      expect(
        cutAtWide && !cutAtStock,
        isFalse,
        reason: 'widening the control made a label that already fitted start '
            'claiming it does not',
      );
    });

    testWidgets('a name long enough to be cut at any width keeps its tooltip', (
      WidgetTester t,
    ) async {
      await pumpSelect(t, kLong, maxWidth: kSelectFieldWideWidth);
      expect(labelTooltip(), findsOneWidget,
          reason: 'widening is not a substitute for the tooltip - it only '
              'reduces how often it is needed');
    });

    testWidgets('the wide setting really is wider', (WidgetTester t) async {
      await pumpSelect(t, 'Any date');
      final double stock = t.getSize(find.byType(SelectField<String>)).width;
      await pumpSelect(t, 'Any date', maxWidth: kSelectFieldWideWidth);
      final double wide = t.getSize(find.byType(SelectField<String>)).width;
      expect(wide, greaterThan(stock));
      expect(wide, kSelectFieldWideWidth);
    });
  });

  // THE MENU IS WHERE THE READER ACTUALLY COMPARES NAMES, and it truncates for
  // the same reason the closed control does: a `DropdownButton`'s menu takes
  // the button's width. A picker whose rows all read "SCORING REVIEW
  // 2026-08-25 - ..." is a picker you cannot choose from.
  group('The open menu explains itself on the same terms', () {
    /// Every tooltip message currently mounted.
    List<String?> messages(WidgetTester t) => t
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((Tooltip w) => w.message)
        .toList();

    testWidgets('a cut row carries the whole name', (WidgetTester t) async {
      await pumpSelect(t, kLong);
      await t.tap(find.byType(DropdownButton<String>));
      await t.pumpAndSettle();

      expect(
        messages(t),
        contains(kLong),
        reason: 'the row the reader is choosing from is the one that has to '
            'be readable',
      );
    });

    testWidgets('a row that fits carries nothing', (WidgetTester t) async {
      await pumpSelect(t, 'Any date');
      await t.tap(find.byType(DropdownButton<String>));
      await t.pumpAndSettle();

      expect(find.byType(Tooltip), findsNothing);
    });
  });

  // THE RULE IS "IFF", AND IT WAS BEING CHECKED AGAINST THE WRONG NUMBER.
  //
  // The measurement used to be `maxWidth - <a constant>`. Both halves of that
  // are wrong. `maxWidth` is a CAP, so a squeezed toolbar paints the label into
  // far less and the control was told it fitted; and the constant for the open
  // menu was derived from the button, which is 40px narrower than the popup
  // Flutter actually builds. Each sweep below asserts the rule directly against
  // the paragraph that did the painting, so nothing here restates a metric.
  group('The tooltip follows the text, not a constant', () {
    testWidgets('a filter squeezed below its cap still explains itself', (
      WidgetTester t,
    ) async {
      int cut = 0;
      int whole = 0;
      for (double box = 140; box <= 340; box += 10) {
        await pumpSelect(
          t,
          kBorderline,
          maxWidth: kSelectFieldWideWidth,
          box: box,
        );
        final bool isCut = wasCut(t, find.text(kBorderline));
        isCut ? cut++ : whole++;
        expect(
          labelTooltip().evaluate().isNotEmpty,
          isCut,
          reason: 'in a ${box}px box the label was '
              '${isCut ? 'cut and had no tooltip' : 'whole and had one'}',
        );
      }
      expect(<int>[cut, whole], everyElement(greaterThan(0)),
          reason: 'the sweep never saw the label both cut and whole, so it '
              'proves nothing about the boundary between them');
    });

    testWidgets('the open menu is measured on the menu\'s own width', (
      WidgetTester t,
    ) async {
      int cut = 0;
      int whole = 0;
      for (double cap = 180; cap <= 320; cap += 4) {
        // A fresh tree each time. The open menu is a route, and pumping the
        // same widget again leaves it mounted - so the next tap would CLOSE it
        // and the sweep would measure nothing.
        await t.pumpWidget(const SizedBox.shrink());
        await t.pumpAndSettle();
        await pumpSelect(t, kBorderline, maxWidth: cap);
        await t.tap(find.byType(DropdownButton<String>));
        await t.pumpAndSettle();

        final Finder row = find.descendant(
          of: find.byType(ListView),
          matching: find.text(kBorderline),
        );
        final bool isCut = wasCut(t, row);
        isCut ? cut++ : whole++;
        expect(
          find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Tooltip),
              )
              .evaluate()
              .isNotEmpty,
          isCut,
          reason: 'at a ${cap}px cap the menu row was '
              '${isCut ? 'cut and had no tooltip' : 'whole and had one'}',
        );
      }
      expect(<int>[cut, whole], everyElement(greaterThan(0)),
          reason: 'the sweep never saw the menu row both cut and whole');
    });

    testWidgets('the measurement follows the viewer\'s own text size', (
      WidgetTester t,
    ) async {
      // A `Text` grows with `MediaQuery.textScalerOf`; a `TextPainter` does not
      // unless it is told. So at the browser's "Large" setting every name
      // ellipsised earlier and none of them carried a tooltip - the
      // accessibility setting removed the only way to read the whole name.
      int cut = 0;
      int whole = 0;
      for (final double scale in <double>[1.0, 1.25, 1.5, 1.75, 2.0]) {
        await pumpSelect(
          t,
          kBorderline,
          maxWidth: kSelectFieldWideWidth,
          scale: scale,
        );
        final bool isCut = wasCut(t, find.text(kBorderline));
        isCut ? cut++ : whole++;
        expect(
          labelTooltip().evaluate().isNotEmpty,
          isCut,
          reason: 'at text scale $scale the label was '
              '${isCut ? 'cut and had no tooltip' : 'whole and had one'}',
        );
      }
      expect(<int>[cut, whole], everyElement(greaterThan(0)),
          reason: 'the sweep never crossed the scale at which the label stops '
              'fitting');
    });
  });

  // THE DASHBOARD'S OWN TOOLBAR, MEASURED.
  //
  // `kSelectFieldWideWidth` is a cap, and a cap only means something if the
  // layout lets it bind. It did not: both filters were nested inside ONE of
  // `Toolbar`'s equal `Flexible` shares, so the moment "Clear Filters" appeared
  // - which is exactly when a long assessment name is on screen - the wide
  // filter was down to a quarter of the left group and rendered NARROWER than
  // the 200px it had been widened from.
  group('The assessment filter keeps the width it was widened to', () {
    testWidgets('a filtered dashboard still renders it at the wide cap', (
      WidgetTester t,
    ) async {
      t.view.physicalSize = const Size(1900, 3000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: AssessmentNavScope(
              nav: AssessmentNav(),
              child: DashboardScreen(store: AppStore()),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      // Narrowing the date window is what puts "Clear Filters" in the toolbar,
      // and that button is a toolbar child in its own right - it takes an equal
      // flex share whether or not it can use one.
      await t.tap(find.byType(SelectField<DateWindow>));
      await t.pumpAndSettle();
      await t.tap(find.text('Last 7 days').last);
      await t.pumpAndSettle();
      expect(find.text('Clear Filters'), findsOneWidget);

      final double wide = t.getSize(find.byType(SelectField<String>)).width;
      expect(
        wide,
        kSelectFieldWideWidth,
        reason: 'with room to spare the wide filter has to reach its cap; it '
            'rendered ${wide}px',
      );
      expect(
        wide,
        greaterThanOrEqualTo(kSelectFieldWidth),
        reason: 'a filter widened to show more of a name must never end up '
            'narrower than the stock width it replaced',
      );
    });
  });
}
