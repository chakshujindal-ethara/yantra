// Back and Forward, over the pages the user actually visited.
//
// WHAT BROKE BEFORE. `AssessmentNav` was a stack: `pop()` dropped the page, so
// there was nothing to go forward to, and `reset()` - which every rail click
// and every "back to my assessments" goes through - cleared the whole thing.
// Between them the trail was destroyed on almost every move the user made, and
// the two members that could have offered Back (`pop`/`canPop`) were called
// from nowhere in `lib/`.
//
// These tests pin the browser model that replaced it, and the two places it
// deliberately does NOT behave like a plain history: the section's entry point,
// which must not leave a page behind that nobody visited, and the exam runner,
// which owns server-side state that page history must not walk into.
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/nav.dart';

void main() {
  group('Routes compare by value', () {
    // The dedupe in `go` is an `==` check. Without these overrides it held
    // only for the fieldless routes the rail builds as `const`, so opening one
    // generator from two different links stacked two identical entries and the
    // first Back press appeared to do nothing.
    test('same type and same fields are the same page', () {
      expect(const GeneratorDetail('7'), const GeneratorDetail('7'));
      expect(
        const AssessmentDetail('3', tab: 'assign'),
        const AssessmentDetail('3', tab: 'assign'),
      );
      expect(const ResponseDetail('a', 'q'), const ResponseDetail('a', 'q'));
      expect(const AttemptDetail('9'), const AttemptDetail('9'));
      expect(const CandidateDetail('p1'), const CandidateDetail('p1'));
      expect(const ReviewQueue(generatorId: 'g'), const ReviewQueue(generatorId: 'g'));
      expect(const Exam('tok'), const Exam('tok'));
    });

    test('a different field is a different page', () {
      expect(const GeneratorDetail('7'), isNot(const GeneratorDetail('8')));
      expect(
        const AssessmentDetail('3', tab: 'assign'),
        isNot(const AssessmentDetail('3', tab: 'questions')),
      );
      // Arriving with the name ready to type into is a different page from
      // arriving to read it - the one caller that sets this has just created
      // the record.
      expect(
        const GeneratorDetail('7'),
        isNot(const GeneratorDetail('7', focusName: true)),
      );
      expect(
        const Exam('tok', questionIndex: 1),
        isNot(const Exam('tok', questionIndex: 2)),
      );
    });

    test('two different fieldless routes never collide', () {
      expect(const QuestionBank(), isNot(const TagsAdmin()));
      expect(const Analytics(), isNot(const StartHere()));
    });

    test('equal routes hash equally, so a Set treats them as one', () {
      // Built from a list rather than written as a set literal: the analyzer
      // rejects a literal with two equal elements, which is the very thing
      // being asserted. `==` without a matching `hashCode` would pass every
      // other test in this group and fail only here.
      const List<AssessmentRoute> twice = <AssessmentRoute>[
        GeneratorDetail('7'),
        GeneratorDetail('7'),
      ];
      expect(twice.toSet(), hasLength(1));
    });
  });

  group('A fresh navigator has nowhere to go', () {
    test('neither direction is offered before anything is visited', () {
      final AssessmentNav nav = AssessmentNav();
      expect(nav.canGoBack, isFalse);
      expect(nav.canGoForward, isFalse);
      expect(nav.previous, isNull);
      expect(nav.next, isNull);
    });

    test('replaceRoot starts a trail rather than extending one', () {
      // What the section's entry point uses. Seeding with `reset` instead would
      // leave the navigator's initial placeholder sitting behind the first real
      // page, and Back on a freshly loaded app would go somewhere the user had
      // never been.
      final AssessmentNav nav = AssessmentNav()
        ..reset(const GeneratorList())
        ..reset(const QuestionBank())
        ..replaceRoot(const Analytics());

      expect(nav.current, const Analytics());
      expect(nav.canGoBack, isFalse);
      expect(nav.canGoForward, isFalse);
    });
  });

  group('Back and Forward walk the trail', () {
    AssessmentNav trail() => AssessmentNav()
      ..replaceRoot(const Analytics())
      ..go(const GeneratorList())
      ..go(const GeneratorDetail('7'));

    test('Back returns to where the user came from', () {
      final AssessmentNav nav = trail();
      expect(nav.canGoBack, isTrue);

      nav.back();
      expect(nav.current, const GeneratorList());
      nav.back();
      expect(nav.current, const Analytics());
    });

    test('the page is kept, so Forward can return to it', () {
      // The whole difference from the stack this replaced.
      final AssessmentNav nav = trail()..back();
      expect(nav.canGoForward, isTrue);

      nav.forward();
      expect(nav.current, const GeneratorDetail('7'));
      expect(nav.canGoForward, isFalse);
    });

    test('Back stops at the start instead of running off the end', () {
      final AssessmentNav nav = trail()
        ..back()
        ..back()
        ..back()
        ..back();
      expect(nav.current, const Analytics());
      expect(nav.canGoBack, isFalse);
    });

    test('previous and next name the destinations, for the tooltips', () {
      final AssessmentNav nav = trail()..back();
      expect(nav.previous, const Analytics());
      expect(nav.next, const GeneratorDetail('7'));
      expect(routeLabel(nav.previous!), 'Dashboard');
    });

    test('every route has a tooltip label', () {
      // `routeLabel` switches exhaustively over a sealed type, so a new route
      // fails to compile rather than reaching a user as a blank tooltip. This
      // guards the other half: that none of the arms is an empty string.
      const List<AssessmentRoute> all = <AssessmentRoute>[
        StartHere(),
        Analytics(),
        AssessmentsList(),
        NewAssessment(),
        AssessmentDetail('1'),
        QuestionBank(),
        GeneratorList(),
        GeneratorDetail('1'),
        ReviewQueue(),
        ResponsesList(),
        ResponseDetail('1', '2'),
        AttemptDetail('1'),
        CandidateDetail('1'),
        TagsAdmin(),
        BudgetAdmin(),
        LedgerAdmin(),
        SettingsAdmin(),
        AccountSettings(),
        MyAssessments(),
        MyPerformance(),
        Exam('t'),
      ];
      for (final AssessmentRoute r in all) {
        expect(routeLabel(r), isNotEmpty, reason: '$r has no label');
      }
    });
  });

  group('Visiting a new page abandons the forward branch', () {
    test('going somewhere new after Back drops what was ahead', () {
      // The browser rule. What was ahead is no longer a trail anyone walked.
      final AssessmentNav nav = AssessmentNav()
        ..replaceRoot(const Analytics())
        ..go(const GeneratorList())
        ..go(const QuestionBank())
        ..back()
        ..go(const TagsAdmin());

      expect(nav.current, const TagsAdmin());
      expect(nav.canGoForward, isFalse);
      nav.back();
      expect(nav.current, const GeneratorList());
    });
  });

  group('The page you are already on is not a new entry', () {
    test('re-visiting the current page changes nothing', () {
      // Clicking the lit rail row must not silently charge the user a Back
      // press to undo.
      final AssessmentNav nav = AssessmentNav()
        ..replaceRoot(const Analytics())
        ..go(const QuestionBank())
        ..go(const QuestionBank())
        ..go(const QuestionBank());

      expect(nav.current, const QuestionBank());
      nav.back();
      expect(nav.current, const Analytics());
      expect(nav.canGoBack, isFalse);
    });

    test('the same detail route reached twice collapses too', () {
      // Needs value equality - this is the case `const` canonicalisation does
      // not cover, because these are built from a record id at runtime.
      final String id = <String>['7'].first;
      final AssessmentNav nav = AssessmentNav()
        ..replaceRoot(const GeneratorList())
        ..go(GeneratorDetail(id))
        ..go(GeneratorDetail(id));

      nav.back();
      expect(nav.current, const GeneratorList());
    });
  });

  group('A rail jump is an ordinary entry', () {
    test('reset no longer clears the trail', () {
      // `reset` is the name 26 call sites already use, and it used to wipe the
      // stack. Every one of them is a rail click or a "back to my
      // assessments", which is exactly the move a user expects Back to undo.
      final AssessmentNav nav = AssessmentNav()
        ..replaceRoot(const Analytics())
        ..reset(const QuestionBank())
        ..reset(const TagsAdmin());

      expect(nav.canGoBack, isTrue);
      nav.back();
      expect(nav.current, const QuestionBank());
      nav.back();
      expect(nav.current, const Analytics());
    });

    test('drilling in and jumping out both stay in the trail', () {
      final AssessmentNav nav = AssessmentNav()
        ..replaceRoot(const GeneratorList())
        ..go(const GeneratorDetail('7'))
        ..reset(const ResponsesList());

      nav.back();
      expect(nav.current, const GeneratorDetail('7'));
      nav.back();
      expect(nav.current, const GeneratorList());
    });
  });

  group('The exam is a boundary in both directions', () {
    test('entering the runner keeps exactly the page it was opened from', () {
      // THIS PINNED AN EMPTY TRAIL, and the empty trail was three bugs.
      //
      // An operator opening a sitting from Responses lost everything and was
      // dropped on the candidate portal on the way out; a candidate opening one
      // from My Performance was returned to the wrong screen; and the admin
      // preview's only exit is `nav.back()`, which with nothing behind it could
      // never fire. One entry costs nothing and answers all three.
      final AssessmentNav nav = AssessmentNav()
        ..replaceRoot(const MyAssessments())
        ..go(const Analytics())
        ..go(const ResponsesList())
        ..go(const Exam('tok'));

      expect(nav.current, const Exam('tok'));
      expect(nav.canGoBack, isTrue, reason: 'the exam has an exit');
      expect(nav.canGoForward, isFalse);

      nav.back();
      expect(
        nav.current,
        const ResponsesList(),
        reason: 'Back leaves the runner and lands where it was opened from',
      );
      expect(
        nav.canGoBack,
        isFalse,
        reason: 'and only that one page survives - the rest of the trail is '
            'still dropped, so the boundary still holds',
      );
    });

    test('moving between stages replaces rather than stacks', () {
      // The runner has its own Previous/Next over questions, and it moves
      // through `/exam/<token>/state` to do it. Page history must not grow a
      // second, conflicting notion of "back" alongside it.
      final AssessmentNav nav = AssessmentNav()..replaceRoot(const MyAssessments());
      nav.exam('tok');
      nav.examQuestion('tok', 1);
      nav.examQuestion('tok', 2);
      nav.examReview('tok');

      expect(nav.current, const Exam('tok', stage: ExamStage.review));
      expect(
        nav.canGoBack,
        isTrue,
        reason: 'Back is the way OUT of the sitting, not a way through it',
      );

      // The stages left no entries of their own: one Back exits, it does not
      // walk question 2 -> question 1 -> gate alongside the runner's own
      // Previous, which is the conflict this boundary exists to prevent.
      nav.back();
      expect(nav.current, isNot(isA<Exam>()));
    });

    test('leaving the runner returns to where it was entered from', () {
      // A submitted attempt is closed, so there is still nothing to walk
      // FORWARD into - but the page the candidate came from is a real
      // destination and used to be thrown away with everything else.
      final AssessmentNav nav = AssessmentNav()
        ..replaceRoot(const MyAssessments())
        ..go(const MyPerformance());
      nav.exam('tok');
      nav.examComplete('tok');
      nav.reset(const MyAssessments());

      expect(nav.current, const MyAssessments());
      expect(nav.canGoForward, isFalse, reason: 'a closed attempt is not ahead');
      expect(nav.canGoBack, isTrue);
      nav.back();
      expect(nav.current, const MyPerformance());
    });
  });

  group('A route with fields is its own history entry', () {
    test('two different forms are two different pages', () {
      // FormDesigner was the ONE route with fields and no `==`, so it inherited
      // the base class's runtimeType-only equality and every FormDesigner
      // equalled every other. `go` drops a route equal to the current one, so
      // this was not a history artefact - opening a second form from the first
      // did nothing at all, on screen, in the shipped app.
      expect(const FormDesigner('a') == const FormDesigner('b'), isFalse);

      final AssessmentNav nav = AssessmentNav()..replaceRoot(const FormStudio());
      nav.formDesigner('form-a');
      nav.formDesigner('form-b');
      expect((nav.current as FormDesigner).id, 'form-b');
    });

    test('the two tabs of one form are two different pages', () {
      // Same defect, the path an operator hits far more often: Design <-> Preview
      // is a tab change on one id, and it silently did nothing.
      final AssessmentNav nav = AssessmentNav()..replaceRoot(const FormStudio());
      nav.formDesigner('form-a', tab: 'design');
      nav.formDesigner('form-a', tab: 'preview');

      expect((nav.current as FormDesigner).tab, 'preview');
      nav.back();
      expect((nav.current as FormDesigner).tab, 'design');
    });

    test('every route with fields overrides equality', () {
      // The property, not the instance. FormDesigner is fixed; this is what
      // stops the next route added with fields from shipping the same way,
      // since the base class makes forgetting it silent.
      const List<(AssessmentRoute, AssessmentRoute)> distinct =
          <(AssessmentRoute, AssessmentRoute)>[
        (AssessmentDetail('1'), AssessmentDetail('2')),
        (GeneratorDetail('1'), GeneratorDetail('2')),
        (ReviewQueue(generatorId: '1'), ReviewQueue(generatorId: '2')),
        (ResponseDetail('a', 'q'), ResponseDetail('b', 'q')),
        (AttemptDetail('1'), AttemptDetail('2')),
        (CandidateDetail('1'), CandidateDetail('2')),
        (CandidatePerformance('1'), CandidatePerformance('2')),
        (FormDesigner('1'), FormDesigner('2')),
        (Exam('a'), Exam('b')),
      ];
      for (final (AssessmentRoute a, AssessmentRoute b) in distinct) {
        expect(a == b, isFalse, reason: '$a and $b must be different entries');
      }
    });
  });

  group('The trail is bounded', () {
    test('a long session drops its oldest pages, not its newest', () {
      final AssessmentNav nav = AssessmentNav()..replaceRoot(const Analytics());
      // Distinct routes, so nothing is dropped by the dedupe instead.
      for (int i = 0; i < AssessmentNav.maxEntries + 20; i++) {
        nav.go(GeneratorDetail('$i'));
      }

      expect(nav.current, GeneratorDetail('${AssessmentNav.maxEntries + 19}'));

      int steps = 0;
      while (nav.canGoBack) {
        nav.back();
        steps++;
      }
      expect(steps, AssessmentNav.maxEntries - 1);
      expect(
        nav.current,
        isNot(const Analytics()),
        reason: 'the oldest entries are the ones that fall off',
      );
    });
  });

  group('The retired stack API still behaves', () {
    test('pop is Back, and canPop is canGoBack', () {
      // Both were dead code in `lib/`, but they are this class's original
      // public API. They differ in the one way that matters: the page is left
      // in the trail rather than dropped, so Forward can return to it.
      final AssessmentNav nav = AssessmentNav()
        ..replaceRoot(const Analytics())
        ..go(const QuestionBank());

      expect(nav.canPop, isTrue);
      nav.pop();
      expect(nav.current, const Analytics());
      expect(nav.canPop, isFalse);
      expect(
        nav.canGoForward,
        isTrue,
        reason: 'pop must no longer throw the page away',
      );
    });
  });

  group('The navigator tells its listeners', () {
    test('every move notifies, and a no-op move does not', () {
      final AssessmentNav nav = AssessmentNav()..replaceRoot(const Analytics());
      int beats = 0;
      nav.addListener(() => beats++);

      nav.go(const QuestionBank());
      expect(beats, 1);

      // Already there.
      nav.go(const QuestionBank());
      expect(beats, 1);

      nav.back();
      expect(beats, 2);

      // Nowhere further back.
      nav.back();
      expect(beats, 2);

      nav.forward();
      expect(beats, 3);

      // Nowhere further forward.
      nav.forward();
      expect(beats, 3);
    });
  });
}
