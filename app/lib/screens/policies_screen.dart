import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/json.dart';
import '../core/theme/portal_tokens.dart';
import '../core/widgets/cards.dart';
import '../core/widgets/portal_page.dart';
import '../core/widgets/side_sheet.dart';
import '../core/widgets/tappable.dart';
import '../core/widgets/detail_frame.dart';
import 'shell.dart';

/// One policy page: a slug (stable, used in keys and routes), a title and its sections. The server's copy
/// (`GET /v1/talent/policies`) is the one shown; [policies] below is the copy shipped with the app, used when
/// the server cannot be reached. [version] is the label a worker accepts ("2026-11"), '' for the shipped copy.
class Policy {
  const Policy({required this.slug, required this.title, required this.summary, required this.sections, this.version = ''});

  final String slug;
  final String title;
  final String summary;
  final List<PolicySection> sections;
  final String version;

  static Policy bySlug(String slug, [List<Policy> from = policies]) =>
      from.firstWhere((p) => p.slug == slug, orElse: () => policies.firstWhere((p) => p.slug == slug, orElse: () => from.first));

  factory Policy.fromJson(Json m) => Policy(
    slug: readString(m, 'slug'),
    title: readString(m, 'title'),
    summary: readString(m, 'summary'),
    version: readString(m, 'version'),
    sections: readList(m, 'sections').whereType<Map>().map((s) => PolicySection.fromJson(Map<String, dynamic>.from(s))).toList(),
  );
}

/// A heading, short paragraphs, then bullet points. Any of the two bodies may be empty.
class PolicySection {
  const PolicySection(this.title, {this.paragraphs = const [], this.bullets = const []});

  final String title;
  final List<String> paragraphs;
  final List<String> bullets;

  factory PolicySection.fromJson(Json m) => PolicySection(
    readString(m, 'title'),
    paragraphs: readList(m, 'paragraphs').map((e) => e.toString()).toList(),
    bullets: readList(m, 'bullets').map((e) => e.toString()).toList(),
  );
}

/// Slugs only a worker needs (pay, disputes, model use, tracking, the agreement and consent). Operators and
/// clients see the conduct rules and the glossary.
const workerOnlyPolicies = {'pay-cycle', 'disputes', 'llm-use', 'tracking', 'contractor-agreement', 'dpdp-consent'};

/// The policies this person reads, in the order of [from].
List<Policy> policiesFor(List<Policy> from, {required bool worker}) => [
  for (final p in from)
    if (worker || !workerOnlyPolicies.contains(p.slug)) p,
];

const policies = <Policy>[
  Policy(
    slug: 'pay-cycle',
    title: 'Pay cycle',
    summary: 'When the week closes, what gets paid and when it lands.',
    sections: [
      PolicySection(
        'The pay week',
        paragraphs: [
          'A pay week runs from Saturday 00:00 to Friday 23:59, Indian time (IST). Every accepted unit is counted in the week its verdict was recorded.',
        ],
      ),
      PolicySection(
        'From cutoff to your bank',
        paragraphs: ['After the Friday cutoff the week moves through four steps. Nothing is paid before all four are done.'],
        bullets: [
          'Review: the accepted units of the week are added up into one statement per worker.',
          'Two approvals: two people at Yantra check and approve the statement.',
          'Payout run: the approved amounts are sent in one run, normally early the next week.',
          'Bank: the money lands in the account ops hold for you, usually within one working day of the run.',
        ],
      ),
      PolicySection(
        'Holds',
        bullets: [
          'Your first payout is held for 7 days after it is approved, once, when you start.',
          'A hold rolls the amount into the next pay window; it is never lost.',
        ],
      ),
      PolicySection(
        'What creates earnings',
        bullets: [
          'Only an accepted unit creates an earning. A unit that needs edits earns when the resubmission is accepted.',
          'The pay on a unit is frozen when the batch is published; it does not change after you claim.',
          'Review and audit work pays per completed review at the rate shown on the queue.',
        ],
      ),
      PolicySection(
        'Statements and tax',
        bullets: [
          'You get one statement per pay window, with every accepted unit on it.',
          'TDS (tax deducted at source) is withheld at your rate and shown as its own line on the statement.',
          'The statement shows the gross amount, the TDS withheld and the net amount paid.',
        ],
      ),
    ],
  ),
  Policy(
    slug: 'disputes',
    title: 'Disputes',
    summary: 'How to challenge a verdict you believe is wrong.',
    sections: [
      PolicySection(
        'Raising a dispute',
        bullets: [
          'One dispute per unit, from My work, within 14 days of the verdict.',
          'A dispute needs a reason. Say what the rubric asked for and why your answer met it.',
          'Duplicate requests on the same unit are ignored; the first one stands.',
        ],
      ),
      PolicySection(
        'How it is decided',
        paragraphs: [
          'A person reads the unit, your answer, the rubric version it was judged against and your reason. The decision is final.',
        ],
      ),
      PolicySection(
        'What the outcome changes',
        bullets: [
          'Upheld: the rejection is cleared from your quality record. Pay never changes, in either direction.',
          'Dismissed: the verdict stays as it was.',
        ],
      ),
    ],
  ),
  Policy(
    slug: 'llm-use',
    title: 'Use of AI models',
    summary: 'What you may and may not do with a language model while working.',
    sections: [
      PolicySection('Allowed', bullets: ['Spelling and grammar checks.', 'Light rephrasing of your own words.']),
      PolicySection(
        'Not allowed',
        paragraphs: ['Unless the pool says the opposite, a model must not do the work for you. That means no:'],
        bullets: [
          'having a model write the answer,',
          'having a model judge model outputs,',
          'having a model write the rationale,',
          'having a model predict what code will do.',
        ],
      ),
      PolicySection(
        'When use is detected',
        bullets: [
          'The unit is rejected with the reason code authenticity.',
          'Repeated use climbs the integrity ladder: removal from the pool, then suspension of the account.',
        ],
      ),
    ],
  ),
  Policy(
    slug: 'conduct',
    title: 'Conduct',
    summary: 'The rules of the platform and what happens when one is broken.',
    sections: [
      PolicySection(
        'Categories',
        paragraphs: ['Integrity findings fall into six categories.'],
        bullets: [
          'Time: claiming units and letting them expire, or working outside the time the claim allows.',
          'Authenticity: work that is not your own, including undisclosed model use.',
          'Identity: working under another person\'s account, or letting someone work under yours.',
          'Tooling: using tools a pool forbids, or bypassing the task form.',
          'Network: sharing units, answers or rubrics outside the platform.',
          'Confidentiality: keeping or passing on client data from a unit.',
        ],
      ),
      PolicySection(
        'The ladder',
        paragraphs: ['Each finding takes one rung. The rung depends on how serious and how repeated it is.'],
        bullets: ['1. The unit is rejected.', '2. Removal from the pool.', '3. The account is suspended.'],
      ),
      PolicySection(
        'Quality is separate from integrity',
        bullets: [
          'Low quality never claws back pay that was already accepted.',
          'Low quality affects your future eligibility for pools, not the money already earned.',
          'Integrity findings are about honesty, and they are the only thing that moves you up the ladder.',
        ],
      ),
    ],
  ),
  Policy(
    slug: 'glossary',
    title: 'Glossary',
    summary: 'The words used across the app, one line each.',
    sections: [
      PolicySection(
        'Work',
        bullets: [
          'Unit: the smallest piece of paid work, such as one clip, one caption or one comparison, with its pay and rubric version.',
          'Batch: a set of units imported together under one project, with one frozen pay.',
          'Pool: a batch you are certified for and can claim from.',
          'Claim: you taking one unit to work on. One live claim per worker, with a time limit.',
          'TTL: the time limit on a claim. When it runs out the unit goes back to the pool.',
          'Manifest: the file shipped with a delivery to the client: checksums, provenance, rubric version, counts.',
        ],
      ),
      PolicySection(
        'Judging',
        bullets: [
          'Verdict: the reviewer\'s decision on a submission: accept, needs edits or reject. Only an accept creates money.',
          'Reason code: a short code required on every rejection, such as timing or glossary.',
          'Rubric version: the exact version of the judging rules a unit was reviewed against, stored on the unit.',
          'Dispute: your one request, within 14 days, for a person to look at a verdict again.',
        ],
      ),
      PolicySection(
        'You',
        bullets: [
          'Bench: the pool of verified workers with their skills, availability and past quality.',
          'Certification: a pass on an assessment paper that opens a category of work.',
        ],
      ),
      PolicySection(
        'Money',
        bullets: [
          'Pay window: the weekly period, Saturday to Friday in Indian time, whose accepted earnings are paid together.',
          'Statement: the list of accepted units and the amounts for one pay window.',
          'Hold: an amount kept back from a payout and rolled into the next window.',
        ],
      ),
    ],
  ),
];

/// The texts a worker accepts during onboarding and the tracking policy, as shipped with the app. The server
/// holds the versions that count; these show only when it cannot be reached.
const acceptedPolicies = <Policy>[
  Policy(
    slug: 'contractor-agreement',
    title: 'Contractor agreement',
    summary: 'The terms you work under: paid per accepted unit, free to stop at any time.',
    sections: [
      PolicySection(
        'The agreement',
        paragraphs: [
          'You work as an independent contractor. You are paid per accepted unit at the rate frozen on each unit; only an accepted unit creates an earning.',
          'You keep the client\'s material confidential, you do not use automated tools where a pool forbids them, and you may stop at any time.',
          'Yantra may pause or end your access for quality or conduct reasons, with the reason given in writing. Disputes on a verdict follow the 14-day dispute process.',
          'Either side may end this agreement with notice; earnings already accepted are paid out.',
        ],
      ),
    ],
  ),
  Policy(
    slug: 'dpdp-consent',
    title: 'Data consent',
    summary: 'What personal data Yantra keeps, why, and how to withdraw consent.',
    sections: [
      PolicySection(
        'Your consent',
        paragraphs: [
          'Under the Digital Personal Data Protection Act, 2023 we ask your consent to store your name, phone, city, PAN and bank details to verify who you are, pay you and meet tax rules.',
          'Your PAN is kept as a keyed digest plus the last four digits. Your account number is encrypted by the payout service; only its last four digits are ever shown.',
          'You may withdraw consent from Profile; new work and payouts then stop. You may also ask for your data to be erased; it is done within 30 days, except what tax law requires us to keep.',
        ],
      ),
    ],
  ),
  Policy(
    slug: 'tracking',
    title: 'What we track',
    summary: 'Only while a claim is open on your screen, and only whether you are active.',
    sections: [
      PolicySection(
        'What is collected',
        bullets: [
          'Every 30 seconds while a claim is open: active (you typed, clicked or scrolled in the last minute), idle, or away (the tab was hidden).',
          'Which claim the time belongs to, and a random device id kept in your browser.',
        ],
      ),
      PolicySection(
        'What is not collected',
        bullets: [
          'Keystrokes, what you type, or what is on your screen.',
          'Window titles, other tabs or other applications.',
          'Screenshots.',
        ],
      ),
      PolicySection(
        'How it is used',
        paragraphs: [
          'Your active hours count against a weekly cap. Patterns no single person could produce are flagged for a human to review.',
          'You are paid per accepted unit, never per hour tracked.',
        ],
      ),
    ],
  ),
];

/// Every policy the app can show without the server, in reading order.
const shippedPolicies = <Policy>[...policies, ...acceptedPolicies];

/// The server's policies, or the shipped copies when the server cannot be reached. Server order wins; a
/// shipped policy the server does not know is kept at the end.
Future<List<Policy>> loadPolicies(BuildContext context) async {
  try {
    final served = await AppScope.of(context).talent.policies();
    if (served.isEmpty) return shippedPolicies;
    final slugs = {for (final p in served) p.slug};
    return [
      ...served,
      for (final p in shippedPolicies)
        if (!slugs.contains(p.slug)) p,
    ];
  } on Object {
    return shippedPolicies;
  }
}

/// Reads one policy in a side sheet without leaving the page (the work screen's "What we track", the
/// onboarding texts). [load] fetches the served copy; the shipped copy shows while it loads or if it fails.
Future<void> showPolicySheet(BuildContext context, String slug, {Future<Policy> Function()? load}) {
  final shipped = Policy.bySlug(slug, shippedPolicies);
  return showSideSheet<void>(
    context,
    title: shipped.title,
    width: 520,
    builder: (ctx) => FutureBuilder<Policy>(
      future: load?.call(),
      builder: (ctx, snap) => SingleChildScrollView(
        padding: const EdgeInsets.all(Space.x16),
        child: _PolicyBody(policy: snap.data ?? shipped),
      ),
    ),
  );
}

/// Full-screen policies reader: a side list above [Layout.twoColumn], a dropdown below.
class PoliciesScreen extends StatefulWidget {
  const PoliciesScreen({super.key, this.initial = 'pay-cycle'});

  final String initial;

  @override
  State<PoliciesScreen> createState() => _PoliciesScreenState();
}

class _PoliciesScreenState extends State<PoliciesScreen> {
  List<Policy> _all = shippedPolicies;
  late Policy _policy = Policy.bySlug(widget.initial, shippedPolicies);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final worker = AppScope.of(context).session.roles.contains('worker');
    final all = policiesFor(await loadPolicies(context), worker: worker);
    if (!mounted || all.isEmpty) return;
    setState(() {
      _all = all;
      _policy = Policy.bySlug(widget.initial, all);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return DetailFrame(
      crumbs: [
        const Crumb('You'),
        Crumb('Profile', path: Destination.profile.path),
        const Crumb('Policies'),
      ],
      body: LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= Layout.twoColumn;
          final reader = PortalPage(
            maxWidth: Layout.pageMaxNarrow,
            children: [
              if (!wide)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.x16),
                  child: DropdownButtonFormField<String>(
                    key: const Key('policy-picker'),
                    initialValue: _policy.slug,
                    decoration: const InputDecoration(labelText: 'Policy'),
                    items: [for (final p in _all) DropdownMenuItem(value: p.slug, child: Text(p.title))],
                    onChanged: (slug) {
                      if (slug != null) setState(() => _policy = Policy.bySlug(slug, _all));
                    },
                  ),
                ),
              _PolicyBody(policy: _policy),
            ],
          );
          if (!wide) return reader;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: Layout.tocWidth,
                decoration: BoxDecoration(
                  color: t.bgApp,
                  border: Border(right: BorderSide(color: t.border)),
                ),
                child: ListView(
                  padding: const EdgeInsets.all(Space.x12),
                  children: [
                    for (final p in _all) _PolicyNav(policy: p, active: p.slug == _policy.slug, onTap: () => setState(() => _policy = p)),
                  ],
                ),
              ),
              Expanded(child: reader),
            ],
          );
        },
      ),
    );
  }
}

class _PolicyNav extends StatelessWidget {
  const _PolicyNav({required this.policy, required this.active, required this.onTap});
  final Policy policy;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.x2),
      child: Material(
        color: active ? t.primarySubtle : Colors.transparent,
        borderRadius: Radii.rMd,
        child: PortalTappable(
          key: Key('policy-nav-${policy.slug}'),
          onTap: onTap,
          selected: active,
          child: Container(
            constraints: const BoxConstraints(minHeight: 36),
            padding: const EdgeInsets.symmetric(horizontal: Space.x12, vertical: Space.x6),
            alignment: Alignment.centerLeft,
            child: Text(policy.title, style: theme.textTheme.labelLarge?.copyWith(color: active ? t.primary : t.textPrimary)),
          ),
        ),
      ),
    );
  }
}

class _PolicyBody extends StatelessWidget {
  const _PolicyBody({required this.policy});
  final Policy policy;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    return Column(
      key: Key('policy-body-${policy.slug}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(policy.title, style: theme.textTheme.headlineMedium),
        const SizedBox(height: Space.x4),
        Text(policy.summary, style: theme.textTheme.bodyMedium?.copyWith(color: t.textSecondary)),
        if (policy.version.isNotEmpty) ...[
          const SizedBox(height: Space.x4),
          Text(
            'Version ${policy.version}',
            key: const Key('policy-version'),
            style: theme.textTheme.labelMedium?.copyWith(color: t.textSecondary),
          ),
        ],
        const SizedBox(height: Space.x20),
        for (final s in policy.sections)
          PortalCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.title, style: theme.textTheme.titleMedium),
                for (final p in s.paragraphs) ...[const SizedBox(height: Space.x8), Text(p, style: theme.textTheme.bodyMedium)],
                if (s.bullets.isNotEmpty) const SizedBox(height: Space.x8),
                for (final b in s.bullets)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.x4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 8, right: Space.x10),
                          child: Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(color: t.textMuted, shape: BoxShape.circle),
                          ),
                        ),
                        Expanded(child: Text(b, style: theme.textTheme.bodyMedium)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
