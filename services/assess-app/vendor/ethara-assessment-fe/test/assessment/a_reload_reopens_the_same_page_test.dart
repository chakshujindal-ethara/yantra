// A reload reopens the page, and the tab, it was on.
//
// The owner's report, from production: on an assessment's Candidates tab the
// address bar showed only the host, so Reload landed on the Dashboard and going
// back to the assessment opened Configuration. `every_page_has_an_address_test`
// pins the mapping; this pins the SECTION using it - restoring a URL on mount,
// writing one on every move (a push for a new page or tab, a replace for a
// filter), and answering the browser's Back and Forward - through a fake
// address bar, so nothing here touches a real `window`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/assessment_section.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/route_url.dart';
import 'package:ethara_assessment/assessment/screens/admin/bank_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/controls.dart';

/// An address bar a test can load a URL into and read back.
class _FakeUrlBar extends UrlBar {
  _FakeUrlBar(String? start) : _start = start == null ? null : Uri.parse(start);

  final Uri? _start;

  /// Every write, in order: (url, pushed?).
  final List<(String, bool)> writes = <(String, bool)>[];
  void Function(Uri)? _onPop;

  @override
  Uri? get current => _start;

  @override
  void write(String url, {required bool push}) => writes.add((url, push));

  @override
  VoidCallback listen(void Function(Uri url) onPop) {
    _onPop = onPop;
    return () => _onPop = null;
  }

  /// The browser's Back or Forward landing on [url].
  void pop(String url) => _onPop!(Uri.parse('https://h$url'));
}

void main() {
  Future<(AssessmentNav, _FakeUrlBar)> pumpAt(
    WidgetTester tester,
    String? url, {
    Portal portal = Portal.admin,
    String? examToken,
  }) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Seed mode: no ApiClient, so the fixtures are the data.
    final AppStore store = AppStore()..portal = portal;
    addTearDown(store.dispose);
    final _FakeUrlBar bar = _FakeUrlBar(url);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AssessmentSection(
            store: store,
            // What `AppShell` passes: the role's home, for when the URL
            // names nothing this role may open.
            entry: portal == Portal.admin
                ? AssessmentEntry.analytics
                : AssessmentEntry.mine,
            examToken: examToken,
            url: bar,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    // Detail screens run watch timers; unmount so none outlives the test.
    addTearDown(() => tester.pumpWidget(const SizedBox()));

    final AssessmentNav nav = tester
        .widget<AssessmentNavScope>(find.byType(AssessmentNavScope))
        .notifier!;
    return (nav, bar);
  }

  /// The active tab of the strip that holds [key] - the page's own strip, not
  /// the history dock's.
  String activeTabOf(WidgetTester tester, String key) => tester
      .widget<TabStrip>(
        find.byWidgetPredicate(
          (Widget w) => w is TabStrip && w.tabs.any((TabDef d) => d.key == key),
        ),
      )
      .active;

  testWidgets('an assessment reloads on its Candidates tab, filter and all', (
    WidgetTester tester,
  ) async {
    final (AssessmentNav nav, _FakeUrlBar bar) = await pumpAt(
      tester,
      '/assessments/A-1/candidates?state=not_started',
    );

    expect(nav.current, const AssessmentDetail('A-1', tab: 'candidates'));
    expect(nav.query['state'], 'not_started');
    expect(activeTabOf(tester, 'candidates'), 'candidates');
    // Restoring is not a move: the first write REPLACES, and says the same.
    expect(bar.writes.first, (
      '/assessments/A-1/candidates?state=not_started',
      false,
    ));
    expect(bar.writes.where(((String, bool) w) => w.$2), isEmpty);
  });

  testWidgets("a generator reloads on its Drafts tab", (
    WidgetTester tester,
  ) async {
    final (AssessmentNav nav, _FakeUrlBar bar) = await pumpAt(
      tester,
      '/generators/GEN-1/drafts',
    );

    expect(nav.current, const GeneratorDetail('GEN-1', tab: 'drafts'));
    expect(activeTabOf(tester, 'drafts'), 'drafts');
    expect(bar.writes.last, ('/generators/GEN-1/drafts', false));
  });

  testWidgets('a tab is pushed, and browser Back and Forward walk it', (
    WidgetTester tester,
  ) async {
    final (AssessmentNav nav, _FakeUrlBar bar) = await pumpAt(
      tester,
      '/assessments/A-1',
    );
    expect(activeTabOf(tester, 'candidates'), 'config');

    await tester.tap(find.text('Candidates').first);
    await tester.pump();
    await tester.pump();
    expect(nav.current, const AssessmentDetail('A-1', tab: 'candidates'));
    expect(bar.writes.last, ('/assessments/A-1/candidates', true));
    expect(activeTabOf(tester, 'candidates'), 'candidates');

    final int before = bar.writes.length;
    bar.pop('/assessments/A-1');
    await tester.pump();
    expect(nav.current, const AssessmentDetail('A-1'));
    expect(activeTabOf(tester, 'candidates'), 'config');
    // The browser already moved; answering it must not push another entry.
    expect(
      bar.writes.skip(before).where(((String, bool) w) => w.$2),
      isEmpty,
    );

    bar.pop('/assessments/A-1/candidates');
    await tester.pump();
    await tester.pump();
    expect(nav.current, const AssessmentDetail('A-1', tab: 'candidates'));
    expect(activeTabOf(tester, 'candidates'), 'candidates');
  });

  testWidgets('a search replaces the entry instead of adding one', (
    WidgetTester tester,
  ) async {
    final (AssessmentNav _, _FakeUrlBar bar) = await pumpAt(tester, '/bank');

    await tester.enterText(
      find.descendant(
        of: find.byType(BankScreen),
        matching: find.byType(TextField),
      ),
      'sql',
    );
    await tester.pump();
    expect(bar.writes.last, ('/bank?q=sql', false));
    expect(bar.writes.where(((String, bool) w) => w.$2), isEmpty);
    await tester.pump(const Duration(milliseconds: 300)); // the debounce
  });

  testWidgets('a restored search is back in the box', (
    WidgetTester tester,
  ) async {
    await pumpAt(tester, '/bank?q=sql');
    expect(
      find.descendant(
        of: find.byType(BankScreen),
        matching: find.widgetWithText(TextField, 'sql'),
      ),
      findsOneWidget,
    );
  });

  testWidgets("an unknown path opens the role's home and says so", (
    WidgetTester tester,
  ) async {
    final (AssessmentNav nav, _FakeUrlBar bar) = await pumpAt(tester, '/nope');
    expect(nav.current, const Analytics());
    expect(bar.writes.first, ('/dashboard', false));
  });

  testWidgets('a candidate cannot restore an operator page', (
    WidgetTester tester,
  ) async {
    final (AssessmentNav nav, _FakeUrlBar bar) = await pumpAt(
      tester,
      '/generators',
      portal: Portal.member,
    );
    expect(nav.current, const MyAssessments());
    expect(bar.writes.first, ('/my-assessments', false));
  });

  testWidgets('the invitation link still opens the exam', (
    WidgetTester tester,
  ) async {
    final (AssessmentNav nav, _FakeUrlBar bar) = await pumpAt(
      tester,
      '/exam/tok-1',
      portal: Portal.member,
      examToken: 'tok-1',
    );
    expect(nav.current, const Exam('tok-1'));
    expect(bar.writes.first, ('/exam/tok-1', false));
  });

  testWidgets('Back with a dialog open closes the dialog, not the page', (
    WidgetTester tester,
  ) async {
    final (AssessmentNav nav, _FakeUrlBar bar) = await pumpAt(tester, '/bank');
    showDialog<void>(
      context: tester.element(find.byType(BankScreen)),
      builder: (_) => const Text('a dialog'),
    );
    await tester.pumpAndSettle();
    expect(find.text('a dialog'), findsOneWidget);

    bar.pop('/dashboard');
    await tester.pumpAndSettle();
    expect(find.text('a dialog'), findsNothing);
    expect(nav.current, const QuestionBank());
    // The browser moved off the page's entry; it is put back.
    expect(bar.writes.last, ('/bank', true));
  });
}
