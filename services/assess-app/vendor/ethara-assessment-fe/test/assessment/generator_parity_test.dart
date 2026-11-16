// Generator parity: the fields the server always sent and the client dropped.
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';

/// A DETAIL payload as `/api/v1/generators/<id>` really returns it.
Map<String, dynamic> wire() => <String, dynamic>{
  'id': 59,
  'name': 'test',
  'sop_title': '260123-high-res-dense-bbox-with-labels',
  'question_count': 5,
  'approved_count': 2,
  'resource_count': 1,
  'similar_count': 3,
  'structure_count': 4,
  'selected_structure_count': 2,
  'structure_mode': 'selected',
  'question_count_mode': 'fixed',
  'sop_question_count': 7,
  'image_label_count': 8,
  'sop_gen_state': 'done',
  'tag_extract_state': 'done',
  'tag_extract_last_run': '2026-08-07T07:11:16Z',
  'last_extract_summary': 'Generated 5 draft(s) from SOP',
  'sop_gen_error': '',
  'tag_extract_error': '',
  'allowed_types': <String>['image_label'],
  'select_all_types': false,
  'tags': <dynamic>[],
};

void main() {
  group('the detail payload is read, not discarded', () {
    test('every parity field survives fromJson', () {
      final Generator g = Generator.fromJson(wire());
      expect(g.questionCount, 5);
      expect(g.approvedCount, 2, reason: 'approved count was dropped');
      expect(g.resourceCount, 1);
      expect(g.similarCount, 3);
      expect(g.structureCount, 4);
      expect(g.selectedStructureCount, 2);
      expect(g.structureMode, 'selected');
      expect(g.questionCountMode, 'fixed');
      expect(g.sopQuestionCount, 7);
      expect(g.imageLabelCount, 8);
      expect(g.tagExtractLastRun, '2026-08-07T07:11:16Z');
      expect(g.lastExtractSummary, 'Generated 5 draft(s) from SOP');
    });

    test('allowed_types arrives from the server, not an empty guess', () {
      // The Generation tab read "0 selected" over a generator that had already
      // produced five Labelling drafts, because the payload carried no list.
      final Generator g = Generator.fromJson(wire());
      expect(
        g.allowedTypes,
        isNotEmpty,
        reason: 'the server sends allowed_types; it must be parsed',
      );
      expect(g.allowedTypes.single, QType.imageLabel);
    });

    test('plannedCount is never an invented 12', () {
      // A generator on `auto` has no chosen number. Defaulting to 12 printed
      // "Generate 12 questions" - a promise the run would not keep.
      final Map<String, dynamic> auto = wire()
        ..['question_count_mode'] = 'auto'
        ..['sop_question_count'] = 0;
      final Generator g = Generator.fromJson(auto);
      expect(g.countIsAuto, isTrue);
      expect(g.plannedCount, 0, reason: '12 was fabricated');
    });

    test('a fixed count is taken from sop_question_count', () {
      final Generator g = Generator.fromJson(wire());
      expect(g.countIsAuto, isFalse);
      expect(g.plannedCount, 7);
    });

    test('lastError prefers the generation error, then the extraction one', () {
      expect(Generator.fromJson(wire()).lastError, isNull);

      final Generator genFailed = Generator.fromJson(
        wire()..['sop_gen_error'] = 'quota exhausted',
      );
      expect(genFailed.lastError, 'quota exhausted');

      final Generator tagFailed = Generator.fromJson(
        wire()..['tag_extract_error'] = 'could not read the PDF',
      );
      expect(tagFailed.lastError, 'could not read the PDF');
    });

    test('fileCount uses the rows when present, the count when not', () {
      // A LIST row carries `resource_count` and no rows at all.
      expect(Generator.fromJson(wire()).fileCount, 1);

      final Map<String, dynamic> withRows = wire()
        ..['resource_count'] = 1
        ..['resources'] = <dynamic>[
          <String, dynamic>{'id': 1, 'filename': 'a.pdf'},
          <String, dynamic>{'id': 2, 'filename': 'b.pdf'},
        ];
      expect(
        Generator.fromJson(withRows).fileCount,
        2,
        reason: 'the DETAIL rows are more accurate than a stale count',
      );
    });

    test('copyWith carries the server fields through', () {
      // The bug this guards: a copyWith that omits server fields resets them to
      // their defaults on any local edit, which is how roster marks fell back
      // to "0 / 0".
      final Generator g = Generator.fromJson(wire());
      final Generator renamed = g.copyWith(name: 'renamed');
      expect(renamed.name, 'renamed');
      expect(renamed.approvedCount, 2);
      expect(renamed.sopQuestionCount, 7);
      expect(renamed.imageLabelCount, 8);
      expect(renamed.questionCountMode, 'fixed');
      expect(renamed.lastExtractSummary, g.lastExtractSummary);
    });

    test('the image label ceiling is read off image_label_count', () {
      // The module names it `image_label_count`; the client speaks camelCase
      // and `jget` derives the snake_case spelling itself. `fromJson` must
      // therefore ask for `imageLabelCount` ONLY - a hand-written snake_case
      // literal there is how a field parses from the fixtures and defaults
      // from the live wire, which is the defect `jget` exists to prevent.
      expect(Generator.fromJson(wire()).imageLabelCount, 8);
      expect(
        Generator.fromJson(<String, dynamic>{
          'id': 3,
          'name': 'camel',
          'imageLabelCount': 8,
        }).imageLabelCount,
        8,
        reason: 'the seed fixtures spell it camelCase',
      );
    });

    test('imageLabelCount survives a toJson/fromJson round trip', () {
      // A field left out of `toJson` reads back at its default, so the
      // round trip is what proves the value is actually carried rather than
      // re-invented - 20 would look plausible over a generator pinned to 8.
      final Generator g = Generator.fromJson(wire());
      final Generator back = Generator.fromJson(g.toJson());
      expect(back.imageLabelCount, 8);
      expect(back.imageLabelCount, g.imageLabelCount);
    });

    test('the live-website switch parses, round-trips and defaults off', () {
      // Off unless a project asks for real website screenshots (owner,
      // 2026-09-29); a LIST row carries no such key.
      final Map<String, dynamic> on = wire()
        ..['image_label_live_capture'] = true;
      final Generator g = Generator.fromJson(on);
      expect(g.imageLabelLiveCapture, isTrue);
      expect(Generator.fromJson(g.toJson()).imageLabelLiveCapture, isTrue);
      expect(Generator.fromJson(wire()).imageLabelLiveCapture, isFalse);
    });

    test('an absent image_label_count falls back to the module default', () {
      // 20 is what the module stores by default, and a LIST row carries no
      // such key. Falling back to 0 would render "no labels allowed" in the
      // stepper over a server that would accept twenty.
      final Map<String, dynamic> thin = wire()..remove('image_label_count');
      expect(Generator.fromJson(thin).imageLabelCount, 20);
    });

    test('a LIST row with none of these keys still parses', () {
      // Absent keys must fall back, not throw: the list route is deliberately
      // thin and every screen builds from it first.
      final Generator g = Generator.fromJson(<String, dynamic>{
        'id': 2,
        'name': 'Warehouse Safety SOP',
      });
      expect(g.approvedCount, 0);
      expect(g.countIsAuto, isTrue);
      expect(g.lastError, isNull);
      expect(g.fileCount, 0);
      expect(g.imageLabelCount, 20);
    });
  });
}
