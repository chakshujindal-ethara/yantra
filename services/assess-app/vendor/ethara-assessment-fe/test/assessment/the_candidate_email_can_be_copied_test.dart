// The candidate's address can be TAKEN off the screen, not retyped.
//
// THE BUG: attempt detail printed "<assessment>  ·  <email>" under the
// candidate's name as a bare `Text` - `PageHead.sub` had no widget slot - so
// there was nowhere for a control to sit beside it. Chasing 24 no-shows after
// a 753-candidate run meant copying every address by eye, one character at a
// time, into a mail client.
//
// What this pins is the whole path, because each half of it has already failed
// once in this console: that the button is THERE, that the exact address
// reaches the clipboard (the "Copy Candidate Link" button once reported
// success without touching it), that one tap is one copy and one toast, that
// an attempt with no address offers no control to press, and that a screen
// reader is told what the glyph is and gets a target big enough to hit.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/attempt_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart' show Toaster;

Widget mount(Widget child, AssessmentNav nav) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(
    body: AssessmentNavScope(nav: nav, child: child),
  ),
);

AppStore seeded({
  String email = 'anita@example.com',
  String name = 'Grade & Fix Quality Sprint #3',
}) {
  final AppStore s = AppStore();
  s.people = <Person>[Person(id: 'p1', name: 'Anita Rao', email: email)];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 'a1',
      'name': name,
      'state': 'done',
      'questions': <dynamic>[
        <String, dynamic>{'id': 'q1', 'name': 'Question 1'},
      ],
    }),
  ];
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': '80',
      'assessment_id': 'a1',
      'candidate': <String, dynamic>{'id': 'p1', 'name': 'Anita Rao'},
      'state': 'submitted',
      'invite_state': 'sent',
      'answered_count': 1,
      'total_questions': 1,
      'access_token': '6df2026a-4d70-42fd-b8c3-144b01ce97da',
    }),
  ];
  return s;
}

/// The clipboard is a platform channel, so in a test it has to be intercepted
/// rather than read back: `Clipboard.getData` answers nothing without a real
/// engine. Returns a one-element list the caller reads the copied text out of.
List<String?> interceptClipboard(WidgetTester t) {
  final List<String?> copied = <String?>[];
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (MethodCall c) async {
      if (c.method == 'Clipboard.setData') {
        copied.add((c.arguments as Map<Object?, Object?>)['text'] as String?);
      }
      return null;
    },
  );
  addTearDown(
    () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}

Future<AppStore> open(
  WidgetTester t,
  Size size, {
  String email = 'anita@example.com',
  String name = 'Grade & Fix Quality Sprint #3',
}) async {
  final AppStore store = seeded(email: email, name: name);
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    mount(
      AttemptDetailScreen(
        store: store,
        portal: Portal.admin,
        attemptId: '80',
      ),
      AssessmentNav(),
    ),
  );
  await t.pumpAndSettle();
  return store;
}

/// A toast lives 3200ms on a real `Timer`, and an unexpired timer fails the
/// test after the tree is torn down. Spend it deliberately once the assertions
/// on it are done.
Future<void> letTheToastExpire(WidgetTester t) async =>
    t.pump(const Duration(milliseconds: 3300));

void main() {
  testWidgets('the address on attempt detail can be copied', (
    WidgetTester t,
  ) async {
    final List<String?> copied = interceptClipboard(t);
    final AppStore store = await open(t, const Size(1800, 3000));

    expect(
      find.byType(CopyBtn),
      findsOneWidget,
      reason: 'the email line carries no way to take the address',
    );

    await t.tap(find.byType(CopyBtn));
    await t.pumpAndSettle();

    // The EXACT address, not a trimmed or re-cased one: it is pasted into a
    // mail client and has to be the string the invitation went to.
    expect(copied, <String>['anita@example.com']);

    // One tap, one copy, one confirmation. The 44x44 target nests a gesture
    // inside `IconBtn`'s own, so a second toast here would mean both fired.
    expect(store.toaster.items.single.message, 'Email copied');

    await letTheToastExpire(t);
  });

  testWidgets('a screen reader is told what it is, and can hit it', (
    WidgetTester t,
  ) async {
    // Disposed inline, not in a tearDown: the harness checks for a live
    // handle BEFORE tearDowns run and fails the test on one it is holding.
    final SemanticsHandle handle = t.ensureSemantics();
    await open(t, const Size(1800, 3000));

    // The glyph alone says nothing, and the tooltip is prose for the pointer.
    // `isButton` because a bare `GestureDetector` announces no role at all -
    // which is still true of every other icon control in this console.
    expect(
      t.getSemantics(find.byType(CopyBtn)),
      isSemantics(
        label: 'Copy email address',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );

    // WCAG 2.5.5. The chip is 27px; the TARGET has to be a real box, because
    // a hit outside a RenderBox's own size never reaches its children.
    final Size box = t.getSize(find.byType(CopyBtn));
    expect(box.width, greaterThanOrEqualTo(44));
    expect(box.height, greaterThanOrEqualTo(44));

    handle.dispose();
  });

  testWidgets('an attempt with no address offers nothing to press', (
    WidgetTester t,
  ) async {
    await open(t, const Size(1800, 3000), email: '');

    // Not a greyed button: an attempt with no address on it is a data state,
    // not a control to offer and then refuse.
    expect(find.byType(CopyBtn), findsNothing);
  });

  testWidgets('and the button itself refuses an empty value', (
    WidgetTester t,
  ) async {
    final SemanticsHandle handle = t.ensureSemantics();
    final List<String?> copied = interceptClipboard(t);
    final Toaster toaster = Toaster();

    await t.pumpWidget(
      mount(
        Center(
          child: CopyBtn(
            '',
            toaster: toaster,
            toast: 'Email copied',
            tooltip: 'Copy this candidate\'s email address.',
            semanticsLabel: 'Copy email address',
          ),
        ),
        AssessmentNav(),
      ),
    );

    expect(t.widget<IconBtn>(find.byType(IconBtn)).onPressed, isNull);
    expect(
      t.getSemantics(find.byType(CopyBtn)),
      isSemantics(hasEnabledState: true, isEnabled: false),
    );

    await t.tap(find.byType(CopyBtn));
    await t.pumpAndSettle();

    // A toast that says "copied" over an untouched clipboard is worse than no
    // control: the operator pastes whatever was there before and never knows.
    expect(copied, isEmpty);
    expect(toaster.items, isEmpty);

    handle.dispose();
  });

  testWidgets('the address still fits, and keeps its button, when narrow', (
    WidgetTester t,
  ) async {
    // A long assessment name plus a long address on a laptop-narrow head. The
    // line used to soft-wrap unbounded; it now ellipsises after two lines, and
    // the thing that must never be pushed off the end is the button.
    await open(
      t,
      const Size(1180, 2400),
      email: 'sejal.pal2021.qa.candidate@ethara.ai',
    );

    // An overflow is reported as an exception during layout, so a clean pump
    // IS the assertion.
    expect(t.takeException(), isNull);
    expect(find.byType(CopyBtn), findsOneWidget);
    expect(t.getTopLeft(find.byType(CopyBtn)).dx, greaterThanOrEqualTo(0));
  });

  testWidgets('the button sits after the address, not after the title', (
    WidgetTester t,
  ) async {
    // THE BUG: the address shared a line with the assessment name, so the
    // button landed wherever that name ended - far right for a long name,
    // mid-line for a short one. It now has a line of its own.
    Future<Offset> buttonAt(String name) async {
      await open(t, const Size(1800, 3000), name: name);
      return t.getTopLeft(find.byType(CopyBtn));
    }

    final Offset short = await buttonAt('Sprint 3');
    final Offset long = await buttonAt(
      'IG Entity Video Cleaning - Quality Assessment (Sprint 3)-1',
    );
    expect(long, short, reason: 'the button moved with the title length');

    // On the address's line, right after it.
    final Rect email = t.getRect(find.text('anita@example.com'));
    // The breadcrumb carries the name too; the head's line is the 2-line one.
    final Rect title = t.getRect(
      find.byWidgetPredicate(
        (Widget w) =>
            w is Text &&
            w.data ==
                'IG Entity Video Cleaning - Quality Assessment (Sprint 3)-1' &&
            w.maxLines == 2,
      ),
    );
    final Rect button = t.getRect(find.byType(CopyBtn));
    expect(email.top, greaterThanOrEqualTo(title.bottom));
    expect(button.left, greaterThanOrEqualTo(email.right));
    expect(button.left - email.right, lessThan(24));
  });
}
