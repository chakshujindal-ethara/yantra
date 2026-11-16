// The spend ledger reports what the module actually did.
//
// THE BUGS THIS EXISTS FOR, all found on a live ledger of 25 real calls:
//
//   1. `LedgerOp.parse` fell back to `summarize` for anything it did not know.
//      Four of the five operations the module emits were unknown, so $16.87 of
//      $17.44 was silently relabelled "Summarize attempt". The chart looked
//      authoritative and was wrong.
//   2. Image and video generation were not counted as authoring, so the screen
//      reported "Authoring share 0%" on a ledger that was almost entirely
//      authoring.
//   3. `LedgerRow` had no `fromJson` at all: it existed only for seeded demo
//      data, so against a live backend the screen summed an empty list and
//      showed "$0.00 / 0 requests".
//
// The operation names below are copied from a live `GET /api/v1/ledger`, so
// this test fails if the module starts emitting something new - which is the
// point. A silent fallback is what caused the misreport in the first place.
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';

void main() {
  group('Every operation the module emits is named', () {
    // Verified live: these are the only `operation` values in the ledger.
    const List<String> live = <String>[
      'generate_image',
      'submit_video_op',
      'generate_questions',
      'verify_planted_flaws',
      'other',
    ];

    test('none of them falls through to a wrong label', () {
      for (final String wire in live) {
        final LedgerOp op = LedgerOp.parse(wire);
        expect(
          op.wire,
          wire,
          reason:
              '"$wire" parsed as "${op.wire}" (${op.label}) - its cost '
              'would be attributed to the wrong operation',
        );
      }
    });

    test('an unknown operation reads as Other, never as a real one', () {
      // `summarize` was the old fallback. An unrecognised call must not be
      // indistinguishable from a genuine one.
      final LedgerOp op = LedgerOp.parse('some_future_operation');
      expect(op, LedgerOp.other);
      expect(op, isNot(LedgerOp.summarize));
    });

    test('producing a question and its media both count as authoring', () {
      for (final LedgerOp op in <LedgerOp>[
        LedgerOp.generateQuestions,
        LedgerOp.generateImage,
        LedgerOp.submitVideoOp,
        LedgerOp.verifyPlantedFlaws,
        LedgerOp.extractTags,
      ]) {
        expect(
          op.isAuthoring,
          isTrue,
          reason:
              '${op.label} is part of authoring a question; excluding it '
              'under-reports the authoring share',
        );
      }
    });

    test('scoring a candidate is NOT authoring', () {
      for (final LedgerOp op in <LedgerOp>[
        LedgerOp.scoreSubjective,
        LedgerOp.scoreImageAb,
        LedgerOp.summarize,
      ]) {
        expect(
          op.isAuthoring,
          isFalse,
          reason: '${op.label} is evaluation spend, not authoring',
        );
      }
    });
  });

  group('A ledger row parses off the wire', () {
    // Verbatim from a live `GET /api/v1/ledger`.
    final Map<String, dynamic> row = <String, dynamic>{
      'id': 66,
      'operation': 'generate_image',
      'model': 'gemini-3-pro-image',
      'tokens_in': 696,
      'tokens_out': 1120,
      'thoughts_tokens': 271,
      'total_tokens': 2087,
      'image_count': 1,
      'video_seconds': 0.0,
      'cost_usd': 0.15208,
      'generator': null,
      'evaluator_id': null,
      'note': 'defect-render',
      'create_date': '2026-08-05T09:48:24Z',
    };

    test('the money and the tokens survive', () {
      final LedgerRow r = LedgerRow.fromJson(row);

      expect(
        r.cost,
        closeTo(0.15208, 0.00001),
        reason: 'the whole screen sums this',
      );
      expect(r.tokensIn, 696);
      expect(r.tokensOut, 1120);
      expect(r.thoughts, 271);
      expect(r.totalTokens, 2087);
      expect(r.images, 1);
      expect(r.op, LedgerOp.generateImage);
      expect(r.model, 'gemini-3-pro-image');
    });

    test('a null attribution does not become the string "null"', () {
      final LedgerRow r = LedgerRow.fromJson(row);
      expect(r.genId, isNull);
      expect(r.evId, isNull);
      expect(r.attributedTo, 'Unattributed');
    });
  });

  group('The web number model does not eat the cents', () {
    // THE BUG THIS EXISTS FOR, and why it survived a green suite:
    //
    // `jval` tested `fallback is int` BEFORE `fallback is double`. Dart on the
    // VM has two numeric types, so `0.0 is int` is false there and every unit
    // test passed. Compiled to JavaScript there is only one, `0.0 is int` is
    // TRUE, and every double was sent through `toInt()`. The LLM budget screen
    // therefore reported $13.00 - the sum of the INTEGER PARTS - against a real
    // $17.4437, and nothing failed.
    //
    // Run this file with `flutter test --platform chrome` to exercise the path
    // that actually broke. On the VM it still guards the ordering.
    test('a sub-dollar cost keeps its cents', () {
      final LedgerRow r = LedgerRow.fromJson(<String, dynamic>{
        'id': 1,
        'operation': 'generate_image',
        'model': 'gemini-3-pro-image',
        'cost_usd': 0.15208,
        'create_date': '2026-08-05T09:48:24Z',
      });
      expect(
        r.cost,
        greaterThan(0.0),
        reason: 'truncation to 0 is how the whole screen read \$0.00',
      );
      expect(r.cost, closeTo(0.15208, 0.00001));
    });

    test('the ledger total matches the server to the cent', () {
      // The five real per-operation totals from a live ledger.
      const List<double> costs = <double>[15.2, 1.36953, 0.56772, 0.30417, 0.0];
      final double total = costs.fold<double>(0, (double a, double b) => a + b);

      final List<LedgerRow> rows = costs
          .map(
            (double c) => LedgerRow.fromJson(<String, dynamic>{
              'id': 1,
              'operation': 'other',
              'model': 'm',
              'cost_usd': c,
              'create_date': '2026-08-05T09:48:24Z',
            }),
          )
          .toList();
      final double parsed = rows.fold<double>(
        0,
        (double a, LedgerRow r) => a + r.cost,
      );

      expect(parsed, closeTo(total, 0.00001));
      expect(
        parsed,
        closeTo(17.44142, 0.001),
        reason: 'the screen must not report the sum of the integer parts',
      );
    });
  });

  // THE FOURTH BUG, found on the LLM budget screen: "Cost by project" drew a
  // card titled `{id: 323, name: Text to Image Gen test}` beside a second card
  // for the very same generator.
  //
  // `usage_row` sends `"generator": {"id": .., "name": ..}` - an OBJECT - and
  // the parser read `'${jget(j, 'generator')}'`, which stringifies the Dart
  // Map. Every authoring row therefore keyed on that literal text: it matched
  // no generator in the store, so the raw map was printed as a project TITLE,
  // and it never met the evaluation rows, which reach the same generator the
  // other way round (attempt -> assessment -> generatorId) and key on its real
  // id. One generator, two cards, one of them unreadable.
  group(
    'A ledger row is attributed to a generator ID, not to its toString',
    () {
      Map<String, dynamic> row({Object? generator}) => <String, dynamic>{
        'id': 1,
        'operation': 'generate_questions',
        'model': 'm',
        'cost_usd': 1.0,
        'generator': generator,
        'create_date': '2026-08-05T09:48:24Z',
      };

      test('the nested object yields the bare id', () {
        final LedgerRow r = LedgerRow.fromJson(
          row(
            generator: <String, dynamic>{
              'id': 323,
              'name': 'Text to Image Gen test',
            },
          ),
        );

        expect(r.genId, '323');
        expect(r.genId, isNot(contains('{')));
        // Carried too, so a card can be titled from the ledger alone - the
        // generator list is paged, and a spend audit reads exactly the history
        // most likely to have fallen off the end of it.
        expect(r.genName, 'Text to Image Gen test');
      });

      test('an unattributed row stays unattributed', () {
        final LedgerRow r = LedgerRow.fromJson(row());
        expect(r.genId, isNull);
        expect(r.genName, '');
      });

      test('a flat id still parses, for the seed fixtures', () {
        expect(LedgerRow.fromJson(row(generator: 'GEN-1')).genId, 'GEN-1');
      });

      test('authoring and evaluation on one generator share a key', () {
        // The two halves as the server really sends them: authoring names the
        // generator, evaluation names only the attempt. They have to agree on
        // the id or the screen draws the generator twice.
        final LedgerRow authoring = LedgerRow.fromJson(
          row(generator: <String, dynamic>{'id': 323, 'name': 'Gen'}),
        );
        expect(authoring.genId, '323');
      });
    },
  );
}
