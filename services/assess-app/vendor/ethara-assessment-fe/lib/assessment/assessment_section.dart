// The assessment section: every screen in the product, under one widget.
//
// PORTED FROM THE HOST PORTAL, which used to supply the authenticated client.
// There is no host now, so the store is INJECTED by whoever builds the section
// - `AppShell` after sign-in, or a test with a seeded store. This widget owns
// only what is inside the content area: which assessment page is showing.
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'domain/enums.dart';
import 'domain/nav_entries.dart';
import 'nav.dart';
import 'route_url.dart';
import 'screens/account/account_screen.dart';
import 'screens/admin/assessment_detail_screen.dart';
import 'screens/admin/assessment_list_screen.dart';
import 'widgets/dock.dart';
import 'widgets/emails_panel.dart';
import 'widgets/chatter.dart';
import 'screens/admin/dashboard_screen.dart';
import 'screens/admin/form_designer_screen.dart';
import 'screens/admin/form_studio_screen.dart';
import 'screens/admin/start_here_screen.dart';
import 'screens/admin/attempt_detail_screen.dart';
import 'screens/admin/candidate_detail_screen.dart';
import 'screens/admin/bank_screen.dart';
import 'screens/admin/budget_screen.dart';
import 'screens/admin/generator_detail_screen.dart';
import 'screens/admin/generator_list_screen.dart';
import 'screens/admin/ledger_screen.dart';
import 'screens/admin/new_assessment_screen.dart';
import 'screens/admin/response_detail_screen.dart';
import 'screens/admin/responses_screen.dart';
import 'screens/admin/review_queue_screen.dart';
import 'screens/admin/settings_screen.dart';
import 'screens/admin/tags_screen.dart';
import 'screens/exam/exam_screen.dart';
import 'screens/member/my_assessments_screen.dart';
import 'screens/member/my_performance_screen.dart';
import 'domain/models.dart';
import 'state/app_store.dart';
import 'theme.dart';
import 'widgets/buttons.dart';
import 'widgets/controls.dart';
import 'widgets/feedback.dart';
import 'widgets/history_bar.dart';
import 'widgets/skeleton.dart';

/// Which screen the section opens on.
///
/// One per sidebar destination. The section owns an internal page stack, so
/// this only picks the ROOT - drilling from a list into a detail stays inside
/// the section and never touches the host shell's selection.
enum AssessmentEntry {
  console,
  startHere,
  analytics,
  mine,
  myPerformance,
  generators,
  questionBank,
  reviewQueue,
  responses,
  tags,
  budget,
  settings,
}

class AssessmentSection extends StatefulWidget {
  const AssessmentSection({
    super.key,
    required this.store,
    this.entry = AssessmentEntry.console,
    this.examToken,
    this.sidebarBuilder,
    this.url = const UrlBar(),
    this.onToggleTheme,
    this.isDark = true,
  });

  /// The shell's theme toggle, handed to the exam top bar while the rail (which
  /// normally carries it) is hidden for a sitting.
  final VoidCallback? onToggleTheme;
  final bool isDark;

  /// The address bar this section keeps in step with where it is.
  ///
  /// Read once on mount - a reload, or the path a signed-out visitor asked for
  /// before signing in - and outranks [entry] when it names a page this role
  /// may open. Written on every move after that. Inert unless the app passes
  /// the browser's; see [UrlBar].
  final UrlBar url;

  /// The store, already signed in. Injected rather than built here: owning the
  /// session is the shell's job, and taking it as a parameter is what lets the
  /// same section be mounted by the app, by a test, or by another host later.
  final AppStore store;

  final AssessmentEntry entry;

  /// An exam access token from the URL, when the app was opened by an
  /// invitation link (`/exam/<token>`).
  ///
  /// Takes precedence over [entry]: a candidate who followed an invite is here
  /// to sit that exam, not to browse.
  final String? examToken;

  /// Builds the left navigation rail, given the live nav state.
  ///
  /// The SHELL owns how the rail looks; this widget owns WHERE the app is.
  /// Passing the entries, the active key and the callback keeps both facts in
  /// one place - the shell cannot show a highlight that disagrees with the
  /// page, which is exactly what a duplicated route copy caused before.
  ///
  /// Null renders the section with no rail, which is what a test or an
  /// embedded host wants.
  final Widget Function(
    BuildContext context,
    List<NavEntry> entries,
    String activeKey,
    void Function(String key) onOpen,
  )?
  sidebarBuilder;

  @override
  State<AssessmentSection> createState() => _AssessmentSectionState();
}

class _AssessmentSectionState extends State<AssessmentSection> {
  late final AssessmentNav _nav = AssessmentNav();
  AppStore get _store => widget.store;

  @override
  void initState() {
    super.initState();

    _nav.addListener(_rebuild);
    _store.addListener(_rebuild);

    _openEntry();

    // After the entry, so the first write is a REPLACE that tidies whatever
    // was typed or linked (`/`, a trailing slash, an unknown path) into the
    // page actually shown.
    _nav.addListener(_writeUrl);
    _nav.onQueryChanged = _writeUrl;
    _stopListening = widget.url.listen(_onPop);
    _writeUrl();
  }

  // ── The address bar ─────────────────────────────────────────────────────

  VoidCallback? _stopListening;

  /// The URL last put in the address bar, or null before the first write.
  String? _written;

  /// True while a move must REPLACE the current entry rather than add one:
  /// answering the browser's own Back/Forward (the entry already exists), and
  /// re-seeding the trail when the role's entry changes.
  bool _replacing = false;

  /// Keep the address bar on the current page.
  ///
  /// A new PATH is a new history entry; a query-only change - a filter, a
  /// search term, a page number - rewrites the entry in place, so Back steps
  /// between pages rather than between keystrokes.
  void _writeUrl() {
    final Uri u = routeToUri(_nav.current, _nav.query);
    final String next = u.toString();
    final String? was = _written;
    if (next == was) return;
    _written = next;
    widget.url.write(
      next,
      push: !_replacing && was != null && Uri.parse(was).path != u.path,
    );
  }

  /// The browser moved Back or Forward to [uri]: show that page.
  void _onPop(Uri uri) {
    if (!mounted) return;
    // A DIALOG OPEN OVER THE PAGE: Back closes it, which is what it did before
    // the app owned the address bar, and the page stays put underneath - moving
    // it would leave the dialog floating over a screen it was never about (the
    // same guard `HistoryShortcuts` makes).
    //
    // A SITTING IN PROGRESS: Back is inert, as the rail and the shortcut are.
    // The browser has already moved, so the page's own entry is put back.
    final bool covered = ModalRoute.of(context)?.isCurrent == false;
    if (covered || _examIsLocked()) {
      if (covered) Navigator.of(context).maybePop();
      final String? here = _written;
      if (here != null) widget.url.write(here, push: true);
      return;
    }
    final RouteAt? at = _restorable(uri);
    final AssessmentRoute to = at?.route ?? _entryRoute();
    _replacing = true;
    try {
      _nav.setQuery(at?.query ?? const <String, String>{}, at: to);
      // Step the trail when the browser stepped onto its neighbour, so the
      // in-app arrows keep agreeing with the browser's; otherwise visit.
      if (to == _nav.previous) {
        _nav.back();
      } else if (to == _nav.next) {
        _nav.forward();
      } else {
        _nav.go(to);
      }
      // Same page, different query: nothing above notified.
      _writeUrl();
    } finally {
      _replacing = false;
    }
  }

  /// The page [uri] names, if this person may open it.
  RouteAt? _restorable(Uri? uri) {
    final RouteAt? at = uri == null ? null : routeFromUri(uri);
    return at != null && _mayOpen(at.route) ? at : null;
  }

  /// Whether a restored URL may open [r] for the signed-in role.
  ///
  /// A URL is typed, pasted or left over from somebody else's session, so it is
  /// checked against the role HERE rather than trusted: a candidate gets their
  /// own four pages, an operator never the candidate portal, and a Manager none
  /// of the authoring pages `_page` would refuse anyway. Anything else opens
  /// the role's home instead - with the URL rewritten to match.
  bool _mayOpen(AssessmentRoute r) {
    if (_store.portal == Portal.member) {
      return r is MyAssessments ||
          r is MyPerformance ||
          r is AccountSettings ||
          r is Exam;
    }
    if (r is MyAssessments || r is MyPerformance) return false;
    return !(_store.accessRole == AccessRole.manager &&
        _isAuthoringOrPlatform(r));
  }

  /// Point the internal navigator at this destination's root screen.
  ///
  /// Called from BOTH [initState] and [didUpdateWidget]. Switching sidebar
  /// items rebuilds the same `AssessmentSection` widget type at the same
  /// position, so Flutter REUSES this State: `initState` does not run again.
  /// When this lived only in `initState`, clicking Question bank left the
  /// route on whatever was opened first - the sidebar highlighted the new
  /// item and the breadcrumb changed, while the body still showed Generators.
  /// That is the "all have same data" report.
  void _openEntry() {
    // A deep link wins over the entry.
    //
    // An invited candidate arrives at `/exam/<token>` from the invitation
    // email, so the exam runner must be the FIRST screen - not their list with
    // the exam one click away. The token is the assessment's own key, the same
    // one the Odoo portal uses, so both front ends resolve one sitting.
    // `replaceRoot`, not `reset`: this is where a trail STARTS.
    //
    // `reset` is an ordinary history entry now, so seeding the section with it
    // would leave the navigator's initial placeholder sitting behind the first
    // real page - and Back on a freshly loaded app would go somewhere the user
    // had never been.
    //
    // This is also the ONE way into the exam with nothing behind it. `nav.go`
    // keeps the page an in-app entry came from, but a link out of an email has
    // no such page, so `canGoBack` stays false for the whole sitting - right
    // for the invited candidate, and the reason a staff member who pastes a
    // candidate's link finds the preview card's Back button inert where the
    // same preview opened from the attempt page works.
    final String? token = widget.examToken;
    final RouteAt? asked = _restorable(widget.url.current);
    if (token != null && token.isNotEmpty) {
      // `/exam/<token>/answers` reopens the released answer sheet; every other
      // form of the link opens the briefing, as it always has.
      final AssessmentRoute? r = asked?.route;
      _nav.replaceRoot(r is Exam && r.token == token ? r : Exam(token));
      return;
    }

    // THE ADDRESS BAR NEXT: a reload, or the page asked for before sign-in,
    // reopens that page - its tab in the path, its filters in the query.
    if (asked != null) {
      _nav.replaceRoot(asked.route);
      _nav.setQuery(asked.query);
      return;
    }

    _nav.replaceRoot(_entryRoute());
  }

  /// The root screen of [AssessmentSection.entry] - the role's home.
  ///
  /// `console` - the plain entry, with no destination asked for - lands on the
  /// DASHBOARD. It used to land on the assessment list, which answers "what
  /// papers exist" rather than "how is this going", and left the rail's first
  /// row unlit. The dashboard is the row an operator opens the console to
  /// read, so it is what the console opens on.
  AssessmentRoute _entryRoute() => switch (widget.entry) {
    AssessmentEntry.startHere => const StartHere(),
    AssessmentEntry.analytics => const Analytics(),
    AssessmentEntry.mine => const MyAssessments(),
    AssessmentEntry.myPerformance => const MyPerformance(),
    AssessmentEntry.generators => const GeneratorList(),
    AssessmentEntry.questionBank => const QuestionBank(),
    AssessmentEntry.reviewQueue => const ReviewQueue(),
    AssessmentEntry.responses => const ResponsesList(),
    AssessmentEntry.tags => const TagsAdmin(),
    AssessmentEntry.budget => const BudgetAdmin(),
    AssessmentEntry.settings => const SettingsAdmin(),
    AssessmentEntry.console => const Analytics(),
  };

  @override
  void didUpdateWidget(AssessmentSection old) {
    super.didUpdateWidget(old);
    // Only on a real change: resetting on every rebuild would throw away a
    // detail screen the user had drilled into.
    if (old.entry != widget.entry) {
      // A fresh trail, so a replace: Back must not return to a page the new
      // role's entry just superseded.
      _replacing = true;
      try {
        _openEntry();
      } finally {
        _replacing = false;
      }
    }
  }

  void _rebuild() {
    if (!mounted) return;
    // NOT MID-BUILD. A detail screen's `initState` marks its record hydrating
    // and the store notifies right then (`AppStore._withHydration`), inside
    // the build that created the screen. This widget is that screen's
    // ANCESTOR, and marking an ancestor dirty during a build asserts - on
    // every assessment opened through the section, and on every reload that
    // restores one. The frame finishes first; the rebuild follows it.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _rebuild());
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _stopListening?.call();
    _nav.onQueryChanged = null;
    _nav.removeListener(_writeUrl);
    _nav.removeListener(_rebuild);
    _store.removeListener(_rebuild);
    _nav.dispose();
    // The store is NOT disposed here: it is injected, so it belongs to
    // whoever built it. Disposing a borrowed object would kill the session the
    // moment this widget unmounted, and the shell would rebuild onto a dead
    // store.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The shell hands this widget the bare content area: no scroll, no
    // padding. Every other view supplies its own, and so must this one - a
    // page taller or wider than the viewport otherwise overflows instead of
    // scrolling, which is what pushed the KPI strip off the right edge.
    //
    // AssessmentNavScope must wrap the pages: every screen navigates with
    // `context.nav`, which reads this scope and ASSERTS when it is missing.
    // Without it the first button press inside any screen throws.
    // The SIDEBAR is built here, not in the shell.
    //
    // These sections were a horizontal TabStrip across the top of the content
    // area: nine tabs is a lot of chrome above every page, it truncated as the
    // window narrowed, and it left the sidebar showing a single row.
    //
    // Built from INSIDE the section because `_nav` lives here: handing the
    // shell a copy of the route state would create a second source of truth
    // that can disagree with the first, which is exactly the bug that made
    // the sidebar highlight one screen while the body showed another.
    final Widget content = AssessmentNavScope(
      nav: _nav,
      child: ToastHost(
        toaster: _store.toaster,
        // Over an exam, above its pinned footer (BR-D2): a refusal sat on top
        // of Previous and Review & Submit, the controls it was asking for.
        lift: _nav.current is Exam ? kExamFooterHeight : 0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (_store.loadState == LoadState.loading)
              const LinearProgressIndicator(minHeight: 2),
            // ABOVE the error banner, not below it.
            //
            // The banner is transient and full-width; the history pair is
            // permanent chrome. Ordered the other way, every server hiccup
            // would shove the two controls down the page and back again.
            //
            // Hidden inside the exam runner, which owns its own Previous and
            // Next over questions and moves through the server to do it. Two
            // pairs of arrows on one screen, each meaning something different,
            // is worse than none.
            //
            // Hidden, not emptied. `AssessmentNav.go` keeps the page the runner
            // was opened FROM, so the runner's own Back - `nav.back()` on the
            // preview card in `screens/exam/exam_screen.dart` - has somewhere
            // to land; it is the generic pair that is out of place here, not
            // the trail behind it.
            if (_nav.current is! Exam)
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: HistoryBar(nav: _nav),
                ),
              ),
            if (_store.loadState == LoadState.failed &&
                _store.loadError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 0),
                child: Notice(
                  strong: 'Could not load from the server.',
                  // Says so when the store is already retrying. Without it the
                  // banner reads as a dead end and the Retry button as the
                  // only way out, when in fact it clears itself.
                  text: _store.isReconnecting
                      ? '${_store.loadError!} Trying again automatically.'
                      : _store.loadError!,
                  tone: Tone.bad,
                  actions: <Widget>[
                    Btn('Retry', size: BtnSize.sm, onPressed: _store.refresh),
                  ],
                ),
              ),
            // THE EXAM RUNNER IS NOT SCROLLED BY THE SECTION.
            //
            // Every other screen here is a document: a page head and some
            // panels that grow downward, which is what the scroll view below
            // is for. The runner is not a document, it is a whole surface -
            // its own `Scaffold`, its own top bar with the timer and progress,
            // and its own inner scroll over the question
            // (`exam_screen.dart:434`, and `gate_screen.dart:56` for the dead
            // ends).
            //
            // A `Scaffold` has to know how tall it is, and a scroll view tells
            // its child it may be as tall as it likes. Nesting the two asks the
            // runner to be infinitely tall, and it throws
            // ("RenderCustomMultiChildLayoutBox was given an infinite size").
            //
            // That was live on the one path a candidate cannot avoid: an
            // invitation link is read at `main.dart:35` and arrives here as
            // `examToken`. It went unseen because every exam test mounts
            // `ExamScreen` straight as `MaterialApp.home`
            // (`exam_navigation_test.dart:190`), which hands it the screen's
            // height and satisfies the `Scaffold`; nothing came in through the
            // section, which is the only way the app comes in.
            //
            // Handing it the bare bounded box is the whole fix. Nothing else
            // changes: `_showListSkeleton` is already false on this route, so
            // the branch below never had anything else to give it.
            // The form designer also owns its own scrolling: its pinned header
            // (title, Add section, the Design/Preview tabs) stays put while
            // the sections scroll under it.
            if (_nav.current is Exam || _nav.current is FormDesigner)
              Expanded(child: _page())
            else
              Expanded(
                child: SingleChildScrollView(
                  // A NEW PAGE OPENS AT ITS TOP.
                  //
                  // One scroll view serves every route, and without a key
                  // Flutter reuses the same ScrollPosition across a
                  // navigation - so opening anything from a control low on a
                  // long page landed you at that same offset in the new
                  // screen, past its heading and its KPIs. From the dashboard
                  // leaderboard, which sits well below the fold, a candidate
                  // with several sittings opened somewhere in the middle of
                  // their own breakdown table and read as the wrong screen
                  // entirely; a candidate with one sitting looked fine only
                  // because their page is too short to hold the offset and it
                  // clamped back to zero.
                  //
                  // Keyed on the ROUTE, not on every build: a rebuild in place
                  // - a store refresh landing, a search box being typed into -
                  // keeps the same key and so keeps the reader where they
                  // were. Routes carrying a field already compare by value,
                  // so this changes exactly when the destination does - and a
                  // TAB is not a destination (`pageOf`): switching one keeps
                  // the screen and where it was scrolled to.
                  key: ValueKey<AssessmentRoute>(pageOf(_nav.current)),
                  padding: const EdgeInsets.fromLTRB(22, 18, 22, 48),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      // FIRST load of a LIST route gets a skeleton.
                      //
                      // On entry the store has no records yet, so `_page()`
                      // renders every screen's empty state - "no generators
                      // yet", "the bank is empty" - which is a factual claim
                      // about the data, made before any has arrived. A refresh
                      // is different: the screen already holds the previous
                      // answer, so it stays put under the progress bar rather
                      // than flashing back to grey blocks.
                      //
                      // Route-GATED, because this shape is a KPI strip over a
                      // wide table. Unguarded it painted that over the exam
                      // runner - a candidate following an invitation link saw
                      // an admin table skeleton - and over every detail and
                      // form route, none of which ever become that layout.
                      // Detail screens now own their own skeleton, keyed on
                      // their record's fetch.
                      if (_showListSkeleton)
                        const ListScreenSkeleton()
                      else
                        _page(),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    // Built through a function because the narrow layout needs a SECOND copy
    // whose rows close the drawer on their way to a page.
    Widget? railWith(void Function(String) onOpen) => _examIsLocked()
        ? null
        : widget.sidebarBuilder?.call(
            context,
            _sectionEntries(),
            _activeTabKey(),
            onOpen,
          );
    final Widget? rail = railWith(_openTab);
    // The dock is a sibling of the content, not part of it. That is what keeps
    // its open state and width across route changes: `content` is rebuilt on
    // every navigation, this subtree is not.
    final ({String kind, String id})? target = _dockTarget();
    final Widget dock = ChatterDock(
      title: switch (target?.kind) {
        'assessment' => 'Assessment history',
        'generator' => 'Generator history',
        'attempt' => 'Attempt history',
        _ => 'History',
      },
      // TABS, not a stack.
      //
      // The two panels answer different questions - the history is what PEOPLE
      // did to the record, Emails is what the MAIL SERVER did with it - and
      // stacking them meant scrolling past the whole history to reach a
      // bounced invitation, in a 380px column. Odoo separates them for the
      // same reason. One is on screen at a time; the other is one click away.
      child: target == null
          ? null
          : _DockTabs(store: _store, kind: target.kind, recordId: target.id),
    );

    // The shortcut wrapper goes OUTSIDE the rail as well as the content, so
    // Back works wherever focus happens to sit - including on a sidebar row the
    // user has just tabbed to, or nowhere at all on a page they have only
    // scrolled.
    final Widget page = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(child: content),
        dock,
      ],
    );
    if (rail == null) {
      return HistoryShortcuts(nav: _nav, child: page);
    }
    // THE RAIL IS A DRAWER ON A PHONE. A 224px rail on a 375px screen leaves
    // 151 for the page, and My Assessments - the first screen an invited
    // candidate sees, since the invitation mails the app's front door - has to
    // fit. The exam runner is unaffected either way: `_examIsLocked` already
    // drops the rail for the whole sitting.
    return HistoryShortcuts(
      nav: _nav,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          if (c.maxWidth >= Layout.headerStack) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                rail,
                Expanded(child: content),
                dock,
              ],
            );
          }
          final AppTokens t = context.tokens;
          return Scaffold(
            key: _narrowShell,
            backgroundColor: Colors.transparent,
            drawer: Drawer(
              width: 224,
              child: SafeArea(
                // A row opened from the drawer has to close it, or the page it
                // just opened is behind the navigation that opened it.
                child:
                    railWith((String key) {
                      _narrowShell.currentState?.closeDrawer();
                      _openTab(key);
                    }) ??
                    const SizedBox.shrink(),
              ),
            ),
            appBar: AppBar(
              backgroundColor: t.bgMuted,
              foregroundColor: t.textPrimary,
              elevation: 0,
              title: Text(_activeTabLabel(), style: context.type.panelTitle),
            ),
            body: page,
          );
        },
      ),
    );
  }

  /// The drawer shell, so a rail row can close the drawer it was tapped in.
  final GlobalKey<ScaffoldState> _narrowShell = GlobalKey<ScaffoldState>();

  /// The current section's own name, for the narrow layout's top bar - the one
  /// place the rail's lit row is not on screen to say where the reader is.
  String _activeTabLabel() {
    final String key = _activeTabKey();
    for (final NavEntry e in _sectionEntries()) {
      if (e.key == key) return e.label;
    }
    return 'Assessments';
  }

  /// The sections, as NAV ENTRIES for the sidebar.
  ///
  /// Same keys `_activeTabKey` and `_openTab` already use, so the rail and the
  /// router cannot drift apart.
  List<NavEntry> _sectionEntries() {
    if (_store.portal == Portal.member) return memberNav();
    return operatorNav(
      // Counts of work WAITING, not totals: a badge on every row is
      // wallpaper. Drafts awaiting approval and answers awaiting a grader are
      // the two an operator has to act on.
      reviewCount: _store.pendingDrafts().length,
      // Answers a grader still has to look at: a subjective answer the LLM has
      // not resolved. An objective answer is already marked.
      responseCount: _store
          .allResponses()
          .where((AnswerRef a) => a.r.llmState == LlmState.pending)
          .length,
      // The rail is narrowed to what this rung may open. A read-only Manager
      // keeps six rows and loses Generators, Review Queue and Settings.
      role: _store.accessRole,
    );
  }

  /// Is the candidate inside a sitting that must not be navigable away from?
  ///
  /// THE SIDEBAR IS AN ESCAPE HATCH DURING AN EXAM. The rail is a sibling of
  /// every route, so it was drawn over the exam too - and its rows are live.
  /// Mid-sitting a candidate could click "My performance", land on their own
  /// results and leave the exam entirely while the clock kept running. That was
  /// reproduced in a browser, not inferred: the exam vanished and the
  /// performance screen took its place.
  ///
  /// `etp_assessment_pro` never had this hole because its exam pages render
  /// through `portal_exam_layout`, which sets `no_header`/`no_footer` and draws
  /// nothing but a brand bar - no navigation exists on that surface at all.
  /// This is the same stance, expressed in the shell that owns the rail.
  ///
  /// GATED ON THE STAGE, NOT MERELY ON `Exam`. The briefing (`gate`) and the
  /// completion card (`complete`) are ordinary pages a candidate is meant to be
  /// able to leave - the briefing is explicitly a "Not now" decision point.
  /// Only the stages where answers are being given lock the chrome.
  ///
  /// AND ON THE ATTEMPT, because the stage alone let the hole back in. A deep
  /// link - `?token=...`, which is how every invitation and every resume
  /// arrives - builds `Exam(token)` with the DEFAULT stage, `gate`. The runner
  /// then decides for itself that this attempt is already under way and draws
  /// the question, without the route ever changing stage. So a candidate who
  /// reloaded mid-exam, or came back to their link after a dropped connection,
  /// sat the rest of the paper with the rail beside them and every row live -
  /// exactly the escape hatch described above, reached by the most ordinary
  /// path there is. Reproduced in a browser: resumed at question 10 of 29 with
  /// "My Assessments" and "My Performance" both clickable.
  ///
  /// The attempt is the truth here, not the route: an attempt that has started
  /// and has not been submitted is a sitting in progress however the candidate
  /// got to it.
  bool _examIsLocked() => switch (_nav.current) {
    Exam(:final ExamStage stage, :final String token) =>
      stage == ExamStage.question ||
          stage == ExamStage.answers ||
          stage == ExamStage.review ||
          (stage == ExamStage.gate && _sittingIsUnderWay(token)),
    _ => false,
  };

  /// True when [token]'s attempt has been started and not yet finished.
  ///
  /// Deliberately false when the attempt is unknown to the store: on a cold
  /// deep link nothing is loaded yet, and the briefing that renders in that
  /// moment IS a page the candidate may leave. The rail reappears for a
  /// fraction of a second at most, and locking on absence would strand anyone
  /// whose attempt failed to load with no way back.
  bool _sittingIsUnderWay(String token) {
    final Attempt? ev = _store.attemptByToken(token);
    if (ev == null) return false;
    return ev.startedAt != null && !ev.isDone;
  }

  /// The record the dock should show history for, or null when the current
  /// route is not about one.
  ///
  /// Lists, Analytics and Start here have no single record, and the EXAM is a
  /// candidate surface - an operator's audit trail has no business on it.
  ({String kind, String id})? _dockTarget() => switch (_nav.current) {
    AssessmentDetail(:final String id) => (kind: 'assessment', id: id),
    GeneratorDetail(:final String id) => (kind: 'generator', id: id),
    AttemptDetail(:final String id) => (kind: 'attempt', id: id),
    // A response belongs to an attempt, so show that attempt's history.
    ResponseDetail(:final String attemptId) => (kind: 'attempt', id: attemptId),
    _ => null,
  };

  /// Which tab the CURRENT route belongs to.
  ///
  /// Derived from the route rather than stored, so drilling into a detail
  /// screen keeps its parent tab lit instead of clearing the strip.
  String _activeTabKey() => switch (_nav.current) {
    StartHere() => 'start',
    Analytics() => 'analytics',
    // An exam route belongs to the candidate's list: it is reached
    // FROM there, so leaving the strip with nothing lit made the
    // review look like a page outside the section.
    MyAssessments() || Exam() => 'mine',
    MyPerformance() => 'performance',
    GeneratorList() || GeneratorDetail() => 'generators',
    QuestionBank() => 'bank',
    ReviewQueue() => 'review',
    ResponsesList() ||
    ResponseDetail() ||
    AttemptDetail() ||
    CandidateDetail() => 'responses',
    CandidatePerformance() => 'analytics',
    TagsAdmin() => 'tags',
    // The designer keeps its parent row lit, same as every detail route.
    FormStudio() || FormDesigner() => 'forms',
    BudgetAdmin() => 'budget',
    LedgerAdmin() => 'ledger',
    SettingsAdmin() => 'settings',
    AccountSettings() => 'account',
    _ => 'assessments',
  };

  void _openTab(String key) {
    _nav.reset(switch (key) {
      'start' => const StartHere(),
      'analytics' => const Analytics(),
      'ledger' => const LedgerAdmin(),
      'mine' => const MyAssessments(),
      'performance' => const MyPerformance(),
      'generators' => const GeneratorList(),
      'bank' => const QuestionBank(),
      'review' => const ReviewQueue(),
      'responses' => const ResponsesList(),
      'tags' => const TagsAdmin(),
      'forms' => const FormStudio(),
      'budget' => const BudgetAdmin(),
      'settings' => const SettingsAdmin(),
      'account' => const AccountSettings(),
      _ => const AssessmentsList(),
    });
  }

  /// Whether to show the list-shaped first-paint skeleton. Only for routes that
  /// become a KPI strip over a wide table, and only before anything arrives -
  /// elsewhere it promises a layout that never comes.
  bool get _showListSkeleton =>
      _store.loadState == LoadState.loading &&
      _store.isEmpty &&
      switch (_nav.current) {
        Analytics() ||
        AssessmentsList() ||
        GeneratorList() ||
        QuestionBank() ||
        ReviewQueue() ||
        ResponsesList() ||
        TagsAdmin() ||
        FormStudio() ||
        BudgetAdmin() ||
        LedgerAdmin() ||
        MyAssessments() ||
        MyPerformance() => true,
        _ => false,
      };

  /// The routes that render an admin AUDIT surface, and which a candidate must
  /// never be shown whatever put them there.
  ///
  /// These screens print the scoring machinery on purpose: the lane
  /// weights ("Key closeness 0.60", "SOP coverage 0.25", "Verdicts 0.75"), the
  /// blended raw, the subjective threshold and the grader's full internal
  /// reasoning. That is right for an admin - a mark nobody can check is a mark
  /// nobody can defend, and the admin is the person who has to defend it. It is
  /// wrong for the candidate the mark was given to, who learns from it which
  /// half of the paper to spend their effort on rather than how to do the work.
  ///
  /// Today nothing candidate-reachable constructs these routes: `memberNav()`
  /// lists two rows, and every `nav.attempt()` / `nav.response()` /
  /// `nav.candidate()` call site sits inside an admin screen. THAT IS AN
  /// ACCIDENT OF THE CALL SITES, not a guarantee, and it is one refactor or one
  /// restored navigation state away from not being true. The guarantee belongs
  /// here, at the single place every screen is constructed.
  static bool _isAdminAudit(AssessmentRoute r) =>
      r is AttemptDetail ||
      r is ResponseDetail ||
      r is CandidateDetail ||
      r is CandidatePerformance;

  /// Routes a read-only Manager must not land on, whatever reached them.
  ///
  /// THE SAME DEFENCE-IN-DEPTH ARGUMENT AS `_isAdminAudit`, and it belongs in
  /// the same place: this is the single point every screen is constructed, so a
  /// guarantee made here cannot be missed by a link somebody adds later. Hiding
  /// the rail rows is the usability half; this is the half that holds when a
  /// button, a deep link or a stale history entry names one anyway.
  ///
  /// `StartHere` is on the list because it is a DIRECTORY of the sections a
  /// Manager cannot open - it links to Generators, Review Queue and the bank -
  /// so leaving it reachable would put every hidden destination one page away.
  ///
  /// `NewAssessment` is here for the deep link, not the button. Its POST to
  /// /api/v1/assessments/create is Admin-only and the New Assessment button is
  /// already hidden, so the only ways onto that form are a pasted URL or a
  /// history entry restored from before the role was read - which is exactly
  /// the case this guard exists for. Letting a Manager fill in a create form
  /// and lose the lot to a 403 on submit is worse than never offering it.
  ///
  /// `FormDesigner` is here because it AUTOSAVES. It is a live editor, not a
  /// document view: the first keystroke, drag or reorder fires a save POST, so
  /// a Manager who opened it would collect one 403 per edit while the design in
  /// front of them appeared to accept every change. With roughly thirty
  /// separate write affordances inside it, threading a read-only mode through a
  /// two-thousand-line editor would be permanent debt - every control added
  /// afterwards is one more somebody has to remember to disable, and the day
  /// they forget is the day it silently writes again. Guarding the route is the
  /// honest fix. A Manager still READS a form's design: Form Studio's rows open
  /// the respondent preview for them instead of the designer.
  static bool _isAuthoringOrPlatform(AssessmentRoute r) =>
      r is GeneratorList ||
      r is GeneratorDetail ||
      r is ReviewQueue ||
      r is SettingsAdmin ||
      r is StartHere ||
      r is NewAssessment ||
      r is FormDesigner;

  Widget _page() {
    final AssessmentRoute r = _nav.current;
    final Portal p = _store.portal;

    if (p == Portal.member && _isAdminAudit(r)) {
      // Their own list, not an error page: a candidate who lands here has done
      // nothing wrong and has no idea what they were denied.
      return MyAssessmentsScreen(store: _store);
    }

    if (_store.accessRole == AccessRole.manager && _isAuthoringOrPlatform(r)) {
      // The dashboard, not a 403: a Manager who got here followed something the
      // console should not have offered, and the fix is a screen they can use
      // rather than an error naming a permission they cannot change.
      return DashboardScreen(store: _store, portal: p);
    }

    return switch (r) {
      StartHere() => StartHereScreen(store: _store),
      Analytics() => DashboardScreen(store: _store, portal: p),
      MyPerformance() => MyPerformanceScreen(store: _store),
      CandidatePerformance() => MyPerformanceScreen(
        store: _store,
        personId: r.personId,
      ),
      AssessmentsList() => AssessmentListScreen(store: _store, portal: p),
      NewAssessment() => NewAssessmentScreen(store: _store),
      AssessmentDetail() => AssessmentDetailScreen(
        store: _store,
        portal: p,
        asmId: r.id,
        tab: r.tab,
      ),
      QuestionBank() => BankScreen(store: _store),
      GeneratorList() => GeneratorListScreen(store: _store),
      GeneratorDetail() => GeneratorDetailScreen(
        store: _store,
        genId: r.id,
        tab: r.tab,
        focusName: r.focusName,
      ),
      ReviewQueue() => ReviewQueueScreen(
        store: _store,
        genFilter: r.generatorId ?? '',
      ),
      ResponsesList() => ResponsesScreen(store: _store),
      ResponseDetail() => ResponseDetailScreen(
        store: _store,
        attemptId: r.attemptId,
        questionId: r.questionId,
      ),
      AttemptDetail() => AttemptDetailScreen(
        store: _store,
        portal: p,
        attemptId: r.id,
      ),
      CandidateDetail() => CandidateDetailScreen(
        store: _store,
        personId: r.personId,
      ),
      TagsAdmin() => TagsScreen(store: _store),
      FormStudio() => FormStudioScreen(store: _store),
      FormDesigner() => FormDesignerScreen(
        store: _store,
        formId: r.id,
        tab: r.tab,
      ),
      BudgetAdmin() => BudgetScreen(store: _store),
      LedgerAdmin() => LedgerScreen(store: _store),
      SettingsAdmin() => SettingsScreen(store: _store),
      AccountSettings() => AccountScreen(store: _store),
      MyAssessments() => MyAssessmentsScreen(store: _store),
      Exam() => ExamScreen(
        store: _store,
        token: r.token,
        sub: switch (r.stage) {
          ExamStage.gate => ExamSub.instructions,
          ExamStage.question => ExamSub.question,
          ExamStage.answers => ExamSub.answers,
          ExamStage.review => ExamSub.review,
          ExamStage.complete => ExamSub.complete,
        },
        questionNumber: r.questionIndex,
        onToggleTheme: _examIsLocked() ? widget.onToggleTheme : null,
        isDark: widget.isDark,
      ),
    };
  }
}

/// The dock's two views: the record's history, and its outgoing mail.
class _DockTabs extends StatefulWidget {
  const _DockTabs({
    required this.store,
    required this.kind,
    required this.recordId,
  });

  final AppStore store;
  final String kind;
  final String recordId;

  @override
  State<_DockTabs> createState() => _DockTabsState();
}

class _DockTabsState extends State<_DockTabs> {
  String _tab = 'history';

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      TabStrip(
        active: _tab,
        onChanged: (String k) => setState(() => _tab = k),
        tabs: const <TabDef>[
          TabDef('history', 'History'),
          TabDef('emails', 'Emails'),
        ],
      ),
      const SizedBox(height: 12),
      // Keyed so switching tabs does not hand one panel's State to the other
      // - they are different widgets at the same position, which is exactly
      // the case Flutter would otherwise try to reuse.
      if (_tab == 'history')
        ChatterPanel(
          key: ValueKey<String>('history-${widget.kind}-${widget.recordId}'),
          store: widget.store,
          kind: widget.kind,
          recordId: widget.recordId,
        )
      else
        EmailsPanel(
          key: ValueKey<String>('emails-${widget.kind}-${widget.recordId}'),
          store: widget.store,
          kind: widget.kind,
          recordId: widget.recordId,
        ),
    ],
  );
}
