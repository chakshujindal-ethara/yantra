/// Category-level strengths and weaknesses.
///
/// THE ARITHMETIC IS SHOWN TO A CANDIDATE ABOUT THEMSELVES, so it has to be
/// defensible by hand. These tests pin the decisions that make it so: marks are
/// summed before dividing (not averaged as percentages), every answer sheet row
/// is weighed by the marks ITS question was worth rather than by 1, only ONE
/// facet is ranked at a time, and an untagged bank produces nothing rather than
/// an "Other" bucket that reads as a weakness.
library;

import 'package:ethara_assessment/assessment/domain/category_scores.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

({List<String> tags, double earned, double possible}) ans(
  List<String> tags,
  double earned,
  double possible,
) => (tags: tags, earned: earned, possible: possible);

void main() {
  group('A tag is split into facet and readable label', () {
    test('a faceted key gives up its facet', () {
      expect(facetOf('skill:ai-artifact-detection'), 'skill');
      expect(facetOf('output-format:ab-choice'), 'output-format');
    });

    test('an unfaceted key is "other" rather than a crash', () {
      expect(facetOf('forklift'), 'other');
    });

    test('the label loses the prefix and the hyphens', () {
      // The machine key under a heading that already names the facet reads as
      // debug output, which is what this exists to prevent.
      expect(readableTag('skill:ai-artifact-detection'), 'AI Artifact Detection');
      expect(readableTag('task:compare-ai-images'), 'Compare AI Images');
    });

    test('an acronym keeps its own casing', () {
      // THE DEFECT THIS REPLACES. Capitalising the first letter and stopping
      // gave 'Ai artifact detection' - the one word on the row a reader
      // actually recognises, spelled wrong, on all five surfaces at once.
      expect(readableTag('skill:ab-choice'), 'A/B Choice');
      expect(readableTag('skill:sop-adherence'), 'SOP Adherence');
      expect(readableTag('task:ui-annotation'), 'UI Annotation');
    });

    test('a minor word stays lower unless it leads', () {
      // Title Case that capitalises "of" reads like a headline generator.
      expect(readableTag('domain:quality-of-service'), 'Quality of Service');
      expect(readableTag('domain:the-floor'), 'The Floor');
    });

    test('the server label wins over anything derived here', () {
      // `readableTag` is a guess from a machine key; `display` is pinned once
      // per tag by the extraction model. A screen holding both must print the
      // pinned one, or two surfaces name the same category differently.
      const CategoryScore pinned = CategoryScore(
        tag: 'skill:ai-artifact-detection',
        earned: 1,
        possible: 2,
        answers: 2,
        serverLabel: 'Artifact Detection (AI)',
      );
      expect(pinned.label, 'Artifact Detection (AI)');

      const CategoryScore derived = CategoryScore(
        tag: 'skill:ai-artifact-detection',
        earned: 1,
        possible: 2,
        answers: 2,
      );
      expect(derived.label, 'AI Artifact Detection');
    });

    test('a blank server label falls back rather than blanking the row', () {
      // The server sends '' when a tag has no pinned display, and an empty
      // string is not a label - it is a missing one.
      const CategoryScore blank = CategoryScore(
        tag: 'skill:ai-artifact-detection',
        earned: 1,
        possible: 2,
        answers: 2,
        serverLabel: '   ',
      );
      expect(blank.label, 'AI Artifact Detection');
    });
  });

  group('Categories average MARKS, not percentages', () {
    test('a big question is not weighted like a small one', () {
      // 6 of 60 is 10%, but averaging the two answers' own percentages
      // (100% and 0%) would report 50% - a figure nobody could reproduce from
      // the marks in front of them.
      final List<CategoryScore> out = categoryScores(<
        ({List<String> tags, double earned, double possible})
      >[
        ans(<String>['skill:x'], 6, 6),
        ans(<String>['skill:x'], 0, 54),
      ]);

      expect(out.single.percent, closeTo(10.0, 0.001));
      expect(out.single.earned, 6);
      expect(out.single.possible, 60);
      expect(out.single.answers, 2);
    });

    test('categories come back strongest first', () {
      final List<CategoryScore> out = categoryScores(<
        ({List<String> tags, double earned, double possible})
      >[
        ans(<String>['skill:weak'], 1, 10),
        ans(<String>['skill:strong'], 9, 10),
        ans(<String>['skill:middle'], 5, 10),
      ]);

      expect(
        out.map((CategoryScore c) => c.tag).toList(),
        <String>['skill:strong', 'skill:middle', 'skill:weak'],
      );
    });

    test('equal scores keep a stable order instead of shuffling', () {
      final List<CategoryScore> out = categoryScores(<
        ({List<String> tags, double earned, double possible})
      >[
        ans(<String>['skill:b'], 5, 10),
        ans(<String>['skill:a'], 5, 10),
      ]);
      expect(
        out.map((CategoryScore c) => c.tag).toList(),
        <String>['skill:a', 'skill:b'],
      );
    });
  });

  group('Only one facet is ranked, and skill wins', () {
    test('skill is preferred over the descriptive facets', () {
      // THE REAL BANK SHAPE on this rig: every question carries domain,
      // modality, output-format AND task. Ranking all of them together would
      // tell a candidate they are "weak at modality:image", which describes the
      // paper rather than them - and every answer would appear in four rows.
      final List<CategoryScore> out = categoryScores(<
        ({List<String> tags, double earned, double possible})
      >[
        ans(<String>[
          'skill:artifact-detection',
          'domain:ai-image-evaluation',
          'modality:image',
          'output-format:ab-choice',
        ], 1, 1),
      ]);

      expect(out.length, 1);
      expect(out.single.tag, 'skill:artifact-detection');
    });

    test('task is the fallback when no skill tags exist', () {
      // Exactly the etp_local bank today: tagged with domain/modality/
      // output-format/task and no skills. Task is the closest thing to an
      // ability among those, so it is ranked rather than showing nothing.
      final List<CategoryScore> out = categoryScores(<
        ({List<String> tags, double earned, double possible})
      >[
        ans(<String>[
          'domain:ai-image-evaluation',
          'modality:image',
          'task:compare-ai-images',
        ], 0, 1),
      ]);

      expect(out.single.tag, 'task:compare-ai-images');
    });

    test('an untagged bank yields NOTHING, not an "Other" bucket', () {
      // The honest empty state. A bucket here would present the absence of a
      // vocabulary as a category people are weak at.
      expect(
        categoryScores(<({List<String> tags, double earned, double possible})>[
          ans(<String>[], 1, 1),
          ans(<String>[], 0, 1),
        ]),
        isEmpty,
      );
    });

    test('a category with nothing available is dropped, not shown as 0%', () {
      // `possible == 0` is "not graded yet", not "scored nothing".
      expect(
        categoryScores(<({List<String> tags, double earned, double possible})>[
          ans(<String>['skill:x'], 0, 0),
        ]),
        isEmpty,
      );
    });

    test('minAnswers suppresses a category backed by one anecdote', () {
      final List<({List<String> tags, double earned, double possible})> a =
          <({List<String> tags, double earned, double possible})>[
            ans(<String>['skill:solid'], 1, 1),
            ans(<String>['skill:solid'], 1, 1),
            ans(<String>['skill:thin'], 0, 1),
          ];

      final List<CategoryScore> out = categoryScores(a, minAnswers: 2);
      expect(out.map((CategoryScore c) => c.tag), <String>['skill:solid']);
    });
  });

  group('A sheet row is weighed by its OWN mark pair', () {
    AnswerSheet sheetOf(List<AnswerSheetRow> rows) =>
        AnswerSheet(released: true, rows: rows);

    test('a 3-mark question pulls three times as hard as a 1-mark one', () {
      // THE BUG THIS PINS. A question is worth one mark per COMPONENT now - a
      // three-part mcq is worth 3 - and the sheet sends that pair on the
      // candidate's own row. The old reading weighed EVERY row as 1 and read an
      // objective row as all-or-nothing, so this paper reported 2 of 2 = 100%
      // to a candidate who had actually earned 3 of 4.
      final List<CategoryScore> out = categoryScores(
        answersOfSheet(
          sheetOf(<AnswerSheetRow>[
            const AnswerSheetRow(
              tags: <String>['skill:x'],
              tone: Tone.ok,
              marksEarned: 2,
              marksAvailable: 3,
            ),
            const AnswerSheetRow(
              tags: <String>['skill:x'],
              tone: Tone.ok,
              marksEarned: 1,
              marksAvailable: 1,
            ),
          ]),
        ),
      );

      expect(out.single.earned, 3);
      expect(out.single.possible, 4);
      expect(out.single.percent, closeTo(75.0, 0.001));
    });

    test('a PARTIAL row counts, where the pass/fail reading discarded it', () {
      // `partial` maps to Tone.warn, which the old code skipped outright: it
      // had no way to say how much of the question was right, so half a mark
      // was silently dropped from the category. The pair says exactly.
      final List<CategoryScore> out = categoryScores(
        answersOfSheet(
          sheetOf(<AnswerSheetRow>[
            const AnswerSheetRow(
              tags: <String>['skill:x'],
              tone: Tone.warn,
              marksEarned: 2,
              marksAvailable: 4,
            ),
          ]),
        ),
      );
      expect(out.single.percent, closeTo(50.0, 0.001));
    });

    test('the four real question shapes add up as the server marked them', () {
      // VERIFIED PAYLOADS, parsed off the wire so the snake_case spellings are
      // pinned too: `marks_earned` / `marks_available` reach the camelCase
      // fields through `jget`. 0/3 + 1/1 + 0/1 + 1/5 = 2 of 10.
      Map<String, dynamic> row(String kind, num earned, int available) =>
          <String, dynamic>{
            'tags': <String>['skill:x'],
            'kind': kind,
            'marks_earned': earned,
            'marks_available': available,
          };

      final AnswerSheet sheet = AnswerSheet.fromJson(<String, dynamic>{
        'result': <String, dynamic>{'released': true},
        'rows': <Map<String, dynamic>>[
          row('incorrect', 0.0, 3), // mcq
          row('correct', 1.0, 1), // subjective_rubric
          row('incorrect', 0.0, 1), // image_label
          row('partial', 1.0, 5), // image_ab
        ],
      });

      final List<CategoryScore> out = categoryScores(answersOfSheet(sheet));
      expect(out.single.earned, closeTo(2.0, 0.001));
      expect(out.single.possible, closeTo(10.0, 0.001));
      expect(out.single.percent, closeTo(20.0, 0.001));
    });

    test('a row from a server with no pair keeps the old one-mark reading', () {
      // Back-compat, and it has to stay honest rather than convenient: an
      // absent `marks_earned` is NOT a zero. Scoring it as one would report a
      // paper of losses to everyone still on an older backend, where a question
      // really was worth exactly 1.
      final List<CategoryScore> out = categoryScores(
        answersOfSheet(
          sheetOf(<AnswerSheetRow>[
            const AnswerSheetRow(tags: <String>['skill:x'], scoreRaw: 0.5),
            const AnswerSheetRow(tags: <String>['skill:x'], tone: Tone.ok),
          ]),
        ),
      );
      expect(out.single.answers, 2);
      expect(out.single.percent, closeTo(75.0, 0.001));
    });

    test('an UNMARKED row is skipped even though its pair reads 0', () {
      // "Not answered" and "Awaiting grading" arrive as Tone.inert with a
      // `marks_earned` of 0 against the question's real `marks_available`, so
      // the pair alone cannot tell them from a genuine zero. Counting them
      // would show a candidate a weakness that is really a queue.
      final List<CategoryScore> out = categoryScores(
        answersOfSheet(
          sheetOf(<AnswerSheetRow>[
            const AnswerSheetRow(
              tags: <String>['skill:x'],
              tone: Tone.ok,
              marksEarned: 3,
              marksAvailable: 3,
            ),
            const AnswerSheetRow(
              tags: <String>['skill:x'],
              marksEarned: 0,
              marksAvailable: 5,
            ),
          ]),
        ),
      );
      expect(out.single.answers, 1);
      expect(out.single.percent, closeTo(100.0, 0.001));
    });
  });

  group('Most improved compares like with like', () {
    List<CategoryScore> at(Map<String, double> pcts) => <CategoryScore>[
      for (final MapEntry<String, double> e in pcts.entries)
        CategoryScore(tag: e.key, earned: e.value, possible: 100, answers: 3),
    ];

    test('it names the biggest gain', () {
      final ({String tag, double delta})? best = mostImproved(
        at(<String, double>{'skill:a': 80, 'skill:b': 55}),
        at(<String, double>{'skill:a': 70, 'skill:b': 20}),
      );
      expect(best?.tag, 'skill:b');
      expect(best?.delta, closeTo(35, 0.001));
    });

    test('a category absent last time is not an improvement', () {
      // Inventing a trend from a single data point. The category is new, so
      // there is nothing to have improved FROM.
      final ({String tag, double delta})? best = mostImproved(
        at(<String, double>{'skill:new': 90}),
        at(<String, double>{'skill:old': 50}),
      );
      expect(best, isNull);
    });

    test('a decline is never dressed up as progress', () {
      expect(
        mostImproved(
          at(<String, double>{'skill:a': 40}),
          at(<String, double>{'skill:a': 90}),
        ),
        isNull,
      );
    });

    test('standing still is not an improvement either', () {
      expect(
        mostImproved(
          at(<String, double>{'skill:a': 60}),
          at(<String, double>{'skill:a': 60}),
        ),
        isNull,
      );
    });

    test('a first-ever sitting has nothing to compare', () {
      expect(
        mostImproved(at(<String, double>{'skill:a': 60}), <CategoryScore>[]),
        isNull,
      );
    });
  });
}
