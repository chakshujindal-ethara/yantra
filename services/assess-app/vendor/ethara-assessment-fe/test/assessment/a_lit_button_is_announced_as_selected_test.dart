// A lit toggle is announced as selected.
//
// `Btn.pressed` is `aria-pressed`: the candidates tiles, the bank's Archived
// and Deleted toggles, the review queue's generator chips. The accent tint was
// its only signal, so a screen reader heard every tile alike and could not
// tell which slice the table below was showing. The role and the disabled
// state were missing too: a `GestureDetector` announces neither.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/widgets/buttons.dart';

void main() {
  testWidgets('a pressed Btn is selected, an unpressed one is not', (
    WidgetTester t,
  ) async {
    final SemanticsHandle h = t.ensureSemantics();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: <Widget>[
              Btn('Lit', pressed: true, onPressed: () {}),
              Btn('Unlit', pressed: false, onPressed: () {}),
              Btn('Plain', onPressed: () {}),
              const Btn('Off'),
            ],
          ),
        ),
      ),
    );

    SemanticsNode node(String label) =>
        t.getSemantics(find.widgetWithText(Btn, label));

    expect(
      node('Lit'),
      isSemantics(
        label: 'Lit',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasSelectedState: true,
        isSelected: true,
        hasTapAction: true,
      ),
    );
    expect(
      node('Unlit'),
      isSemantics(
        label: 'Unlit',
        isButton: true,
        hasSelectedState: true,
        isSelected: false,
      ),
    );
    // Not a toggle at all: there is no selected state to announce.
    expect(
      node('Plain'),
      isSemantics(label: 'Plain', isButton: true, hasSelectedState: false),
    );
    // Disabled is announced, not only drawn at 42% opacity.
    expect(
      node('Off'),
      isSemantics(
        label: 'Off',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        hasTapAction: false,
      ),
    );
    h.dispose();
  });
}
