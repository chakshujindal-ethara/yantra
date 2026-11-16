import 'package:flutter/material.dart';

import '../../api/support_models.dart';
import '../../app_scope.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/portal_tokens.dart';
import '../../core/widgets/action_dialog.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/loader.dart';
import '../../core/widgets/people.dart';
import '../../core/widgets/portal_page.dart';
import '../../core/widgets/side_sheet.dart';
import '../../core/widgets/tables.dart';
import '../../widgets/load_view.dart';

/// Support for the operator: a board of tickets (open, in progress, resolved) with a drawer per ticket.
class SupportScreen extends StatefulWidget {
  const SupportScreen({super.key});

  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

/// Below this width the board becomes filter chips over one list.
const _boardMinWidth = Layout.twoColumn;

const _columns = [('open', 'Open'), ('in_progress', 'In progress'), ('resolved', 'Resolved')];

(String, StatusKind) ticketStatus(String status) => switch (status) {
  'open' => ('Open', StatusKind.warn),
  'in_progress' => ('In progress', StatusKind.info),
  'resolved' => ('Resolved', StatusKind.success),
  _ => (humanize(status), StatusKind.info),
};

class _SupportScreenState extends State<SupportScreen> {
  final _loader = GlobalKey<LoadViewState<List<Ticket>>>();
  String? _filter;
  String _q = '';

  Future<void> _open(Ticket t) async {
    var changed = false;
    await showSideSheet<void>(
      context,
      title: t.title,
      builder: (_) => _TicketSheet(ticket: t, onChanged: () => changed = true),
    );
    if (changed) await _loader.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return PortalPage(
      kicker: 'Operate · Support',
      title: 'Support',
      subtitle: 'Tickets from workers and clients',
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Space.x12),
          child: TextField(
            key: const Key('support-search'),
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search title, text, person or page…'),
            onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
          ),
        ),
        LoadView<List<Ticket>>(
          firstWait: LoadWait.brand,
          wrapInCard: true,
          key: _loader,
          load: () => AppScope.of(context).support.all(),
          isEmpty: (t) => t.isEmpty,
          emptyMessage: 'No tickets. A person reports a problem from their Profile; it lands here.',
          builder: (context, all, _) {
            final tickets = all.where((t) => t.matches(_q)).toList();
            if (tickets.isEmpty) return EmptyView(message: 'No ticket matches "$_q"');
            return LayoutBuilder(
              builder: (context, c) => c.maxWidth >= _boardMinWidth
                  ? _Board(tickets: tickets, onOpen: _open)
                  : _NarrowList(tickets: tickets, filter: _filter, onFilter: (f) => setState(() => _filter = f), onOpen: _open),
            );
          },
        ),
      ],
    );
  }
}

class _Board extends StatelessWidget {
  const _Board({required this.tickets, required this.onOpen});
  final List<Ticket> tickets;
  final void Function(Ticket) onOpen;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, (status, label)) in _columns.indexed) ...[
          if (i > 0) const SizedBox(width: Space.x12),
          Expanded(
            child: Container(
              key: Key('column-$status'),
              padding: const EdgeInsets.all(Space.x8),
              decoration: BoxDecoration(color: t.bgMuted, borderRadius: Radii.rMd),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Space.x8, Space.x4, Space.x8, Space.x8),
                    child: Row(
                      children: [
                        Expanded(child: Text(label, style: theme.textTheme.titleSmall)),
                        Text(
                          '${tickets.where((x) => x.status == status).length}',
                          style: AppTheme.mono(context, fontSize: 12, color: t.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  for (final x in tickets.where((x) => x.status == status)) _TicketCard(ticket: x, onTap: () => onOpen(x)),
                  if (!tickets.any((x) => x.status == status))
                    Padding(
                      padding: const EdgeInsets.all(Space.x12),
                      child: Text('Nothing ${label.toLowerCase()}', style: theme.textTheme.bodySmall?.copyWith(color: t.textMuted)),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _NarrowList extends StatelessWidget {
  const _NarrowList({required this.tickets, required this.filter, required this.onFilter, required this.onOpen});
  final List<Ticket> tickets;
  final String? filter;
  final void Function(String?) onFilter;
  final void Function(Ticket) onOpen;

  @override
  Widget build(BuildContext context) {
    final shown = tickets.where((x) => filter == null || x.status == filter).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Space.x12),
          child: FilterChips<String>(values: {'All': null, for (final (s, l) in _columns) l: s}, selected: filter, onSelected: onFilter),
        ),
        if (shown.isEmpty)
          PortalCard(child: EmptyView(message: 'Nothing ${ticketStatus(filter ?? '').$1.toLowerCase()} right now.'))
        else
          for (final x in shown) _TicketCard(ticket: x, onTap: () => onOpen(x)),
      ],
    );
  }
}

class _TicketCard extends StatelessWidget {
  const _TicketCard({required this.ticket, required this.onTap});
  final Ticket ticket;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final created = ticket.createdAt;
    return PortalCard(
      key: Key('ticket-${ticket.id}'),
      onTap: onTap,
      margin: const EdgeInsets.only(bottom: Space.x8),
      padding: const EdgeInsets.all(Space.x12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Space.x8,
            runSpacing: Space.x4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusChip(humanize(ticket.category), kind: StatusKind.info),
              if (ticket.screen.isNotEmpty) Text(ticket.screen, style: theme.textTheme.labelSmall),
            ],
          ),
          const SizedBox(height: Space.x6),
          Text(ticket.title, style: theme.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: Space.x4),
          Row(
            children: [
              Flexible(
                child: NameOf(
                  ticket.authorId,
                  name: ticket.authorName,
                  style: theme.textTheme.labelMedium?.copyWith(color: t.textSecondary),
                ),
              ),
              const Spacer(),
              if (created != null) Text(relative(created), style: theme.textTheme.labelSmall),
            ],
          ),
        ],
      ),
    );
  }
}

/// The ticket in the drawer: body, context, where it stands, and the move it allows.
class _TicketSheet extends StatefulWidget {
  const _TicketSheet({required this.ticket, required this.onChanged});
  final Ticket ticket;

  /// Told once a move landed, so the board behind reloads when the sheet closes.
  final VoidCallback onChanged;

  @override
  State<_TicketSheet> createState() => _TicketSheetState();
}

class _TicketSheetState extends State<_TicketSheet> {
  late Ticket _t = widget.ticket;
  final _note = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _move(String status, {required String done}) async {
    final scope = AppScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final t = await withActionKey(
        scope.keys,
        'ticket:${_t.id}:$status',
        (key) => scope.support.setStatus(_t.id, status: status, note: _note.text.trim(), key: key),
      );
      if (!mounted) return;
      setState(() => _t = t);
      widget.onChanged();
      _note.clear();
      toast(context, done);
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = PortalTokens.of(context);
    final t = _t;
    final (label, kind) = ticketStatus(t.status);
    final created = t.createdAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: Space.x8,
          runSpacing: Space.x6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            StatusChip(label, key: const Key('ticket-status'), kind: kind),
            StatusChip(humanize(t.category), kind: StatusKind.info),
            if (t.screen.isNotEmpty) Text('on ${t.screen}', style: theme.textTheme.labelSmall),
          ],
        ),
        const SizedBox(height: Space.x12),
        Text(t.body, style: theme.textTheme.bodyMedium),
        const SizedBox(height: Space.x12),
        if (t.authorName.isNotEmpty) LabelValue(label: 'Author', value: t.authorName),
        LabelValue(label: t.authorName.isEmpty ? 'Author' : 'Author id', value: t.authorId.isEmpty ? '—' : t.authorId, mono: true),
        if (created != null) LabelValue(label: 'Raised', value: dateTime(created)),
        if (t.context.isNotEmpty) ...[
          Text('Context', style: theme.textTheme.labelMedium),
          const SizedBox(height: Space.x4),
          Wrap(
            spacing: Space.x8,
            runSpacing: Space.x4,
            children: [
              for (final e in t.context.entries)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: Space.x8, vertical: Space.x2),
                  decoration: BoxDecoration(color: tokens.bgMuted, borderRadius: Radii.rFull),
                  child: Text('${e.key}: ${e.value}', style: AppTheme.mono(context, fontSize: 12, color: tokens.textSecondary)),
                ),
            ],
          ),
        ],
        if (t.note.isNotEmpty) ...[
          const SizedBox(height: Space.x12),
          Text('Ops note', style: theme.textTheme.labelMedium),
          Text(t.note, key: const Key('ticket-note-shown'), style: theme.textTheme.bodyMedium),
        ],
        const SizedBox(height: Space.x16),
        Divider(color: tokens.borderSubtle),
        const SizedBox(height: Space.x12),
        ErrorBanner(_error),
        if (!t.isResolved) ...[
          TextField(
            key: const Key('ticket-note'),
            controller: _note,
            enabled: !_busy,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(labelText: t.isOpen ? 'Note (optional)' : 'What was done'),
          ),
          const SizedBox(height: Space.x12),
        ],
        Wrap(
          spacing: Space.x8,
          runSpacing: Space.x8,
          children: [
            if (t.isOpen)
              FilledButton(
                key: const Key('ticket-start'),
                onPressed: _busy ? null : () => _move('in_progress', done: 'Started'),
                child: const Text('Start'),
              ),
            if (t.isInProgress)
              FilledButton(
                key: const Key('ticket-resolve'),
                onPressed: _busy ? null : () => _move('resolved', done: 'Resolved'),
                child: const Text('Resolve'),
              ),
            if (t.isResolved)
              OutlinedButton(
                key: const Key('ticket-reopen'),
                onPressed: _busy ? null : () => _move('open', done: 'Reopened'),
                child: const Text('Reopen'),
              ),
          ],
        ),
      ],
    );
  }
}
