@TestOn('vm')

/// Both halves of every conditional import must exist on disk.
///
/// THE DEFECT, AND WHY NOTHING CAUGHT IT. Four files spelled the web half of
/// their file-picker import with one `../` too many, resolving to a
/// `services/` directory at the REPO ROOT that has never existed. Dart does
/// not treat a missing conditional-import URI as an error - it falls back to
/// the default one - so `dart analyze` stayed clean, the web build succeeded,
/// and those screens silently compiled against `file_pick_stub.dart`, whose
/// `pickFile` is `async => null`. On web the file chooser simply never opened:
/// the Import sheet, both generator uploads and the two Form Studio uploads
/// were dead, with nothing anywhere reporting a fault.
///
/// A wrong path that still compiles cannot be caught by the compiler, so it
/// has to be caught here.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `import 'a.dart' if (dart.library.x) 'b.dart';` - both URIs, and the
/// condition, across a directive that is almost always split over two lines.
final RegExp _conditional = RegExp(
  r"""import\s+'([^']+\.dart)'\s*if\s*\(([\w.]+)\)\s*'([^']+\.dart)'""",
  multiLine: true,
);

void main() {
  test('every conditional import resolves on BOTH branches', () {
    final List<File> sources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'))
        .toList();
    expect(sources, isNotEmpty, reason: 'no sources scanned - wrong cwd?');

    final List<String> broken = <String>[];
    int checked = 0;

    for (final File f in sources) {
      final String src = f.readAsStringSync().replaceAll('\n', ' ');
      for (final RegExpMatch m in _conditional.allMatches(src)) {
        checked++;
        final String dir = f.parent.path;
        for (final String uri in <String>[m.group(1)!, m.group(3)!]) {
          // package: and dart: URIs are the analyzer's job, not ours.
          if (uri.contains(':')) continue;
          final String resolved = File('$dir/$uri').absolute.path;
          if (!File(resolved).existsSync()) {
            broken.add('${f.path}: "$uri" does not exist');
          }
        }
      }
    }

    expect(checked, greaterThan(0), reason: 'the regex matched nothing');
    expect(broken, isEmpty, reason: broken.join('\n'));
  });

  test('the stub and the web picker still agree on their API', () {
    // The fallback is only SAFE because the two sides match. If they drift,
    // a wrong path becomes a compile error instead of a silent no-op - which
    // would be an improvement, but the test above should be what tells us.
    for (final String p in <String>[
      'lib/services/file_pick_stub.dart',
      'lib/services/file_pick_web.dart',
    ]) {
      expect(File(p).existsSync(), isTrue, reason: '$p is missing');
      expect(
        File(p).readAsStringSync(),
        contains('pickFile({String accept'),
        reason: '$p no longer declares pickFile with the shared signature',
      );
    }
  });
}
