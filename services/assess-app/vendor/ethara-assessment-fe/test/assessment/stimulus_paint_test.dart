import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/exam/stimulus.dart';

const String _png =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA'
    'C0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

void main() {
  testWidgets('an inline data URL paints an Image, not the empty state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: StimulusArt(
              asset: Asset.fromJson(const <String, dynamic>{
                'slot': 'single',
                'label': 'Shot',
                'data': _png,
              }),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byType(Image),
      findsOneWidget,
      reason: 'a data: URL must be decoded and painted',
    );
    expect(find.byType(MissingStimulus), findsNothing);
  });
}
