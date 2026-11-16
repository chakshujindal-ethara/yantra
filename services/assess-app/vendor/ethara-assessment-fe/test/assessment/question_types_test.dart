@TestOn('vm')
// Reads the SOURCE TREE through dart:io, so it can only run on the VM.
// Under `--platform chrome` there is no filesystem and it fails with
// "Unsupported operation: _Namespace" - a harness limit, not a defect.
// Tagging it keeps a chrome run honest: real failures stay visible
// instead of being lost in a dozen expected ones.
// The client's question-type table must match the module's.
//
// WHY THIS EXISTS: the client's enum and the module's `QUESTION_TYPE_SELECTION`
// are two copies of one registry, and they have drifted before. A KPI card here
// hardcoded "of 7" while the module's table had already moved on, so the card
// under-reported the product; a type retired server-side leaves the reverse
// wound, a shape the client still parses and offers that nothing can send.
//
// The second rule is subtler and matters more: the module may mark a type
// IMPORT-ONLY through `NON_GENERATABLE_QUESTION_TYPES`, meaning the LLM
// pipeline has no way to author it. That set is EMPTY today, but the
// generator's type picker once offered an excluded type anyway, so an operator
// could build a generator that silently produced nothing for it. What is
// asserted is the RELATIONSHIP - the picker offers exactly the types the module
// will author - so it holds whether the set is empty or grows again.
//
// These are asserted against the real `constants.py` rather than a copy, so
// the test fails when the module changes and the client does not.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';

/// The module is a sibling checkout; skip rather than fail when it is absent
/// so this suite still runs on a frontend-only clone.
///
/// SEARCHED, not hardcoded. This used to name one absolute path, so moving the
/// backend turned the whole group into a silent skip - green, checking nothing.
/// That is exactly what happened when the module was forked from
/// `etp_assessment_pro` into `assessments_be_v2`: the tail below still named
/// the old package, every candidate missed, and this file reported success
/// without reading a single constant. The list carries every location the
/// module has actually lived in, newest first, and the fork is deliberately not
/// among them - `etp_assessment_pro` is a separate module whose constants no
/// longer describe this client. `ethara-etp/custom_addons` is the one that
/// matters: it is the copy that gets pushed. `ETP_MODULE_PATH` still wins for a
/// checkout somewhere else entirely.
String? _findConstants() {
  const String tail = 'custom_addons/assessments_be_v2/constants.py';
  final String? fromEnv = Platform.environment['ETP_MODULE_PATH'];
  final List<String> candidates = <String>[
    if (fromEnv != null && fromEnv.isNotEmpty) '$fromEnv/constants.py',
    '../ethara-etp/$tail',
    '../assessments-be-v2/constants.py',
    '../assessments_be_v2/constants.py',
  ];
  for (final String p in candidates) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

void main() {
  group('QType mirrors the module', () {
    final String? path = _findConstants();
    if (path == null) {
      test('module constants.py not present - skipped', () {}, skip: true);
      return;
    }
    final File f = File(path);
    final String src = f.readAsStringSync();

    test('every wire code the module ships has a QType', () {
      final RegExp sel = RegExp(
        r'QUESTION_TYPE_SELECTION\s*=\s*\[(.*?)\]',
        dotAll: true,
      );
      final String block = sel.firstMatch(src)!.group(1)!;
      final List<String> codes = RegExp(
        r'\(\s*"([a-z0-9_]+)"',
      ).allMatches(block).map((RegExpMatch m) => m.group(1)!).toList();

      expect(codes, isNotEmpty, reason: 'could not parse constants.py');

      // `known`, not `values`: `unsupported` is the client's own stand-in for
      // a code it cannot name (A-053), never a module type.
      final Set<String> mine = QType.known.map((QType q) => q.wire).toSet();
      expect(
        mine,
        equals(codes.toSet()),
        reason: 'client types $mine do not match module types $codes',
      );
    });

    test('the generator picker offers exactly what the module can author', () {
      // The module's own exclusion set. The braces are OPTIONAL in this
      // pattern because an empty set is written `frozenset()`, with no braces
      // at all - and that is the form the module ships today. Matching only
      // `frozenset({...})` and then forcing the result with `!` is how this
      // assertion would crash on the very payload it is meant to accept.
      final RegExp non = RegExp(
        r'NON_GENERATABLE_QUESTION_TYPES\s*=\s*frozenset\(\s*(?:\{([^}]*)\})?\s*\)',
      );
      final RegExpMatch? m = non.firstMatch(src);
      expect(
        m,
        isNotNull,
        reason:
            'NON_GENERATABLE_QUESTION_TYPES is gone from constants.py, and '
            'QType.isGeneratable still mirrors it',
      );
      // A null group is the empty set, not a parse failure.
      final Set<String> excluded = RegExp(r'"([a-z0-9_]+)"')
          .allMatches(m!.group(1) ?? '')
          .map((RegExpMatch e) => e.group(1)!)
          .toSet();

      final Set<String> offered = QType.generatable
          .map((QType q) => q.wire)
          .toSet();
      for (final String code in excluded) {
        expect(
          offered,
          isNot(contains(code)),
          reason:
              '$code cannot be authored by the pipeline, so the '
              'generator picker must not offer it',
        );
      }

      // The other direction, which is the one that bites while the exclusion
      // set is empty: a type the pipeline CAN author but the picker withholds
      // is just as broken, and nothing else would catch it.
      final Set<String> all = QType.known.map((QType q) => q.wire).toSet();
      expect(
        offered,
        isNot(contains(QType.unsupported.wire)),
        reason: 'nothing can author a type this build cannot name',
      );
      expect(
        offered,
        equals(all.difference(excluded)),
        reason:
            'the picker offers $offered, the module authors '
            '${all.difference(excluded)}',
      );
    });
  });
}
