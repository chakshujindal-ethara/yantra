// Browser campaign, 8 Oct 2026: the exam's top bar on a phone.
//
// BR-D7. At 390 px the exam title in the top bar vanished: it shared what the
// counts and the clock left with the progress bar, a few pixels. On a phone
// it has a line of its own now, cut with an ellipsis.
//
// Ported from stage's the_exam_chrome_works_on_a_phone_and_by_keyboard_test;
// its keyboard half (BR-D9: IconBtn and AckBox focus) is another port.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/assessment_section.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';

const String kToken = 'tok-chrome';
const String kTitle = 'Senior Backend Engineer - Systems Design Screening';

AppStore _store({bool timeUp = false, bool serverDeadline = true}) {
  final AppStore s = AppStore();
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': 7,
      'access_token': kToken,
      'assessment_id': 21,
      'state': 'in_progress',
      'started_at': DateTime.now().toUtc().toIso8601String(),
      if (serverDeadline)
        'deadline': DateTime.now()
            .add(Duration(minutes: timeUp ? -1 : 30))
            .toUtc()
            .toIso8601String(),
    }),
  ];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 21,
      'name': kTitle,
      'state': 'in_progress',
      'duration_minutes': 45,
      'rules': <String, dynamic>{'tab_switch': true},
      'violation_action': 'auto_submit',
      'max_violations': 3,
    }),
  ];
  s.examByToken[kToken] = ExamView.fromJson(<String, dynamic>{
    'outcome': 'question',
    'question': <String, dynamic>{
      'id': '10',
      'index': 1,
      'total': 3,
      'name': 'Question 1',
      'prompt': 'Prompt.',
      'question_type': 'subjective_rubric',
    },
  });
  return s;
}

Future<void> _mount(
  WidgetTester t,
  AppStore s, {
  required Size size,
  VoidCallback? onToggleTheme,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      // The test font draws every glyph a full em wide, nearly twice a real
      // one, so a phone-width bar would overflow here and not in a browser.
      // Scaled to real widths.
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(0.55)),
        child: child!,
      ),
      home: AssessmentNavScope(
        nav: AssessmentNav(),
        child: ExamScreen(
          store: s,
          token: kToken,
          sub: ExamSub.question,
          onToggleTheme: onToggleTheme,
        ),
      ),
    ),
  );
  await t.pump();
}

/// Tab until the focus is inside [target], or give up.
Future<bool> _tabTo(WidgetTester t, Finder target) async {
  final Element host = t.element(target);
  for (int i = 0; i < 12; i++) {
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    final BuildContext? at = FocusManager.instance.primaryFocus?.context;
    bool inside = identical(at, host);
    at?.visitAncestorElements((Element e) => !(inside = identical(e, host)));
    if (inside) return true;
  }
  return false;
}

void main() {
  group('BR-D7: the exam title stays on the top bar', () {
    for (final Size size in const <Size>[Size(390, 844), Size(1440, 900)]) {
      testWidgets('at ${size.width.toInt()} px it is there, on one line', (
        WidgetTester t,
      ) async {
        await _mount(t, _store(), size: size);

        final Finder title = find.descendant(
          of: find.byType(ExamTopBar),
          matching: find.text(kTitle),
        );
        expect(title, findsOneWidget);
        final Text text = t.widget<Text>(title);
        expect(text.maxLines, 1);
        expect(text.overflow, TextOverflow.ellipsis);
        expect(
          t.getSize(title).width,
          greaterThan(150),
          reason: 'enough of the name to read, not a sliver',
        );
        expect(
          t.getRect(title).right,
          lessThanOrEqualTo(size.width),
          reason: 'on screen',
        );
        expect(t.takeException(), isNull);

        await t.pumpWidget(const SizedBox());
      });
    }

    testWidgets('at 390 px the title sits on its own line, above the clock', (
      WidgetTester t,
    ) async {
      await _mount(t, _store(), size: const Size(390, 844));
      final Finder bar = find.byType(ExamTopBar);
      final Rect title = t.getRect(
        find.descendant(of: bar, matching: find.text(kTitle)),
      );
      final Rect count = t.getRect(
        find.descendant(of: bar, matching: find.text('Question 1 of 3')),
      );
      expect(title.bottom, lessThanOrEqualTo(count.top));

      await t.pumpWidget(const SizedBox());
    });
  });

  testWidgets('with no server deadline the bar counts from the start', (
    WidgetTester t,
  ) async {
    await _mount(t, _store(serverDeadline: false), size: const Size(1440, 900));
    final Clock clock = t.widget<Clock>(find.byType(Clock));
    expect(clock.deadline, isNotNull);
    expect(
      clock.deadline!.difference(DateTime.now()).inMinutes,
      inInclusiveRange(43, 45),
    );
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('behind a full-screen overlay Tab never reaches the toggle '
      '(BR-D15 review, P3-7b)', (WidgetTester t) async {
    await _mount(
      t,
      _store(timeUp: true),
      size: const Size(1400, 2400),
      onToggleTheme: () {},
    );
    await t.pump(const Duration(seconds: 2));
    expect(find.text('Time is up'), findsOneWidget);

    final Finder toggle = find.descendant(
      of: find.byType(ExamTopBar),
      matching: find.byType(IconBtn),
    );
    expect(toggle, findsOneWidget);
    expect(await _tabTo(t, toggle), isFalse);
    // Pinned on the wrapper too: this lane's IconBtn takes no focus yet
    // (BR-D9 is another port), so the Tab walk alone would pass without it.
    ExcludeFocus bar() => t.widget<ExcludeFocus>(
      find
          .ancestor(
            of: find.byType(ExamTopBar),
            matching: find.byType(ExcludeFocus),
          )
          .first,
    );
    expect(bar().excluding, isTrue);

    await t.pumpWidget(const SizedBox());
  });

  testWidgets('with no overlay the top bar stays in the keyboard\'s reach', (
    WidgetTester t,
  ) async {
    await _mount(
      t,
      _store(),
      size: const Size(1400, 2400),
      onToggleTheme: () {},
    );
    final ExcludeFocus bar = t.widget<ExcludeFocus>(
      find
          .ancestor(
            of: find.byType(ExamTopBar),
            matching: find.byType(ExcludeFocus),
          )
          .first,
    );
    expect(bar.excluding, isFalse);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('the section hands the shell\'s toggle to the exam bar during '
      'a sitting', (WidgetTester t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    // The fixture store: an exam in progress, no backend.
    final AppStore s = AppStore();
    addTearDown(s.dispose);
    final Attempt sitting = s.attempts.firstWhere(
      (Attempt a) => a.state == AttemptState.inProgress && a.startedAt != null,
    );
    int flips = 0;
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: AssessmentSection(
            store: s,
            examToken: sitting.token,
            onToggleTheme: () => flips++,
            isDark: false,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(ExamTopBar), findsOneWidget);

    final Finder toggle = find.descendant(
      of: find.byType(ExamTopBar),
      matching: find.byTooltip('Switch to dark'),
    );
    expect(toggle, findsOneWidget);
    await t.tap(toggle);
    expect(flips, 1);

    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(minutes: 1));
  });
}
