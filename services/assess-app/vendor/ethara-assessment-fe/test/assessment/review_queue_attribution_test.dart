// Every draft card names the SOP it came from.
//
// WHY THIS IS A TEST AND NOT JUST A LINE OF UI. The review queue's generator
// filter defaults to All, and both ordinary ways in - the sidebar entry and the
// bank's "Go to review queue" - arrive unfiltered. So the usual queue is mixed
// across generators, and a reviewer approves a question INTO THE BANK from
// these cards. Without the name on the card there is nothing saying which
// document justified the question being asked.
//
// It is pinned here because the obvious placement does not work and somebody
// will try it again. Putting the attribution in the Panel's `headActions` -
// beside the type, the difficulty, Preview, Open generator and three
// conditional recovery buttons - overflows that row by 109px, and capping the
// text to 26 characters produces the same 109px, because the row has no spare
// width at all. It lives in the card BODY, next to the position counter.
//
// `section_entry_test.dart` catches the overflow half (a RenderFlex overflow
// fails a widget test). This catches the other half: that the name is actually
// there. A silently missing label breaks nothing and shows up in no other test.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/assessment_section.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// The seed generator every seeded draft belongs to.
const String _seedGenerator = 'Warehouse annotation SOP';

Future<AppStore> _pumpQueue(WidgetTester tester) async {
  // The grids on this screen declare a minWidth well past the 800x600 default,
  // so a narrower surface would overflow and the failure would read as a
  // layout bug rather than a viewport that is simply smaller than the app
  // targets.
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final AppStore store = AppStore();
  addTearDown(store.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AssessmentSection(
          store: store,
          entry: AssessmentEntry.reviewQueue,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

void main() {
  group('A draft card says which SOP it came from', () {
    testWidgets('the generator is named on the card', (WidgetTester t) async {
      final AppStore store = await _pumpQueue(t);

      // The fixture has to actually exercise the thing, or this passes by
      // being empty.
      expect(
        store.pendingDrafts(),
        isNotEmpty,
        reason: 'the seed must carry drafts for the queue to render any card',
      );

      // `find.text` EXACTLY, not `textContaining`. The filter chip above the
      // list renders the same generator name with its pending count appended
      // ('Warehouse annotation SOP  4'), so a substring match would pass with
      // no attribution on the card at all - the test would be asserting the
      // filter row it was never about.
      expect(
        find.text(_seedGenerator),
        findsWidgets,
        reason:
            'the queue defaults to All, so a reviewer approving into the bank '
            'has to be able to see which document justified the question',
      );
    });

    testWidgets('every row of the scan list names its generator', (
      WidgetTester t,
    ) async {
      await _pumpQueue(t);

      // THE LIST, not just the focused card. The right-hand queue is what an
      // operator scans across on All, where drafts from several generators sit
      // together - naming it only on the open card leaves every other row
      // unplaceable without clicking it.
      //
      // AT LEAST TWO, not one per draft. An exact count would be wrong twice
      // over: `ListView.builder` only builds the rows currently visible in a
      // 620px-capped panel, and the seeded drafts do not all belong to the
      // same generator. Two is the assertion that actually means something -
      // one is the open card, so a second can only have come from a row.
      //
      // The filter chip cannot inflate this: it renders the name with its
      // pending count appended, so it is not an exact-text match.
      expect(
        find.text(_seedGenerator),
        findsAtLeastNWidgets(2),
        reason:
            'the open card names it once; a second match means the scan list '
            'names it too, which is the half this test exists for',
      );
    });

    testWidgets('the queue opens unfiltered, which is why it matters', (
      WidgetTester t,
    ) async {
      final AppStore store = await _pumpQueue(t);

      // Entering from the sidebar carries no generator filter, so the list is
      // `pendingDrafts()` across every generator. If this ever starts arriving
      // pre-filtered the attribution becomes redundant rather than load-
      // bearing, and the reasoning above should be revisited.
      expect(store.pendingDrafts().length, greaterThan(0));
      expect(
        find.text('All  ${store.pendingDrafts().length}'),
        findsOneWidget,
        reason: 'the All chip is pressed by default, so the queue is mixed',
      );
    });
  });

  group('Attribution survives what a generator does not', () {
    test('a draft carries the name the API sent, not just an id', () {
      // `genName` is read off the row itself, so it is right before the
      // generators load and stays right once the generator is deleted -
      // `generator_id` is ondelete="set null" on the server.
      final Question q = Question.fromJson(<String, dynamic>{
        'id': 12,
        'name': 'Battery charging',
        'question_type': 'mcq',
        'generator': <String, dynamic>{'id': 3, 'name': 'Forklift SOP'},
        'source_ref': 'gen:Forklift SOP',
      });

      expect(q.genId, '3');
      expect(q.genName, 'Forklift SOP');
      expect(q.sourceRef, 'gen:Forklift SOP');
    });

    test('source_ref outlives the generator', () {
      // What the server sends once the generator has been deleted: no nested
      // `generator` object at all, but the stamp taken at approval time.
      final Question q = Question.fromJson(<String, dynamic>{
        'id': 12,
        'name': 'Battery charging',
        'question_type': 'mcq',
        'source_ref': 'gen:Forklift SOP',
      });

      expect(q.genId, isEmpty);
      expect(q.genName, isEmpty);
      expect(
        q.sourceRef,
        'gen:Forklift SOP',
        reason:
            'the last attribution an orphaned question has - the card falls '
            'back to this rather than printing a raw id',
      );
    });
  });
}
