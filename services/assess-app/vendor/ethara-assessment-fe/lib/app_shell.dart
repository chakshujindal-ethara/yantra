import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'assessment/assessment_section.dart';
import 'assessment/domain/nav_entries.dart';
import 'assessment/domain/enums.dart';
import 'assessment/route_url.dart';
import 'assessment/state/app_store.dart';
import 'assessment/theme.dart';
import 'assessment/widgets/buttons.dart';
import 'config.dart';
import 'session.dart';

/// The application shell: the sidebar and the assessment content area.
///
/// WHAT THIS REPLACES. In the host portal all of this came from `MainShell` -
/// the chrome, the account menu, sign-out, the theme toggle. This app has no
/// host, so it draws its own, using the same tokens and the same widgets the
/// content area uses.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.session,
    required this.onToggleTheme,
    required this.isDark,
    this.examToken,
    this.url = const UrlBar(),
  });

  final Session session;
  final VoidCallback onToggleTheme;
  final bool isDark;

  /// An exam token read from the URL the app was opened with.
  final String? examToken;

  /// The address bar, handed to the section. Inert unless `main.dart` passes
  /// the browser's, so a test that mounts the shell never touches it.
  final UrlBar url;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  /// Built HERE and disposed here.
  ///
  /// `AssessmentSection` takes it as a parameter and does not dispose it: the
  /// store must outlive any single mount of the section, or switching portals
  /// would drop the session.
  late final AppStore _store;

  @override
  void initState() {
    super.initState();
    _store = AppStore(api: widget.session.api);
    // The role comes from the SERVER (`/api/v1/auth/me`), never from the
    // client. `adoptSession` maps it to a Portal and kicks off the first load.
    _store.adoptSession(
      orgRole: widget.session.role,
      name: widget.session.name,
      uid: widget.session.uid,
      email: widget.session.email,
      accessRoleWire: widget.session.accessRole,
      capabilities: widget.session.capabilities
          ?.map(Capability.parse)
          .whereType<Capability>()
          .toSet(),
    );
    // The store ends the API session; only the Session moves the app back to
    // the login form (`main.dart` switches on `signedIn`). Without this a
    // sign-out raised inside the portal leaves the person on a shell with no
    // token.
    _store.onSignedOut = widget.session.signOut;
    _store.addListener(_rebuild);
  }

  void _rebuild() {
    if (!mounted) return;
    // Not mid-build: see `_AssessmentSectionState._rebuild`, same store, same
    // ancestor-marked-dirty assert.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _rebuild());
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _store.removeListener(_rebuild);
    _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool isAdmin = _store.portal == Portal.admin;

    // Yantra (studio look): the page sits on the studio board, a magenta bloom
    // at the top left and a teal one at the bottom right.
    RadialGradient bloom(Alignment at, Color c, double r) => RadialGradient(
      center: at,
      radius: r,
      colors: <Color>[c, c.withValues(alpha: 0)],
    );
    return Scaffold(
      backgroundColor: t.bgSubtle,
      // The SECTION draws the rail, through the builder below, because the
      // route state lives there - a copy held here could disagree with the
      // page being shown.
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: bloom(
            const Alignment(-0.7, -1.1),
            Color(t.isDark ? 0x2EE11FE0 : 0x24E11FE0),
            1.0,
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: bloom(
              const Alignment(1, 1),
              Color(t.isDark ? 0x182DE2C8 : 0x1A2DE2C8),
              0.9,
            ),
          ),
          child: AssessmentSection(
            store: _store,
            examToken: widget.examToken,
            url: widget.url,
            onToggleTheme: widget.onToggleTheme,
            isDark: widget.isDark,
            // Analytics, not the assessments list: an admin signing in wants the
            // state of the system before a table of records.
            entry: isAdmin ? AssessmentEntry.analytics : AssessmentEntry.mine,
            sidebarBuilder:
                (
                  BuildContext context,
                  List<NavEntry> entries,
                  String activeKey,
                  void Function(String) onOpen,
                ) => _Sidebar(
                  entries: entries,
                  activeKey: activeKey,
                  onOpen: onOpen,
                  name: widget.session.name,
                  // `AccessRole`, not `Portal`. Portal is binary and reports
                  // `admin` for a read-only Manager too, so this card told a
                  // Manager they were an Admin.
                  role: _store.accessRole.label,
                  onSignOut: () => widget.session.signOut(),
                  isDark: widget.isDark,
                  onToggleTheme: widget.onToggleTheme,
                ),
          ),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.entries,
    required this.activeKey,
    required this.onOpen,
    required this.name,
    required this.role,
    required this.onSignOut,
    required this.isDark,
    required this.onToggleTheme,
  });

  final List<NavEntry> entries;
  final String activeKey;
  final void Function(String key) onOpen;
  final String name;
  final String role;
  final VoidCallback onSignOut;
  final bool isDark;
  final VoidCallback onToggleTheme;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      width: 224,
      // Yantra (studio look): the rail is the board with a faint magenta wash
      // down its top (the wash in foreground: one decoration cannot paint a
      // colour and a gradient).
      foregroundDecoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0x0DE11FE0), Color(0x00E11FE0)],
          stops: <double>[0, 0.3],
        ),
      ),
      decoration: BoxDecoration(
        color: t.bgSubtle,
        border: Border(right: BorderSide(color: t.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // Product mark, with the theme toggle beside it. The toggle used to
          // sit in a top bar that existed only to hold it; one control does
          // not earn a whole row across the page.
          // Brand block, left-aligned like the nav items under it (their
          // text starts 18px in: 9px pill inset + 9px inner padding), the
          // way the HRMS portal rail places its mark. Company wordmark first
          // at a moderate size, product name as the smaller line under it
          // with the theme toggle at the row's end.
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 10, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // The PNG is white on transparent, so it is tinted to the
                // text colour or it vanishes on the light theme. 132px wide
                // keeps its 256x82 ratio (42px tall): large enough to read as
                // the brand, small enough to leave the rail breathing room.
                Image.asset(
                  'assets/ethara-logo.png',
                  width: 132,
                  fit: BoxFit.fitWidth,
                  color: t.textPrimary,
                  colorBlendMode: BlendMode.srcIn,
                  semanticLabel: 'Ethara.AI',
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        kAppName,
                        style: context.type.panelTitle.copyWith(
                          color: t.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconBtn(
                      isDark
                          ? Icons.light_mode_outlined
                          : Icons.dark_mode_outlined,
                      tooltip: isDark ? 'Switch to light' : 'Switch to dark',
                      onPressed: onToggleTheme,
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (int i = 0; i < entries.length; i++) ...<Widget>[
                    // A heading only when the group CHANGES, so the first
                    // block stays unlabelled and the daily destination sits
                    // directly under the product name.
                    if (entries[i].group.isNotEmpty &&
                        (i == 0 || entries[i - 1].group != entries[i].group))
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          14,
                          i == 0 ? 2 : 16,
                          14,
                          6,
                        ),
                        child: Text(
                          entries[i].group,
                          style: context.type.eyebrow,
                        ),
                      ),
                    _NavItem(
                      label: entries[i].label,
                      icon: entries[i].icon,
                      badge: entries[i].badge,
                      selected: entries[i].key == activeKey,
                      onTap: () => onOpen(entries[i].key),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Divider(height: 1, color: t.border),
          // THE NAME CARD OPENS THE ACCOUNT MENU.
          //
          // Account used to be a rail row beside Settings and LLM budget, which
          // made a password form about the signed-in PERSON look like a third
          // way to configure the product. A MENU rather than a straight jump to
          // the page, because there is more than one thing a person does about
          // themselves - and grouping them is what makes sign-out safe to
          // include: a named row you choose, not a target a slightly-off click
          // on the card can hit.
          _AccountMenu(
            name: name,
            role: role,
            active: activeKey == 'account',
            isDark: isDark,
            onProfile: () => onOpen('account'),
            onToggleTheme: onToggleTheme,
            onSignOut: onSignOut,
          ),
        ],
      ),
    );
  }
}

/// The signed-in person's own card, and the menu it opens.
///
/// One control for everything about the PERSON rather than the product. There
/// is deliberately no Downloads row: this app has nothing to put in it, and a
/// menu entry that opens an empty page is worse than an absent one.
class _AccountMenu extends StatelessWidget {
  final String name;
  final String role;
  final bool active;
  final bool isDark;
  final VoidCallback onProfile;
  final VoidCallback onToggleTheme;
  final VoidCallback onSignOut;

  const _AccountMenu({
    required this.name,
    required this.role,
    required this.active,
    required this.isDark,
    required this.onProfile,
    required this.onToggleTheme,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final String who = name.isEmpty ? 'Signed in' : name;

    return Padding(
      padding: const EdgeInsets.fromLTRB(9, 6, 10, 8),
      child: PopupMenuButton<String>(
        tooltip: 'Account',
        // ABOVE the card, not below it: the card sits at the bottom of the
        // rail, so a menu anchored under it would open off-screen.
        position: PopupMenuPosition.over,
        offset: const Offset(0, -8),
        color: t.bgApp,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.card,
          side: BorderSide(color: t.border),
        ),
        padding: EdgeInsets.zero,
        onSelected: (String v) => switch (v) {
          'profile' => onProfile(),
          'theme' => onToggleTheme(),
          'signout' => onSignOut(),
          _ => null,
        },
        itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
          // The header repeats the name on purpose: the card that opened the
          // menu is covered by it, and a menu about "you" that does not say
          // who you are makes the reader check by closing it again.
          PopupMenuItem<String>(
            enabled: false,
            height: 44,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  who,
                  style: context.type.small.copyWith(
                    color: t.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(role, style: context.type.tiny),
              ],
            ),
          ),
          const PopupMenuDivider(),
          _row(context, 'profile', Icons.person_outline, 'Profile'),
          _row(
            context,
            'theme',
            isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            isDark ? 'Switch to light' : 'Switch to dark',
          ),
          const PopupMenuDivider(),
          _row(context, 'signout', Icons.logout, 'Sign out', tone: t.destText),
        ],
        child: Container(
          decoration: BoxDecoration(
            color: active ? t.selected : null,
            borderRadius: BorderRadius.circular(7),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
          child: Row(
            children: <Widget>[
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: t.primarySubtle,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Text(
                  (name.isEmpty ? '?' : name.characters.first).toUpperCase(),
                  style: context.type.small.copyWith(color: t.primary),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      who,
                      style: context.type.small.copyWith(
                        color: active ? t.textPrimary : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(role, style: context.type.tiny),
                  ],
                ),
              ),
              Icon(Icons.expand_less, size: 16, color: t.textMuted),
            ],
          ),
        ),
      ),
    );
  }

  PopupMenuItem<String> _row(
    BuildContext context,
    String value,
    IconData icon,
    String label, {
    Color? tone,
  }) => PopupMenuItem<String>(
    value: value,
    height: 38,
    child: Row(
      children: <Widget>[
        Icon(icon, size: 16, color: tone ?? context.tokens.textSecondary),
        const SizedBox(width: 10),
        Text(
          label,
          style: context.type.small.copyWith(
            color: tone ?? context.tokens.textPrimary,
          ),
        ),
      ],
    ),
  );
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.badge = 0,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  /// Work waiting. Zero renders NOTHING - a grey "0" beside every row reads
  /// as a broken counter, and a badge that is always present stops being a
  /// signal at all.
  final int badge;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    // Yantra (studio look): the page you are on wears a magenta wash and its
    // icon sits on a brand-gradient chip, as in Yantra's own rail.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Ink(
            decoration: BoxDecoration(
              gradient: selected
                  ? const LinearGradient(
                      colors: <Color>[Color(0x21E11FE0), Color(0x0AE11FE0)],
                    )
                  : null,
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            child: Row(
              children: <Widget>[
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: selected ? PortalTokens.brand : null,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    icon,
                    size: 15,
                    color: selected ? Colors.white : t.textSecondary,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.body.copyWith(
                      color: selected ? t.textPrimary : t.textSecondary,
                    ),
                  ),
                ),
                if (badge > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: t.bgApp,
                      borderRadius: Radii.badge,
                      border: Border.all(color: t.border),
                    ),
                    child: Text('$badge', style: context.type.tiny),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
