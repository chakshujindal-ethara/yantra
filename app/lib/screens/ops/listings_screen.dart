import 'package:flutter/material.dart';

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
import '../../core/widgets/tables.dart';
import '../../widgets/load_view.dart';
import '../../core/money.dart';
import '../../app_router.dart';
import 'package:go_router/go_router.dart';

/// Every listing, open or not, with its slots and where its applicants stand.
class ListingsScreen extends StatelessWidget {
  const ListingsScreen({super.key});

  Future<void> _create(BuildContext context, Future<void> Function() reload) async {
    final created = await showDialog<Listing>(context: context, builder: (_) => const ListingFormDialog());
    if (created == null || !context.mounted) return;
    toast(context, 'Listing "${created.title}" created as a draft');
    await reload();
  }

  @override
  Widget build(BuildContext context) {
    return LoadView<List<Listing>>(
      firstWait: LoadWait.brand,
      load: () => AppScope.of(context).ops.listings(),
      builder: (context, all, reload) => PortalPage(
        kicker: 'Operate · Listings',
        title: 'Listings',
        subtitle: 'Pools open for applications',
        onRefresh: reload,
        actions: [
          FilledButton.icon(
            key: const Key('new-listing'),
            onPressed: () => _create(context, reload),
            icon: const Icon(Icons.add, size: Sizes.iconSm),
            label: const Text('New listing'),
          ),
        ],
        children: [
          if (all.isEmpty)
            const PortalCard(child: EmptyView(message: 'No listings yet. "New listing" opens the first pool.'))
          else
            PortalTable(
              minWidth: 960,
              columns: const [
                PortalColumn('Title', flex: 2),
                PortalColumn('Domain'),
                PortalColumn('Status', width: 130),
                PortalColumn('Pay per unit', flex: 2),
                PortalColumn('Slots', width: 90, numeric: true),
                PortalColumn('Hired this week', width: 130, numeric: true),
                PortalColumn('Applications', flex: 3),
              ],
              rows: [
                for (final l in all)
                  PortalRow(
                    [
                      Text(l.title),
                      Text(l.domain.isEmpty ? '—' : l.domain),
                      ConsoleStatus(l.status),
                      Text(payRange(l.payMin, l.payMax, currency: l.currency), style: AppTheme.figure(context, fontSize: 13)),
                      Text('${l.slotsFilled}/${l.slotsTotal}'),
                      Text(l.hiredThisWeek == 0 ? '—' : '${l.hiredThisWeek}'),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(applicationsLine(l.applications), style: Theme.of(context).textTheme.bodySmall),
                      ),
                    ],
                    key: Key('listing-${l.id}'),
                    onTap: () => context.push(Paths.opsListing(l.id)),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// `4 applied · 2 screening · 1 offered · 3 accepted`.
String applicationsLine(ApplicationCounts a) =>
    '${a.applied + a.assessment} applied · ${a.screening} screening · ${a.offered} offered · ${a.accepted} accepted';

/// One question row of the listing form.
class _QuestionRow {
  _QuestionRow({String key = '', String prompt = '', this.kind = 'text', String options = '', this.required = true})
    : key = TextEditingController(text: key),
      prompt = TextEditingController(text: prompt),
      options = TextEditingController(text: options);

  factory _QuestionRow.from(ListingQuestion q) =>
      _QuestionRow(key: q.key, prompt: q.prompt, kind: q.kind, options: q.options.join(', '), required: q.required);

  final TextEditingController key;
  final TextEditingController prompt;
  final TextEditingController options;
  String kind;
  bool required;

  void dispose() {
    key.dispose();
    prompt.dispose();
    options.dispose();
  }

  /// Throws [FormatException] when the row is incomplete.
  ListingQuestion toQuestion(int index) {
    final k = key.text.trim();
    final p = prompt.text.trim();
    if (k.isEmpty || p.isEmpty) throw FormatException('Question ${index + 1} needs a key and a prompt');
    final opts = options.text.split(',').map((o) => o.trim()).where((o) => o.isNotEmpty).toList();
    if (kind == 'choice' && opts.length < 2) throw FormatException('Question ${index + 1} needs at least two options');
    return ListingQuestion(key: k, prompt: p, kind: kind, options: opts, required: required);
  }
}

/// The listing form: creates when [initial] is null, edits otherwise. Pops with the saved listing.
class ListingFormDialog extends StatefulWidget {
  const ListingFormDialog({super.key, this.initial});
  final Listing? initial;

  @override
  State<ListingFormDialog> createState() => _ListingFormDialogState();
}

class _ListingFormDialogState extends State<ListingFormDialog> {
  late final _title = TextEditingController(text: widget.initial?.title ?? '');
  late final _domain = TextEditingController(text: widget.initial?.domain ?? '');
  late final _summary = TextEditingController(text: widget.initial?.summary ?? '');
  late final _description = TextEditingController(text: widget.initial?.description ?? '');
  late final _payMin = TextEditingController(text: widget.initial?.payMin ?? '');
  late final _payMax = TextEditingController(text: widget.initial?.payMax ?? '');
  late final _currency = TextEditingController(text: widget.initial?.currency ?? 'INR');
  late final _hours = TextEditingController(text: widget.initial == null ? '' : '${widget.initial!.hoursPerWeek}');
  late final _slots = TextEditingController(text: widget.initial == null ? '' : '${widget.initial!.slotsTotal}');
  late final _gate = TextEditingController(text: widget.initial?.certGate ?? '');
  late final _closes = TextEditingController(text: dayText(widget.initial?.closesAt));
  late final _requirements = TextEditingController(text: widget.initial?.requirements.join('\n') ?? '');
  late final _llm = TextEditingController(text: widget.initial?.llmPolicy ?? '');
  late String _commitment = widget.initial?.commitment ?? 'task_based';
  late String _paper = widget.initial?.paperId ?? '';
  late bool _sensitive = widget.initial?.sensitive ?? false;
  late bool _availability = widget.initial?.steps.contains('availability') ?? false;
  late final List<_QuestionRow> _questions = [for (final q in widget.initial?.questions ?? const <ListingQuestion>[]) _QuestionRow.from(q)];
  List<Paper> _papers = const [];
  bool _started = false;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.initial != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _loadPapers();
    }
  }

  Future<void> _loadPapers() async {
    try {
      final papers = await AppScope.of(context).ops.papers();
      if (mounted) setState(() => _papers = papers);
    } on Object {
      // The dropdown keeps "None"; a paper can be attached later.
    }
  }

  @override
  void dispose() {
    for (final c in [
      _title,
      _domain,
      _summary,
      _description,
      _payMin,
      _payMax,
      _currency,
      _hours,
      _slots,
      _gate,
      _closes,
      _requirements,
      _llm,
    ]) {
      c.dispose();
    }
    for (final q in _questions) {
      q.dispose();
    }
    super.dispose();
  }

  ListingInput? _input() {
    final title = _title.text.trim();
    final domain = _domain.text.trim();
    if (title.isEmpty || domain.isEmpty) {
      _error = 'Title and domain are required';
      return null;
    }
    final min = double.tryParse(_payMin.text.trim());
    final max = double.tryParse(_payMax.text.trim());
    if (min == null || max == null || min < 0 || max < min) {
      _error = 'Pay range needs a minimum and a maximum, minimum first';
      return null;
    }
    final currency = _currency.text.trim().toUpperCase();
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
      _error = 'Currency is a three-letter code, like INR';
      return null;
    }
    final hours = int.tryParse(_hours.text.trim().isEmpty ? '0' : _hours.text.trim());
    final slots = int.tryParse(_slots.text.trim().isEmpty ? '0' : _slots.text.trim());
    if (hours == null || hours < 0 || slots == null || slots < 0) {
      _error = 'Hours per week and slots are whole numbers';
      return null;
    }
    final DateTime? closes;
    final questions = <ListingQuestion>[];
    try {
      closes = parseDay(_closes.text, label: 'Closes at');
      for (final (i, q) in _questions.indexed) {
        questions.add(q.toQuestion(i));
      }
    } on FormatException catch (e) {
      _error = e.message;
      return null;
    }
    return ListingInput(
      title: title,
      domain: domain,
      summary: _summary.text.trim(),
      description: _description.text.trim(),
      payMin: min.toStringAsFixed(2),
      payMax: max.toStringAsFixed(2),
      currency: currency,
      commitment: _commitment,
      hoursPerWeek: hours,
      slotsTotal: slots,
      certGate: _gate.text.trim(),
      paperId: _paper,
      requirements: _requirements.text.split('\n').map((r) => r.trim()).where((r) => r.isNotEmpty).toList(),
      questions: questions,
      llmPolicy: _llm.text.trim(),
      sensitive: _sensitive,
      closesAt: closes,
      askAvailability: _availability,
    );
  }

  Future<void> _save() async {
    final scope = AppScope.of(context);
    _error = null;
    final input = _input();
    if (input == null) {
      setState(() {});
      return;
    }
    final action = _editing ? 'listing:edit:${widget.initial!.id}' : 'listing:create';
    setState(() => _busy = true);
    try {
      final saved = _editing
          ? await scope.ops.patchListing(widget.initial!.id, input.toJson(), key: scope.keys.start(action))
          : await scope.ops.createListing(input, key: scope.keys.start(action));
      scope.keys.finish(action);
      if (mounted) Navigator.of(context).pop(saved);
    } on Object catch (e) {
      scope.keys.settle(action, e);
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickDay() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: parseDayOrNull(_closes.text) ?? now.add(const Duration(days: 14)),
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _closes.text = dayText(DateTime.utc(picked.year, picked.month, picked.day)));
  }

  static DateTime? parseDayOrNull(String text) {
    try {
      return parseDay(text);
    } on FormatException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FormSheet(
      title: _editing ? 'Edit listing' : 'New listing',
      saveLabel: _editing ? 'Save' : 'Create listing',
      saveKey: const Key('listing-save'),
      busy: _busy,
      error: ErrorBanner(_error),
      maxWidth: 640,
      onSave: _save,
      children: [
        TextField(
          key: const Key('listing-title'),
          controller: _title,
          decoration: const InputDecoration(labelText: 'Title'),
        ),
        fieldGap,
        FieldPair(
          TextField(
            key: const Key('listing-domain'),
            controller: _domain,
            decoration: const InputDecoration(labelText: 'Domain', hintText: 'Transcription'),
          ),
          TextField(
            key: const Key('listing-gate'),
            controller: _gate,
            decoration: const InputDecoration(labelText: 'Certification gate', hintText: 'transcription'),
          ),
        ),
        fieldGap,
        TextField(
          key: const Key('listing-summary'),
          controller: _summary,
          decoration: const InputDecoration(labelText: 'Summary', helperText: 'One line on the card'),
        ),
        fieldGap,
        TextField(
          key: const Key('listing-description'),
          controller: _description,
          maxLines: 5,
          minLines: 3,
          decoration: const InputDecoration(labelText: 'Description', alignLabelWithHint: true),
        ),
        fieldGap,
        Text('Pay per accepted unit', style: theme.textTheme.labelMedium),
        const SizedBox(height: Space.x6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: const Key('listing-pay-min'),
                controller: _payMin,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'From'),
              ),
            ),
            const SizedBox(width: Space.x8),
            Expanded(
              child: TextField(
                key: const Key('listing-pay-max'),
                controller: _payMax,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'To'),
              ),
            ),
            const SizedBox(width: Space.x8),
            SizedBox(
              width: 88,
              child: TextField(
                key: const Key('listing-currency'),
                controller: _currency,
                maxLength: 3,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Currency', counterText: ''),
              ),
            ),
          ],
        ),
        fieldGap,
        FieldPair(
          DropdownButtonFormField<String>(
            key: const Key('listing-commitment'),
            isExpanded: true,
            initialValue: _commitment,
            decoration: const InputDecoration(labelText: 'Commitment'),
            items: const [
              DropdownMenuItem(value: 'task_based', child: Text('Task based')),
              DropdownMenuItem(value: 'part_time', child: Text('Part time')),
            ],
            onChanged: (v) => setState(() => _commitment = v ?? 'task_based'),
          ),
          TextField(
            key: const Key('listing-hours'),
            controller: _hours,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Hours per week'),
          ),
        ),
        fieldGap,
        FieldPair(
          TextField(
            key: const Key('listing-slots'),
            controller: _slots,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Slots'),
          ),
          TextField(
            key: const Key('listing-closes'),
            controller: _closes,
            decoration: InputDecoration(
              labelText: 'Closes at',
              hintText: 'YYYY-MM-DD',
              suffixIcon: IconButton(
                key: const Key('listing-closes-pick'),
                tooltip: 'Pick a date',
                icon: const Icon(Icons.calendar_today_outlined, size: Sizes.iconSm),
                onPressed: _pickDay,
              ),
            ),
          ),
        ),
        fieldGap,
        DropdownButtonFormField<String>(
          key: const Key('listing-paper'),
          isExpanded: true,
          initialValue: _papers.any((p) => p.id == _paper) ? _paper : '',
          decoration: const InputDecoration(
            labelText: 'Assessment paper',
            helperText: 'Applicants without the gate sit it before screening',
          ),
          items: [
            const DropdownMenuItem(value: '', child: Text('None')),
            for (final p in _papers) DropdownMenuItem(value: p.id, child: Text('${p.title} · ${p.gate}')),
          ],
          onChanged: (v) => setState(() => _paper = v ?? ''),
        ),
        fieldGap,
        TextField(
          key: const Key('listing-requirements'),
          controller: _requirements,
          maxLines: 5,
          minLines: 2,
          decoration: const InputDecoration(labelText: 'Requirements', helperText: 'One per line', alignLabelWithHint: true),
        ),
        fieldGap,
        TextField(
          key: const Key('listing-llm'),
          controller: _llm,
          maxLines: 3,
          minLines: 2,
          decoration: const InputDecoration(labelText: 'LLM policy', alignLabelWithHint: true),
        ),
        fieldGap,
        SwitchRow(
          label: 'Sensitive',
          hint: 'Applicants see a confidentiality notice',
          value: _sensitive,
          switchKey: const Key('listing-sensitive'),
          onChanged: (v) => setState(() => _sensitive = v),
        ),
        fieldGap,
        SwitchRow(
          label: 'Ask for availability',
          hint: 'A step after the form${_paper.isEmpty ? '' : ' and the paper'}: the hours a week the applicant can give',
          value: _availability,
          switchKey: const Key('listing-availability'),
          onChanged: (v) => setState(() => _availability = v),
        ),
        const SizedBox(height: Space.x16),
        Row(
          children: [
            Expanded(child: Text('Application questions', style: theme.textTheme.titleSmall)),
            TextButton.icon(
              key: const Key('question-add'),
              onPressed: () => setState(() => _questions.add(_QuestionRow())),
              icon: const Icon(Icons.add, size: Sizes.iconSm),
              label: const Text('Add question'),
            ),
          ],
        ),
        if (_questions.isEmpty) Text('No questions: the form step is just the application itself.', style: theme.textTheme.bodySmall),
        for (final (i, q) in _questions.indexed)
          _QuestionEditor(
            index: i,
            row: q,
            onChanged: () => setState(() {}),
            onRemove: () => setState(() => _questions.removeAt(i).dispose()),
          ),
      ],
    );
  }
}

class _QuestionEditor extends StatelessWidget {
  const _QuestionEditor({required this.index, required this.row, required this.onChanged, required this.onRemove});
  final int index;
  final _QuestionRow row;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return Container(
      margin: const EdgeInsets.only(top: Space.x8),
      padding: const EdgeInsets.all(Space.x12),
      decoration: BoxDecoration(
        color: t.bgMuted,
        borderRadius: Radii.rMd,
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Question ${index + 1}', style: Theme.of(context).textTheme.labelMedium)),
              IconButton(
                key: Key('question-remove-$index'),
                tooltip: 'Remove question ${index + 1}',
                visualDensity: VisualDensity.compact,
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline, size: Sizes.iconSm),
              ),
            ],
          ),
          FieldPair(
            TextField(
              key: Key('question-key-$index'),
              controller: row.key,
              decoration: const InputDecoration(labelText: 'Key', hintText: 'experience'),
            ),
            DropdownButtonFormField<String>(
              key: Key('question-kind-$index'),
              isExpanded: true,
              initialValue: row.kind,
              decoration: const InputDecoration(labelText: 'Kind'),
              items: const [
                DropdownMenuItem(value: 'text', child: Text('Text')),
                DropdownMenuItem(value: 'choice', child: Text('Choice')),
              ],
              onChanged: (v) {
                row.kind = v ?? 'text';
                onChanged();
              },
            ),
          ),
          fieldGap,
          TextField(
            key: Key('question-prompt-$index'),
            controller: row.prompt,
            decoration: const InputDecoration(labelText: 'Prompt'),
          ),
          if (row.kind == 'choice') ...[
            fieldGap,
            TextField(
              key: Key('question-options-$index'),
              controller: row.options,
              decoration: const InputDecoration(labelText: 'Options', helperText: 'Comma-separated'),
            ),
          ],
          SwitchRow(
            label: 'Required',
            value: row.required,
            switchKey: Key('question-required-$index'),
            onChanged: (v) {
              row.required = v;
              onChanged();
            },
          ),
        ],
      ),
    );
  }
}
