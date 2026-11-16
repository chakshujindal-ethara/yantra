import 'package:flutter/material.dart';

import '../api/talent_models.dart';
import '../app_scope.dart';
import '../core/format.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/portal_tokens.dart';
import '../core/widgets/cards.dart';
import '../core/widgets/portal_page.dart';
import '../core/widgets/tables.dart';
import '../widgets/load_view.dart';
import 'listing_screen.dart';
import '../app_router.dart';
import 'package:go_router/go_router.dart';

/// Every open listing as a card, filtered by domain and commitment. A card opens the listing.
class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  final _loadKey = GlobalKey<LoadViewState<List<Listing>>>();
  String? _domain;
  String? _commitment;

  Future<List<Listing>> _load() => AppScope.of(context).talent.listings();

  Future<void> _open(Listing listing) async {
    await context.push(Paths.listing(listing.id));
    await _loadKey.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return LoadView<List<Listing>>(
      firstWait: LoadWait.brand,
      key: _loadKey,
      load: _load,
      builder: (context, listings, reload) {
        final domains = {for (final l in listings) l.domain}.where((d) => d.isNotEmpty).toList()..sort();
        final commitments = {for (final l in listings) l.commitment}.where((c) => c.isNotEmpty).toList()..sort();
        final shown = [
          for (final l in listings)
            if ((_domain == null || l.domain == _domain) && (_commitment == null || l.commitment == _commitment)) l,
        ];
        return PortalPage(
          kicker: 'Work · Explore',
          title: 'Explore',
          subtitle: 'Pools you can apply to; the ones with open slots first',
          onRefresh: reload,
          children: [
            if (listings.isEmpty)
              const PortalCard(
                key: Key('explore-empty'),
                child: EmptyView(message: 'No open pools right now; your certifications unlock pools automatically.'),
              )
            else ...[
              Toolbar(
                children: [
                  if (domains.length > 1)
                    FilterChips<String>(
                      values: {'All domains': null, for (final d in domains) humanize(d): d},
                      selected: _domain,
                      onSelected: (v) => setState(() => _domain = v),
                    ),
                  if (commitments.length > 1)
                    FilterChips<String>(
                      values: {'Any commitment': null, for (final c in commitments) _commitmentLabel(c): c},
                      selected: _commitment,
                      onSelected: (v) => setState(() => _commitment = v),
                    ),
                ],
              ),
              if (shown.isEmpty)
                const PortalCard(child: EmptyView(message: 'No pools match these filters.'))
              else
                _CardGrid(
                  children: [for (final l in shown) ListingCard(listing: l, onTap: () => _open(l))],
                ),
            ],
          ],
        );
      },
    );
  }

  static String _commitmentLabel(String c) => switch (c) {
    'task_based' => 'Task-based',
    'part_time' => 'Part-time',
    _ => humanize(c),
  };
}

/// Two columns of cards at or above [Layout.twoColumn], one below.
class _CardGrid extends StatelessWidget {
  const _CardGrid({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final columns = c.maxWidth >= Layout.twoColumn ? 2 : 1;
        final width = (c.maxWidth - Layout.gap * (columns - 1)) / columns;
        return Wrap(
          spacing: Layout.gap,
          runSpacing: 0,
          children: [for (final child in children) SizedBox(width: width, child: child)],
        );
      },
    );
  }
}

/// One listing: title, domain, pay range, commitment, slots left, and the worker's own standing.
class ListingCard extends StatelessWidget {
  const ListingCard({super.key, required this.listing, required this.onTap});
  final Listing listing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final status = listing.viewer.applicationStatus;
    return Semantics(
      button: true,
      label: 'Open ${listing.title}',
      child: PortalCard(
        key: Key('listing-${listing.id}'),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: Space.x8,
              runSpacing: Space.x8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DomainChip(listing.domain),
                if (listing.viewer.prequalified) const StatusChip('Prequalified', kind: StatusKind.success),
                if (listing.hiredThisWeek > 0) HiredChip(listing.hiredThisWeek),
                if (status.isNotEmpty) StatusChip(applicationLabel(status), kind: applicationKind(status)),
              ],
            ),
            const SizedBox(height: Space.x10),
            Text(listing.title, style: theme.textTheme.titleMedium),
            if (listing.summary.isNotEmpty) ...[
              const SizedBox(height: Space.x2),
              Text(listing.summary, style: theme.textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
            const SizedBox(height: Space.x12),
            Text(listing.payLabel, style: AppTheme.figure(context, fontSize: 14)),
            const SizedBox(height: Space.x8),
            Row(
              children: [
                Icon(Icons.schedule_outlined, size: Sizes.iconSm, color: t.textMuted),
                const SizedBox(width: Space.x6),
                Expanded(
                  child: Text(
                    '${listing.commitmentLabel}${listing.hoursPerWeek > 0 ? ' · ${listing.hoursPerWeek} h per week' : ''}',
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: Space.x8),
                SlotsChip(listing),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// "3 hired this week": how fast a pool is taking people, on the card and the listing page.
class HiredChip extends StatelessWidget {
  const HiredChip(this.count, {super.key});
  final int count;

  @override
  Widget build(BuildContext context) => StatusChip('$count hired this week', key: const Key('hired-this-week'), kind: StatusKind.info);
}
