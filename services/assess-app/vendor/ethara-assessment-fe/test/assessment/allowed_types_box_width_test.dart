/// The "Allowed question types" frame fills once its content wraps.
///
/// WHAT WAS ACTUALLY BROKEN, measured rather than assumed: only the wrapped
/// case. A `Wrap` sizes to its widest ROW, so with enough chips to need a
/// second line the frame stopped at ~1388 of a ~1433 card while standing two
/// rows tall - a field cut off mid-row with the "Add a type" dropdown dangling
/// beneath it. Hugging at 0, 1 and 2 chips was already correct; the frame
/// measures identically with and without the fix at those counts.
///
/// SO WHAT ARE THE HUG TESTS FOR. They are regression guards against the wrong
/// fix, not proof of the right one - and the wrong fix shipped once and was
/// rejected on sight. Forcing `width: double.infinity` makes the wrapped case
/// correct by drawing a full-width frame around a single 250px dropdown, which
/// reads as an empty box. They are labelled as guards below so nobody mistakes
/// them for coverage of the change.
///
/// MEASURED, AND STATED AS RELATIONSHIPS rather than pixel counts, so a theme
/// or font change cannot invalidate them.
library;

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/generator_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const String kHelp =
    'Pick the shapes this generator may author. At least one is required; '
    'tick several and the generator chooses per item.';

/// Opens the Generation tab with exactly [types] ticked and [templates] in the
/// store.
///
/// TEMPLATES WERE THE HOLE IN THIS FILE. Every measurement here used to run
/// against an empty `store.taskTemplates`, which is the one condition that
/// hides a dropdown sized by a name nobody can see - so the suite measured a
/// menu production does not have.
Future<AppStore> openWith(
  WidgetTester tester,
  List<QType> types, {
  List<TaskTemplate> templates = const <TaskTemplate>[],
}) async {
  tester.view.physicalSize = const Size(1500, 4200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final AppStore s = AppStore();
  final Generator g = s.generators.first;
  s.source = DataSource.live;
  s.updateGenerator(g.copyWith(
    allowedTypes: types,
    shapeQuotas: const <String, int>{},
  ));
  s.taskTemplates = templates;

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: GeneratorDetailScreen(store: s, genId: g.id, tab: 'generation'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return s;
}

Future<void> close(WidgetTester tester, AppStore s) async {
  await tester.pump(const Duration(seconds: 4));
  s.dispose();
}

/// The width of the card, taken from the help line under the picker.
double cardWidth(WidgetTester tester) => tester.getSize(find.text(kHelp)).width;

/// The painted frame around the picker.
///
/// FIRST, not last: `find.ancestor` walks outwards, so `.last` is the page card
/// and measuring it reports the viewport width whatever the picker does.
double frameWidth(WidgetTester tester) {
  // Anchored on the picker's dropdown, which exists nowhere else on this tab.
  // Anchoring on `Wrap` matched a different one and measured the page card.
  final Finder frame = find.ancestor(
    of: find.byType(DropdownButtonHideUnderline),
    matching: find.byType(Container),
  );
  expect(frame, findsWidgets, reason: 'the picker frame must exist');
  return tester.getSize(frame.first).width;
}

/// Frame width for a given set of ticked types, on a fresh tree each time.
Future<double> widthFor(WidgetTester tester, List<QType> types) async {
  final AppStore s = await openWith(tester, types);
  final double w = frameWidth(tester);
  await close(tester, s);
  return w;
}

/// How many rows the picker's content occupies.
///
/// THE ASSERTION THAT WAS MISSING, and the reason a "fix" that looked right by
/// width alone shipped broken twice: the frame can be the correct width while
/// the dropdown has been shoved onto a row of its own beside acres of space.
int rowCount(WidgetTester tester) {
  // The Wrap's OWN children, not every Padding beneath it - the chips contain
  // Paddings of their own and counting those reported seven rows for one.
  final Finder picker = find.ancestor(
    of: find.byType(DropdownButtonHideUnderline),
    matching: find.byType(Wrap),
  );
  final RenderWrap wrap = tester.renderObject<RenderWrap>(picker.first);
  final Set<double> tops = <double>{
    for (final RenderBox child in wrap.getChildrenAsList())
      ((child.parentData! as WrapParentData).offset.dy),
  };
  return tops.length;
}

void main() {
  group('The content breaks only when it must', () {
    testWidgets('one chip and the dropdown share a row', (
      WidgetTester tester,
    ) async {
      // `IntrinsicWidth` over a `Wrap` with `spacing` set asks for a width one
      // gap per item too small, so the last item never fits. One chip beside a
      // half-empty row is the most visible version of that.
      final AppStore s = await openWith(tester, const <QType>[QType.mcq]);
      expect(rowCount(tester), 1, reason: 'the dropdown must not drop below');
      await close(tester, s);
    });

    testWidgets('two chips and the dropdown still share a row', (
      WidgetTester tester,
    ) async {
      final AppStore s =
          await openWith(tester, const <QType>[QType.mcq, QType.msq]);
      expect(rowCount(tester), 1);
      await close(tester, s);
    });
  });

  // REGRESSION GUARDS against the 'always fill' fix, which was shipped and
  // rejected. These pass against the pre-fix widget too - they pin behaviour
  // that was already right, which is worth keeping and is not coverage of the
  // change itself. The group below is the one that tests the fix.
  group('The frame still hugs when there is room (guard)', () {
    testWidgets('an empty picker is the width of its dropdown, not the card', (
      WidgetTester tester,
    ) async {
      final AppStore s = await openWith(tester, const <QType>[]);
      final double card = cardWidth(tester);
      final double frame = frameWidth(tester);

      expect(
        frame,
        lessThan(card * 0.6),
        reason: 'a full-width frame around one dropdown reads as an empty box '
            '(frame $frame, card $card)',
      );
      await close(tester, s);
    });

    testWidgets('it grows with each type added, rather than jumping to full', (
      WidgetTester tester,
    ) async {
      // THE CASE THAT WAS WRONG. One chip and two chips both drew a full-width
      // frame, because the fix was "fill as soon as there is any chip".
      final double none = await widthFor(tester, const <QType>[]);
      final double one = await widthFor(tester, const <QType>[QType.mcq]);
      final double two =
          await widthFor(tester, const <QType>[QType.mcq, QType.msq]);

      expect(one, greaterThan(none), reason: 'one chip is wider than none');
      expect(two, greaterThan(one), reason: 'two chips are wider than one');
    });

    testWidgets('a couple of chips still leave room on the row', (
      WidgetTester tester,
    ) async {
      final AppStore s = await openWith(
        tester,
        const <QType>[QType.mcq, QType.msq],
      );
      final double card = cardWidth(tester);
      final double frame = frameWidth(tester);

      expect(
        frame,
        lessThan(card),
        reason: 'two chips and a dropdown do not fill the card, so the frame '
            'must not pretend they do (frame $frame, card $card)',
      );
      await close(tester, s);
    });
  });

  // THE FIX ITSELF. This is the only group that fails against the pre-fix
  // widget.
  group('The frame fills once the content wraps', () {
    testWidgets('enough types to wrap makes the frame span the card', (
      WidgetTester tester,
    ) async {
      // All but one, so the "Add a type" dropdown still exists to anchor the
      // finder on - with every type ticked there is nothing left to add and the
      // control is gone.
      final AppStore s = await openWith(
        tester,
        QType.generatable.take(QType.generatable.length - 1).toList(),
      );
      final double card = cardWidth(tester);
      final double frame = frameWidth(tester);

      // With everything ticked the chips wrap to a second row. A frame that
      // stopped at the widest row would stand two rows tall while ending
      // mid-card, which is the original report.
      expect(
        frame,
        greaterThanOrEqualTo(card),
        reason: 'wrapped content must fill the card, not stop at its widest '
            'row (frame $frame, card $card)',
      );
      await close(tester, s);
    });
  });

  // THE SECOND FIX, and the defect it came from.
  //
  // Found by comparing production against a local checkout: the same build drew
  // a ~600pt frame on one and ~290pt on the other, with nothing ticked on
  // either. The difference was not the code. `DropdownButton` measures every
  // MENU item to size the CLOSED control, the menu lists task templates, and
  // `etp_local` had none - so local hugged and production, which holds a
  // template called "Task: Describe UI Elements - Spotify Web Player (Full
  // Coverage)", drew a half-empty field around the words "Any type".
  //
  // Measured before the fix, same tree, nothing ticked: 480.6 with no
  // templates, 480.6 with one called "Short", 933.5 with the long one.
  group('A name in a closed menu cannot set the width of the box', () {
    TaskTemplate named(String name) => TaskTemplate(id: name.length, name: name);

    testWidgets('a long template name does not widen the empty picker', (
      WidgetTester tester,
    ) async {
      final double none = await widthFor(tester, const <QType>[]);
      final AppStore s = await openWith(
        tester,
        const <QType>[],
        templates: <TaskTemplate>[
          named('Task: Describe UI Elements - Spotify Web Player '
              '(Full Coverage) - second pass, high resolution'),
        ],
      );
      final double withLong = frameWidth(tester);
      await close(tester, s);

      expect(
        withLong,
        none,
        reason: 'the frame grew from a string the operator cannot see - it is '
            'in a menu that is shut (empty $none, with a long template name '
            '$withLong)',
      );
    });

    testWidgets('and neither does a whole library of them', (
      WidgetTester tester,
    ) async {
      // The real shape of the data: several templates, one of them very long.
      final double none = await widthFor(tester, const <QType>[]);
      final AppStore s = await openWith(
        tester,
        const <QType>[],
        templates: <TaskTemplate>[
          named('Short'),
          named('Describe UI Elements - GitHub Homepage (Missing Coverage)'),
          named('Task: Describe UI Elements - Spotify Web Player '
              '(Full Coverage) - second pass, high resolution, dense'),
        ],
      );
      final double withMany = frameWidth(tester);
      await close(tester, s);

      expect(withMany, none);
    });

    testWidgets('a long-named template is still listed, and still pickable', (
      WidgetTester tester,
    ) async {
      // THE OTHER HALF OF THE FIX. Capping the control would be a bad trade if
      // it made the thing being capped unreachable: the names now ellipsise, so
      // this opens the menu and picks the row to prove the item is still there
      // and still wired to `_setTemplate`.
      const String long = 'Task: Describe UI Elements - Spotify Web Player '
          '(Full Coverage) - second pass, high resolution';
      final AppStore s = await openWith(
        tester,
        const <QType>[],
        templates: <TaskTemplate>[const TaskTemplate(id: 77, name: long)],
      );

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      expect(find.text(long), findsWidgets, reason: 'the row must still exist');

      await tester.tap(find.text(long).last);
      await tester.pumpAndSettle();

      expect(
        s.genById(s.generators.first.id)?.shapeQuotas['template:77'],
        1,
        reason: 'picking the row must still set the quota',
      );
      await close(tester, s);
    });

    testWidgets('a template the examiner PICKED still widens it', (
      WidgetTester tester,
    ) async {
      // The distinction that matters. Sizing to what was chosen is the
      // behaviour worth keeping; sizing to what is merely on offer is the bug.
      // A chip carries the template's name, so the frame grows with it.
      tester.view.physicalSize = const Size(1500, 4200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final double none = await widthFor(tester, const <QType>[]);

      final AppStore s = AppStore();
      final Generator g = s.generators.first;
      s.source = DataSource.live;
      final TaskTemplate tpl = named('Describe UI Elements - GitHub Homepage');
      s.taskTemplates = <TaskTemplate>[tpl];
      s.updateGenerator(g.copyWith(
        allowedTypes: const <QType>[],
        shapeQuotas: <String, int>{tpl.shapeKey: 1},
      ));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: AssessmentNavScope(
              nav: AssessmentNav(),
              child:
                  GeneratorDetailScreen(store: s, genId: g.id, tab: 'generation'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final double picked = frameWidth(tester);
      await close(tester, s);

      expect(
        picked,
        greaterThan(none),
        reason: 'a chosen template is visible content and must size the frame',
      );
    });
  });
}
