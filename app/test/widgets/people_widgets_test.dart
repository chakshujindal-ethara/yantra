import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/widgets/people.dart';
import 'package:yantra_app/core/widgets/portal_page.dart';

import '../screens/fixtures.dart';
import '../support/fake_backend.dart';

void main() {
  testWidgets('NameOf: the row\'s name, else the batched lookup, else the short id; the id is in the tooltip', (tester) async {
    final backend = FakeBackend({
      'GET /v1/claims/active': (_) => json(emptyActive),
      'GET /v1/batches': (_) => json([]),
      'GET /v1/people': (r) => json({
        'aaaaaaaa-1111': {'name': 'Asha Rao', 'kind': 'worker'},
      }),
    });
    await pumpApp(tester, backend);
    final page = tester.element(find.byType(PortalPage).first);
    showDialog<void>(
      context: page,
      builder: (_) => const Dialog(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            NameOf('bbbbbbbb-2222', name: 'Bina'),
            NameOf('aaaaaaaa-1111'),
            NameOf('cccccccc-3333'),
            ShortId('dddddddd-4444'),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    expect(find.text('Bina'), findsOneWidget);
    expect(find.text('Asha Rao'), findsOneWidget);
    expect(find.text('ccc-3333'), findsOneWidget);
    expect(find.text('ddd-4444'), findsOneWidget);
    expect(find.byTooltip('aaaaaaaa-1111'), findsOneWidget);
    final asked = backend.sent('GET', '/v1/people');
    expect(asked, hasLength(1));
    expect(asked.single.url.queryParameters['ids'], 'aaaaaaaa-1111,cccccccc-3333');

    // a screen reader hears the name alone when one is known; an unknown person is read by id
    final handle = tester.ensureSemantics();
    await tester.pump();
    final heard = tester.getSemantics(find.text('Bina')).label;
    expect(heard, startsWith('Bina\nAsha Rao\n'));
    expect(heard, isNot(contains('bbbbbbbb-2222')));
    expect(heard, isNot(contains('aaaaaaaa-1111')));
    expect(heard, contains('id cccccccc-3333'), reason: 'an unknown person is read by id');
    handle.dispose();
  });
}
