@TestOn('vm')
// Reads the SOURCE TREE through dart:io, so it can only run on the VM.
// Under `--platform chrome` there is no filesystem and it fails with
// "Unsupported operation: _Namespace" - a harness limit, not a defect.
// Tagging it keeps a chrome run honest: real failures stay visible
// instead of being lost in a dozen expected ones.
// Do the parsers survive what the server ACTUALLY sends?
//
// THE BUG THIS EXISTS FOR: `refresh()` caught only `ApiError`. A `TypeError`
// or `FormatException` thrown inside any `fromJson` escaped the try, so
// `loadState` never left `loading` - the screen span a loader forever and the
// error was silent. Every list stayed empty behind that spinner, which is why
// several screens looked like they held "the same data": they held none.
//
// These payloads are captured verbatim from the running module, so a field
// the server renames breaks this test instead of the app.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';

/// Rows out of the module's `{ok, data, meta}` envelope.
///
/// The fixtures live IN THE REPO, not in /tmp. They used to be captured to
/// /tmp/payloads, which macOS clears - so the whole file silently degraded to
/// "no rows, nothing checked" after a reboot and reported green while guarding
/// nothing. Re-capture with tool/capture_payloads.py against a live backend.
List<Map<String, dynamic>> rowsOf(String file) {
  final File f = File('test/assessment/payloads/$file.json');
  if (!f.existsSync()) return const <Map<String, dynamic>>[];
  final Map<String, dynamic> body =
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  final Object? data = body['data'];
  if (data is List) {
    return data.cast<Map<String, dynamic>>();
  }
  return const <Map<String, dynamic>>[];
}

/// The `data` object of a single-record payload.
Map<String, dynamic> objectOf(String file) {
  final File f = File('test/assessment/payloads/$file.json');
  if (!f.existsSync()) return const <String, dynamic>{};
  final Map<String, dynamic> body =
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  final Object? data = body['data'];
  return data is Map<String, dynamic> ? data : const <String, dynamic>{};
}

void main() {
  group('Real server payloads parse', () {
    test('assessments', () {
      final List<Map<String, dynamic>> rows = rowsOf('assessments');
      expect(
        rows,
        isNotEmpty,
        reason: 'capture payloads first: see the curl in the verify script',
      );
      for (final Map<String, dynamic> r in rows) {
        expect(
          () => Assessment.fromJson(r),
          returnsNormally,
          reason: 'Assessment.fromJson threw on ${r['id']}: $r',
        );
      }
    });

    test('generators', () {
      for (final Map<String, dynamic> r in rowsOf('generators')) {
        expect(
          () => Generator.fromJson(r),
          returnsNormally,
          reason: 'Generator.fromJson threw on ${r['id']}: $r',
        );
      }
    });

    test('bank questions', () {
      for (final Map<String, dynamic> r in rowsOf('bank')) {
        expect(
          () => Question.fromJson(r),
          returnsNormally,
          reason: 'Question.fromJson threw on ${r['id']}: $r',
        );
      }
    });

    test('drafts', () {
      for (final Map<String, dynamic> r in rowsOf('drafts')) {
        expect(
          () => Question.fromJson(r),
          returnsNormally,
          reason: 'Question.fromJson threw on ${r['id']}: $r',
        );
      }
    });

    // NOT `returnsNormally`. THAT IS THE POINT.
    //
    // Every check above asserts only that parsing did not throw, and a parser
    // that returns a record with every field at its default passes all of them.
    // That is exactly what shipped: a draft's answer key arrived, was parsed
    // into nothing, and rendered as an empty option list under "No answer key"
    // - with this suite green, because nothing here ever looked at a VALUE.
    //
    // These two assert content. The fixtures are the detail routes, which are
    // also new: only the list routes were ever captured, so the payloads that
    // carry an answer key had never been checked against the parser at all.
    test(
      'a draft detail carries its answer key all the way into the model',
      () {
        final Map<String, dynamic> raw = objectOf('draft_detail');
        if (raw.isEmpty) {
          markTestSkipped(
            'no draft_detail fixture - run tool/capture_payloads.py',
          );
          return;
        }
        final Question q = Question.fromJson(raw);
        expect(
          q.type.hasOptionKey,
          isTrue,
          reason: 'the fixture must be a keyed type to prove anything',
        );
        expect(q.dims, isNotEmpty, reason: 'the axes did not survive parsing');
        expect(
          q.dims
              .expand((QDimension d) => d.options)
              .where((QOption o) => o.correct),
          isNotEmpty,
          reason: 'no option came through marked correct, so the key is lost',
        );
        // The verdict the review queue renders its blocking warning from.
        expect(
          q.hasCompleteKey,
          isTrue,
          reason: 'a keyed draft still reports "No answer key"',
        );
        expect(
          q.warnings.map((QualityWarning w) => w.title),
          isNot(contains('No answer key')),
        );
      },
    );

    test('a bank detail carries its dimensions and media', () {
      final Map<String, dynamic> raw = objectOf('bank_detail');
      if (raw.isEmpty) {
        markTestSkipped(
          'no bank_detail fixture - run tool/capture_payloads.py',
        );
        return;
      }
      final Question q = Question.fromJson(raw);
      expect(q.dims, isNotEmpty);
      expect(
        q.dims
            .expand((QDimension d) => d.options)
            .where((QOption o) => o.correct),
        isNotEmpty,
      );
      expect(q.hasCompleteKey, isTrue);
    });

    // The list row is what the queue actually holds most of the time, because
    // a refresh follows every mutation. If the key is not on it, it is gone.
    test('an objective draft LIST row carries the key too', () {
      final List<Map<String, dynamic>> keyed = rowsOf('drafts')
          .where(
            (Map<String, dynamic> r) => const <String>{
              'mcq',
              'msq',
              'image_ab',
            }.contains(r['question_type']),
          )
          .toList();
      if (keyed.isEmpty) {
        markTestSkipped('no objective draft in the drafts fixture');
        return;
      }
      for (final Map<String, dynamic> r in keyed) {
        final Question q = Question.fromJson(r);
        expect(
          q.dims,
          isNotEmpty,
          reason:
              'draft ${r['id']} (${r['question_type']}) lost its key on '
              'the list route',
        );
        expect(
          q.hasCompleteKey,
          isTrue,
          reason: 'draft ${r['id']} would show a false "No answer key"',
        );
      }
    });

    test('tags', () {
      for (final Map<String, dynamic> r in rowsOf('tags')) {
        expect(
          () => Tag.fromJson(r),
          returnsNormally,
          reason: 'Tag.fromJson threw on $r',
        );
      }
    });

    test('candidate attempts', () {
      final List<Map<String, dynamic>> rows = rowsOf('candidates');
      expect(rows, isNotEmpty, reason: 'seed an evaluator before capturing');
      for (final Map<String, dynamic> r in rows) {
        expect(
          () => Attempt.fromJson(r),
          returnsNormally,
          reason: 'Attempt.fromJson threw on ${r['id']}: $r',
        );
      }
    });

    test('an attempt keeps the fields its screens render', () {
      final List<Map<String, dynamic>> rows = rowsOf('candidates');
      final Attempt a = Attempt.fromJson(rows.first);

      // Parsing "successfully" into all-defaults is the failure this guards:
      // a roster of blank rows looks like an empty assessment, not a bug.
      expect(a.id, isNotEmpty, reason: 'integer id must survive as a String');
      expect(
        a.assessmentId,
        isNotEmpty,
        reason: 'assessment_id is what groups a roster',
      );
      expect(
        a.employeeId,
        isNotEmpty,
        reason:
            'candidate is NESTED on the wire; without it the roster '
            'renders a blank name for every row',
      );
    });
  });

  group('An uploaded document reaches the screen', () {
    // THE BUG THIS EXISTS FOR. A 6.5 MB PDF uploaded successfully (HTTP 200,
    // 6,815,753 bytes stored) and the corpus tab still said "No files
    // attached". Three separate faults, all client-side:
    //
    //   1. the DETAIL payload nests resources at `tabs.resources`; the parser
    //      only read the root, where the fixtures put them
    //   2. `Resource.fromJson` read `file`/`kind`/`error`, but the wire sends
    //      `name`/`category`/`extraction_error` - so even a found row rendered
    //      blank
    //   3. nothing ever called `/api/v1/generators/<id>`: the screen rendered
    //      the LIST row, which carries `resource_count` and no records
    test('the detail payload yields the attached file', () {
      final Map<String, dynamic> data = objectOf('generator_detail');
      expect(
        data,
        isNotEmpty,
        reason: 'capture fixtures with tool/capture_payloads.py',
      );

      final Generator g = Generator.fromJson(data);
      expect(
        g.resources,
        isNotEmpty,
        reason:
            'the server nests these under tabs.resources - reading only '
            'the root is what produced "No files attached"',
      );

      final Resource r = g.resources.first;
      expect(
        r.file,
        isNotEmpty,
        reason:
            'the wire calls it `name`, not `file`; an empty string here '
            'renders a blank row for a real document',
      );
      expect(r.id, isNotEmpty);
    });

    test('a PDF stored natively is not reported as a failure', () {
      // A PDF goes to the model natively and is never text-extracted, so it
      // reports char_count 0. That must read as "Stored", not as an error.
      final Generator g = Generator.fromJson(objectOf('generator_detail'));
      final Resource r = g.resources.first;
      expect(
        r.status,
        isNot(ResourceStatus.failed),
        reason: 'char_count 0 on a native PDF is normal',
      );
      expect(r.error ?? '', isEmpty);
    });

    test('a large upload reports its size', () {
      // The SIZE column was blank on a 6.5 MB PDF because the server never
      // sent one and the client fell back to char_count, which is 0 for a
      // natively-read document. That left no column anywhere on the screen
      // that could distinguish a 6 MB file from an empty one.
      final Generator g = Generator.fromJson(objectOf('generator_detail'));
      final Resource r = g.resources.first;
      expect(
        r.size,
        isNotEmpty,
        reason:
            'resource_row must send file_size, and the client must '
            'render it - this is the only proof the upload landed',
      );
      expect(
        r.size,
        matches(RegExp(r'^[0-9.]+ (B|KB|MB)$')),
        reason: 'got "${r.size}"',
      );
    });

    test('a sub-kilobyte file is not rounded away to 0 KB', () {
      // A real 446-byte SOP displayed as "0 KB", which reads as a failed read.
      expect(humanBytes(446), '446 B');
      expect(humanBytes(6815753), '6.5 MB');
      expect(humanBytes(0), isEmpty);
    });

    test('every category the server accepts has a client name', () {
      // The server accepts `other` and the enum did not know it, so such a
      // document silently displayed as "Reference".
      for (final String wire in <String>[
        'sop',
        'reference',
        'sample',
        'vendor',
        'client',
        'other',
      ]) {
        expect(
          ResourceKind.parse(wire).wire,
          wire,
          reason:
              '"$wire" is accepted by /resources but parses to '
              '"${ResourceKind.parse(wire).wire}"',
        );
      }
    });
  });
}
