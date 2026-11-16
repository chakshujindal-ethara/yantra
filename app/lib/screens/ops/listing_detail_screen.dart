import 'package:flutter/material.dart' hide StepState;
import '../../core/widgets/people.dart';
import '../../core/widgets/side_sheet.dart';

import '../../api/ops_models.dart';
import '../../app_scope.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/portal_tokens.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/form_sheet.dart';
import '../../core/widgets/loader.dart';
import '../../core/widgets/portal_page.dart';
import '../../core/widgets/stage_bar.dart';
import '../../core/widgets/steps.dart';
import '../../core/widgets/tables.dart';
import '../../widgets/load_view.dart';
import '../shell.dart';
import 'listings_screen.dart';
import '../../core/money.dart';
import '../../core/widgets/detail_frame.dart';

/// One listing as a pushed route: edit, open or close it, and the applications pipeline (applied →
/// screening → offered → accepted) as columns on a desktop, a filtered list on a phone.
class ListingDetailScreen extends StatefulWidget {
  const ListingDetailScreen({super.key, required this.listingId});
  final String listingId;

  @override
  State<ListingDetailScreen> createState() => _ListingDetailScreenState();
}

typedef ListingView = ({Listing listing, List<Application> applications});

/// The four pipeline columns; `applied` also holds applicants sitting the paper.
const pipeline = [
  ('Applied', ['applied', 'assessment']),
  ('Screening', ['screening']),
  ('Offered', ['offered']),
  ('Accepted', ['accepted']),
];

class _ListingDetailScreenState extends State<ListingDetailScreen> {
  String? _error;
  bool _busy = false;
  Future<void> Function()? _reload;

  Future<ListingView> _load() async {
    final ops = AppScope.of(context).ops;
    final listing = await ops.listing(widget.listingId);
    final applications = await ops.applications(widget.listingId);
    return (listing: listing, applications: applications);
  }

  Future<void> _run(String action, Future<Object?> Function(String key) call, {required String done}) async {
    final scope = AppScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await call(scope.keys.start(action));
      scope.keys.finish(action);
      scope.stale.mark([Destination.listings]);
      if (!mounted) return;
      toast(context, done);
      await _reload?.call();
    } on Object catch (e) {
      scope.keys.settle(action, e);
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(Listing l) async {
    final saved = await showDialog<Listing>(
      context: context,
      builder: (_) => ListingFormDialog(initial: l),
    );
    if (saved == null || !mounted) return;
    AppScope.of(context).stale.mark([Destination.listings]);
    toast(context, 'Listing saved');
    await _reload?.call();
  }

  Future<void> _setStatus(Listing l, String status) async {
    final ops = AppScope.of(context).ops;
    if (status == 'closed') {
      final ok = await confirm(
        context,
        title: 'Close "${l.title}"?',
        body: 'Workers stop seeing it and nobody new can apply. Applications already in the pipeline keep going.',
        confirmLabel: 'Close listing',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    // the target is part of the action: a key kept after a failed close is never reused to open
    await _run(
      'listing:status:${l.id}:$status',
      (key) => ops.patchListing(l.id, {'status': status}, key: key),
      done: status == 'open' ? 'Listing is open' : 'Listing closed',
    );
  }

  Future<void> _decide(Application a, {required bool offer}) async {
    final ops = AppScope.of(context).ops;
    final result = await showDialog<(String, int?)>(
      context: context,
      builder: (_) => _DecideDialog(application: a, offer: offer),
    );
    if (result == null || !mounted) return;
    final (note, days) = result;
    await _run(
      'application:${offer ? 'offer' : 'reject'}:${a.id}',
      (key) => ops.decide(a.id, decision: offer ? 'offer' : 'reject', note: note, offerDays: days, key: key),
      done: offer ? 'Offer sent to ${a.workerName.isEmpty ? shortId(a.workerId) : a.workerName}' : 'Application rejected',
    );
  }

  /// The applicant in a side sheet: answers against the listing's questions, steps, the paper, the note;
  /// Offer and Reject from there pop the sheet and run the same decision as the card buttons.
  Future<void> _openApplicant(Listing l, Application a) async {
    final choice = await showSideSheet<bool>(
      context,
      title: a.workerName.isEmpty ? 'Applicant ${shortId(a.workerId)}' : a.workerName,
      builder: (_) => _ApplicantSheet(listing: l, application: a),
    );
    if (choice == null || !mounted) return;
    await _decide(a, offer: choice);
  }

  @override
  Widget build(BuildContext context) {
    return DetailFrame(
      crumbs: [
        const Crumb('Operate'),
        Crumb('Listings', path: Destination.listings.path),
        const Crumb('Listing'),
      ],
      body: LoadView<ListingView>(
        firstWait: LoadWait.brand,
        load: _load,
        builder: (context, v, reload) {
          _reload = reload;
          final l = v.listing;
          return PortalPage(
            kicker: 'Operate · Listing',
            title: l.title,
            subtitle:
                '${l.domain} · ${payRange(l.payMin, l.payMax, currency: l.currency)} per unit · ${l.slotsFilled} of ${l.slotsTotal} slots filled'
                '${l.hiredThisWeek > 0 ? ' · ${l.hiredThisWeek} hired this week' : ''}',
            onRefresh: reload,
            actions: [
              ConsoleStatus(l.status),
              OutlinedButton.icon(
                key: const Key('listing-edit'),
                onPressed: _busy ? null : () => _edit(l),
                icon: const Icon(Icons.edit_outlined, size: Sizes.iconSm),
                label: const Text('Edit'),
              ),
              if (l.status != 'open')
                FilledButton.icon(
                  key: const Key('listing-open'),
                  onPressed: _busy ? null : () => _setStatus(l, 'open'),
                  icon: const Icon(Icons.campaign_outlined, size: Sizes.iconSm),
                  label: const Text('Open'),
                )
              else
                OutlinedButton.icon(
                  key: const Key('listing-close'),
                  onPressed: _busy ? null : () => _setStatus(l, 'closed'),
                  icon: const Icon(Icons.lock_outline, size: Sizes.iconSm),
                  label: const Text('Close'),
                ),
            ],
            children: [
              // always in the tree: a banner that appears would shift the cards below it and drop their typed state
              ErrorBanner(_error, key: const Key('listing-error')),
              _Summary(l),
              const SectionTitle('Applications', subtitle: 'Applied → screening → offered → accepted; offers expire on their own'),
              _Pipeline(
                applications: v.applications,
                busy: _busy,
                onOffer: (a) => _decide(a, offer: true),
                onReject: (a) => _decide(a, offer: false),
                onOpen: (a) => _openApplicant(l, a),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary(this.l);
  final Listing l;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: Space.x24,
            runSpacing: Space.x4,
            children: [
              LabelValue(label: 'Commitment', value: '${humanize(l.commitment)}${l.hoursPerWeek > 0 ? ' · ${l.hoursPerWeek} h/wk' : ''}'),
              LabelValue(label: 'Gate', value: l.certGate.isEmpty ? '—' : l.certGate, mono: true),
              LabelValue(label: 'Paper', value: l.paperId.isEmpty ? 'None' : shortId(l.paperId), mono: true),
              LabelValue(label: 'Closes', value: l.closesAt == null ? '—' : shortDate(l.closesAt!)),
              LabelValue(label: 'Steps', value: l.steps.isEmpty ? '—' : l.steps.map(humanize).join(' → ')),
              LabelValue(label: 'Posted', value: l.postedAt == null ? '—' : shortDate(l.postedAt!)),
            ],
          ),
          if (l.summary.isNotEmpty) ...[const SizedBox(height: Space.x8), Text(l.summary, style: theme.textTheme.bodyMedium)],
          if (l.requirements.isNotEmpty) ...[
            const SizedBox(height: Space.x12),
            Text('Requirements', style: theme.textTheme.labelMedium),
            for (final r in l.requirements) Text('• $r', style: theme.textTheme.bodyMedium),
          ],
          if (l.questions.isNotEmpty) ...[
            const SizedBox(height: Space.x12),
            Text('Questions', style: theme.textTheme.labelMedium),
            for (final q in l.questions)
              Text(
                '${q.prompt}${q.required ? '' : ' (optional)'}${q.kind == 'choice' ? ' · ${q.options.join(' / ')}' : ''}',
                style: theme.textTheme.bodyMedium,
              ),
          ],
          if (l.sensitive) ...[
            const SizedBox(height: Space.x8),
            const Align(
              alignment: Alignment.centerLeft,
              child: StatusChip('Sensitive', kind: StatusKind.warn),
            ),
          ],
        ],
      ),
    );
  }
}

class _Pipeline extends StatefulWidget {
  const _Pipeline({required this.applications, required this.busy, required this.onOffer, required this.onReject, required this.onOpen});
  final List<Application> applications;
  final bool busy;
  final void Function(Application) onOffer;
  final void Function(Application) onReject;
  final void Function(Application) onOpen;

  @override
  State<_Pipeline> createState() => _PipelineState();
}

class _PipelineState extends State<_Pipeline> {
  int _column = 0;

  List<Application> _of(List<String> statuses) => [
    for (final a in widget.applications)
      if (statuses.contains(a.status)) a,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final ended = widget.applications.where((a) => !pipeline.any((c) => c.$2.contains(a.status))).length;
    Widget card(Application a) => _ApplicationCard(
      a,
      busy: widget.busy,
      onOffer: () => widget.onOffer(a),
      onReject: () => widget.onReject(a),
      onOpen: () => widget.onOpen(a),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, c) {
            if (c.maxWidth >= Layout.wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (i, col) in pipeline.indexed) ...[
                    if (i > 0) const SizedBox(width: Space.x12),
                    Expanded(
                      child: Column(
                        key: Key('pipeline-${col.$1.toLowerCase()}'),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: Space.x8),
                            child: Text('${col.$1} · ${_of(col.$2).length}', style: theme.textTheme.titleSmall),
                          ),
                          if (_of(col.$2).isEmpty) Text('Nobody here', style: theme.textTheme.bodySmall?.copyWith(color: t.textMuted)),
                          for (final a in _of(col.$2)) card(a),
                        ],
                      ),
                    ),
                  ],
                ],
              );
            }
            final col = pipeline[_column];
            final rows = _of(col.$2);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Toolbar(
                  children: [
                    FilterChips<int>(
                      values: {for (final (i, c) in pipeline.indexed) '${c.$1} ${_of(c.$2).length}': i},
                      selected: _column,
                      onSelected: (v) => setState(() => _column = v ?? 0),
                    ),
                  ],
                ),
                if (rows.isEmpty) PortalCard(child: Text('Nobody in ${col.$1.toLowerCase()}', style: theme.textTheme.bodySmall)),
                for (final a in rows) card(a),
              ],
            );
          },
        ),
        if (ended > 0)
          Padding(
            padding: const EdgeInsets.only(top: Space.x8),
            child: Text('$ended ended (rejected, declined, withdrawn or expired)', style: theme.textTheme.labelSmall),
          ),
      ],
    );
  }
}

class _ApplicationCard extends StatelessWidget {
  const _ApplicationCard(this.a, {required this.busy, required this.onOffer, required this.onReject, required this.onOpen});
  final Application a;
  final bool busy;
  final VoidCallback onOffer;
  final VoidCallback onReject;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final expires = a.offerExpiresAt;
    return PortalCard(
      key: Key('application-${a.id}'),
      padding: const EdgeInsets.all(Space.x12),
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Avatar(a.workerId, size: 24),
              const SizedBox(width: Space.x8),
              Expanded(child: NameOf(a.workerId, name: a.workerName)),
              ConsoleStatus(a.status),
            ],
          ),
          const SizedBox(height: Space.x6),
          if (a.createdAt != null)
            Text('Applied ${relative(a.createdAt!)}', style: theme.textTheme.labelSmall?.copyWith(color: t.textMuted)),
          if (a.status == 'offered' && expires != null) ...[
            const SizedBox(height: Space.x6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Countdown(until: expires, prefix: 'Expires'),
            ),
          ],
          if (a.paper != null) ...[const SizedBox(height: Space.x6), Text(_paperLine(a.paper!), style: theme.textTheme.labelSmall)],
          if (a.note.isNotEmpty) ...[const SizedBox(height: Space.x6), Text(a.note, style: theme.textTheme.bodySmall)],
          if (a.status == 'screening') ...[
            const SizedBox(height: Space.x8),
            Wrap(
              spacing: Space.x8,
              runSpacing: Space.x4,
              children: [
                FilledButton(
                  key: Key('offer-${a.id}'),
                  onPressed: busy ? null : onOffer,
                  style: FilledButton.styleFrom(minimumSize: const Size(0, Sizes.controlSm)),
                  child: const Text('Offer'),
                ),
                OutlinedButton(
                  key: Key('reject-${a.id}'),
                  onPressed: busy ? null : onReject,
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, Sizes.controlSm)),
                  child: const Text('Reject'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Offer (with the days it stays open) or reject (with a note). Pops with `(note, offerDays)`.
class _DecideDialog extends StatefulWidget {
  const _DecideDialog({required this.application, required this.offer});
  final Application application;
  final bool offer;

  @override
  State<_DecideDialog> createState() => _DecideDialogState();
}

class _DecideDialogState extends State<_DecideDialog> {
  final _days = TextEditingController(text: '7');
  final _note = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _days.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    final note = _note.text.trim();
    if (!widget.offer && note.isEmpty) {
      setState(() => _error = 'A note is required to reject; the applicant reads it');
      return;
    }
    int? days;
    if (widget.offer) {
      days = int.tryParse(_days.text.trim());
      if (days == null || days < 1 || days > 60) {
        setState(() => _error = 'Offer days is a whole number from 1 to 60');
        return;
      }
    }
    Navigator.of(context).pop((note, days));
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.application;
    final who = a.workerName.isEmpty ? shortId(a.workerId) : a.workerName;
    return FormSheet(
      title: widget.offer ? 'Offer $who a slot' : 'Reject $who',
      saveLabel: widget.offer ? 'Send offer' : 'Reject',
      saveKey: Key(widget.offer ? 'offer-confirm' : 'reject-confirm'),
      error: ErrorBanner(_error),
      onSave: _submit,
      children: [
        if (widget.offer) ...[
          TextField(
            key: const Key('offer-days'),
            controller: _days,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Offer open for (days)', helperText: 'Expired equals declined'),
          ),
          fieldGap,
        ],
        TextField(
          key: Key(widget.offer ? 'offer-note' : 'reject-note'),
          controller: _note,
          maxLines: 3,
          minLines: 2,
          decoration: InputDecoration(labelText: widget.offer ? 'Note (optional)' : 'Note', alignLabelWithHint: true),
        ),
      ],
    );
  }
}

/// `Paper passed · 92% · 3 Nov` or `Paper failed · 50% · 1 attempt left`.
String _paperLine(PaperResult p) {
  final score = p.score == null ? '' : ' · ${(p.score! * (p.score! <= 1 ? 100 : 1)).round()}%';
  final left = p.status == 'failed' && p.attemptsLeft != null
      ? ' · ${p.attemptsLeft} ${p.attemptsLeft == 1 ? 'attempt' : 'attempts'} left'
      : '';
  return 'Paper ${p.status}$score${p.at == null ? '' : ' · ${shortDate(p.at!)}'}$left';
}

/// What ops decide on: the applicant's answers against the listing's questions, the steps, the paper
/// outcome, the note, who decided. Pops `true` for Offer and `false` for Reject while screening.
class _ApplicantSheet extends StatelessWidget {
  const _ApplicantSheet({required this.listing, required this.application});
  final Listing listing;
  final Application application;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = application;
    final asked = {for (final q in listing.questions) q.key};
    final extra = a.answers.keys.where((k) => !asked.contains(k)).toList();
    String answerOf(String key) {
      final v = a.answers[key];
      if (v == null || (v is String && v.trim().isEmpty)) return 'No answer';
      return v is List ? v.join(', ') : '$v';
    }

    return Column(
      key: const Key('applicant-sheet'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            ConsoleStatus(a.status),
            const SizedBox(width: Space.x8),
            if (a.createdAt != null) Text('Applied ${relative(a.createdAt!)}', style: theme.textTheme.labelSmall),
          ],
        ),
        const SizedBox(height: Space.x16),
        Text('Answers', style: theme.textTheme.titleSmall),
        const SizedBox(height: Space.x8),
        if (listing.questions.isEmpty && a.answers.isEmpty) Text('The listing asked nothing.', style: theme.textTheme.bodySmall),
        for (final q in listing.questions)
          Padding(
            key: Key('applicant-answer-${q.key}'),
            padding: const EdgeInsets.only(bottom: Space.x12),
            child: LabelValue(label: q.prompt, value: answerOf(q.key)),
          ),
        for (final k in extra)
          Padding(
            key: Key('applicant-answer-$k'),
            padding: const EdgeInsets.only(bottom: Space.x12),
            child: LabelValue(label: humanize(k), value: answerOf(k)),
          ),
        if (a.steps.isNotEmpty) ...[
          const SizedBox(height: Space.x8),
          StepList(
            title: 'Steps',
            steps: [
              for (final s in a.steps)
                StepTile(
                  title: humanize(s.kind),
                  state: switch (s.status) {
                    'done' => StepState.done,
                    'failed' => StepState.failed,
                    _ => StepState.pending,
                  },
                ),
            ],
          ),
        ],
        if (a.paper != null) LabelValue(label: 'Assessment', value: _paperLine(a.paper!)),
        if (a.note.isNotEmpty) LabelValue(label: 'Note', value: a.note),
        if (a.decidedBy.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Space.x8),
            child: Row(
              children: [
                Text('Decided by ', style: theme.textTheme.labelSmall),
                NameOf(a.decidedBy, style: theme.textTheme.labelSmall),
              ],
            ),
          ),
        if (a.status == 'screening') ...[
          const SizedBox(height: Space.x16),
          Wrap(
            spacing: Space.x8,
            children: [
              FilledButton(key: const Key('sheet-offer'), onPressed: () => Navigator.of(context).pop(true), child: const Text('Offer')),
              OutlinedButton(
                key: const Key('sheet-reject'),
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Reject'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
