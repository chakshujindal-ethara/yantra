import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/widgets/currency_field.dart';

import '../../api/ops_models.dart';
import '../../app_scope.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/json.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/portal_tokens.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/form_sheet.dart';
import '../../core/widgets/loader.dart';
import '../../core/widgets/portal_page.dart';
import '../../core/widgets/stage_bar.dart';
import '../../core/widgets/tables.dart';
import '../../widgets/load_view.dart';
import '../shell.dart';
import '../../app_router.dart';
import 'package:go_router/go_router.dart';

/// Every client project: search, a status filter, units by stage, and the form that creates one.
class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  String _query = '';
  String? _status;

  List<ProjectSummary> _filter(List<ProjectSummary> all) {
    final q = _query.trim().toLowerCase();
    return [
      for (final p in all)
        if ((q.isEmpty || p.name.toLowerCase().contains(q)) && (_status == null || p.status == _status)) p,
    ];
  }

  Future<void> _create(Future<void> Function() reload) async {
    final created = await showDialog<ProjectDetail>(context: context, builder: (_) => const ProjectFormDialog());
    if (created == null || !mounted) return;
    ShellActions.of(context).markStale(Destination.opsOverview);
    toast(context, 'Project "${created.name}" created');
    await reload();
  }

  @override
  Widget build(BuildContext context) {
    return LoadView<List<ProjectSummary>>(
      firstWait: LoadWait.brand,
      load: () => AppScope.of(context).ops.projects(),
      builder: (context, all, reload) {
        final shown = _filter(all);
        return PortalPage(
          kicker: 'Operate · Projects',
          title: 'Projects',
          subtitle: 'Client projects and their batches',
          onRefresh: reload,
          actions: [
            FilledButton.icon(
              key: const Key('new-project'),
              onPressed: () => _create(reload),
              icon: const Icon(Icons.add, size: Sizes.iconSm),
              label: const Text('New project'),
            ),
          ],
          children: [
            Toolbar(
              search: TextField(
                key: const Key('projects-search'),
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search by name'),
                onChanged: (v) => setState(() => _query = v),
              ),
              children: [
                FilterChips<String>(
                  values: const {'All': null, 'Draft': 'draft', 'Active': 'active', 'Closed': 'closed'},
                  selected: _status,
                  onSelected: (v) => setState(() => _status = v),
                ),
              ],
            ),
            if (all.isEmpty)
              const PortalCard(child: EmptyView(message: 'No projects yet. "New project" starts the first one.'))
            else
              PortalTable(
                minWidth: 880,
                emptyMessage: 'No project matches',
                columns: const [
                  PortalColumn('Name', flex: 2),
                  PortalColumn('Status', width: 130),
                  PortalColumn('Currency', width: 90),
                  PortalColumn('Gate'),
                  PortalColumn('Batches', width: 90, numeric: true),
                  PortalColumn('Units', flex: 2),
                  PortalColumn('Created', width: 110),
                ],
                rows: [
                  for (final p in shown)
                    PortalRow(key: Key('project-${p.id}'), onTap: () => context.push(Paths.project(p.id)), [
                      Text(p.name),
                      ConsoleStatus(p.status),
                      Text(p.currency, style: AppTheme.mono(context, fontSize: 13)),
                      Text(p.certGate.isEmpty ? '—' : p.certGate),
                      Text('${p.batchCount}'),
                      StageBar(
                        legend: false,
                        available: p.units.available,
                        inProgress: p.units.claimed,
                        inReview: p.units.reviewing,
                        accepted: p.units.accepted,
                        rejected: p.units.rejected,
                        needsEdits: p.units.needsEdits,
                      ),
                      Text(p.createdAt == null ? '—' : shortDate(p.createdAt!)),
                    ]),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// Parses a JSON object field. Returns the object, or null when [text] is empty; throws [FormatException]
/// with a line a person can act on otherwise.
Json? parseSchema(String text, String label) {
  if (text.trim().isEmpty) return null;
  final Object? v;
  try {
    v = jsonDecode(text);
  } on FormatException catch (e) {
    throw FormatException('$label is not valid JSON: ${e.message}');
  }
  if (v is! Map) throw FormatException('$label must be a JSON object');
  return Map<String, dynamic>.from(v);
}

/// The project form: creates when [initial] is null, edits otherwise. Pops with the saved project.
class ProjectFormDialog extends StatefulWidget {
  const ProjectFormDialog({super.key, this.initial});
  final ProjectDetail? initial;

  @override
  State<ProjectFormDialog> createState() => _ProjectFormDialogState();
}

class _ProjectFormDialogState extends State<ProjectFormDialog> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late String _currency = widget.initial?.currency ?? 'INR';
  late final _retention = TextEditingController(text: '${widget.initial?.retentionDays ?? 180}');
  late final _gate = TextEditingController(text: widget.initial?.certGate ?? '');
  late final _rubric = TextEditingController(text: widget.initial?.rubricVersion ?? 'v1');
  late final _floor = TextEditingController(
    text: widget.initial?.marginFloor == null ? '' : (widget.initial!.marginFloor! * 100).toStringAsFixed(0),
  );
  late final _brief = TextEditingController(text: widget.initial?.brief ?? '');
  late final _llm = TextEditingController(text: widget.initial?.llmPolicy ?? '');
  late final _payload = TextEditingController(
    text: widget.initial == null ? '{"type": "object", "properties": {}}' : prettyJson.convert(widget.initial!.payloadSchema),
  );
  late final _answer = TextEditingController(
    text: widget.initial == null || widget.initial!.answerSchema.isEmpty ? '' : prettyJson.convert(widget.initial!.answerSchema),
  );
  late bool _sensitive = widget.initial?.sensitive ?? false;
  late String _org = widget.initial?.clientOrgId ?? '';
  late String _status = widget.initial?.status ?? '';
  List<ClientOrg> _orgs = const [];
  bool _orgsFailed = false;
  bool _busy = false;
  String? _error;

  /// The project the POST created. From then on the dialog only PATCHes the extra fields: a failed
  /// PATCH must never lead to a second POST.
  ProjectDetail? _created;
  String? _patchError;

  bool get _editing => widget.initial != null;

  /// Fields creation fixed: they are read-only while editing and once the POST has landed.
  bool get _locked => _editing || _created != null;

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _loadOrgs();
    }
  }

  Future<void> _loadOrgs() async {
    try {
      final orgs = await AppScope.of(context).ops.clientOrgs();
      if (mounted) setState(() => _orgs = orgs);
    } on Object {
      if (mounted) setState(() => _orgsFailed = true);
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _retention, _gate, _rubric, _floor, _brief, _llm, _payload, _answer]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The input, or null with [_error] set.
  ProjectInput? _input() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _error = 'Name is required';
      return null;
    }
    final currency = _currency;
    final retention = int.tryParse(_retention.text.trim());
    if (retention == null || retention < 1 || retention > 3650) {
      _error = 'Retention is a number of days from 1 to 3650';
      return null;
    }
    double? floor;
    if (_floor.text.trim().isNotEmpty) {
      final pct = double.tryParse(_floor.text.trim());
      if (pct == null || pct < 0 || pct > 100) {
        _error = 'Margin floor is a percentage from 0 to 100';
        return null;
      }
      floor = pct / 100;
    }
    final Json? payload;
    final Json? answer;
    try {
      payload = parseSchema(_payload.text, 'Payload schema');
      answer = parseSchema(_answer.text, 'Answer schema');
    } on FormatException catch (e) {
      _error = e.message;
      return null;
    }
    if (payload == null && !_editing) {
      _error = 'Payload schema is required';
      return null;
    }
    return ProjectInput(
      name: name,
      currency: currency,
      payloadSchema: payload ?? const {},
      answerSchema: answer,
      rubricVersion: _rubric.text.trim().isEmpty ? 'v1' : _rubric.text.trim(),
      marginFloor: floor,
      certGate: _gate.text.trim(),
      brief: _brief.text.trim(),
      llmPolicy: _llm.text.trim(),
      sensitive: _sensitive,
      clientOrgId: _org,
      status: _status,
      retentionDays: retention,
    );
  }

  Future<void> _save() async {
    final scope = AppScope.of(context);
    _error = null;
    _patchError = null;
    final input = _input();
    if (input == null) {
      setState(() {});
      return;
    }
    setState(() => _busy = true);
    try {
      if (_editing) {
        final action = 'project:edit:${widget.initial!.id}';
        final saved = await _run(action, () => scope.ops.patchProject(widget.initial!.id, input.editBody, key: scope.keys.start(action)));
        if (saved != null && mounted) Navigator.of(context).pop(saved);
        return;
      }
      final created =
          _created ?? await _run('project:create', () => scope.ops.createProject(input, key: scope.keys.start('project:create')));
      if (created == null) return;
      _created = created;
      await _patchExtras(created, input.createPatchBody);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The POST landed; only the extra fields are left. Pops with the project once they are saved, else
  /// keeps the dialog open with the reason and a Retry that PATCHes again.
  Future<void> _patchExtras(ProjectDetail created, Json patch) async {
    if (patch.isEmpty) {
      if (mounted) Navigator.of(context).pop(created);
      return;
    }
    final scope = AppScope.of(context);
    final action = 'project:create:patch:${created.id}';
    final saved = await _run(
      action,
      () => scope.ops.patchProject(created.id, patch, key: scope.keys.start(action)),
      onError: (m) => _patchError = m,
    );
    if (saved != null && mounted) Navigator.of(context).pop(saved);
  }

  Future<void> _retryPatch() async {
    final created = _created;
    final input = _input();
    if (created == null || input == null) {
      setState(() {});
      return;
    }
    setState(() {
      _busy = true;
      _patchError = null;
    });
    try {
      await _patchExtras(created, input.createPatchBody);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// One mutation under [action]'s key: finished on success, settled on failure. Null with the message
  /// placed by [onError] (the main error line by default) when it failed.
  Future<ProjectDetail?> _run(String action, Future<ProjectDetail> Function() call, {void Function(String message)? onError}) async {
    final scope = AppScope.of(context);
    try {
      final saved = await call();
      scope.keys.finish(action);
      return saved;
    } on Object catch (e) {
      scope.keys.settle(action, e);
      if (mounted) setState(() => (onError ?? (m) => _error = m)(describeError(e)));
      return null;
    }
  }

  /// Cancel after the POST landed still hands the created project back, so the list reloads.
  void _cancel() => Navigator.of(context).pop(_created);

  @override
  Widget build(BuildContext context) {
    final mono = AppTheme.mono(context);
    final patchError = _patchError;
    return FormSheet(
      title: _editing ? 'Edit project' : 'New project',
      saveLabel: _editing
          ? 'Save'
          : _created == null
          ? 'Create project'
          : 'Save extra fields',
      saveKey: const Key('project-save'),
      busy: _busy,
      onCancel: _editing ? null : _cancel,
      error: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ErrorBanner(_error),
          if (patchError != null) ...[
            StatusBanner(
              'Project created; the extra fields were not saved: $patchError',
              key: const Key('project-patch-error'),
              kind: StatusKind.warn,
              icon: Icons.warning_amber_rounded,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                key: const Key('project-patch-retry'),
                onPressed: _busy ? null : _retryPatch,
                child: const Text('Retry'),
              ),
            ),
            fieldGap,
          ],
        ],
      ),
      onSave: _save,
      children: [
        TextField(
          key: const Key('project-name'),
          controller: _name,
          enabled: _created == null,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        fieldGap,
        FieldPair(
          KeyedSubtree(
            key: const Key('project-currency'),
            child: CurrencyField(value: _currency, enabled: !_locked, onChanged: (c) => setState(() => _currency = c)),
          ),
          TextField(
            key: const Key('project-gate'),
            controller: _gate,
            enabled: _created == null,
            decoration: const InputDecoration(labelText: 'Certification gate', hintText: 'transcription'),
          ),
        ),
        fieldGap,
        FieldPair(
          TextField(
            key: const Key('project-rubric'),
            controller: _rubric,
            enabled: _created == null,
            decoration: const InputDecoration(labelText: 'Rubric version'),
          ),
          TextField(
            key: const Key('project-floor'),
            controller: _floor,
            enabled: _created == null,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Margin floor (%)', hintText: '30'),
          ),
        ),
        if (_editing) ...[
          fieldGap,
          DropdownButtonFormField<String>(
            key: const Key('project-status'),
            isExpanded: true,
            initialValue: _status.isEmpty ? null : _status,
            decoration: const InputDecoration(labelText: 'Status'),
            items: const [
              DropdownMenuItem(value: 'draft', child: Text('Draft')),
              DropdownMenuItem(value: 'active', child: Text('Active')),
              DropdownMenuItem(value: 'closed', child: Text('Closed')),
            ],
            onChanged: (v) => setState(() => _status = v ?? ''),
          ),
        ],
        fieldGap,
        DropdownButtonFormField<String>(
          key: const Key('project-org'),
          isExpanded: true,
          initialValue: _orgs.any((o) => o.id == _org) ? _org : '',
          decoration: InputDecoration(labelText: 'Client org', helperText: _orgsFailed ? 'Client orgs could not be loaded' : null),
          items: [
            const DropdownMenuItem(value: '', child: Text('None')),
            for (final o in _orgs) DropdownMenuItem(value: o.id, child: Text(o.name)),
          ],
          onChanged: (v) => setState(() => _org = v ?? ''),
        ),
        fieldGap,
        TextField(
          key: const Key('project-brief'),
          controller: _brief,
          maxLines: 4,
          minLines: 2,
          decoration: const InputDecoration(labelText: 'Brief', alignLabelWithHint: true),
        ),
        fieldGap,
        TextField(
          key: const Key('project-llm'),
          controller: _llm,
          maxLines: 3,
          minLines: 2,
          decoration: const InputDecoration(labelText: 'LLM policy', alignLabelWithHint: true),
        ),
        fieldGap,
        SwitchRow(
          label: 'Sensitive',
          hint: 'Workers see a confidentiality notice; exports are restricted',
          value: _sensitive,
          switchKey: const Key('project-sensitive'),
          onChanged: (v) => setState(() => _sensitive = v),
        ),
        fieldGap,
        TextField(
          key: const Key('project-retention'),
          controller: _retention,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Keep payloads and answers for (days)',
            helperText: 'After delivery; counts, digests and money records are kept',
          ),
        ),
        fieldGap,
        _SchemaField(
          fieldKey: const Key('project-payload-schema'),
          sampleKey: const Key('project-payload-sample'),
          controller: _payload,
          enabled: !_locked,
          label: 'Payload schema (JSON)',
          helper: _editing ? 'Set at creation; it cannot change' : 'A JSON Schema object for what each unit carries',
          sample: samplePayloadSchema,
          style: mono,
        ),
        fieldGap,
        _SchemaField(
          fieldKey: const Key('project-answer-schema'),
          sampleKey: const Key('project-answer-sample'),
          controller: _answer,
          enabled: true,
          label: 'Answer schema (JSON, optional)',
          helper: 'Builds the worker\'s answer form',
          sample: sampleAnswerSchema,
          style: mono,
        ),
      ],
    );
  }
}

/// A starting point for a payload schema: an audio clip and its language.
const samplePayloadSchema = {
  'type': 'object',
  'required': ['audio_ref', 'language'],
  'properties': {
    'audio_ref': {'type': 'string', 'minLength': 1, 'title': 'Audio clip'},
    'language': {
      'type': 'string',
      'enum': ['hi', 'ta', 'en'],
      'title': 'Language',
    },
  },
};

/// A starting point for an answer schema: a transcript, the speaker count and a noise flag.
const sampleAnswerSchema = {
  'type': 'object',
  'required': ['transcript'],
  'properties': {
    'transcript': {'type': 'string', 'title': 'Transcript', 'minLength': 1},
    'speakers': {'type': 'integer', 'title': 'Number of speakers', 'minimum': 1},
    'noisy': {'type': 'boolean', 'title': 'Background noise'},
  },
};

/// A JSON Schema typed in a box: checked as it is typed (half a second after the last key), with a button
/// that fills a sample when the box is empty or only `{}`-ish.
class _SchemaField extends StatefulWidget {
  const _SchemaField({
    required this.fieldKey,
    required this.sampleKey,
    required this.controller,
    required this.enabled,
    required this.label,
    required this.helper,
    required this.sample,
    required this.style,
  });
  final Key fieldKey;
  final Key sampleKey;
  final TextEditingController controller;
  final bool enabled;
  final String label;
  final String helper;
  final Map<String, Object> sample;
  final TextStyle style;

  @override
  State<_SchemaField> createState() => _SchemaFieldState();
}

class _SchemaFieldState extends State<_SchemaField> {
  String? _problem;
  Timer? _typing;

  @override
  void dispose() {
    _typing?.cancel();
    super.dispose();
  }

  void _check() {
    String? problem;
    try {
      final schema = parseSchema(widget.controller.text, widget.label.split(' (').first);
      if (schema != null && schema['type'] != 'object') problem = 'The schema\'s "type" should be "object"';
      if (schema != null && schema['properties'] is! Map?) problem = '"properties" should be an object of fields';
    } on FormatException catch (e) {
      problem = e.message;
    }
    if (mounted) setState(() => _problem = problem);
  }

  void _changed(String _) {
    _typing?.cancel();
    _typing = Timer(const Duration(milliseconds: 500), _check);
  }

  void _insertSample() {
    widget.controller.text = prettyJson.convert(widget.sample);
    _check();
  }

  @override
  Widget build(BuildContext context) {
    final empty = widget.controller.text.trim().isEmpty || RegExp(r'"properties"\s*:\s*\{\s*\}').hasMatch(widget.controller.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: widget.fieldKey,
          controller: widget.controller,
          enabled: widget.enabled,
          maxLines: 8,
          minLines: 3,
          style: widget.style,
          onChanged: _changed,
          decoration: InputDecoration(labelText: widget.label, alignLabelWithHint: true, helperText: widget.helper, errorText: _problem),
        ),
        if (widget.enabled && empty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: widget.sampleKey,
              onPressed: _insertSample,
              icon: const Icon(Icons.auto_fix_high_outlined, size: 16),
              label: const Text('Insert sample'),
            ),
          ),
      ],
    );
  }
}
