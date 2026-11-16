@TestOn('vm')
// Reads the SOURCE TREE through dart:io, so it can only run on the VM.
// Under `--platform chrome` there is no filesystem and it fails with
// "Unsupported operation: _Namespace" - a harness limit, not a defect.
// Tagging it keeps a chrome run honest: real failures stay visible
// instead of being lost in a dozen expected ones.
// No parser may read a raw JSON key.
//
// THE BUG THIS EXISTS FOR: every `fromJson` that did `j['id'] as String`
// threw a TypeError against the live API, because Odoo sends integer ids.
// That TypeError escaped `refresh()` (which caught only ApiError), so
// `loadState` never left `loading`: an eternal spinner with empty lists
// behind it, and no error anywhere. Fourteen parsers had the flaw.
//
// A unit test per model would not have caught it - each one passed against
// the seed fixtures, which are camelCase and string-id. The rule has to be
// enforced on the SOURCE: read through jget/jval/jid, which accept both
// shapes, or the next parser someone adds reintroduces the same hang.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every fromJson reads through jget/jval/jid, never raw j[...]', () {
    final String src = File(
      'lib/assessment/domain/models.dart',
    ).readAsStringSync();

    // Each `factory X.fromJson(...)` body, up to the next member.
    final RegExp factories = RegExp(
      r"factory (\w+)\.fromJson\(Map<String, dynamic> j\)"
      r"(.*?)(?=\n  (?:factory|static|Map<String)|\n\}\n)",
      dotAll: true,
    );
    final RegExp rawRead = RegExp(r"j\['(\w+)'\]");

    final Map<String, List<String>> offenders = <String, List<String>>{};
    for (final RegExpMatch m in factories.allMatches(src)) {
      final String cls = m.group(1)!;
      final String body = m.group(2)!;
      final List<String> keys =
          rawRead
              .allMatches(body)
              .map((RegExpMatch k) => k.group(1)!)
              .toSet()
              .toList()
            ..sort();
      if (keys.isNotEmpty) offenders[cls] = keys;
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These parsers read raw JSON keys and will throw on the wire, '
          'hanging the loader. Use jget/jval/jid instead: $offenders',
    );
  });

  test('a double field is never given an int fallback', () {
    // `jval` keys off the FALLBACK's runtime type: an int fallback sends the
    // value through `toInt()`, so 0.15208 becomes 0. That silently zeroed
    // every cost on the LLM budget screen, and would do the same to a
    // fractional subjective score.
    //
    // Declared-double fields must therefore use a double literal (0.0), not 0.
    final File f = File('lib/assessment/domain/models.dart');
    final List<String> lines = f.readAsLinesSync();

    // Scope each field to its OWN class. Two classes can name a field `score`
    // and mean different things - Response.score counts whole COMPONENTS and
    // is an int, while Rubric.score is a fractional double. A flat name set
    // conflates them and reports a false positive.
    final Map<String, Set<String>> doublesByClass = <String, Set<String>>{};
    String cls = '';
    for (final String line in lines) {
      final RegExpMatch? c = RegExp(
        r'^(?:abstract\s+)?class\s+(\w+)',
      ).firstMatch(line);
      if (c != null) cls = c.group(1)!;
      final RegExpMatch? m = RegExp(
        r'^\s+final double\??\s+(\w+);',
      ).firstMatch(line);
      if (m != null) {
        (doublesByClass[cls] ??= <String>{}).add(m.group(1)!);
      }
    }

    final List<String> offenders = <String>[];
    String inClass = '';
    for (int i = 0; i < lines.length; i++) {
      final RegExpMatch? c = RegExp(
        r'^(?:abstract\s+)?class\s+(\w+)',
      ).firstMatch(lines[i]);
      if (c != null) inClass = c.group(1)!;
      final RegExpMatch? m = RegExp(
        r"(\w+):\s*jval(?:<[^>]+>)?\([^,]+,\s*'\w+',\s*([^),]+)\)",
      ).firstMatch(lines[i]);
      if (m == null) continue;
      final String field = m.group(1)!;
      final String fallback = m.group(2)!.trim();
      final bool isDouble = (doublesByClass[inClass] ?? <String>{}).contains(
        field,
      );
      if (isDouble && !fallback.contains('.')) {
        offenders.add(
          'models.dart:${i + 1}  $inClass.$field  '
          'fallback=$fallback',
        );
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'these double fields truncate to 0 on the wire. Use a double '
          'literal fallback (0.0):\n${offenders.join('\n')}',
    );
  });
}
