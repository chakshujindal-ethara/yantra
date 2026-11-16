import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../api/ops_models.dart';
import '../../app_router.dart';
import '../../app_scope.dart';
import '../../core/errors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/portal_tokens.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/form_sheet.dart';
import '../../core/widgets/loader.dart';
import '../../core/widgets/portal_page.dart';
import '../../core/widgets/stage_bar.dart';
import '../../core/widgets/tables.dart';
import '../../widgets/load_view.dart';

/// Papers: each certifies a gate by passing an exam in Assessment v2. The exam (questions, proctoring,
/// marking) is built and run there; Yantra links it to the gate and follows every attempt.
class PapersScreen extends StatelessWidget {
  const PapersScreen({super.key});

  Future<void> _create(BuildContext context, Future<void> Function() reload) async {
    final created = await showDialog<Paper>(context: context, builder: (_) => const PaperFormDialog());
    if (created == null || !context.mounted) return;
    toast(context, 'Paper "${created.title}" created as a draft');
    await reload();
  }

  @override
  Widget build(BuildContext context) {
    return LoadView<List<Paper>>(
      firstWait: LoadWait.brand,
      load: () => AppScope.of(context).ops.papers(),
      builder: (context, all, reload) => PortalPage(
        kicker: 'Operate · Papers',
        title: 'Papers',
        subtitle: 'Certification exams, sat in Assessment v2',
        onRefresh: reload,
        actions: [
          FilledButton.icon(
            key: const Key('new-paper'),
            onPressed: () => _create(context, reload),
            icon: const Icon(Icons.add, size: Sizes.iconSm),
            label: const Text('New paper'),
          ),
        ],
        children: [
          if (all.isEmpty)
            const PortalCard(child: EmptyView(message: 'No papers yet. "New paper" links an assessment or writes a quick one.'))
          else
            PortalTable(
              minWidth: 1000,
              columns: const [
                PortalColumn('Title', flex: 2),
                PortalColumn('Gate'),
                PortalColumn('Assessment', flex: 2),
                PortalColumn('Status', width: 120),
                PortalColumn('Attempts', width: 90, numeric: true),
                PortalColumn('Passed', width: 90, numeric: true),
                PortalColumn('Awaiting release', width: 130, numeric: true),
                PortalColumn('Pass rate', width: 90, numeric: true),
              ],
              rows: [
                for (final p in all)
                  PortalRow(
                    [
                      Text(p.title),
                      Text(p.gate, style: AppTheme.mono(context, fontSize: 13)),
                      Text(assessmentLabel(p), overflow: TextOverflow.ellipsis),
                      ConsoleStatus(p.status),
                      Text('${p.maxAttempts}'),
                      Text('${p.stats.passed} / ${p.stats.total}'),
                      Text('${p.stats.awaitingResult}', key: Key('awaiting-${p.id}')),
                      Text(p.stats.total == 0 ? '—' : percent(p.stats.passRate)),
                    ],
                    key: Key('paper-${p.id}'),
                    onTap: () => context.push(Paths.paper(p.id)),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// "Name · #id" of the v2 assessment behind a paper; a paper from before Assessment v2 says so.
String assessmentLabel(Paper p) {
  if (p.engine != 'v2') return 'Retired quiz';
  final name = p.snapshot.name.isEmpty ? 'Assessment' : p.snapshot.name;
  return p.engineBaseId.isEmpty ? name : '$name · #${p.engineBaseId}';
}

class _QuestionRow {
  final id = TextEditingController();
  final prompt = TextEditingController();
  final options = TextEditingController();
  final answer = TextEditingController();
  String kind = 'single';

  void dispose() {
    id.dispose();
    prompt.dispose();
    options.dispose();
    answer.dispose();
  }

  /// Throws [FormatException] when the row is incomplete or an answer is not among the options.
  QuickQuestion toQuestion(int index) {
    final n = index + 1;
    final qid = id.text.trim();
    final p = prompt.text.trim();
    if (qid.isEmpty || p.isEmpty) throw FormatException('Question $n needs an id and a prompt');
    final opts = options.text.split('\n').map((o) => o.trim()).where((o) => o.isNotEmpty).toList();
    final answers = kind == 'multi'
        ? answer.text.split(',').map((a) => a.trim()).where((a) => a.isNotEmpty).toList()
        : (answer.text.trim().isEmpty ? const <String>[] : [answer.text.trim()]);
    if (answers.isEmpty) throw FormatException('Question $n needs an answer');
    if (opts.length < 2) throw FormatException('Question $n needs at least two options, one per line');
    for (final a in answers) {
      if (!opts.contains(a)) throw FormatException('Question $n: answer "$a" is not one of its options');
    }
    return QuickQuestion(id: qid, prompt: p, kind: kind, options: opts, answer: answers);
  }
}

enum _Source { link, quick }

/// A new paper: the gate it certifies and what sits behind it, either an assessment already built in
/// Assessment v2 (any question type, proctoring, SOP-generated papers) or a quick single/multiple choice paper
/// typed here.
class PaperFormDialog extends StatefulWidget {
  const PaperFormDialog({super.key});

  @override
  State<PaperFormDialog> createState() => _PaperFormDialogState();
}

class _PaperFormDialogState extends State<PaperFormDialog> {
  final _gate = TextEditingController();
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _duration = TextEditingController(text: '30');
  final _passMark = TextEditingController(text: '70');
  final _attempts = TextEditingController(text: '2');
  final List<_QuestionRow> _questions = [_QuestionRow()];
  _Source _source = _Source.link;
  String _releasePolicy = 'manual';
  List<EngineAssessment>? _assessments;
  String? _assessmentsError;
  String? _assessmentId;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAssessments());
  }

  Future<void> _loadAssessments() async {
    try {
      final list = await AppScope.of(context).ops.engineAssessments();
      if (mounted) {
        setState(() {
          _assessments = list;
          _assessmentsError = null;
        });
      }
    } on Object catch (e) {
      if (mounted) setState(() => _assessmentsError = describeError(e));
    }
  }

  @override
  void dispose() {
    for (final c in [_gate, _title, _description, _duration, _passMark, _attempts]) {
      c.dispose();
    }
    for (final q in _questions) {
      q.dispose();
    }
    super.dispose();
  }

  PaperInput? _input() {
    final gate = _gate.text.trim();
    final title = _title.text.trim();
    if (gate.isEmpty || title.isEmpty) {
      _error = 'Gate and title are required';
      return null;
    }
    final attempts = int.tryParse(_attempts.text.trim());
    if (attempts == null || attempts < 1) {
      _error = 'Max attempts is a whole number, 1 or more';
      return null;
    }
    final PaperSource source;
    if (_source == _Source.link) {
      final id = _assessmentId;
      if (id == null) {
        _error = 'Pick the assessment this paper uses';
        return null;
      }
      source = LinkedAssessment(id);
    } else {
      final duration = int.tryParse(_duration.text.trim());
      if (duration == null || duration < 2) {
        _error = 'Duration is whole minutes, 2 or more';
        return null;
      }
      final pass = double.tryParse(_passMark.text.trim());
      if (pass == null || pass < 0 || pass > 100) {
        _error = 'Pass mark is a percentage from 0 to 100';
        return null;
      }
      if (_questions.isEmpty) {
        _error = 'A paper needs at least one question';
        return null;
      }
      final questions = <QuickQuestion>[];
      try {
        for (final (i, q) in _questions.indexed) {
          questions.add(q.toQuestion(i));
        }
      } on FormatException catch (e) {
        _error = e.message;
        return null;
      }
      source = QuickPaper(durationMinutes: duration, passMark: pass / 100, questions: questions);
    }
    return PaperInput(
      gate: gate,
      title: title,
      description: _description.text.trim(),
      maxAttempts: attempts,
      releasePolicy: _releasePolicy,
      source: source,
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
    const action = 'paper:create';
    setState(() => _busy = true);
    try {
      final created = await scope.ops.createPaper(input, key: scope.keys.start(action));
      scope.keys.finish(action);
      if (mounted) Navigator.of(context).pop(created);
    } on Object catch (e) {
      scope.keys.settle(action, e);
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FormSheet(
      title: 'New paper',
      saveLabel: 'Create draft',
      saveKey: const Key('paper-save'),
      busy: _busy,
      error: ErrorBanner(_error),
      maxWidth: 680,
      onSave: _save,
      children: [
        FieldPair(
          TextField(
            key: const Key('paper-gate'),
            controller: _gate,
            decoration: const InputDecoration(labelText: 'Gate', hintText: 'transcription', helperText: 'Passing certifies this gate'),
          ),
          TextField(
            key: const Key('paper-title'),
            controller: _title,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
        ),
        fieldGap,
        TextField(
          key: const Key('paper-description'),
          controller: _description,
          maxLines: 3,
          minLines: 2,
          decoration: const InputDecoration(labelText: 'Description', alignLabelWithHint: true),
        ),
        fieldGap,
        FieldPair(
          TextField(
            key: const Key('paper-attempts'),
            controller: _attempts,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Max attempts', helperText: 'Each retake is a fresh paper'),
          ),
          DropdownButtonFormField<String>(
            key: const Key('paper-release'),
            isExpanded: true,
            initialValue: _releasePolicy,
            decoration: const InputDecoration(labelText: 'Results'),
            items: const [
              DropdownMenuItem(value: 'manual', child: Text('Released by ops')),
              DropdownMenuItem(value: 'auto_objective', child: Text('Released at once when fully objective')),
            ],
            onChanged: (v) => setState(() => _releasePolicy = v ?? 'manual'),
          ),
        ),
        const SizedBox(height: Space.x16),
        Text('The exam', style: theme.textTheme.titleSmall),
        const SizedBox(height: Space.x8),
        SegmentedButton<_Source>(
          key: const Key('paper-source'),
          segments: const [
            ButtonSegment(value: _Source.link, label: Text('Link an assessment'), icon: Icon(Icons.link)),
            ButtonSegment(value: _Source.quick, label: Text('Quick paper'), icon: Icon(Icons.edit_note)),
          ],
          selected: {_source},
          onSelectionChanged: (s) => setState(() => _source = s.first),
        ),
        const SizedBox(height: Space.x12),
        if (_source == _Source.link) _linkPicker(theme) else ..._quickEditor(theme),
      ],
    );
  }

  Widget _linkPicker(ThemeData theme) {
    final list = _assessments;
    if (_assessmentsError != null) {
      return Row(
        children: [
          Expanded(child: Text(_assessmentsError!, style: theme.textTheme.bodySmall)),
          TextButton(key: const Key('assessments-retry'), onPressed: _loadAssessments, child: const Text('Retry')),
        ],
      );
    }
    if (list == null) return const LinearProgressIndicator();
    if (list.isEmpty) {
      return Text(
        'No draft assessments in Assessment v2 yet. Build one there (generate from an SOP, import a bank, or Form '
        'Studio), or write a quick paper here.',
        key: const Key('assessments-empty'),
        style: theme.textTheme.bodySmall,
      );
    }
    return DropdownButtonFormField<String>(
      key: const Key('paper-assessment'),
      isExpanded: true,
      initialValue: _assessmentId,
      decoration: const InputDecoration(labelText: 'Assessment', helperText: 'Questions, proctoring and marking come from it'),
      items: [
        for (final a in list)
          DropdownMenuItem(
            value: a.id,
            child: Text(
              '${a.name} · #${a.id}${a.questionCount > 0 ? ' · ${a.questionCount} questions' : ''}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (v) => setState(() => _assessmentId = v),
    );
  }

  List<Widget> _quickEditor(ThemeData theme) => [
    Text(
      'Single and multiple choice only; written, audio, image and video questions are built in Assessment v2 and linked.',
      style: theme.textTheme.bodySmall,
    ),
    fieldGap,
    FieldPair(
      TextField(
        key: const Key('paper-duration'),
        controller: _duration,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'Duration (min)'),
      ),
      TextField(
        key: const Key('paper-pass-mark'),
        controller: _passMark,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'Pass mark (%)'),
      ),
    ),
    const SizedBox(height: Space.x16),
    Row(
      children: [
        Expanded(child: Text('Questions', style: theme.textTheme.titleSmall)),
        TextButton.icon(
          key: const Key('pq-add'),
          onPressed: () => setState(() => _questions.add(_QuestionRow())),
          icon: const Icon(Icons.add, size: Sizes.iconSm),
          label: const Text('Add question'),
        ),
      ],
    ),
    for (final (i, q) in _questions.indexed)
      _QuestionEditor(index: i, row: q, onChanged: () => setState(() {}), onRemove: () => setState(() => _questions.removeAt(i).dispose())),
  ];
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
                key: Key('pq-remove-$index'),
                tooltip: 'Remove question ${index + 1}',
                visualDensity: VisualDensity.compact,
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline, size: Sizes.iconSm),
              ),
            ],
          ),
          FieldPair(
            TextField(
              key: Key('pq-id-$index'),
              controller: row.id,
              decoration: const InputDecoration(labelText: 'Id', hintText: 'q1'),
            ),
            DropdownButtonFormField<String>(
              key: Key('pq-kind-$index'),
              isExpanded: true,
              initialValue: row.kind,
              decoration: const InputDecoration(labelText: 'Kind'),
              items: const [
                DropdownMenuItem(value: 'single', child: Text('Single choice')),
                DropdownMenuItem(value: 'multi', child: Text('Multiple choice')),
              ],
              onChanged: (v) {
                row.kind = v ?? 'single';
                onChanged();
              },
            ),
          ),
          fieldGap,
          TextField(
            key: Key('pq-prompt-$index'),
            controller: row.prompt,
            decoration: const InputDecoration(labelText: 'Prompt'),
          ),
          fieldGap,
          TextField(
            key: Key('pq-options-$index'),
            controller: row.options,
            maxLines: 4,
            minLines: 2,
            decoration: const InputDecoration(labelText: 'Options', helperText: 'One per line', alignLabelWithHint: true),
          ),
          fieldGap,
          TextField(
            key: Key('pq-answer-$index'),
            controller: row.answer,
            decoration: InputDecoration(
              labelText: 'Answer',
              helperText: row.kind == 'multi' ? 'Every correct option, comma-separated' : 'One of the options, exactly',
            ),
          ),
        ],
      ),
    );
  }
}
