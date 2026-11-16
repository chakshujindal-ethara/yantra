/// Time analysis and the Pace tag.
///
/// THE ARITHMETIC IS THE RISK HERE, not the layout. A Pace tag is shown next to
/// a person's name, so a median computed over the wrong set - or a duration
/// invented for a paper still being written - labels a real candidate Slow on
/// evidence that does not exist. These tests pin the decisions the spec is
/// explicit about: median not mean, per-test not cohort-wide, descriptive only.
library;

import 'package:ethara_assessment/assessment/domain/category_scores.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/dashboard_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/marks.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Attempt sitting({String? started, String? submitted}) => Attempt(
  id: 'e1',
  assessmentId: 'a1',
  employeeId: 'p1',
  token: 't1',
  startedAt: started == null ? null : DateTime.parse(started),
  submittedAt: submitted == null ? null : DateTime.parse(submitted),
);

Duration mins(int n) => Duration(minutes: n);

/// The ratio exactly as [paceExplanation] printed it, read back off the string.
///
/// The point of every test below that uses this is that the operator's only
/// source for the number is this string - so the string is what the tag has to
/// agree with, not the unrounded double nobody can see.
double shownRatio(String why) =>
    double.parse(RegExp(r': ([\d.]+)x\n').firstMatch(why)!.group(1)!);

/// Which band the legend puts [shown] in, read the way an operator reads it.
Pace bandFromLegend(double shown) => shown <= kPaceFastAtOrBelow
    ? Pace.fast
    : shown >= kPaceSlowAtOrAbove
    ? Pace.slow
    : Pace.average;

Widget mountDashboard(AppStore store) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(
    body: AssessmentNavScope(
      nav: AssessmentNav(),
      child: DashboardScreen(store: store),
    ),
  ),
);

/// The Time Analysis panel, as the admin dashboard really builds it.
Future<Finder> pumpTimeAnalysis(WidgetTester t) async {
  t.view.physicalSize = const Size(1900, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(mountDashboard(AppStore()));
  await t.pumpAndSettle();
  final Finder panel = find.ancestor(
    of: find.text('Time Analysis'),
    matching: find.byType(Panel),
  );
  expect(panel, findsOneWidget);
  return panel;
}

void main() {
  group('A sitting only has a duration when it really has one', () {
    test('a started-and-submitted paper measures the span between', () {
      expect(
        attemptDuration(
          sitting(started: '2026-08-17T13:00:00Z', submitted: '2026-08-17T13:25:00Z'),
        ),
        mins(25),
      );
    });

    test('an IN-PROGRESS paper has no duration', () {
      // THE IMPORTANT ONE. Treating "now minus started" as elapsed time would
      // give an abandoned attempt a duration that grows forever and drag the
      // cohort median with it - so every other candidate drifts towards "Fast"
      // the longer one person leaves a tab open.
      expect(attemptDuration(sitting(started: '2026-08-17T13:00:00Z')), isNull);
    });

    test('a never-opened paper has no duration', () {
      expect(attemptDuration(sitting()), isNull);
    });

    test('a backwards span is discarded, not clamped to zero', () {
      // Clock disagreement between a server stamp and a backfilled one. A
      // 0-minute sitting in the median is a quiet lie about the cohort;
      // absent is honest.
      expect(
        attemptDuration(
          sitting(started: '2026-08-17T13:25:00Z', submitted: '2026-08-17T13:00:00Z'),
        ),
        isNull,
      );
    });
  });

  group('The cohort is summarised by a median, not a mean', () {
    test('an odd count takes the middle value', () {
      expect(
        medianDuration(<Duration>[mins(10), mins(30), mins(20)]),
        mins(20),
      );
    });

    test('an even count averages the two middles', () {
      expect(
        medianDuration(<Duration>[mins(10), mins(20), mins(30), mins(40)]),
        mins(25),
      );
    });

    test('one outlier does not move it - which is the whole point', () {
      // The lunch-break case, stated as a test. The mean of these is 74 min,
      // which would make four of the five sittings look Fast.
      final List<Duration> xs = <Duration>[
        mins(18),
        mins(20),
        mins(22),
        mins(24),
        mins(300),
      ];
      expect(medianDuration(xs), mins(22));
    });

    test('nothing to measure yields null rather than zero', () {
      expect(medianDuration(<Duration>[]), isNull);
    });
  });

  group('Pace is a band, not a coin flip on the median', () {
    final Duration median = mins(20);

    test('a clearly quick sitting is Fast', () {
      expect(paceOf(mins(10), median), Pace.fast);
    });

    test('a clearly long sitting is Slow', () {
      expect(paceOf(mins(40), median), Pace.slow);
    });

    test('anything close to typical is Average', () {
      // WITHOUT A BAND THIS TEST FAILS BY DESIGN: 19 and 21 minutes sit either
      // side of a 20-minute median, so a bare comparison labels one Fast and
      // the other Slow and half the cohort gets a tag that means nothing.
      expect(paceOf(mins(19), median), Pace.average);
      expect(paceOf(mins(20), median), Pace.average);
      expect(paceOf(mins(21), median), Pace.average);
    });

    test('the band edges are inclusive on the outside', () {
      // 25% either way. Pinned so a later tweak to the constants is a decision
      // rather than an accident.
      expect(paceOf(mins(15), median), Pace.fast);
      expect(paceOf(mins(25), median), Pace.slow);
      expect(paceOf(mins(16), median), Pace.average);
      expect(paceOf(mins(24), median), Pace.average);
    });

    test('no median means no tag', () {
      // A cohort of one unfinished paper. Labelling that sitting against
      // nothing would be inventing a comparison.
      expect(paceOf(mins(20), null), isNull);
      expect(paceOf(null, median), isNull);
      expect(paceOf(mins(20), Duration.zero), isNull);
    });
  });

  group('Durations are written for a person', () {
    test('sub-minute reads as under a minute, not 0', () {
      expect(humanDuration(const Duration(seconds: 40)), '<1 min');
    });

    test('minutes stay minutes', () {
      expect(humanDuration(mins(45)), '45 min');
    });

    test('an hour and over reads in hours', () {
      expect(humanDuration(mins(60)), '1h');
      expect(humanDuration(mins(95)), '1h 35m');
    });
  });

  group('The date window keeps in-progress work in the cohort', () {
    test('every window has a cutoff except Any date', () {
      final DateTime now = DateTime.parse('2026-08-20T12:00:00Z');
      expect(DateWindow.all.cutoffFrom(now), isNull);
      expect(
        DateWindow.last7.cutoffFrom(now),
        DateTime.parse('2026-08-13T12:00:00Z'),
      );
      expect(
        DateWindow.last30.cutoffFrom(now),
        DateTime.parse('2026-07-21T12:00:00Z'),
      );
    });

    test('Any date is the default, so the dashboard opens un-narrowed', () {
      // A dashboard that opens pre-filtered hides work from the person whose
      // job is to notice it.
      expect(DateWindow.values.first, DateWindow.all);
    });
  });

  // A TAG NOBODY CAN DECODE IS A TAG NOBODY TRUSTS.
  //
  // Pace shipped with its thresholds only in `paceOf`. On screen the reader saw
  // `1h 8m / <1 min / Slow`, and - worse - `<1 min / <1 min / Average`, because
  // both time columns round to whole minutes and floor at "<1 min". There was
  // no way to check the tag, so a developer reading the dashboard could not say
  // how Pace was decided, let alone an operator.
  group('Pace explains itself', () {
    test('the sentence is built from the same numbers as the branch', () {
      // Two copies of "1.25" - one deciding, one explaining - is how a tag
      // comes to contradict its own tooltip.
      expect(paceOf(const Duration(minutes: 5), const Duration(minutes: 4)),
          Pace.slow);
      expect(kPaceSlowAtOrAbove, 1.25);
      expect(kPaceFastAtOrBelow, 0.75);
      expect(
        paceExplanation(const Duration(minutes: 5), const Duration(minutes: 4)),
        contains('1.25x'),
      );
    });

    test('the tooltip is exactly the agreed two-line format', () {
      expect(
        paceExplanation(
          const Duration(minutes: 45, seconds: 22),
          const Duration(minutes: 24, seconds: 19),
        ),
        "45m 22s against test's median 24m 19s: 1.87x\n"
        'Fast \u2264 0.75x  \u2022  Normal 0.76x\u20131.24x  \u2022  '
        'Slow \u2265 1.25x',
      );
    });

    test('the band is called Normal, not Average', () {
      expect(Pace.average.label, 'Normal');
      expect(paceLegend, contains('Normal'));
      expect(paceLegend, isNot(contains('Average')));
    });

    test('it carries the ratio and BOTH exact durations', () {
      final String why = paceExplanation(
        const Duration(minutes: 4, seconds: 12),
        const Duration(minutes: 2, seconds: 5),
      );
      expect(why, contains('4m 12s'));
      expect(why, contains('2m 5s'));
      expect(why, contains('2.02x'));
    });

    test('the seconds survive where the columns round them away', () {
      // THE CASE THAT MADE THIS NECESSARY: both columns render "<1 min", so
      // the row looked like a coin toss. The explanation has to separate them.
      final String why = paceExplanation(
        const Duration(seconds: 50),
        const Duration(seconds: 20),
      );
      expect(why, contains('50s'));
      expect(why, contains('20s'));
      expect(why, contains('2.50x'));
      expect(paceOf(const Duration(seconds: 50), const Duration(seconds: 20)),
          Pace.slow);
    });

    test('no median is said plainly, not left blank', () {
      expect(paceExplanation(const Duration(minutes: 3), null),
          contains('no median'));
    });

    test('preciseDuration keeps what humanDuration drops', () {
      expect(preciseDuration(const Duration(seconds: 41)), '41s');
      expect(preciseDuration(const Duration(minutes: 4, seconds: 12)), '4m 12s');
      expect(preciseDuration(const Duration(minutes: 68)), '1h 8m');
      expect(preciseDuration(const Duration(hours: 2)), '2h');
    });

    test('an hour-long sitting keeps its seconds too', () {
      // THE ROWS THIS PANEL EXISTS FOR. It sorts slowest first, so the tooltips
      // an operator actually opens are the long ones - and the hour branch used
      // to drop the seconds, making this identical to `humanDuration`. The
      // tooltip then repeated the two figures already in the columns while the
      // ratio beside them was still computed from the seconds it had thrown
      // away, so the arithmetic could not be checked at all.
      expect(preciseDuration(const Duration(hours: 1, seconds: 50)), '1h 50s');
      expect(
        preciseDuration(const Duration(hours: 1, minutes: 8, seconds: 3)),
        '1h 8m 3s',
      );
      expect(
        preciseDuration(const Duration(hours: 2, minutes: 30, seconds: 59)),
        '2h 30m 59s',
      );
    });

    test('a long sitting can be checked against its own tooltip', () {
      // 3650s against 3000s. The columns read `1h` and `50 min`, which works
      // out at 1.20x; the tooltip says 1.22x. Unless the tooltip shows the 50
      // seconds the columns dropped, those two numbers cannot be reconciled by
      // the person reading them.
      final String why = paceExplanation(
        const Duration(hours: 1, seconds: 50),
        const Duration(minutes: 50),
      );
      expect(why, startsWith("1h 50s against test's median 50m: 1.22x"));
      expect(
        preciseDuration(const Duration(hours: 1, seconds: 50)),
        isNot(humanDuration(const Duration(hours: 1, seconds: 50))),
        reason: 'a "precise" duration that equals the rounded one in the '
            'column tells the reader nothing they did not already have',
      );
    });
  });

  // THE TAG AND THE LEGEND HAVE TO AGREE FOR EVERY VALUE THAT CAN BE SEEN.
  //
  // An operator checking a Pace tag against the legend is the entire audience
  // for this feature. Two things broke that: the legend printed Normal as the
  // CLOSED range 0.75x-1.25x while `paceOf` gives both of those numbers away to
  // Fast and Slow, and the ratio was rounded to two decimals only for display -
  // so a sitting at 1.2499 was tagged Normal and printed "1.25x" one line above
  // a legend saying 1.25x is Slow.
  group('The band edges say the same thing twice', () {
    test('the legend claims no number the branch gives away', () {
      expect(
        paceLegend,
        'Fast \u2264 0.75x  \u2022  Normal 0.76x\u20131.24x  \u2022  '
        'Slow \u2265 1.25x',
      );
    });

    test('the tag is decided by the number that is printed', () {
      // 1.249 and 0.7545 both round onto an edge. Whatever the raw quotient
      // was, the reader only ever sees the rounded one, so that is the one the
      // tag has to be true of.
      const Duration median = Duration(seconds: 1000);
      expect(paceOf(const Duration(seconds: 1249), median), Pace.slow);
      expect(
        paceExplanation(const Duration(seconds: 1249), median),
        contains('1.25x'),
      );
      expect(
        paceOf(const Duration(seconds: 7545), const Duration(seconds: 10000)),
        Pace.fast,
      );
      expect(
        paceExplanation(
          const Duration(seconds: 7545),
          const Duration(seconds: 10000),
        ),
        contains('0.75x'),
      );
    });

    test('every ratio an operator can reach obeys the legend', () {
      // SWEPT, not sampled. The failure was a handful of ratios either side of
      // each edge, which is exactly what a few hand-picked cases miss.
      const Duration median = Duration(seconds: 1000);
      int fast = 0;
      int normal = 0;
      int slow = 0;
      for (int s = 1; s <= 2500; s++) {
        final Duration one = Duration(seconds: s);
        final Pace pace = paceOf(one, median)!;
        final double shown = shownRatio(paceExplanation(one, median));
        expect(
          pace,
          bandFromLegend(shown),
          reason: '$s s prints ${shown}x and is tagged ${pace.label}, which '
              'the legend contradicts',
        );
        switch (pace) {
          case Pace.fast:
            fast++;
          case Pace.average:
            normal++;
          case Pace.slow:
            slow++;
        }
      }
      expect(<int>[fast, normal, slow], everyElement(greaterThan(0)),
          reason: 'the sweep never reached all three bands, so it proves '
              'nothing about the edges between them');
    });
  });

  // THE WIRING, NOT JUST THE STRINGS.
  //
  // Every test above passes with the legend deleted from the panel header and
  // the tooltip deleted from the Pace cell, because both live in
  // `dashboard_screen.dart` and nothing pinned them there. These mount the real
  // dashboard.
  group('The dashboard actually shows what Pace promises', () {
    testWidgets('the Time Analysis header states the rule', (
      WidgetTester t,
    ) async {
      final Finder panel = await pumpTimeAnalysis(t);
      expect(
        find.descendant(
          of: panel,
          matching: find.textContaining(
            'descriptive only - time is never scored',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: panel, matching: find.textContaining(paceLegend)),
        findsOneWidget,
        reason: 'a tag nobody can decode is a tag nobody trusts - the legend '
            'has to be on the panel, not only in the domain layer',
      );
    });

    testWidgets('every Pace tag carries its own arithmetic', (
      WidgetTester t,
    ) async {
      final Finder panel = await pumpTimeAnalysis(t);
      final Finder pills = find.descendant(
        of: panel,
        matching: find.byType(Pill),
      );
      expect(pills, findsWidgets, reason: 'no Pace tags rendered to check');

      final List<Tooltip> tips = <Tooltip>[
        for (final Element e in find
            .descendant(
              of: panel,
              matching: find.ancestor(
                of: find.byType(Pill),
                matching: find.byType(Tooltip),
              ),
            )
            .evaluate())
          e.widget as Tooltip,
      ];
      expect(
        tips.length,
        pills.evaluate().length,
        reason: 'a Pace tag with no tooltip cannot be checked against '
            'anything, which is the only reason the tag is allowed to exist',
      );

      for (final Tooltip tip in tips) {
        final String why = tip.message!;
        expect(why, endsWith(paceLegend));
        // ITS OWN ROW'S NUMBERS. One shared sentence, or the legend alone,
        // would pass a "there is a tooltip" test and still tell the operator
        // nothing about the row under the cursor.
        expect(
          bandFromLegend(shownRatio(why)),
          Pace.values.firstWhere(
            (Pace p) => p.label == (tip.child! as Pill).label,
          ),
          reason: 'the tooltip reads "$why" beside a '
              '"${(tip.child! as Pill).label}" tag',
        );
      }
    });
  });
}
