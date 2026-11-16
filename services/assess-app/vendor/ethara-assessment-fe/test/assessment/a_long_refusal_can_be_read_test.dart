// A REFUSAL THAT NAMES THE GATES HAS TO BE READABLE.
//
// `AppStore.launch` now spends what the gates already computed: instead of
// "some checks have not passed" it says `Launch blocked: <name> - <why>; ...`
// for every failing gate. Four gates is 439 characters - about seventy words.
// Two things then threw most of it away again:
//
//   TIME. `Toaster.show` armed a flat 3200ms timer, so the answer the operator
//   had asked for was on screen for 3.2 seconds. Seventy words in 3.2 seconds
//   is not a message, it is a flicker.
//
//   SPACE. `ToastLayer` was a `Positioned(left/right/bottom)`, which hands its
//   child an UNBOUNDED height. The bubble grew upward out of the top of the
//   Stack and was clipped with NO overflow exception to say so. At 390x700 a
//   six-gate refusal lost 48px off the top and a twelve-gate one lost 768px -
//   and the part that vanished was the head: `Launch blocked:` and the first
//   gate. At 1440x900 it fits, which is why nobody on a laptop saw it.
//
// Both halves have a negative control below: the old flat dwell and the old
// unbounded `Positioned` are reconstructed in-file and the same assertion is
// shown failing against them.
import 'dart:async';

import 'package:ethara_assessment/assessment/widgets/feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The real shape `AppStore.launch` builds: `Launch blocked: ` then
/// `<name> - <why>` per failing gate, joined with `; `.
String refusal(int gates) =>
    'Launch blocked: ${List<String>.generate(gates, (int i) => 'Gate ${i + 1} name goes here - the reason this one did not pass, '
        'spelled out the way the operator asked for').join('; ')}';

/// The reported case, to the character.
const String _fourGates =
    'Launch blocked: Generator has servable questions - No usable questions '
    'with their required media for the shape this paper asks for; Roster is '
    'not empty - No candidates have been added to this assessment yet; Pass '
    'mark is set - The pass mark is still at its default and has not been '
    'confirmed by anyone; Duration is set - No sitting length has been chosen '
    'for this paper, so the clock cannot start. Choose one on the Config tab before this ';

Widget host(Toaster toaster) => MaterialApp(
  home: Scaffold(
    body: Stack(
      children: <Widget>[const SizedBox.expand(), ToastLayer(toaster)],
    ),
  ),
);

/// The pre-fix layer, character for character, so the clipping it caused can be
/// measured rather than asserted from memory.
class _UnboundedLayer extends StatelessWidget {
  const _UnboundedLayer(this.toaster);

  final Toaster toaster;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    bottom: 18,
    child: IgnorePointer(
      child: ListenableBuilder(
        listenable: toaster,
        builder: (BuildContext context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: toaster.items
              .map(
                (ToastMsg m) => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 9,
                    ),
                    color: const Color(0xFF222222),
                    child: Text(m.message),
                  ),
                ),
              )
              .toList(),
        ),
      ),
    ),
  );
}

void main() {
  group('a long refusal is given time to be read', () {
    test('dwell scales with the message, with a floor and a ceiling', () {
      // THE FLOOR IS THE OLD CONSTANT, so nothing short starts lingering.
      expect(toastDwell('Saved'), const Duration(milliseconds: 3200));
      expect(
        toastDwell('Launched - 12 invitation(s) queued'),
        const Duration(milliseconds: 3200),
      );

      // Every acknowledgement this app actually writes is inside the floor -
      // the longest is 106 characters - so none of them changes at all.
      expect(
        toastDwell(
          'Keep at least one question. An empty shortlist means the '
          'whole generator, not an empty paper.',
        ),
        const Duration(milliseconds: 3200),
      );

      // The slope past it: 45ms a character.
      final String midway = 'x' * 240;
      expect(toastDwell(midway), const Duration(milliseconds: 3200 + 100 * 45));

      expect(_fourGates.length, 439, reason: 'the reported message');
      expect(
        toastDwell(_fourGates),
        greaterThan(const Duration(seconds: 15)),
        reason: 'seventy words need more than 3.2 seconds',
      );
      // AND A CEILING, so unbounded growth cannot strand a twelve-gate refusal
      // on screen for the best part of a minute. Past here the toast is read by
      // scrolling it and taken down by tapping it.
      expect(toastDwell(refusal(12)), const Duration(seconds: 20));
    });

    testWidgets('the long one is still up when the short one has gone', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final Toaster toaster = Toaster();
      toaster.bad(_fourGates);
      toaster.ok('Saved');

      await tester.pump(const Duration(milliseconds: 3300));
      expect(
        toaster.items.map((ToastMsg m) => m.message),
        <String>[_fourGates],
        reason:
            'the acknowledgement expires on the old clock; the refusal '
            'the operator asked for does not',
      );

      await tester.pump(const Duration(seconds: 21));
      expect(toaster.items, isEmpty, reason: 'and it does still expire');
    });

    testWidgets('NEGATIVE CONTROL: the flat 3200ms dwell loses it', (
      WidgetTester tester,
    ) async {
      // What `Toaster.show` did before: one constant for every message.
      await tester.pumpWidget(const SizedBox.shrink());
      final Toaster toaster = Toaster();
      final int id = toaster.busy(_fourGates);
      Timer(const Duration(milliseconds: 3200), () => toaster.dismiss(id));

      await tester.pump(const Duration(milliseconds: 3300));
      expect(toaster.items, isEmpty, reason: 'this is the pre-fix behaviour');
    });

    testWidgets('a toast can be dismissed by tapping it', (
      WidgetTester tester,
    ) async {
      // The counterweight to a twenty-second dwell: nobody has to wait it out.
      final Toaster toaster = Toaster();
      await tester.pumpWidget(host(toaster));
      toaster.bad(_fourGates);
      await tester.pump();
      expect(find.text(_fourGates), findsOneWidget);

      await tester.tap(find.text(_fourGates));
      await tester.pump();
      expect(toaster.items, isEmpty);

      await tester.pump(const Duration(seconds: 21));
    });
  });

  group('a long refusal is given room to be read', () {
    // The phone-width case from the report. 1440x900 fits and always did,
    // which is the whole reason this shipped.
    Future<Rect> place(
      WidgetTester tester,
      Widget layer,
      String message,
    ) async {
      tester.view.physicalSize = const Size(390, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(children: <Widget>[const SizedBox.expand(), layer]),
          ),
        ),
      );
      await tester.pump();
      return tester.getRect(find.text(message));
    }

    testWidgets('a refusal taller than the viewport keeps its head on screen', (
      WidgetTester tester,
    ) async {
      final Toaster toaster = Toaster();
      final String message = refusal(8);
      final int id = toaster.busy(message);
      final Rect r = await place(tester, ToastLayer(toaster), message);
      expect(
        r.top,
        greaterThanOrEqualTo(0.0),
        reason:
            'the first words - "Launch blocked:" and the first gate - used '
            'to be laid out ABOVE the top of the Stack and clipped away with '
            'no overflow exception to say so',
      );
      toaster.dismiss(id);
      await tester.pump();
    });

    testWidgets('and what will not fit is scrollable, not discarded', (
      WidgetTester tester,
    ) async {
      final Toaster toaster = Toaster();
      final String message = refusal(12);
      final int id = toaster.busy(message);
      final Rect r = await place(tester, ToastLayer(toaster), message);
      expect(r.top, greaterThanOrEqualTo(0.0));

      final ScrollableState sc = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(ToastLayer),
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        sc.position.maxScrollExtent,
        greaterThan(0.0),
        reason: 'the tail is reachable - "truncate or scroll", never vanish',
      );
      toaster.dismiss(id);
      await tester.pump();
    });

    testWidgets('NEGATIVE CONTROL: the unbounded Positioned clips upward', (
      WidgetTester tester,
    ) async {
      final Toaster toaster = Toaster();
      final String message = refusal(8);
      final int id = toaster.busy(message);
      final Rect r = await place(tester, _UnboundedLayer(toaster), message);
      expect(
        r.top,
        lessThan(0.0),
        reason:
            'this is the pre-fix layout, and it reports no overflow while '
            'it does it',
      );
      toaster.dismiss(id);
      await tester.pump();
    });
  });
}
