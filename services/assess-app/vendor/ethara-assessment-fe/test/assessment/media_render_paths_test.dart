// EVERY NETWORK IMAGE PATH DECIDES HEADERS AND STRATEGY PER ORIGIN, or says
// in writing why it does not.
//
// THE DEFECT THIS EXISTS FOR, and it shipped. The per-origin rule was written
// once and applied to two of the app's three `Image.network` call sites. The
// one missed was `StimulusArt` (`stimulus.dart`), which is what `StimulusPlate`
// draws - so it is every A/B comparison plate, the review queue and the
// question editor. It kept `headers: mediaAuthHeaders` unconditionally and set
// no `webHtmlElementStrategy` at all, which is the pre-fix code verbatim: a
// non-empty headers map disables the `<img>` element path
// (`containsNetworkImageHeaders` routes to `loadViaDecode()`), and the XHR that
// remains needs the far host to send `Access-Control-Allow-Origin`, which
// almost no image host does. A pasted third-party URL therefore still drew a
// dead plate on exactly the screens a candidate sees, after the bug was
// reported fixed.
//
// WHY NO OTHER TEST COULD CATCH IT. `webHtmlElementStrategy` is INERT off-web -
// `_network_image_io.dart` stores the field and never reads it - so the whole VM
// suite passes with the argument missing entirely. `tool/corsprobe/run.sh`
// measures the mechanism in a real browser but on its own probe widget, so a
// missed CALL SITE is invisible to it too. The only way to catch "the rule was
// not applied here" is to read the source, which is what this does.
//
// SO THIS IS A SOURCE TEST, NOT A WIDGET TEST. It parses `lib/` and asserts
// every network-image construction either passes `webHtmlElementStrategy` or
// carries an opt-out comment naming why. A fourth render path cannot be added
// without answering the question.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The marker a call site uses to declare it has thought about this and is
/// deliberately staying on the byte-fetch default.
///
/// Spelled as a comment rather than an annotation because the exemption has to
/// carry a REASON a reader can weigh - `stimulusImageProvider` is exempt
/// because the annotation editor reads `.image` off the result, and under
/// `fallback` a cross-origin image resolves to a `WebImageInfo` whose `.image`
/// getter throws `UnsupportedError`. An annotation could not say that.
const String kOptOut = 'CORS-EXEMPT:';

/// A network-image construction: `Image.network(` or `NetworkImage(`.
///
/// `MemoryImage`, `Image.memory` and `Image.asset` are not network paths and
/// carry no CORS question, so they are not matched.
final RegExp _networkImage = RegExp(r'\b(?:Image\.network|NetworkImage)\s*\(');

/// One call site: where it is, its raw argument source, and that source with
/// comments stripped.
class _Site {
  _Site(this.path, this.line, this.args, this.code);

  final String path;
  final int line;

  /// Everything between the call's parens, comments included. The opt-out
  /// marker lives in a comment, so it is searched here.
  final String args;

  /// The same span with comments removed. Every argument check reads THIS, so
  /// a name that appears only in prose cannot satisfy it - a comment saying
  /// "gate this on isOurMediaOrigin one day" must not pass for having done it.
  final String code;

  String get where => '$path:$line';
}

/// The span between the call's parens, found by counting parens while skipping
/// anything where a paren is not a paren.
///
/// THREE THINGS HAVE TO BE SKIPPED, and each one bit a draft of this test:
///
///   * STRINGS, and INTERPOLATION INSIDE THEM. A `\${...}` hole re-enters code,
///     so a nested quote there is a new string, not the end of the outer one:
///     `'\$a\${a.contains('?') ? '&' : '?'}'` closed at the inner `'?'` under a
///     naive scanner, and the `)` that followed then closed the whole call -
///     hiding every argument after it and reporting a correctly-fixed call site
///     as broken. Interpolation depth is tracked so those quotes nest properly.
///   * LINE COMMENTS, because the comments in these calls are prose with
///     apostrophes in them ("Flutter's image cache"), and an apostrophe read as
///     a string open swallows the rest of the call. That is what made this test
///     report a correctly-fixed call site as broken.
///   * BLOCK COMMENTS, for the same reason, pre-emptively.
///
/// Returns (rawSpan, codeSpan): the same text with and without its comments.
(String, String) _spanOf(String src, int start) {
  final int open = src.indexOf('(', start);
  if (open < 0) return ('', '');

  final StringBuffer code = StringBuffer();
  int depth = 0;
  // The string-quote stack. An interpolation hole inside a string can open
  // another string, so this nests rather than being a single nullable.
  final List<String> quotes = <String>[];
  // Open `\${` holes, per enclosing string. While one is open we are back in
  // CODE, so quotes and parens count again.
  final List<int> holes = <int>[];

  bool inString() => quotes.isNotEmpty && (holes.isEmpty || holes.last == 0);

  for (int i = open; i < src.length; i++) {
    final String c = src[i];
    final String next = i + 1 < src.length ? src[i + 1] : '';

    if (inString()) {
      // A backslash escapes the next character, so an escaped quote does not
      // close the string.
      if (c == '\\') {
        code.write(src.substring(i, i + 2 <= src.length ? i + 2 : i + 1));
        i++;
        continue;
      }
      // `\${` re-enters code inside the string.
      if (c == '\$' && next == '{') {
        if (holes.isEmpty) {
          holes.add(1);
        } else {
          holes[holes.length - 1] = holes.last + 1;
        }
        code.write('\${');
        i++;
        continue;
      }
      if (c == quotes.last) {
        quotes.removeLast();
        if (holes.isNotEmpty) holes.removeLast();
      }
      code.write(c);
      continue;
    }

    // Inside a `\${...}` hole: a closing brace may end it.
    if (holes.isNotEmpty && holes.last > 0 && c == '}') {
      holes[holes.length - 1] = holes.last - 1;
      code.write(c);
      continue;
    }

    if (c == '/' && next == '/') {
      final int eol = src.indexOf('\n', i);
      if (eol < 0) break;
      i = eol - 1;
      continue;
    }
    if (c == '/' && next == '*') {
      final int end = src.indexOf('*/', i + 2);
      if (end < 0) break;
      i = end + 1;
      continue;
    }

    if (c == "'" || c == '"') {
      quotes.add(c);
      holes.add(0);
      code.write(c);
      continue;
    }

    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) {
        return (src.substring(open + 1, i), code.toString());
      }
    }
    code.write(c);
  }

  // Unbalanced source would not compile, so this is unreachable in practice;
  // returning the tail keeps the walker from throwing if it ever happens.
  return (src.substring(open + 1), code.toString());
}

/// Every network-image call site under `lib/`.
List<_Site> _sites() {
  final List<File> sources = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .toList();
  expect(sources, isNotEmpty, reason: 'no sources scanned - wrong cwd?');

  final List<_Site> out = <_Site>[];
  for (final File f in sources) {
    final String src = f.readAsStringSync();
    for (final RegExpMatch m in _networkImage.allMatches(src)) {
      // A mention inside a comment or a doc comment is prose, not a call.
      final int lineStart = src.lastIndexOf('\n', m.start) + 1;
      final String before = src.substring(lineStart, m.start);
      if (before.trimLeft().startsWith('//')) continue;

      final int line = src.substring(0, m.start).split('\n').length;
      final (String args, String code) = _spanOf(src, m.start);
      out.add(_Site(f.path, line, args, code));
    }
  }
  return out;
}

void main() {
  test('the walker still finds the known network-image call sites', () {
    final List<_Site> sites = _sites();
    // A GUARD ON THE GUARD. If the matcher silently stopped matching, every
    // assertion below would pass vacuously and the regression would be
    // invisible for a second time. Three at the time of writing: two in
    // stimulus.dart (StimulusArt, stimulusImage) and one in
    // form_item_editor.dart, plus the exempt provider.
    expect(
      sites.length,
      greaterThanOrEqualTo(3),
      reason: 'the walker found ${sites.length} network-image call sites, '
          'fewer than the known set - the matcher has probably stopped '
          'matching rather than the call sites having gone away',
    );

    // And the span extraction still works: a call site whose args came back
    // near-empty means the scanner bailed early, which is how a fixed call
    // site gets reported as broken.
    for (final _Site s in sites) {
      expect(s.code.length, greaterThan(20),
          reason: '${s.where}: extracted only ${s.code.length} characters of '
              'arguments, so the paren scanner bailed early');
    }
  });

  test('every network image sets webHtmlElementStrategy, or opts out by name',
      () {
    final List<String> silent = <String>[];

    for (final _Site s in _sites()) {
      if (s.code.contains('webHtmlElementStrategy')) continue;
      if (s.args.contains(kOptOut)) continue;
      silent.add(s.where);
    }

    expect(
      silent,
      isEmpty,
      reason: 'These network-image call sites neither set '
          'webHtmlElementStrategy nor carry a "$kOptOut" comment saying why '
          'not. Flutter defaults to WebHtmlElementStrategy.never, which '
          'XHR-fetches the bytes - so on a host that sends no '
          'Access-Control-Allow-Origin they render NOTHING, even though a '
          'plain <img> would have displayed the image. Pass '
          'WebHtmlElementStrategy.fallback for third-party origins (see '
          'stimulusImage in stimulus.dart), or add a "$kOptOut <reason>" '
          'comment inside the call:\n  ${silent.join('\n  ')}',
    );
  });

  test('a bearer is never sent unconditionally to a third-party host', () {
    // THE HEADER IS HALF THE BUG, and the more damaging half: a non-empty
    // `headers` map disables the `<img>` path outright, so a call site can pass
    // `fallback` and still fail if it hands the token to every host. An
    // unconditional `headers: mediaAuthHeaders` is the exact shape that
    // shipped, so it is named as a failure rather than left to review.
    final List<String> unconditional = <String>[];

    for (final _Site s in _sites()) {
      if (!s.code.contains('mediaAuthHeaders')) continue;
      if (s.args.contains(kOptOut)) continue;
      // Guarded by SOMETHING. `isOurMediaOrigin` is the intended test and the
      // one to look for; a bare `?` is accepted so a future call site may guard
      // differently without this test dictating its spelling.
      final bool guarded =
          s.code.contains('isOurMediaOrigin') || s.code.contains('?');
      if (!guarded) unconditional.add(s.where);
    }

    expect(
      unconditional,
      isEmpty,
      reason: 'These call sites attach mediaAuthHeaders to EVERY origin. Our '
          'own auth="user" proxies need the bearer, but sending it to a '
          "third-party CDN forces Flutter's byte-fetch path and disables the "
          '<img> element path, so the picture cannot render at all - a browser '
          'needs CORS to READ an image, not to SHOW one. Gate it on '
          'isOurMediaOrigin(resolvedUrl):\n  ${unconditional.join('\n  ')}',
    );
  });

  test('the two stimulus paths agree with each other', () {
    // `StimulusArt` and `stimulusImage` both put a stimulus URL on screen and
    // must make the SAME decision. They drifted once - the fix was applied to
    // the second and not the first - and the screens that broke were the ones
    // only the first one draws.
    final List<_Site> here = _sites()
        .where((_Site s) => s.path.endsWith('stimulus.dart'))
        .where((_Site s) => !s.args.contains(kOptOut))
        .toList();

    expect(here.length, 2,
        reason: 'expected exactly two non-exempt network-image paths in '
            'stimulus.dart (StimulusArt and stimulusImage); found '
            '${here.length} at ${here.map((_Site s) => s.where).toList()}');

    // BOTH BRANCHES, IN THE CALL ITSELF. The origin test is computed on the
    // line above (`final bool ours = isOurMediaOrigin(resolved);`) and used as
    // a ternary inside the call, so what is asserted here is that BOTH outcomes
    // are present - a call site that names only one branch has hard-coded it.
    for (final _Site s in here) {
      expect(s.code, contains('WebHtmlElementStrategy.fallback'),
          reason: '${s.where} never reaches the <img> fallback, so a '
              'third-party host with no CORS headers cannot render there.');
      expect(s.code, contains('WebHtmlElementStrategy.never'),
          reason: '${s.where} must keep our OWN origin on the byte path, '
              'where the bearer works and the proxies need it.');
      expect(s.code, contains('mediaAuthHeaders'),
          reason: '${s.where} sends no bearer at all, so our own auth="user" '
              'media proxies will answer 401.');
    }

    // And the origin test is what drives them. Asserted over the FILE rather
    // than the call span because `ours` is bound one line above each call; both
    // bindings must exist, one per path.
    final String src =
        File('lib/assessment/screens/exam/stimulus.dart').readAsStringSync();
    expect(
      RegExp(r'final bool ours = isOurMediaOrigin\(')
          .allMatches(src)
          .length,
      2,
      reason: 'stimulus.dart must derive `ours` from isOurMediaOrigin once per '
          'render path. Two paths, two bindings - if there is only one, a path '
          'is deciding by something other than origin.',
    );
  });
}
