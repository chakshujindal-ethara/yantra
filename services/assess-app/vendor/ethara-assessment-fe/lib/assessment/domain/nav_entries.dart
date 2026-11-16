import 'package:flutter/material.dart';

import 'enums.dart';

/// One entry in the left navigation.
class NavEntry {
  const NavEntry(
    this.key,
    this.label,
    this.icon, {
    this.group = '',
    this.badge = 0,
  });

  /// Matches the tab keys the section already routes on, so moving these into
  /// the sidebar did not need a second routing vocabulary.
  final String key;
  final String label;
  final IconData icon;

  /// The heading this entry sits under. Empty means "no heading" - the first
  /// block is deliberately unlabelled so the daily destination is the first
  /// thing under the product name rather than under a category.
  final String group;

  /// A count worth interrupting for (work waiting), never a total. A badge on
  /// every row is wallpaper; a badge on the two rows that need action is a
  /// signal.
  final int badge;
}

/// The operator sections, grouped the way the work actually flows.
///
/// Grouped, not flat, to match the reference design (`assessments.html`):
/// AUTHORING / RESULTS / PLATFORM, with the daily destination above every
/// heading. Badge counts come from the caller - only the store knows them.
/// The operator rail, narrowed to what [role] may open.
///
/// FILTERED HERE, ONCE, rather than at the sidebar: `_openTab`, `_activeTabKey`
/// and `_page` all key off these entries, and a row that renders without a
/// route (or a route with no row) is the exact drift `sidebar_reachable_test`
/// exists to catch. Filtering the source list keeps all four in step.
///
/// The rail is not the security boundary - the server refuses what it refuses.
/// This is so a read-only Manager is not shown three sections that answer 403.
List<NavEntry> operatorNav({
  int reviewCount = 0,
  int responseCount = 0,
  AccessRole role = AccessRole.admin,
}) => <NavEntry>[
  for (final NavEntry e in _operatorNavAll(
    reviewCount: reviewCount,
    responseCount: responseCount,
  ))
    if (role.navKeys == null || role.navKeys!.contains(e.key)) e,
];

List<NavEntry> _operatorNavAll({
  int reviewCount = 0,
  int responseCount = 0,
}) => <NavEntry>[
  // Ungrouped: the daily entry points, above any heading. Dashboard FIRST
  // because it is the landing screen after sign-in, so the lit row is the one
  // the operator is actually looking at.
  const NavEntry('analytics', 'Dashboard', Icons.insights_outlined),
  const NavEntry('assessments', 'Assessments', Icons.assignment_outlined),
  const NavEntry(
    'generators',
    'Generators',
    Icons.auto_awesome_outlined,
    group: 'AUTHORING',
  ),
  NavEntry(
    'review',
    'Review Queue',
    Icons.rule_outlined,
    group: 'AUTHORING',
    badge: reviewCount,
  ),
  const NavEntry(
    'bank',
    'Question Bank',
    Icons.inventory_2_outlined,
    group: 'AUTHORING',
  ),
  const NavEntry('tags', 'Tags', Icons.sell_outlined, group: 'AUTHORING'),
  // Last under AUTHORING: forms are authored here but respond on their own
  // cadence, so the row sits after the question-bank flow rather than inside
  // it.
  const NavEntry(
    'forms',
    'Form Studio',
    Icons.dynamic_form_outlined,
    group: 'AUTHORING',
  ),
  NavEntry(
    'responses',
    'Responses',
    Icons.fact_check_outlined,
    group: 'RESULTS',
    badge: responseCount,
  ),
  const NavEntry(
    'budget',
    'LLM Budget',
    Icons.savings_outlined,
    group: 'PLATFORM',
  ),
  // The per-call spend log is NOT on the rail: it is one click from LLM
  // budget, and the two link to each other both ways.
  //
  // STAGES IS NOT A RAIL ROW EITHER. A page ABOUT the sidebar sections does
  // not belong in the list of sidebar sections; it is reached from the
  // dashboard ("Go to Stages") and returns there by the button in that slot.
  const NavEntry(
    'settings',
    'Settings',
    Icons.settings_outlined,
    group: 'PLATFORM',
  ),
  // ACCOUNT IS NOT A RAIL ROW. It is reached by clicking your own name in the
  // card at the foot of the sidebar - see `_Sidebar` in `app_shell.dart`.
  //
  // Every other destination is part of the PRODUCT; this one is a password
  // form about the person holding the session, and under PLATFORM it read as
  // a third kind of settings next to Settings and LLM budget.
];

/// The candidate's destinations. No groups: two rows do not need headings.
///
/// Account is not here either, for the reason given in `operatorNav`. It
/// matters MORE to a candidate - they sign in with the shared default password
/// their account was provisioned with, and this is the only place that changes
/// it - but the name card is on this rail too, which is where someone looks
/// for their own password before a list of product sections.
List<NavEntry> memberNav() => const <NavEntry>[
  NavEntry('mine', 'My Assessments', Icons.assignment_outlined),
  NavEntry('performance', 'My Performance', Icons.trending_up_outlined),
];
