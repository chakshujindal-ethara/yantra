import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/models.dart';
import '../app_scope.dart';
import '../core/errors.dart';
import '../core/format.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/portal_tokens.dart';
import '../core/widgets/cards.dart';
import '../core/widgets/portal_page.dart';
import '../widgets/load_view.dart';
import 'shell.dart';
import '../core/widgets/loader.dart';

enum _Filter { all, unread }

/// Verdicts, payouts and notices, newest first, grouped by day. Opening an item marks it read; the
/// shell's bell follows the unread count. Email settings live in Profile.
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key, this.clock});

  final DateTime Function()? clock;

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  final _loadKey = GlobalKey<LoadViewState<List<InboxItem>>>();
  List<InboxItem> _items = const [];
  final Set<String> _expanded = {};
  _Filter _filter = _Filter.all;
  bool _markingAll = false;

  DateTime get _now => (widget.clock ?? DateTime.now)();

  int get _unread => _items.where((i) => !i.isRead).length;

  Future<List<InboxItem>> _load() async {
    final items = await AppScope.of(context).notify.inbox();
    items.sort((a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)));
    _items = items;
    _expanded.clear();
    _pushUnread();
    return items;
  }

  void _pushUnread() {
    if (mounted) ShellActions.of(context).setUnread(_unread);
  }

  Future<void> _open(InboxItem item) async {
    setState(() {
      if (!_expanded.remove(item.id)) _expanded.add(item.id);
    });
    if (!item.isRead) await _markRead(item);
  }

  /// Marks one item read on the server, then locally. Returns false (and shows why) when it failed.
  Future<bool> _markRead(InboxItem item) async {
    final scope = AppScope.of(context);
    final action = 'read:${item.id}';
    try {
      await scope.notify.markRead(item.id, key: scope.keys.start(action));
      scope.keys.finish(action);
    } on AppException catch (e) {
      scope.keys.settle(action, e);
      if (mounted) toast(context, describeError(e));
      return false;
    }
    if (!mounted) return false;
    final at = _now;
    setState(() => _items = [for (final i in _items) i.id == item.id ? i.asRead(at) : i]);
    _pushUnread();
    return true;
  }

  Future<void> _markAllRead() async {
    setState(() => _markingAll = true);
    try {
      for (final item in _items.where((i) => !i.isRead).toList()) {
        if (!await _markRead(item)) break;
      }
    } finally {
      if (mounted) setState(() => _markingAll = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LoadView<List<InboxItem>>(
      key: _loadKey,
      load: _load,
      builder: (context, _, reload) {
        final shown = _filter == _Filter.all ? _items : _items.where((i) => !i.isRead).toList();
        return PortalPage(
          kicker: 'You',
          title: 'Inbox',
          subtitle: 'Verdicts, payouts and notices',
          onRefresh: reload,
          actions: [
            SegmentedButton<_Filter>(
              key: const Key('inbox-filter'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: _Filter.all, label: Text('All')),
                ButtonSegment(value: _Filter.unread, label: Text('Unread')),
              ],
              selected: {_filter},
              onSelectionChanged: (s) => setState(() => _filter = s.first),
            ),
          ],
          children: [
            if (_items.isEmpty)
              const PortalCard(child: EmptyView(message: 'No notifications yet. Verdicts and payouts land here.'))
            else ...[
              _Toolbar(unread: _unread, busy: _markingAll, onMarkAll: _markAllRead),
              if (shown.isEmpty)
                const PortalCard(child: EmptyView(message: 'Nothing unread. You are all caught up.'))
              else
                for (final (label, items) in _groupByDay(shown, _now)) ...[
                  _DayLabel(label),
                  for (final item in items)
                    _InboxCard(
                      key: Key('inbox-${item.id}'),
                      item: item,
                      expanded: _expanded.contains(item.id),
                      now: _now,
                      onTap: () => _open(item),
                    ),
                ],
            ],
          ],
        );
      },
    );
  }
}

/// Items in their given order, cut into Today / Yesterday / `3 Nov` runs by local calendar day.
List<(String, List<InboxItem>)> _groupByDay(List<InboxItem> items, DateTime now) {
  final groups = <(String, List<InboxItem>)>[];
  for (final item in items) {
    final label = _dayLabel(item.createdAt, now);
    if (groups.isNotEmpty && groups.last.$1 == label) {
      groups.last.$2.add(item);
    } else {
      groups.add((label, [item]));
    }
  }
  return groups;
}

String _dayLabel(DateTime? at, DateTime now) {
  if (at == null) return 'Earlier';
  final d = at.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final days = today.difference(day).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  return shortDate(d, now: now);
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.unread, required this.busy, required this.onMarkAll});
  final int unread;
  final bool busy;
  final VoidCallback onMarkAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.x4),
      child: Row(
        children: [
          Expanded(child: Text(unread == 0 ? 'All read' : '$unread unread', style: theme.textTheme.labelMedium)),
          TextButton(
            key: const Key('mark-all-read'),
            onPressed: unread == 0 || busy ? null : onMarkAll,
            child: const Text('Mark all read'),
          ),
        ],
      ),
    );
  }
}

class _DayLabel extends StatelessWidget {
  const _DayLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Space.x8, bottom: Space.x8),
      child: Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 0.4)),
    );
  }
}

/// Kinds are `verdict_accepted`, `verdict_rejected`, `verdict_needs_edits`, `payout_paid`, ... (as notify emits);
/// the prefix test also accepts the dotted spelling.
IconData _iconFor(String kind) {
  if (kind.startsWith('verdict')) return Icons.rule_outlined;
  if (kind.startsWith('payout') || kind.startsWith('window') || kind.startsWith('adjustment')) return Icons.payments_outlined;
  if (kind.startsWith('application')) return Icons.work_outline;
  if (kind.startsWith('bank')) return Icons.account_balance_outlined;
  return Icons.notifications_outlined;
}

/// Where an item leads: the page that shows what it is about, and the words on the link. Null when it is
/// only news (erasure done, a reply on a ticket).
({String label, String path})? inboxTarget(String kind) => switch (kind) {
  _ when kind.startsWith('verdict') => (label: 'See my work', path: '/work/my-work'),
  'payout_paid' || 'adjustment_approved' => (label: 'See earnings', path: '/work/earnings'),
  _ when kind.startsWith('payout') => (label: 'See earnings', path: '/work/earnings'),
  _ when kind.startsWith('application') => (label: 'See applications', path: '/work/applications'),
  'bank_rejected' => (label: 'Fix bank account', path: '/work/home/onboarding'),
  'bank_verified' => (label: 'See onboarding', path: '/work/home/onboarding'),
  _ => null,
};

class _InboxCard extends StatelessWidget {
  const _InboxCard({super.key, required this.item, required this.expanded, required this.now, required this.onTap});
  final InboxItem item;
  final bool expanded;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final unread = !item.isRead;
    final created = item.createdAt;
    return PortalCard(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: t.bgMuted, borderRadius: Radii.rMd),
            child: Icon(_iconFor(item.kind), color: t.textSecondary),
          ),
          const SizedBox(width: Space.x12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (unread) ...[
                      Container(
                        key: Key('unread-dot-${item.id}'),
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: t.primary, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: Space.x8),
                    ],
                    Expanded(
                      child: Text(
                        item.subject,
                        style: theme.textTheme.bodyMedium?.merge(AppTheme.weight(unread ? FontWeight.w600 : FontWeight.w400)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.x4),
                Text(
                  item.body,
                  style: theme.textTheme.bodySmall,
                  maxLines: expanded ? null : 2,
                  overflow: expanded ? null : TextOverflow.ellipsis,
                ),
                if (inboxTarget(item.kind) case final target? when expanded)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: Key('inbox-open-${item.id}'),
                      style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: Space.x4)),
                      onPressed: () => context.go(target.path),
                      child: Text(target.label),
                    ),
                  ),
              ],
            ),
          ),
          if (created != null) ...[
            const SizedBox(width: Space.x12),
            Text(
              relative(created, now: now),
              style: AppTheme.mono(context, fontSize: 11, color: t.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}
