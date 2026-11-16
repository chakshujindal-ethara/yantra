// The shell has to fit the screen the invitation is opened on.
//
// THE BUG. The shell composed the rail and the page as a plain Row with a
// hard-coded 224px rail - no LayoutBuilder, no MediaQuery, and no use of the
// `Layout` breakpoints that already exist. The rail is dropped only mid-sitting
// by `_examIsLocked`, which covers the question/review/answers stages and not
// My Assessments, My Performance or the completion card. At 375px the rail took
// 224 and left 151 for the page it is a rail FOR - and the invitation now lands
// every candidate on the app front door, so My Assessments is the first screen
// they see.
//
// Below `Layout.headerStack` the rail becomes a drawer: the same rows, one tap
// away, and the page gets the whole viewport. Above it, nothing changes.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/assessment_section.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/nav_entries.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// Stands in for `_Sidebar`: what matters here is where the shell PUTS the
/// rail, not what the rail draws.
const Key kRail = Key('test-rail');

Future<AppStore> _open(WidgetTester t, Size size) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  final AppStore store = AppStore();
  store.portal = Portal.member;
  addTearDown(store.dispose);

  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentSection(
          store: store,
          entry: AssessmentEntry.mine,
          sidebarBuilder:
              (
                BuildContext context,
                List<NavEntry> entries,
                String activeKey,
                void Function(String) onOpen,
              ) => Container(
                key: kRail,
                width: 224,
                color: const Color(0xFF202020),
                child: Column(
                  children: <Widget>[
                    for (final NavEntry e in entries)
                      TextButton(
                        onPressed: () => onOpen(e.key),
                        child: Text(e.label),
                      ),
                  ],
                ),
              ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  return store;
}

void main() {
  testWidgets('on a phone the rail is a drawer, not a 224px slice', (
    WidgetTester t,
  ) async {
    await _open(t, const Size(375, 812));

    expect(
      find.byKey(kRail),
      findsNothing,
      reason: 'a 375px viewport cannot spare 224 of them for navigation',
    );
    expect(find.byIcon(Icons.menu), findsOneWidget);
    expect(t.takeException(), isNull);

    await t.tap(find.byIcon(Icons.menu));
    await t.pumpAndSettle();
    expect(
      find.byKey(kRail),
      findsOneWidget,
      reason: 'the rows are one tap away, not gone',
    );
  });

  testWidgets('opening a destination closes the drawer behind it', (
    WidgetTester t,
  ) async {
    await _open(t, const Size(375, 812));
    await t.tap(find.byIcon(Icons.menu));
    await t.pumpAndSettle();

    await t.tap(find.text('My Performance'));
    await t.pumpAndSettle();

    expect(
      find.byKey(kRail),
      findsNothing,
      reason: 'a drawer left open covers the page it just opened',
    );
  });

  testWidgets('on a laptop nothing changes', (WidgetTester t) async {
    await _open(t, const Size(1400, 900));

    expect(find.byKey(kRail), findsOneWidget);
    expect(
      find.byIcon(Icons.menu),
      findsNothing,
      reason: 'the rail is on screen; a button to open it would be a second '
          'way to the same rows',
    );
    expect(t.takeException(), isNull);
  });
}
