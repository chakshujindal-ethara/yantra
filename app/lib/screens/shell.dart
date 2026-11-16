import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../api/models.dart';
import '../app_scope.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/portal_tokens.dart';
import '../core/widgets/backdrop.dart';
import '../core/widgets/cards.dart';
import '../core/page_commands.dart';
import '../core/poller.dart';
import '../core/widgets/portal_page.dart';
import 'applications_screen.dart';
import 'client/deliveries_screen.dart';
import 'client/overview_screen.dart';
import 'client/projects_screen.dart';
import 'earnings_screen.dart';
import 'explore_screen.dart';
import 'home_screen.dart';
import 'inbox_screen.dart';
import 'my_work_screen.dart';
import 'ops/finance_screen.dart';
import 'ops/leadership_screen.dart';
import 'ops/settings_screen.dart';
import 'ops/system_screen.dart';
import 'ops/listings_screen.dart';
import 'ops/overview_screen.dart';
import 'ops/papers_screen.dart';
import 'ops/projects_screen.dart';
import 'ops/quality_screen.dart';
import 'ops/support_screen.dart';
import 'ops/workers_screen.dart';
import 'profile_screen.dart';
import 'report_problem.dart';
import 'review_screen.dart';
import '../core/widgets/tappable.dart';

/// Where a person can go. Which destinations the shell shows comes from the token's realm roles
/// ([Destination.visibleTo]); a reviewer-lead who is `ops` and `worker` sees both sets, grouped.
/// The active destination is state the shell owns; pages receive [ShellActions] to move around.
enum Destination {
  // worker
  home('Home', Icons.home_outlined, Icons.home, 'Today, your claim, open pools', 'Work', {'worker'}, '/work/home'),
  explore('Explore', Icons.explore_outlined, Icons.explore, 'Pools you can apply to', 'Work', {'worker'}, '/work/explore'),
  myWork('My work', Icons.fact_check_outlined, Icons.fact_check, 'Verdicts and disputes', 'Work', {'worker'}, '/work/my-work'),
  review('Review', Icons.rate_review_outlined, Icons.rate_review, "Judge others' work", 'Work', {'reviewer'}, '/work/review'),
  applications('Applications', Icons.how_to_reg_outlined, Icons.how_to_reg, 'Where each application stands', 'Work', {
    'worker',
  }, '/work/applications'),
  earnings('Earnings', Icons.payments_outlined, Icons.payments, 'Pay windows and statements', 'Money', {'worker'}, '/work/earnings'),
  // ops
  opsOverview('Overview', Icons.dashboard_outlined, Icons.dashboard, 'The platform today', 'Operate', {'ops'}, '/ops/overview'),
  projects('Projects', Icons.folder_outlined, Icons.folder, 'Client projects and batches', 'Operate', {'ops'}, '/ops/projects'),
  listings('Listings', Icons.campaign_outlined, Icons.campaign, 'Pools and applicants', 'Operate', {'ops'}, '/ops/listings'),
  papers('Papers', Icons.quiz_outlined, Icons.quiz, 'Assessments and certification', 'Operate', {'ops'}, '/ops/papers'),
  workers('Workers', Icons.groups_outlined, Icons.groups, 'The bench', 'Operate', {'ops'}, '/ops/workers'),
  quality('Quality', Icons.verified_outlined, Icons.verified, 'Flags, disputes, the queue', 'Operate', {'ops'}, '/ops/quality'),
  // Operators read the money pages (Odoo's ops account does too); only finance approves and pays.
  finance('Finance', Icons.account_balance_outlined, Icons.account_balance, 'Windows, rail, holds, margin', 'Money', {
    'finance',
    'ops',
  }, '/ops/finance'),
  support('Support', Icons.support_agent_outlined, Icons.support_agent, 'Tickets', 'Operate', {'ops'}, '/ops/support'),
  leadership('Leadership', Icons.query_stats_outlined, Icons.query_stats, 'The four numbers, margin, watch list', 'Insight', {
    'ops',
    'finance',
    'admin',
  }, '/ops/leadership'),
  // client
  clientOverview('Overview', Icons.insights_outlined, Icons.insights, 'Your work with Yantra', 'Client', {'client'}, '/client/overview'),
  clientProjects('Projects', Icons.work_outline, Icons.work, 'Progress, quality, invoices', 'Client', {'client'}, '/client/projects'),
  deliveries('Deliveries', Icons.inventory_2_outlined, Icons.inventory_2, 'Every manifest', 'Client', {'client'}, '/client/deliveries'),
  // admin
  system('System', Icons.memory_outlined, Icons.memory, 'Stuck work, dead letters, jobs', 'Admin', {'admin', 'ops'}, '/ops/system'),
  settings('Settings', Icons.tune_outlined, Icons.tune, 'Orgs, policies, reasons, caps, erasure', 'Admin', {'ops'}, '/ops/settings'),
  // everyone
  // the inbox holds rows notify writes for workers and operators; finance, admin and client tokens have none
  // (notify refuses them), so the destination and its unread poll stay off for them
  inbox('Inbox', Icons.notifications_outlined, Icons.notifications, 'Verdicts, payouts, notices', 'You', {'worker', 'ops'}, '/inbox'),
  profile('Profile', Icons.person_outline, Icons.person, 'Availability, theme, policies', 'You', knownRoles, '/profile');

  const Destination(this.label, this.icon, this.activeIcon, this.hint, this.group, this.roles, this.path);

  final String label;
  final IconData icon;
  final IconData activeIcon;

  /// One line under the label in the narrow screen's drawer (the rail shows the label alone).
  final String hint;
  final String group;
  final Set<String> roles;

  /// The branch root in the URL (`/ops/projects`); detail pages nest under it (`/ops/projects/<id>`).
  final String path;

  /// The destination whose branch owns [location]: the longest [path] that prefixes it. Null for routes
  /// outside the shell (`/login`, `/no-access`).
  static Destination? byPath(String location) {
    final p = Uri.parse(location).path;
    Destination? best;
    for (final d in values) {
      if ((p == d.path || p.startsWith('${d.path}/')) && (best == null || d.path.length > best.path.length)) best = d;
    }
    return best;
  }

  static const _groupOrder = ['Work', 'Operate', 'Insight', 'Client', 'Money', 'Admin', 'You'];

  /// The realm roles the app knows, in the gateway's order. Anything else in a token is ignored.
  static const knownRoles = {'admin', 'ops', 'finance', 'reviewer', 'client', 'worker'};

  /// Every destination at least one of [held] roles may use, in declaration order. A token with no known
  /// role gets nothing: the app shows the no-access page instead of a shell full of refusals.
  static List<Destination> visibleTo(Set<String> held) => [
    for (final d in values)
      if (d.roles.any(held.contains)) d,
  ];

  /// Sidebar groups, in order, for the destinations [visibleTo] the roles.
  static List<(String, List<Destination>)> groupsFor(Set<String> held) {
    final visible = visibleTo(held);
    return [
      for (final g in _groupOrder)
        if (visible.any((d) => d.group == g))
          (
            g,
            [
              for (final d in visible)
                if (d.group == g) d,
            ],
          ),
    ];
  }

  /// The person's primary role decides the first page and the bottom bar: an operator, then finance,
  /// a client, a worker, a reviewer, an admin. Null for no known role.
  static String? primaryRole(Set<String> held) {
    for (final r in const ['ops', 'finance', 'client', 'worker', 'reviewer', 'admin']) {
      if (held.contains(r)) return r;
    }
    return null;
  }

  static Destination? firstFor(Set<String> held) => switch (primaryRole(held)) {
    'ops' => opsOverview,
    'finance' => finance,
    'client' => clientOverview,
    'worker' => home,
    'reviewer' => review,
    'admin' => system,
    _ => null,
  };

  /// The bottom bar shows five at most, from the primary role's preference list, keeping only what the
  /// roles may use; the rest are in the drawer and the top-bar avatar.
  static List<Destination> bottomBarFor(Set<String> held) {
    final preferred = switch (primaryRole(held)) {
      'ops' => const [opsOverview, projects, quality, finance, support, workers, listings],
      'finance' => const [finance, leadership, profile],
      'client' => const [clientOverview, clientProjects, deliveries, profile],
      'worker' => const [home, explore, myWork, earnings, inbox],
      'reviewer' => const [review, profile],
      'admin' => const [system, leadership, profile],
      _ => const [profile],
    };
    final visible = visibleTo(held).toSet();
    return [
      for (final d in preferred)
        if (visible.contains(d)) d,
    ].take(5).toList();
  }

  /// The primary role as a word, for the account footer and the profile.
  static String roleName(Set<String> held) => switch (primaryRole(held)) {
    'ops' => 'Operator',
    'finance' => 'Finance',
    'client' => 'Client',
    'admin' => 'Admin',
    'reviewer' => 'Reviewer',
    _ => 'Worker',
  };
}

/// Decides whether a page the shell keeps alive is rebuilt (its data loaded again) when it is entered
/// again: after [after] since it was last entered, when a mutation elsewhere marked it stale, or when
/// asked outright. A first visit builds once whatever the marks say.
class RevisitPolicy {
  RevisitPolicy({DateTime Function()? clock, this.after = const Duration(seconds: 30)}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Duration after;
  final Map<Destination, DateTime> _entered = {};
  final Map<Destination, int> _generation = {};

  bool visited(Destination d) => _entered.containsKey(d);

  /// The page's generation: a changed generation is a rebuilt page.
  int generation(Destination d) => _generation[d] ?? 0;

  /// Records the entry and returns the generation the page now has.
  int enter(Destination d, {bool refresh = false, bool stale = false}) {
    final now = _clock();
    final before = _entered[d];
    _entered[d] = now;
    if (before == null) return _generation[d] = 0;
    if (refresh || stale || now.difference(before) >= after) return _generation[d] = generation(d) + 1;
    return generation(d);
  }
}

/// What pages may ask of the shell.
class ShellActions {
  const ShellActions({required this.go, required this.setUnread, required this.markStale});

  /// Goes to [d]. A page visited before is rebuilt after 30 seconds, after a [markStale], or with `refresh`.
  /// Going to the destination you are on returns to its root (a detail page open in it is closed).
  final void Function(Destination d, {bool refresh}) go;

  /// A page that changed shared state names the destinations now showing old data; each is rebuilt on
  /// its next visit. Detail pages reach the same marks through `AppScope.of(context).stale`.
  final void Function(Destination d) markStale;

  /// The inbox tells the shell how many are unread; the bell shows it.
  final void Function(int) setUnread;

  static ShellActions of(BuildContext context) => _ShellScope.of(context).actions;
}

class _ShellScope extends InheritedWidget {
  const _ShellScope({required this.actions, required this.generations, required super.child});
  final ShellActions actions;

  /// Each destination's page generation ([RevisitPolicy]); a changed number rebuilds that branch's root.
  final Map<Destination, int> generations;

  static _ShellScope of(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<_ShellScope>();
    assert(s != null, 'ShellActions missing above this widget');
    return s ?? (throw StateError('ShellActions missing'));
  }

  @override
  bool updateShouldNotify(_ShellScope oldWidget) => !mapEquals(generations, oldWidget.generations);
}

/// The root page of one shell branch: the destination's screen, keyed by its generation so a revisit the
/// [RevisitPolicy] calls for rebuilds it (and loads its data again).
class ShellPage extends StatelessWidget {
  const ShellPage(this.destination, {super.key});
  final Destination destination;

  @override
  Widget build(BuildContext context) {
    final generation = _ShellScope.of(context).generations[destination] ?? 0;
    return KeyedSubtree(key: ValueKey('${destination.name}:$generation'), child: pageFor(destination));
  }

  static Widget pageFor(Destination d) => switch (d) {
    Destination.home => const HomeScreen(),
    Destination.explore => const ExploreScreen(),
    Destination.myWork => const MyWorkScreen(),
    Destination.review => const ReviewScreen(),
    Destination.applications => const ApplicationsScreen(),
    Destination.earnings => const EarningsScreen(),
    Destination.opsOverview => const OpsOverviewScreen(),
    Destination.projects => const ProjectsScreen(),
    Destination.listings => const ListingsScreen(),
    Destination.papers => const PapersScreen(),
    Destination.workers => const WorkersScreen(),
    Destination.quality => const QualityScreen(),
    Destination.finance => const FinanceScreen(),
    Destination.support => const SupportScreen(),
    Destination.leadership => const LeadershipScreen(),
    Destination.clientOverview => const ClientOverviewScreen(),
    Destination.clientProjects => const ClientProjectsScreen(),
    Destination.deliveries => const ClientDeliveriesScreen(),
    Destination.system => const SystemScreen(),
    Destination.settings => const SettingsScreen(),
    Destination.inbox => const InboxScreen(),
    Destination.profile => const ProfileScreen(),
  };
}

/// The app chrome around the current branch of the router, in the Social AI studio's look. Wide: a 64px
/// rail of icon chips that opens over the page with the grouped destinations and the account, a 64px top
/// bar with the breadcrumb, the command palette, the theme toggle and the bell, all on the studio board. Narrow: a top bar with a drawer button, and a bottom
/// bar for the primary role's five. Cmd/Ctrl+K opens the command palette anywhere. The unread count on
/// the bell is polled every minute while the tab is visible.
class Shell extends StatefulWidget {
  const Shell({super.key, required this.navigationShell, this.clock, this.pollEvery = const Duration(seconds: 60)});

  /// The router's branch container; its index is the active destination.
  final StatefulNavigationShell navigationShell;

  /// For tests: the clock behind the 30-second revisit rule.
  final DateTime Function()? clock;

  final Duration pollEvery;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _unread = 0;
  Destination? _entered;
  bool _refreshNext = false;
  Poller? _poller;
  late final ShellActions _actions = ShellActions(
    go: _go,
    setUnread: (n) {
      if (n != _unread && mounted) setState(() => _unread = n);
    },
    markStale: (d) => AppScope.of(context).stale.mark([d]),
  );

  /// Pages are built on their first visit and kept alive afterwards, so sign-in costs one page's
  /// requests, not every page's. A kept page is rebuilt on re-entry by [RevisitPolicy].
  late final RevisitPolicy _policy = RevisitPolicy(clock: widget.clock);
  final _commands = PageCommands();

  Destination get _active => Destination.values[widget.navigationShell.currentIndex];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_poller != null) return;
    final scope = AppScope.of(context);
    scope.people.announceSelf(scope.session.subject);
    if (scope.session.roles.any(const {'worker', 'reviewer', 'ops'}.contains)) _loadReasons(scope);
    if (Destination.visibleTo(scope.session.roles).contains(Destination.inbox)) {
      _poller = Poller(every: widget.pollEvery, tick: _pollUnread)..start();
    }
  }

  @override
  void dispose() {
    _poller?.dispose();
    super.dispose();
  }

  /// The reason catalogue the quality service serves; the shipped list stays in use when it cannot be read.
  Future<void> _loadReasons(AppScope scope) async {
    try {
      ReasonCode.adopt(await scope.review.reasons());
    } on Object {
      // the built-in catalogue stands
    }
  }

  Future<void> _pollUnread() async {
    final scope = AppScope.of(context);
    try {
      final n = await scope.notify.unreadCount();
      if (!mounted) return;
      if (n > _unread) scope.stale.mark([Destination.inbox]);
      _actions.setUnread(n);
    } on Object {
      // a missed poll changes nothing; the next one, or opening the inbox, catches up
    }
  }

  void _go(Destination d, {bool refresh = false}) {
    final index = Destination.values.indexOf(d);
    if (index == widget.navigationShell.currentIndex) {
      final stale = AppScope.of(context).stale.take(d);
      setState(() => _policy.enter(d, refresh: refresh, stale: stale));
      widget.navigationShell.goBranch(index, initialLocation: true);
      return;
    }
    _refreshNext = refresh;
    widget.navigationShell.goBranch(index);
  }

  Future<void> _openPalette(BuildContext context, Set<String> roles) async {
    final location = GoRouter.of(context).routeInformationProvider.value.uri.path;
    final picked = await showDialog<Object>(
      context: context,
      builder: (_) => CommandPalette(
        destinations: Destination.visibleTo(roles),
        commands: _commands.at(location),
        help: [
          PageCommand(
            'Report a problem',
            Icons.flag_outlined,
            () => reportProblem(context, _active),
            key: const Key('palette-report-problem'),
          ),
        ],
      ),
    );
    switch (picked) {
      case Destination d:
        _actions.go(d);
      case PageCommand c:
        c.run();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final roles = scope.session.roles;
    final active = _active;
    if (active != _entered) {
      // entered by the sidebar, a link, the palette or the browser's back button: one rule for all
      _entered = active;
      _policy.enter(active, refresh: _refreshNext, stale: scope.stale.take(active));
      _refreshNext = false;
    }
    final body = Column(
      children: [
        const _NetworkBanner(),
        Expanded(child: widget.navigationShell),
      ],
    );
    return _ShellScope(
      actions: _actions,
      generations: {for (final d in Destination.values) d: _policy.generation(d)},
      child: PageCommandsScope(
        commands: _commands,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () => _openPalette(context, roles),
            const SingleActivator(LogicalKeyboardKey.keyK, control: true): () => _openPalette(context, roles),
          },
          child: Focus(
            autofocus: true,
            child: LayoutBuilder(
              builder: (context, c) => c.maxWidth >= Layout.wide
                  ? _WideShell(
                      active: active,
                      unread: _unread,
                      actions: _actions,
                      roles: roles,
                      onPalette: () => _openPalette(context, roles),
                      child: body,
                    )
                  : _NarrowShell(
                      active: active,
                      unread: _unread,
                      actions: _actions,
                      roles: roles,
                      onPalette: () => _openPalette(context, roles),
                      child: body,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One line above the page while the browser is offline or the gateway did not answer the last request.
class _NetworkBanner extends StatelessWidget {
  const _NetworkBanner();

  @override
  Widget build(BuildContext context) {
    final network = AppScope.of(context).network;
    return ListenableBuilder(
      listenable: network,
      builder: (context, _) {
        if (network.online && network.reachable) return const SizedBox.shrink();
        final t = PortalTokens.of(context);
        final text = network.online
            ? "Can't reach Yantra. Your next action will try again."
            : "You're offline. Nothing you do will be sent until the connection is back.";
        return Semantics(
          liveRegion: true,
          child: Container(
            key: const Key('network-banner'),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: Space.x16, vertical: Space.x8),
            decoration: BoxDecoration(
              color: t.warnBg,
              border: Border(bottom: BorderSide(color: t.warnDot.withValues(alpha: 0.4))),
            ),
            child: Row(
              children: [
                Icon(network.online ? Icons.cloud_off_outlined : Icons.wifi_off, size: Sizes.iconSm, color: t.warnDot),
                const SizedBox(width: Space.x8),
                Expanded(
                  child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: t.warnText)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _WideShell extends StatelessWidget {
  const _WideShell({
    required this.active,
    required this.unread,
    required this.actions,
    required this.roles,
    required this.onPalette,
    required this.child,
  });
  final Destination active;
  final int unread;
  final ShellActions actions;
  final Set<String> roles;
  final VoidCallback onPalette;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      children: [
        _TopBar(active: active, unread: unread, actions: actions, roles: roles, onPalette: onPalette, narrow: false),
        Expanded(child: child),
      ],
    );
    // the studio's slim rail holds 64px; it opens over the page on hover or keyboard focus, so nothing moves
    return Scaffold(
      body: StudioBackdrop(
        child: Stack(
          children: [
            Row(
              children: [
                const SizedBox(width: Layout.rail),
                Expanded(child: content),
              ],
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: _Sidebar(active: active, actions: actions, roles: roles),
            ),
          ],
        ),
      ),
    );
  }
}

class _NarrowShell extends StatelessWidget {
  const _NarrowShell({
    required this.active,
    required this.unread,
    required this.actions,
    required this.roles,
    required this.onPalette,
    required this.child,
  });
  final Destination active;
  final int unread;
  final ShellActions actions;
  final Set<String> roles;
  final VoidCallback onPalette;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final bar = Destination.bottomBarFor(roles);
    final inBar = bar.indexOf(active);
    // A page outside the bar (Profile, Review, a drawer pick) is active: no bar item may look selected.
    final barTheme = Theme.of(context).navigationBarTheme;
    final quiet = barTheme.copyWith(
      indicatorColor: Colors.transparent,
      iconTheme: WidgetStatePropertyAll(IconThemeData(color: t.textSecondary, size: Sizes.iconLg)),
      labelTextStyle: WidgetStatePropertyAll(Theme.of(context).textTheme.labelMedium?.copyWith(color: t.textSecondary)),
    );
    return Scaffold(
      drawer: Drawer(
        backgroundColor: t.bgApp,
        child: SafeArea(
          child: _NavList(active: active, actions: actions, roles: roles, closeDrawer: true),
        ),
      ),
      body: StudioBackdrop(
        child: Column(
          children: [
            _TopBar(active: active, unread: unread, actions: actions, roles: roles, onPalette: onPalette, narrow: true),
            Expanded(child: child),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: t.border)),
        ),
        child: NavigationBarTheme(
          data: inBar < 0 ? quiet : barTheme,
          child: NavigationBar(
            selectedIndex: inBar < 0 ? 0 : inBar,
            onDestinationSelected: (i) => actions.go(bar[i]),
            destinations: [
              for (final d in bar)
                NavigationDestination(
                  icon: d == Destination.inbox ? _Bell(unread: unread, icon: d.icon) : Icon(d.icon),
                  selectedIcon: Icon(d.activeIcon),
                  label: d.label,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.active,
    required this.unread,
    required this.actions,
    required this.roles,
    required this.onPalette,
    required this.narrow,
  });
  final Destination active;
  final int unread;
  final ShellActions actions;
  final Set<String> roles;
  final VoidCallback onPalette;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final scope = AppScope.of(context);
    final dark = theme.brightness == Brightness.dark;
    final showInbox = Destination.visibleTo(roles).contains(Destination.inbox);
    // round, outlined, on a solid face: the studio's top-bar buttons
    final round = IconButton.styleFrom(
      backgroundColor: t.bgApp,
      side: BorderSide(color: t.border),
      fixedSize: const Size(36, 36),
      minimumSize: const Size(36, 36),
      padding: EdgeInsets.zero,
      iconSize: 18,
    );
    return Material(
      color: t.card,
      child: Container(
        height: narrow ? Sizes.topBar : Layout.topBarWide,
        padding: EdgeInsets.symmetric(horizontal: narrow ? Space.x8 : Space.x24),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.cardLine)),
        ),
        child: Row(
          children: [
            if (narrow) ...[
              Builder(
                builder: (context) => IconButton(
                  key: const Key('menu'),
                  tooltip: 'Menu',
                  icon: const Icon(Icons.menu),
                  onPressed: () => Scaffold.of(context).openDrawer(),
                ),
              ),
              const SizedBox(width: Space.x4),
            ],
            // the studio's breadcrumb: the product, a slash, the page
            if (!narrow) ...[
              Text('Yantra', style: theme.textTheme.titleSmall?.copyWith(color: t.textSecondary, fontSize: 14)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.x10),
                child: Text('/', style: theme.textTheme.titleSmall?.copyWith(color: t.textMuted, fontSize: 14)),
              ),
            ],
            Expanded(
              child: Text(
                active.label,
                key: const Key('page-title'),
                style: theme.textTheme.titleMedium?.copyWith(fontSize: 14.5),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!narrow)
              Padding(
                padding: const EdgeInsets.only(right: Space.x10),
                child: OutlinedButton.icon(
                  key: const Key('command-palette'),
                  onPressed: onPalette,
                  icon: const Icon(Icons.search, size: Sizes.iconSm),
                  label: Text(defaultTargetPlatform == TargetPlatform.macOS ? 'Go to…  ⌘K' : 'Go to…  Ctrl K'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: t.textSecondary,
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: Space.x16),
                  ),
                ),
              ),
            IconButton(
              key: const Key('report-problem-bar'),
              tooltip: 'Report a problem',
              style: narrow ? null : round,
              icon: const Icon(Icons.flag_outlined),
              onPressed: () => reportProblem(context, active),
            ),
            if (!narrow) const SizedBox(width: Space.x8),
            IconButton(
              key: const Key('theme-toggle'),
              tooltip: dark ? 'Switch to light' : 'Switch to dark',
              style: narrow ? null : round,
              icon: Icon(dark ? Icons.dark_mode_outlined : Icons.light_mode_outlined),
              onPressed: () => scope.theme.toggle(theme.brightness),
            ),
            if (showInbox) ...[
              if (!narrow) const SizedBox(width: Space.x8),
              IconButton(
                key: const Key('bell'),
                tooltip: unread == 0 ? 'Inbox' : 'Inbox, $unread unread',
                style: narrow ? null : round,
                icon: _Bell(unread: unread, icon: Icons.notifications_outlined),
                onPressed: () => actions.go(Destination.inbox),
              ),
            ],
            if (narrow)
              IconButton(
                key: const Key('avatar-menu'),
                tooltip: 'Profile',
                onPressed: () => actions.go(Destination.profile),
                icon: Avatar(scope.session.username, size: 28),
              ),
          ],
        ),
      ),
    );
  }
}

/// Opens "Report a problem" from anywhere, with the page the person is on filled in. A ticket sent marks
/// Profile (where "My tickets" lives) for a reload.
Future<void> reportProblem(BuildContext context, Destination on) async {
  final sent = await showReportProblem(context, title: on.label);
  if (sent != null && context.mounted) AppScope.of(context).stale.mark([Destination.profile]);
}

class _Bell extends StatelessWidget {
  const _Bell({required this.unread, required this.icon});
  final int unread;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    if (unread == 0) return Icon(icon);
    return Badge(label: Text(unread > 99 ? '99+' : '$unread'), backgroundColor: t.accentFill, textColor: Colors.white, child: Icon(icon));
  }
}

/// The wide shell's side menu, after the Social AI studio's rail: 64px of icons at the left edge that opens
/// to [Layout.railOpen] over the page while the pointer is on it or keyboard focus is inside it. Choosing a link
/// (pointer or keyboard) folds it at once and gives up focus; it opens again when the pointer comes back after
/// leaving, or when focus returns. Reduced motion skips the slide.
class _Sidebar extends StatefulWidget {
  const _Sidebar({required this.active, required this.actions, required this.roles});
  final Destination active;
  final ShellActions actions;
  final Set<String> roles;

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  bool _hover = false;
  bool _focus = false;
  bool _shut = false;

  bool get _open => !_shut && (_focus || _hover);

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final open = _open;
    final still = MediaQuery.disableAnimationsOf(context);
    final panel = AnimatedContainer(
      key: const Key('sidebar'),
      duration: still ? Duration.zero : const Duration(milliseconds: 220),
      curve: const Cubic(0.16, 1, 0.3, 1),
      width: open ? Layout.railOpen : Layout.rail,
      decoration: BoxDecoration(
        color: t.bgSubtle,
        border: Border(right: BorderSide(color: t.border)),
        boxShadow: open ? const [BoxShadow(color: Color(0x59140A28), offset: Offset(18, 0), blurRadius: 40, spreadRadius: -18)] : null,
      ),
      child: DecoratedBox(
        decoration: const BoxDecoration(gradient: PortalTokens.railWash),
        child: ClipRect(
          // laid out at the rail's width while folded (so each link is where it is seen and tapped), at the
          // open width as soon as it opens (the names do not reflow while the rail slides)
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: open ? Layout.railOpen : Layout.rail,
            maxWidth: open ? Layout.railOpen : Layout.rail,
            child: Material(
              type: MaterialType.transparency,
              child: _NavList(
                active: widget.active,
                actions: widget.actions,
                roles: widget.roles,
                closeDrawer: false,
                compact: !open,
                onPicked: () {
                  // a keyboard pick would otherwise keep the rail open over the page it just opened
                  FocusManager.instance.primaryFocus?.unfocus();
                  setState(() => _shut = true);
                },
              ),
            ),
          ),
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _shut = false;
      }),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (has) => setState(() {
          _focus = has;
          if (has) _shut = false; // tabbing back in opens it again
        }),
        child: panel,
      ),
    );
  }
}

/// The grouped destinations with the brand at the top and the account at the foot. Used by the rail and,
/// on narrow screens, by the drawer. [compact] (the folded rail) hides the names, leaving the icon chips.
class _NavList extends StatelessWidget {
  const _NavList({
    required this.active,
    required this.actions,
    required this.roles,
    required this.closeDrawer,
    this.compact = false,
    this.onPicked,
  });
  final Destination active;
  final ShellActions actions;
  final Set<String> roles;
  final bool closeDrawer;
  final bool compact;

  /// A link was chosen (the rail folds).
  final VoidCallback? onPicked;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final session = AppScope.of(context).session;
    final still = MediaQuery.disableAnimationsOf(context);
    final fade = still ? Duration.zero : const Duration(milliseconds: 160);
    void go(Destination d) {
      if (closeDrawer) Scaffold.of(context).closeDrawer();
      onPicked?.call();
      actions.go(d);
    }

    // names exist only while the rail is open (the folded rail is 44px inside its padding), fading in
    Widget label(Widget child) => _FadeIn(child: child);

    final groups = Destination.groupsFor(roles);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.x10, Space.x12, Space.x10, Space.x12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // the mark and the name, set apart from the links by a hairline
          Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 7),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.border)),
            ),
            child: Row(
              children: [
                const _Mark(size: 30),
                if (!compact) ...[
                  const SizedBox(width: 11),
                  Expanded(
                    child: label(
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Yantra', style: theme.textTheme.titleMedium),
                          Text('Ethara.AI work platform', style: theme.textTheme.labelSmall?.copyWith(fontSize: 10.5, color: t.textMuted)),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: Space.x12),
              children: [
                for (final (i, (group, items)) in groups.indexed) ...[
                  if (i > 0)
                    AnimatedContainer(
                      duration: fade,
                      margin: const EdgeInsets.only(top: Space.x8),
                      height: 1,
                      color: compact ? t.border : Colors.transparent,
                    ),
                  AnimatedContainer(
                    duration: fade,
                    height: compact ? Space.x8 : 28,
                    padding: const EdgeInsets.fromLTRB(9, Space.x10, 9, 0),
                    alignment: Alignment.topLeft,
                    child: compact
                        ? null
                        : label(
                            Text(
                              group.toUpperCase(),
                              style: theme.textTheme.labelSmall?.copyWith(fontSize: 9.5, letterSpacing: 1.1, color: t.textMuted),
                              overflow: TextOverflow.clip,
                              maxLines: 1,
                            ),
                          ),
                  ),
                  for (final d in items)
                    _NavRow(destination: d, active: d == active, onTap: () => go(d), compact: compact, showHint: closeDrawer),
                ],
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.only(top: Space.x10),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: t.border)),
            ),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Semantics(
                    label: compact ? '${session.username}, ${Destination.roleName(roles)}' : null,
                    child: Avatar(session.username, size: 36),
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(width: Space.x10),
                  Expanded(
                    child: label(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(session.username, style: theme.textTheme.labelLarge, overflow: TextOverflow.ellipsis),
                          Text(Destination.roleName(roles), style: theme.textTheme.labelSmall),
                        ],
                      ),
                    ),
                  ),
                  label(
                    IconButton(
                      key: const Key('logout'),
                      tooltip: 'Sign out',
                      icon: const Icon(Icons.logout, size: Sizes.iconMd),
                      onPressed: session.logout,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One link: the icon in a soft 30px chip, the name beside it. The page you are on wears the brand gradient
/// on its chip, a magenta wash across the row and a short gradient marker at the rail's edge; a row pointed
/// at lifts onto a solid face with its chip tinted.
class _NavRow extends StatefulWidget {
  const _NavRow({required this.destination, required this.active, required this.onTap, this.compact = false, this.showHint = false});
  final Destination destination;
  final bool active;
  final VoidCallback onTap;

  /// The rail is folded: the name is hidden (assistive tech still hears it).
  final bool compact;

  /// The one-line hint under the name (the drawer shows it; the rail does not).
  final bool showHint;

  @override
  State<_NavRow> createState() => _NavRowState();
}

class _NavRowState extends State<_NavRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final d = widget.destination;
    final active = widget.active;
    final hot = _hover && !active;
    final still = MediaQuery.disableAnimationsOf(context);
    final dur = still ? Duration.zero : const Duration(milliseconds: 180);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.x2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: dur,
          decoration: BoxDecoration(
            borderRadius: Radii.rLg,
            color: hot ? (t.isDark ? const Color(0x14FFFFFF) : Colors.white) : null,
            gradient: active ? PortalTokens.navWash : null,
            boxShadow: hot && !t.isDark ? PortalTokens.rowLift : null,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: PortalTappable(
              key: Key('nav-${d.name}'),
              onTap: widget.onTap,
              selected: active,
              borderRadius: Radii.rLg,
              hoverColor: Colors.transparent,
              semanticsLabel: widget.compact ? d.label : null,
              child: Stack(
                children: [
                  if (active)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: Container(
                          width: 3,
                          height: 16,
                          decoration: const BoxDecoration(
                            gradient: PortalTokens.brand,
                            borderRadius: BorderRadius.horizontal(right: Radius.circular(3)),
                          ),
                        ),
                      ),
                    ),
                  Container(
                    constraints: BoxConstraints(minHeight: widget.showHint ? 48 : 42),
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: Space.x4),
                    child: Row(
                      children: [
                        AnimatedContainer(
                          duration: dur,
                          width: 30,
                          height: 30,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            borderRadius: const BorderRadius.all(Radius.circular(9)),
                            gradient: active ? PortalTokens.brand : null,
                            color: active ? null : (hot ? PortalTokens.navHoverChip : Colors.transparent),
                            boxShadow: active ? PortalTokens.chipGlow : null,
                          ),
                          child: Icon(
                            active ? d.activeIcon : d.icon,
                            size: 18,
                            color: active ? Colors.white : (hot ? t.primary : t.textMuted),
                          ),
                        ),
                        if (!widget.compact) ...[
                          const SizedBox(width: 11),
                          Expanded(
                            child: _FadeIn(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    d.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelLarge
                                        ?.copyWith(fontSize: 13.5, color: active || hot ? t.textPrimary : t.textSecondary)
                                        .merge(AppTheme.weight(active ? FontWeight.w600 : FontWeight.w500)),
                                  ),
                                  if (widget.showHint)
                                    Text(
                                      d.hint,
                                      style: theme.textTheme.labelSmall?.copyWith(color: t.textMuted, fontSize: 11),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Fades its child in once, when it first appears (the rail's names as it opens).
/// Reduced motion shows it at once.
class _FadeIn extends StatelessWidget {
  const _FadeIn({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: still ? 1 : 0, end: 1),
      duration: still ? Duration.zero : const Duration(milliseconds: 160),
      builder: (context, v, child) => Opacity(opacity: v, child: child),
      child: child,
    );
  }
}

/// Cmd/Ctrl+K: type to filter the page's actions ("On this page") and the destinations; Enter or a tap
/// picks. Returns the [PageCommand] or the [Destination] picked.
class CommandPalette extends StatefulWidget {
  const CommandPalette({super.key, required this.destinations, this.commands = const [], this.help = const []});
  final List<Destination> destinations;
  final List<PageCommand> commands;

  /// Actions open on every page ("Report a problem"), listed after the destinations.
  final List<PageCommand> help;

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

typedef _Item = ({Object value, String label, String hint, IconData icon, String group, Key key});

class _CommandPaletteState extends State<CommandPalette> {
  String _query = '';
  int _cursor = 0;

  List<_Item> get _items => [
    for (final (i, c) in widget.commands.indexed)
      (value: c, label: c.label, hint: '', icon: c.icon, group: 'On this page', key: c.key ?? Key('palette-action-$i')),
    for (final d in widget.destinations)
      (value: d, label: d.label, hint: d.hint, icon: d.icon, group: d.group, key: Key('palette-${d.name}')),
    for (final (i, c) in widget.help.indexed)
      (value: c, label: c.label, hint: '', icon: c.icon, group: 'Help', key: c.key ?? Key('palette-help-$i')),
  ];

  List<_Item> get _matches {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _items;
    return [
      for (final it in _items)
        if (it.label.toLowerCase().contains(q) || it.hint.toLowerCase().contains(q) || it.group.toLowerCase().contains(q)) it,
    ];
  }

  void _pick([_Item? item]) {
    final list = _matches;
    final chosen = item ?? (list.isEmpty ? null : list[_cursor.clamp(0, list.length - 1)]);
    Navigator.of(context).pop(chosen?.value);
  }

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final list = _matches;
    return Dialog(
      key: const Key('palette'),
      alignment: const Alignment(0, -0.6),
      backgroundColor: t.bgApp,
      shape: RoundedRectangleBorder(
        borderRadius: Radii.rLg,
        side: BorderSide(color: t.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 440),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                setState(() => _cursor = list.isEmpty ? 0 : (_cursor + 1) % list.length),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                setState(() => _cursor = list.isEmpty ? 0 : (_cursor - 1 + list.length) % list.length),
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(Space.x12),
                child: TextField(
                  key: const Key('palette-query'),
                  autofocus: true,
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Go to a page or run an action…'),
                  onChanged: (v) => setState(() {
                    _query = v;
                    _cursor = 0;
                  }),
                  onSubmitted: (_) => _pick(),
                ),
              ),
              Flexible(
                child: list.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(Space.x24),
                        child: Text('Nothing matches', style: TextStyle(color: t.textSecondary)),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final it = list[i];
                          final on = i == _cursor;
                          return Material(
                            color: on ? t.selected : Colors.transparent,
                            child: ListTile(
                              key: it.key,
                              dense: true,
                              selected: on,
                              leading: Icon(it.icon, size: Sizes.iconMd, color: on ? t.primary : t.textSecondary),
                              title: Text(it.label, style: theme.textTheme.labelLarge),
                              subtitle: it.hint.isEmpty ? null : Text(it.hint, style: theme.textTheme.labelSmall),
                              trailing: Text(it.group, style: theme.textTheme.labelSmall?.copyWith(color: t.textMuted)),
                              onTap: () => _pick(it),
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: Space.x8),
            ],
          ),
        ),
      ),
    );
  }
}

/// The brand mark: a white Y on the brand gradient, softly rounded.
class _Mark extends StatelessWidget {
  const _Mark({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: PortalTokens.brand,
        borderRadius: BorderRadius.all(Radius.circular(size * 0.3)),
        boxShadow: PortalTokens.chipGlow,
      ),
      child: Text(
        'Y',
        style: TextStyle(
          fontFamily: PortalType.familyUi,
          color: Colors.white,
          fontSize: size * 0.55,
          fontWeight: FontWeight.w700,
          fontVariations: const [FontVariation('wght', 700)],
        ),
      ),
    );
  }
}

/// Exposed for the login screen, which paints the same mark.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context) => _Mark(size: size);
}
