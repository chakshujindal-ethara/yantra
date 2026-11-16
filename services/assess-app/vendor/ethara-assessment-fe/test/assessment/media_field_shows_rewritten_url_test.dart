// THE FIELD MUST SHOW WHAT THE MODEL HOLDS.
//
// THE DEFECT THIS PINS. Pasting a Google Drive share link rewrites it into a url
// that works (`_resolveShareLink` -> the server's import route), and the model was
// updated correctly - but `FormTextInput` handed its value to
// `TextFormField.initialValue`, which is read ONCE in `initState`. The widget key
// is the record id, stable across a value change, so the element was UPDATED and
// never remounted: the box went on showing the share page the examiner pasted
// while the item held the rewritten url.
//
// The whole suite passed throughout, because every existing test asserts the
// HELPER functions (`isImportableMediaSource`) or the model,
// and none of them asserts what the field actually displays. That gap is the
// reason the bug reached a human, so these tests deliberately go through the
// rendered widget rather than calling the helpers.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/widgets/controls.dart';

/// A host that owns a value and rebuilds its child on change, which is exactly
/// what `_mediaUrlRow` does - the field is handed `it.mediaUrl` on every build.
class _Host extends StatefulWidget {
  const _Host({required this.initial});
  final String initial;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late String _value = widget.initial;

  /// Stands in for the programmatic rewrite: a write the field did not author.
  void rewrite(String v) => setState(() => _value = v);

  @override
  Widget build(BuildContext context) => MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: FormTextInput(
            id: 'media-main-q1',
            value: _value,
            hint: 'Image URL (https://…)',
            onChanged: (String v) => setState(() => _value = v),
          ),
        ),
      );
}

void main() {
  const String shareLink =
      'https://drive.google.com/file/d/1dvYrRhY6NP9c--vg3_PSX4M5jG8E4kji/view';
  const String rewritten =
      'https://lh3.googleusercontent.com/d/1dvYrRhY6NP9c--vg3_PSX4M5jG8E4kji';

  testWidgets('a value the field did not author still reaches the box',
      (WidgetTester tester) async {
    await tester.pumpWidget(const _Host(initial: shareLink));
    expect(find.text(shareLink), findsOneWidget);

    // The rewrite lands on the model, the same way `_resolveShareLink` applies
    // it once the content-type probe answers.
    final _HostState host = tester.state<_HostState>(find.byType(_Host));
    host.rewrite(rewritten);
    await tester.pump();

    expect(find.text(rewritten), findsOneWidget,
        reason: 'the box must show the url the model now holds');
    expect(find.text(shareLink), findsNothing,
        reason: 'the pasted share page must be gone, not merely overlaid');
  });

  testWidgets('the caret lands at the end of a rewritten value',
      (WidgetTester tester) async {
    // A rewrite that left the selection where it was would put the caret in the
    // middle of a url the examiner never typed.
    await tester.pumpWidget(const _Host(initial: shareLink));
    tester.state<_HostState>(find.byType(_Host)).rewrite(rewritten);
    await tester.pump();

    final EditableText field = tester.widget<EditableText>(
      find.byType(EditableText),
    );
    expect(field.controller.selection.baseOffset, rewritten.length);
  });

  testWidgets('typing is not disturbed by the host rebuilding on every keystroke',
      (WidgetTester tester) async {
    // THE REGRESSION THE FIX COULD EASILY INTRODUCE. Syncing the controller
    // unconditionally on rebuild would reset the selection on every character,
    // because the host rebuilds with the value it just received from onChanged.
    await tester.pumpWidget(const _Host(initial: ''));
    await tester.enterText(find.byType(TextFormField), 'https://a.test/p.png');
    await tester.pump();

    final EditableText field = tester.widget<EditableText>(
      find.byType(EditableText),
    );
    expect(field.controller.text, 'https://a.test/p.png');
    expect(field.controller.selection.baseOffset, 'https://a.test/p.png'.length,
        reason: 'the caret must stay where the typist left it');
  });
}
