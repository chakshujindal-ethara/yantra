import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/errors.dart';
import 'package:yantra_app/core/theme/app_theme.dart';
import 'package:yantra_app/core/widgets/cards.dart';
import 'package:yantra_app/core/widgets/loader.dart';
import 'package:yantra_app/widgets/load_view.dart';

Widget host(Widget child) => MaterialApp(
  theme: AppTheme.light,
  home: Scaffold(body: child),
);

void main() {
  testWidgets('the first wait is skeleton rows by default and the brand loader when asked', (tester) async {
    final gate = Completer<int>();
    await tester.pumpWidget(host(LoadView<int>(load: () => gate.future, builder: (_, n, _) => Text('$n'))));
    expect(find.byType(Skeleton), findsOneWidget);
    expect(find.byType(BrandLoader), findsNothing);

    await tester.pumpWidget(host(LoadView<int>(firstWait: LoadWait.brand, load: () => gate.future, builder: (_, n, _) => Text('$n'))));
    expect(find.byType(BrandLoader), findsOneWidget);
    gate.complete(7);
    await tester.pumpAndSettle();
    expect(find.text('7'), findsOneWidget);
  });

  testWidgets('wrapInCard puts the error and the empty state in a card; emptyAction sits under the message', (tester) async {
    var fail = true;
    await tester.pumpWidget(
      host(
        LoadView<List<int>>(
          wrapInCard: true,
          load: () async => fail ? throw const TransportException('offline') : <int>[],
          isEmpty: (l) => l.isEmpty,
          emptyMessage: 'Nothing yet',
          emptyAction: const Text('Do this next'),
          builder: (_, l, _) => Text('${l.length}'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(PortalCard), matching: find.textContaining("Can't reach Yantra")), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(PortalCard), matching: find.text('Nothing yet')), findsOneWidget);
    expect(find.text('Do this next'), findsOneWidget);
  });

  testWidgets('without wrapInCard the error stands bare', (tester) async {
    await tester.pumpWidget(
      host(LoadView<int>(load: () async => throw const TransportException('offline'), builder: (_, n, _) => Text('$n'))),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining("Can't reach Yantra"), findsOneWidget);
    expect(find.byType(PortalCard), findsNothing);
  });
}
