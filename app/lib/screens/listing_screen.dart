import 'package:flutter/material.dart' hide StepState;

import '../api/talent_models.dart';
import '../app_scope.dart';
import '../core/errors.dart';
import '../core/format.dart';
import '../core/json.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/portal_tokens.dart';
import '../core/widgets/cards.dart';
import '../core/widgets/loader.dart';
import '../core/widgets/portal_page.dart';
import '../core/widgets/steps.dart';
import '../widgets/load_view.dart';
import 'explore_screen.dart' show HiredChip;
import 'shell.dart';
import '../core/money.dart';
import '../core/widgets/detail_frame.dart';
import '../app_router.dart';
import 'package:go_router/go_router.dart';

/// The status family of an application status: an offer asks for attention, a rejection is a failure,
/// an expiry a warning; everything else is neutral.
StatusKind applicationKind(String status) => switch (status) {
  'accepted' => StatusKind.success,
  'offered' || 'expired' => StatusKind.warn,
  'rejected' => StatusKind.dest,
  _ => StatusKind.info,
};

/// `screening` → `Screening`; `offered` → `Offer waiting`.
String applicationLabel(String status) => switch (status) {
  'offered' => 'Offer waiting',
  'assessment' => 'Paper pending',
  _ => humanize(status),
};

/// The neutral domain pill on a listing.
class DomainChip extends StatelessWidget {
  const DomainChip(this.domain, {super.key});
  final String domain;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.x8, vertical: Space.x2),
      decoration: BoxDecoration(
        color: t.bgMuted,
        borderRadius: Radii.rFull,
        border: Border.all(color: t.borderSubtle),
      ),
      child: Text(humanize(domain), style: Theme.of(context).textTheme.labelMedium?.copyWith(color: t.textSecondary)),
    );
  }
}

/// A listing as a full-screen route: what the pool is, what it asks, how to apply, and a sticky apply card.
class ListingScreen extends StatefulWidget {
  const ListingScreen({super.key, required this.listingId});

  final String listingId;

  @override
  State<ListingScreen> createState() => _ListingScreenState();
}

class _ListingScreenState extends State<ListingScreen> {
  Listing? _listing;
  String? _loadError;
  bool _loading = true;

  /// The application sent from this screen; it wins over the viewer block the listing came with.
  Application? _application;

  /// A refusal from the gateway (already applied, pool full), shown in the apply card.
  String? _refusal;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final listing = await AppScope.of(context).talent.listing(widget.listingId);
      if (mounted) setState(() => _listing = listing);
    } on Object catch (e) {
      if (mounted) setState(() => _loadError = describeError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _apply(Listing listing) async {
    final outcome = await showDialog<_ApplyOutcome>(
      context: context,
      builder: (_) => _ApplyDialog(listing: listing),
    );
    if (outcome == null || !mounted) return;
    setState(() {
      _application = outcome.application ?? _application;
      _refusal = outcome.refusal;
    });
    if (outcome.application != null) {
      // Home's offers and readiness and the Applications list read this
      AppScope.of(context).stale.mark([Destination.home, Destination.applications]);
      toast(context, 'Application sent');
    } else {
      // refused (already applied, pool full): the card and the slots are read again so they are current
      await _load();
    }
  }

  void _openRedirect(ListingRedirect r) {
    context.pushReplacement(Paths.listing(r.id));
  }

  @override
  Widget build(BuildContext context) {
    final listing = _listing;
    final narrow = MediaQuery.sizeOf(context).width < Layout.twoColumn;
    final status = _application?.status ?? listing?.viewer.applicationStatus ?? '';
    final apply = listing == null ? null : _ApplyState.of(listing, applicationStatus: status);
    final button = apply == null
        ? null
        : FilledButton(key: const Key('apply'), onPressed: apply.enabled ? () => _apply(listing!) : null, child: Text(apply.label));
    return DetailFrame(
      crumbs: [
        const Crumb('Work'),
        Crumb('Explore', path: Destination.explore.path),
        Crumb(listing?.title ?? 'Listing'),
      ],
      body: listing == null
          ? (_loading ? const Center(child: BrandLoader()) : ErrorView(message: _loadError ?? 'No data', onRetry: _load))
          : PortalPage(
              onRefresh: _load,
              children: [
                if (listing.viewer.redirect != null) _RedirectCard(redirect: listing.viewer.redirect!, onOpen: _openRedirect),
                TwoColumn(
                  ratio: 1.6,
                  left: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _AboutCard(listing: listing),
                      if (listing.requirements.isNotEmpty) _RequirementsCard(listing.requirements),
                      _HowToApplyCard(listing: listing, application: _application, applicationStatus: status),
                      if (listing.sensitive)
                        const StatusBanner(
                          'This pool contains sensitive content (graphic or distressing material). You may stop at any time; '
                          'tell ops if it affects you.',
                          kind: StatusKind.warn,
                          icon: Icons.warning_amber_outlined,
                        ),
                      if (listing.llmPolicy.isNotEmpty) _PolicyCard(listing.llmPolicy),
                    ],
                  ),
                  right: _ApplyCard(
                    listing: listing,
                    state: apply!,
                    refusal: _refusal,
                    applicationStatus: status,
                    button: narrow ? null : button,
                  ),
                ),
              ],
            ),
      footer: narrow && listing != null && button != null ? _StickyBar(listing: listing, button: button) : null,
    );
  }
}

/// Whether Apply is pressable and what it says when it is not.
class _ApplyState {
  const _ApplyState({required this.enabled, required this.label, this.reason});
  final bool enabled;
  final String label;
  final String? reason;

  /// An application that ended without a slot: the worker may apply again while the pool is open.
  static const ended = {'withdrawn', 'declined', 'expired', 'rejected'};

  static _ApplyState of(Listing listing, {required String applicationStatus}) {
    final earlier = ended.contains(applicationStatus);
    if (applicationStatus.isNotEmpty && !earlier) {
      return _ApplyState(
        enabled: false,
        label: 'Applied',
        reason: 'You applied to this pool: ${applicationLabel(applicationStatus).toLowerCase()}.',
      );
    }
    if (!listing.isOpen) return const _ApplyState(enabled: false, label: 'Closed', reason: 'This pool is closed to new applications.');
    if (listing.isFull) return const _ApplyState(enabled: false, label: 'Full', reason: 'Every slot in this pool is filled.');
    if (earlier) {
      return _ApplyState(
        enabled: true,
        label: 'Apply',
        reason: 'Your earlier application was ${applicationLabel(applicationStatus).toLowerCase()}; you can apply again.',
      );
    }
    return const _ApplyState(enabled: true, label: 'Apply');
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard({required this.listing});
  final Listing listing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    return PortalCard(
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
              if (!listing.isOpen) StatusChip(humanize(listing.status), kind: StatusKind.warn),
            ],
          ),
          const SizedBox(height: Space.x12),
          Text(listing.title, style: theme.textTheme.headlineSmall),
          if (listing.summary.isNotEmpty) ...[
            const SizedBox(height: Space.x4),
            Text(listing.summary, style: theme.textTheme.bodyMedium?.copyWith(color: t.textSecondary)),
          ],
          if (listing.description.isNotEmpty) ...[
            const SizedBox(height: Space.x12),
            Text(listing.description, style: theme.textTheme.bodyMedium),
          ],
          if (listing.closesAt != null) ...[
            const SizedBox(height: Space.x12),
            Text('Applications close ${shortDate(listing.closesAt!)}', style: theme.textTheme.labelSmall),
          ],
        ],
      ),
    );
  }
}

class _RequirementsCard extends StatelessWidget {
  const _RequirementsCard(this.requirements);
  final List<String> requirements;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Requirements', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x8),
          for (final r in requirements)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.x4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(Icons.check_circle_outline, size: Sizes.iconSm, color: t.successDot),
                  ),
                  const SizedBox(width: Space.x8),
                  Expanded(child: Text(r, style: theme.textTheme.bodyMedium)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The three steps of an application, with the state the viewer's application gives them.
class _HowToApplyCard extends StatelessWidget {
  const _HowToApplyCard({required this.listing, required this.application, required this.applicationStatus});
  final Listing listing;
  final Application? application;
  final String applicationStatus;

  StepState _state(String kind) {
    final app = application;
    if (app != null && app.steps.isNotEmpty) {
      final step = app.steps.where((s) => s.kind == kind).firstOrNull;
      if (step == null) return StepState.pending;
      if (step.isDone) return StepState.done;
      if (step.isFailed) return StepState.failed;
      return app.steps.where((s) => !s.isDone).firstOrNull?.kind == kind ? StepState.active : StepState.pending;
    }
    final status = applicationStatus;
    if (status.isEmpty) return kind == 'form' ? StepState.active : StepState.pending;
    return switch (kind) {
      'form' => StepState.done,
      'paper' =>
        status == 'assessment'
            ? StepState.active
            : (listing.viewer.prequalified || status != 'applied' ? StepState.done : StepState.pending),
      _ => const {'offered', 'accepted'}.contains(status) ? StepState.done : StepState.pending,
    };
  }

  /// The steps this pool uses: the listing's own list when the server sends one, else form, the paper when
  /// there is one, and availability.
  bool _uses(String kind) => listing.steps.isEmpty ? (kind != 'paper' || listing.hasPaper) : listing.steps.contains(kind);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('How to apply', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x12),
          StepList(
            steps: [
              if (_uses('form'))
                StepTile(
                  key: const Key('how-form'),
                  title: 'Answer a few questions',
                  hint: listing.questions.isEmpty
                      ? 'One tap; there is no form for this pool'
                      : '${listing.questions.length} ${listing.questions.length == 1 ? 'question' : 'questions'}',
                  state: _state('form'),
                ),
              if (_uses('paper'))
                StepTile(
                  key: const Key('how-paper'),
                  title: 'Pass the assessment paper',
                  hint: listing.viewer.prequalified
                      ? 'You already hold the ${humanize(listing.certGate).toLowerCase()} certification'
                      : 'Certifies you for ${humanize(listing.certGate).toLowerCase()} pools',
                  state: _state('paper'),
                  // the step a worker is on is the step they can act on: open the paper from right here
                  action: _state('paper') == StepState.active && listing.hasPaper
                      ? FilledButton(
                          key: const Key('take-paper-listing'),
                          onPressed: () => context.go(Paths.assessment(listing.paperId)),
                          child: const Text('Take the paper'),
                        )
                      : null,
                ),
              if (_uses('availability'))
                StepTile(
                  key: const Key('how-availability'),
                  title: 'Confirm your availability',
                  hint: listing.hoursPerWeek > 0 ? 'About ${listing.hoursPerWeek} h per week' : 'Tell ops the hours you can give',
                  state: _state('availability'),
                ),
            ],
            showProgress: applicationStatus.isNotEmpty,
          ),
        ],
      ),
    );
  }
}

class _PolicyCard extends StatelessWidget {
  const _PolicyCard(this.policy);
  final String policy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    return PortalCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.smart_toy_outlined, size: Sizes.iconMd, color: t.textMuted),
          const SizedBox(width: Space.x12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('LLM policy', style: theme.textTheme.titleMedium),
                const SizedBox(height: Space.x4),
                Text(policy, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RedirectCard extends StatelessWidget {
  const _RedirectCard({required this.redirect, required this.onOpen});
  final ListingRedirect redirect;
  final void Function(ListingRedirect) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PortalCard(
      key: const Key('redirect'),
      emphasis: true,
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Space.x12,
        runSpacing: Space.x8,
        children: [
          Text('This pool is closed; the ${redirect.title} pool in the same domain is open.', style: theme.textTheme.bodyMedium),
          OutlinedButton(key: const Key('redirect-open'), onPressed: () => onOpen(redirect), child: Text('Open ${redirect.title}')),
        ],
      ),
    );
  }
}

/// Pay, commitment, slots and the primary action. Sticky at the right on wide screens; on phones the
/// button moves to the bottom bar and this card keeps the facts.
class _ApplyCard extends StatelessWidget {
  const _ApplyCard({
    required this.listing,
    required this.state,
    required this.refusal,
    required this.applicationStatus,
    required this.button,
  });
  final Listing listing;
  final _ApplyState state;
  final String? refusal;
  final String applicationStatus;
  final Widget? button;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    return PortalCard(
      key: const Key('apply-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            payRange(listing.payMin, listing.payMax, currency: listing.currency),
            style: TextStyle(fontFamily: PortalType.familyMono, fontSize: 26, fontWeight: FontWeight.w500, color: t.textPrimary),
          ),
          Text(payUnitLabel(listing.payUnit), style: theme.textTheme.bodySmall),
          const SizedBox(height: Space.x12),
          Fact(
            expand: true,
            icon: Icons.schedule_outlined,
            text: '${listing.commitmentLabel}${listing.hoursPerWeek > 0 ? ' · ${listing.hoursPerWeek} h per week' : ''}',
          ),
          const SizedBox(height: Space.x6),
          Fact(expand: true, icon: Icons.group_outlined, text: '${listing.slotsFilled} of ${listing.slotsTotal} slots filled'),
          const SizedBox(height: Space.x12),
          Wrap(
            spacing: Space.x8,
            runSpacing: Space.x8,
            children: [
              SlotsChip(listing),
              if (listing.viewer.prequalified) const StatusChip('Prequalified', kind: StatusKind.success),
              if (applicationStatus.isNotEmpty) StatusChip(applicationLabel(applicationStatus), kind: applicationKind(applicationStatus)),
            ],
          ),
          if (refusal != null) ...[
            const SizedBox(height: Space.x12),
            StatusBanner(refusal!, kind: StatusKind.warn, icon: Icons.info_outline),
          ],
          if (button != null) ...[const SizedBox(height: Space.x12), button!],
          if (state.reason != null) ...[
            const SizedBox(height: Space.x8),
            Text(state.reason!, key: const Key('apply-reason'), style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// `2 slots left` in the info family, warn under three, `Full` at zero.
class SlotsChip extends StatelessWidget {
  const SlotsChip(this.listing, {super.key});
  final Listing listing;

  @override
  Widget build(BuildContext context) {
    final left = listing.slotsLeft;
    if (listing.isFull) return const StatusChip('Full', kind: StatusKind.warn);
    return StatusChip('$left ${left == 1 ? 'slot' : 'slots'} left', kind: left < 3 ? StatusKind.warn : StatusKind.info);
  }
}

class _StickyBar extends StatelessWidget {
  const _StickyBar({required this.listing, required this.button});
  final Listing listing;
  final Widget button;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    return Material(
      color: t.bgApp,
      child: SafeArea(
        top: false,
        child: Container(
          key: const Key('apply-bar'),
          padding: const EdgeInsets.symmetric(horizontal: Space.x16, vertical: Space.x12),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: t.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      payRange(listing.payMin, listing.payMax, currency: listing.currency),
                      style: AppTheme.figure(context, fontSize: 16),
                    ),
                    Text(payUnitLabel(listing.payUnit), style: theme.textTheme.labelSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              const SizedBox(width: Space.x12),
              button,
            ],
          ),
        ),
      ),
    );
  }
}

/// What the apply dialog hands back: the application, or the gateway's refusal in one line.
class _ApplyOutcome {
  const _ApplyOutcome({this.application, this.refusal});
  final Application? application;
  final String? refusal;
}

/// The application form built from the listing's questions. Posts with one key per listing; a 409
/// (already applied, pool full) closes the dialog and is shown on the apply card.
class _ApplyDialog extends StatefulWidget {
  const _ApplyDialog({required this.listing});
  final Listing listing;

  @override
  State<_ApplyDialog> createState() => _ApplyDialogState();
}

class _ApplyDialogState extends State<_ApplyDialog> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _text = {
    for (final q in widget.listing.questions)
      if (!q.isChoice) q.key: TextEditingController(),
  };
  final Map<String, String?> _choice = {};
  final Map<String, String> _choiceError = {};
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  Json? _answers() {
    var ok = _form.currentState?.validate() ?? true;
    _choiceError.clear();
    final out = <String, dynamic>{};
    for (final q in widget.listing.questions) {
      if (q.isChoice) {
        final v = _choice[q.key];
        if (v == null) {
          if (q.required) {
            _choiceError[q.key] = 'Pick one';
            ok = false;
          }
        } else {
          out[q.key] = v;
        }
      } else {
        final v = _text[q.key]!.text.trim();
        if (v.isNotEmpty) out[q.key] = v;
      }
    }
    return ok ? out : null;
  }

  Future<void> _send() async {
    final answers = _answers();
    if (answers == null) {
      setState(() => _error = 'Answer the required questions before you send.');
      return;
    }
    final scope = AppScope.of(context);
    final action = 'apply:${widget.listing.id}';
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final application = await scope.talent.apply(widget.listing.id, answers, key: scope.keys.start(action));
      scope.keys.finish(action);
      if (mounted) Navigator.of(context).pop(_ApplyOutcome(application: application));
    } on ApiException catch (e) {
      scope.keys.settle(action, e);
      if (!mounted) return;
      if (e.isConflict) {
        Navigator.of(context).pop(_ApplyOutcome(refusal: _refusal(e)));
      } else {
        setState(() => _error = describeError(e));
      }
    } on Object catch (e) {
      scope.keys.settle(action, e);
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _refusal(ApiException e) => describeError(e);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final questions = widget.listing.questions;
    return AlertDialog(
      title: Text('Apply to ${widget.listing.title}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ErrorBanner(_error),
                if (questions.isEmpty)
                  Text('This pool has no questions. Send the application to start the next step.', style: theme.textTheme.bodyMedium)
                else
                  for (final q in questions)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Space.x12),
                      child: q.isChoice ? _choiceField(q) : _textField(q),
                    ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('apply-cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(key: const Key('apply-send'), onPressed: _busy ? null : _send, child: const Text('Send application')),
      ],
    );
  }

  Widget _textField(ListingQuestion q) => TextFormField(
    key: Key('q-${q.key}'),
    controller: _text[q.key],
    enabled: !_busy,
    minLines: 1,
    maxLines: 4,
    decoration: InputDecoration(labelText: q.required ? '${q.prompt} *' : q.prompt),
    validator: (v) => q.required && (v ?? '').trim().isEmpty ? 'Required' : null,
  );

  Widget _choiceField(ListingQuestion q) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final error = _choiceError[q.key];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(q.required ? '${q.prompt} *' : q.prompt, style: theme.textTheme.labelMedium),
        RadioGroup<String>(
          groupValue: _choice[q.key],
          onChanged: _busy ? (_) {} : (v) => setState(() => _choice[q.key] = v),
          child: Column(
            children: [
              for (final o in q.options)
                RadioListTile<String>(
                  key: Key('q-${q.key}-$o'),
                  value: o,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(humanize(o)),
                ),
            ],
          ),
        ),
        if (error != null) Text(error, style: theme.textTheme.bodySmall?.copyWith(color: t.destText)),
      ],
    );
  }
}
