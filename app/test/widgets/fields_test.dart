import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/format.dart';
import 'package:yantra_app/core/widgets/currency_field.dart';
import 'package:yantra_app/core/widgets/date_field.dart';

Widget host(Widget child) => MaterialApp(
  home: Scaffold(
    body: Form(autovalidateMode: AutovalidateMode.always, child: child),
  ),
);

void main() {
  test('parseDay reads a day as UTC midnight, empty as null, and names the field in its errors', () {
    expect(parseDay('2026-11-30'), DateTime.utc(2026, 11, 30));
    expect(parseDay('  '), isNull);
    expect(
      () => parseDay('30/11/2026', label: 'Until'),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('Until'))),
    );
    expect(
      () => parseDay('2026-02-30', label: 'Due'),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', 'Due is not a real date')),
    );
    expect(dayText(DateTime.utc(2026, 1, 5)), '2026-01-05');
    expect(dayText(null), '');
  });

  testWidgets('DateField validates what is typed and fills the box from the calendar', (tester) async {
    final c = TextEditingController();
    await tester.pumpWidget(
      host(DateField(controller: c, label: 'Until', fieldKey: const Key('f'), pickKey: const Key('p'), optional: false)),
    );
    await tester.pump();
    expect(find.text('Until is required'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('f')), '2026-13-01');
    await tester.pump();
    expect(find.text('Until is not a real date'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('f')), '');
    await tester.tap(find.byKey(const Key('p')));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(c.text), isTrue);
  });

  testWidgets('an optional DateField accepts empty; the calendar starts inside its bounds', (tester) async {
    final c = TextEditingController(text: '2020-01-01');
    final first = DateTime.now();
    await tester.pumpWidget(host(DateField(controller: c, label: 'Due', pickKey: const Key('p'), first: first)));
    await tester.pump();
    expect(find.text('Due (optional)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('p')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(c.text, '2020-01-01', reason: 'cancel keeps what was typed');
  });

  testWidgets('CurrencyField offers the four currencies and keeps an unknown one the record carries', (tester) async {
    String? picked;
    await tester.pumpWidget(host(CurrencyField(value: 'AED', onChanged: (c) => picked = c)));
    await tester.tap(find.text('AED'));
    await tester.pumpAndSettle();
    for (final c in [...supportedCurrencies, 'AED']) {
      expect(find.text(c), findsWidgets);
    }
    await tester.tap(find.text('USD').last);
    await tester.pumpAndSettle();
    expect(picked, 'USD');
  });

  testWidgets('a disabled CurrencyField cannot change', (tester) async {
    String? picked;
    await tester.pumpWidget(host(CurrencyField(value: '', enabled: false, onChanged: (c) => picked = c)));
    expect(find.text('INR'), findsOneWidget, reason: 'empty reads as the first currency');
    await tester.tap(find.text('INR'));
    await tester.pumpAndSettle();
    expect(picked, isNull);
  });
}
