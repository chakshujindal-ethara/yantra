@TestOn('vm')
library;

// Every route that carries a field declares its own equality.
//
// WHY A SOURCE SCAN AND NOT A LIST. `history_nav_test.dart` pins nine route
// pairs by hand and its docstring claimed that stopped the next route shipping
// without `==`. It cannot: a tenth class is simply absent from the list, which
// is exactly how `FormDesigner` shipped. A hand-written list can only ever
// cover the mistakes somebody already thought of.
//
// WHAT IT COSTS TO FORGET. `AssessmentRoute` compares on `runtimeType` alone,
// so a subclass that adds fields and no `operator ==` makes every instance of
// itself equal to every other. `AssessmentNav.go` drops a route equal to the
// current one, so navigating between two of them does nothing at all - no
// error, no log, the screen simply does not change.
//
// The repo already scans its own source this way; see kpi_tone_test.dart and
// raw_is_a_decimal_test.dart. `@TestOn('vm')` for the same reason they carry it:
// a browser has no filesystem.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Class bodies in nav.dart, by name, for classes extending AssessmentRoute.
Map<String, String> _routeBodies() {
  final String src = File('lib/assessment/nav.dart').readAsStringSync();
  final RegExp decl = RegExp(
    r'class\s+(\w+)\s+extends\s+AssessmentRoute\s*\{',
    multiLine: true,
  );
  final Map<String, String> bodies = <String, String>{};
  for (final RegExpMatch m in decl.allMatches(src)) {
    // Walk braces from the opening one so a nested `{}` cannot end the body
    // early - a naive "next }" match stops inside the first method.
    int depth = 0;
    final int start = m.end - 1;
    for (int i = start; i < src.length; i++) {
      if (src[i] == '{') depth++;
      if (src[i] == '}') {
        depth--;
        if (depth == 0) {
          bodies[m.group(1)!] = src.substring(start + 1, i);
          break;
        }
      }
    }
  }
  return bodies;
}

void main() {
  test('the scan finds the routes at all', () {
    // A regex that silently matches nothing would make every assertion below
    // vacuous, which is the failure mode this whole file exists to avoid.
    final Map<String, String> bodies = _routeBodies();

    expect(bodies.length, greaterThan(15),
        reason: 'nav.dart declares ~24 routes; found ${bodies.length}');
    expect(bodies.keys, contains('FormDesigner'));
    expect(bodies.keys, contains('AssessmentsList'));
  });

  test('a route with fields declares == and hashCode', () {
    final Map<String, String> bodies = _routeBodies();
    final List<String> offenders = <String>[];

    bodies.forEach((String name, String body) {
      // `final <Type> <name>;` - an instance field. A `const` constructor
      // parameter alone is not one, and static members do not affect identity.
      final bool hasField =
          RegExp(r'^\s*final\s+[\w<>,\s?]+\s+\w+\s*;', multiLine: true)
              .hasMatch(body);
      if (!hasField) return;
      final bool hasEq = body.contains('operator ==');
      final bool hasHash = body.contains('get hashCode');
      if (!hasEq || !hasHash) offenders.add(name);
    });

    expect(
      offenders,
      isEmpty,
      reason: 'these routes carry fields but inherit runtimeType-only '
          'equality, so every instance compares equal to every other and '
          '`go()` silently refuses to navigate between them: $offenders',
    );
  });
}
