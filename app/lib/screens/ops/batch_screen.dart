import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import '../../core/widgets/action_dialog.dart';
import '../../core/widgets/date_field.dart';
import '../../api/ops_models.dart';
import '../../app_scope.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/portal_tokens.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/form_sheet.dart';
import '../../core/widgets/loader.dart';
import '../../core/widgets/people.dart';
import '../../core/widgets/portal_page.dart';
import '../../core/widgets/stage_bar.dart';
import '../../core/widgets/tables.dart';
import '../../widgets/load_view.dart';
import '../shell.dart';
import '../../core/widgets/detail_frame.dart';
import '../../app_router.dart';

/// One batch as a pushed route: the counts, the live claims, the actions its status allows, the import
/// with its dry-run report, the units table, and the manifest behind the delivery gate.
class BatchScreen extends StatefulWidget {
  const BatchScreen({super.key, required this.batchId, this.projectId, this.marginFloor});
  final String batchId;

  /// The project the breadcrumb links back to, when the route knows it.
  final String? projectId;

  /// The project's floor when the caller knows it; otherwise the screen reads the project.
  final double? marginFloor;

  @override
  State<BatchScreen> createState() => _BatchScreenState();
}

/// The batch and its project's margin floor. [floorError] is set when the project could not be read:
/// the floor is then unknown, not absent, and Publish waits for a Retry.
typedef BatchView = ({BatchSummary batch, double? floor, String? floorError});

class _BatchScreenState extends State<BatchScreen> {
  String? _error;
  bool _busy = false;
  int _unitsToken = 0;
  Future<void> Function()? _reload;

  Future<BatchView> _load() async {
    final ops = AppScope.of(context).ops;
    final batch = await ops.batch(widget.batchId);
    var floor = widget.marginFloor;
    String? floorError;
    if (floor == null) {
      try {
        floor = (await ops.project(batch.projectId)).marginFloor;
      } on Object catch (e) {
        floorError = describeError(e);
      }
    }
    return (batch: batch, floor: floor, floorError: floorError);
  }

  Future<void> _refresh() async {
    setState(() => _unitsToken++);
    await _reload?.call();
  }

  /// Runs one mutation under its idempotency key; a failure (a 409 among them) lands in the banner.
  Future<void> _run(String action, Future<Object?> Function(String key) call, {required String done}) async {
    final scope = AppScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await call(scope.keys.start(action));
      scope.keys.finish(action);
      scope.stale.mark([Destination.projects, Destination.opsOverview]);
      if (!mounted) return;
      toast(context, done);
      await _refresh();
    } on Object catch (e) {
      scope.keys.settle(action, e);
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _publish(BatchView v) async {
    final ops = AppScope.of(context).ops;
    String? approvedBy;
    String? note;
    if (v.batch.underFloor(v.floor)) {
      final approval = await showDialog<(String, String)>(
        context: context,
        builder: (_) => _ApprovalDialog(batch: v.batch, floor: v.floor!),
      );
      if (approval == null) return;
      (approvedBy, note) = approval;
    } else {
      final ok = await confirm(
        context,
        title: 'Publish "${v.batch.title}"?',
        body: 'Eligible workers see it and can claim its ${v.batch.units.available} available units at once.',
        confirmLabel: 'Publish',
      );
      if (!ok) return;
    }
    if (!mounted) return;
    await _run(
      'batch:publish:${v.batch.id}',
      (key) => ops.publishBatch(v.batch.id, approvedBy: approvedBy, note: note, key: key),
      done: 'Batch published',
    );
  }

  Future<void> _cancel(BatchSummary b) async {
    final ops = AppScope.of(context).ops;
    final ok = await confirm(
      context,
      title: 'Cancel "${b.title}"?',
      body: 'Its units are withdrawn and nothing more can be claimed. A batch with live claims cannot be cancelled.',
      confirmLabel: 'Cancel batch',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _run('batch:cancel:${b.id}', (key) => ops.batchAction(b.id, 'cancel', key: key), done: 'Batch cancelled');
  }

  Future<void> _due(BatchSummary b) async {
    final ops = AppScope.of(context).ops;
    final picked = await showDialog<({DateTime? due})>(
      context: context,
      builder: (_) => _DueDialog(current: b.dueAt),
    );
    if (picked == null || !mounted) return;
    final due = picked.due;
    await _run(
      'batch:due:${b.id}:${due?.toIso8601String() ?? 'none'}',
      (key) => ops.patchBatch(b.id, dueAt: due, clearDue: due == null, key: key),
      done: due == null ? 'Due date cleared' : 'Due ${shortDate(due)}',
    );
  }

  List<Widget> _actions(BatchView v) {
    final ops = AppScope.of(context).ops;
    final b = v.batch;
    return [
      ConsoleStatus(b.status),
      OutlinedButton.icon(
        key: const Key('batch-due'),
        onPressed: _busy ? null : () => _due(b),
        icon: const Icon(Icons.event_outlined, size: Sizes.iconSm),
        label: Text(b.dueAt == null ? 'Due date' : 'Due ${shortDate(b.dueAt!)}'),
      ),
      OutlinedButton.icon(
        key: const Key('batch-review-queue'),
        onPressed: () => context.go('${Destination.quality.path}?batch=${b.id}'),
        icon: const Icon(Icons.rate_review_outlined, size: Sizes.iconSm),
        label: const Text('Review queue'),
      ),
      if (b.status == 'draft')
        Tooltip(
          message: v.floorError == null ? '' : 'Floor unknown, retry',
          child: FilledButton.icon(
            key: const Key('batch-publish'),
            onPressed: _busy || v.floorError != null ? null : () => _publish(v),
            icon: const Icon(Icons.publish_outlined, size: Sizes.iconSm),
            label: const Text('Publish'),
          ),
        ),
      if (b.status == 'published' || b.status == 'open')
        OutlinedButton.icon(
          key: const Key('batch-pause'),
          onPressed: _busy
              ? null
              : () => _run('batch:pause:${b.id}', (key) => ops.batchAction(b.id, 'pause', key: key), done: 'Batch paused'),
          icon: const Icon(Icons.pause_outlined, size: Sizes.iconSm),
          label: const Text('Pause'),
        ),
      if (b.status == 'paused')
        FilledButton.icon(
          key: const Key('batch-resume'),
          onPressed: _busy
              ? null
              : () => _run('batch:resume:${b.id}', (key) => ops.batchAction(b.id, 'resume', key: key), done: 'Batch resumed'),
          icon: const Icon(Icons.play_arrow_outlined, size: Sizes.iconSm),
          label: const Text('Resume'),
        ),
      if (b.status == 'draft' || b.status == 'published' || b.status == 'open' || b.status == 'paused')
        OutlinedButton.icon(
          key: const Key('batch-cancel'),
          onPressed: _busy ? null : () => _cancel(b),
          icon: const Icon(Icons.cancel_outlined, size: Sizes.iconSm),
          label: const Text('Cancel'),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final projectId = widget.projectId;
    return DetailFrame(
      crumbs: [
        const Crumb('Operate'),
        Crumb('Projects', path: Destination.projects.path),
        Crumb('Project', path: projectId == null ? null : Paths.project(projectId)),
        const Crumb('Batch'),
      ],
      body: LoadView<BatchView>(
        firstWait: LoadWait.brand,
        load: _load,
        builder: (context, v, reload) {
          _reload = reload;
          final b = v.batch;
          return PortalPage(
            kicker: 'Operate · Batch',
            title: b.title,
            subtitle:
                '${b.projectName} · ${humanize(b.mode)} · claim TTL ${minutesLabel(b.claimTtlMinutes)} · rubric ${b.rubricVersion}'
                '${b.dueAt == null ? '' : ' · due ${shortDate(b.dueAt!)}'}${b.purgedAt == null ? '' : ' · payloads purged ${shortDate(b.purgedAt!)}'}',
            onRefresh: _refresh,
            actions: _actions(v),
            children: [
              // always in the tree: a banner that appears would shift the cards below it and drop their typed state
              ErrorBanner(_error, key: const Key('batch-error')),
              if (v.floorError != null)
                PortalCard(
                  key: const Key('floor-error'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      StatusBanner(
                        "The project's margin floor could not be read (${v.floorError}). Floor unknown, retry before publishing.",
                        kind: StatusKind.warn,
                        icon: Icons.warning_amber_rounded,
                      ),
                      OutlinedButton(key: const Key('floor-retry'), onPressed: _busy ? null : _refresh, child: const Text('Retry')),
                    ],
                  ),
                ),
              _PayCard(v),
              _UnitKpis(b),
              TwoColumn(
                left: _ImportCard(batchId: b.id, draft: b.status == 'draft', onImported: _refresh),
                right: _ManifestCard(batch: b, onBuilt: _refresh),
              ),
              _UnitsCard(batchId: b.id, token: _unitsToken, hasPool: b.mode != 'assigned'),
            ],
          );
        },
      ),
    );
  }
}

class _PayCard extends StatelessWidget {
  const _PayCard(this.v);
  final BatchView v;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = v.batch;
    final under = b.underFloor(v.floor);
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Pay and bill', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x8),
          PayBill(pay: b.unitPay, bill: b.unitPrice, currency: b.currency, margin: b.margin, underFloor: under),
          const SizedBox(height: Space.x4),
          Text(
            'Review pay ${formatMoney(b.reviewPay, currency: b.currency)} per review'
            '${v.floor == null ? '' : ' · floor ${percent(v.floor)}'}'
            '${b.floorApprovedBy.isEmpty ? '' : ' · under-floor publish approved by ${b.floorApprovedBy}'}'
            '${b.publishedAt == null ? '' : ' · published ${shortDate(b.publishedAt!)}'}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _UnitKpis extends StatelessWidget {
  const _UnitKpis(this.b);
  final BatchSummary b;

  @override
  Widget build(BuildContext context) {
    final u = b.units;
    return KpiRow(
      children: [
        KpiTile(label: 'Available', value: '${u.available}', note: 'of ${u.total} units', icon: Icons.inventory_2_outlined),
        KpiTile(
          label: 'Live claims',
          value: '${b.liveClaims}',
          note: '${u.claimed} units claimed',
          kind: StatusKind.info,
          icon: Icons.bolt_outlined,
        ),
        KpiTile(
          label: 'In review',
          value: '${u.reviewing}',
          note: '${u.submitted} submitted · ${u.inReview} in review',
          kind: StatusKind.warn,
          icon: Icons.rate_review_outlined,
        ),
        KpiTile(
          label: 'Accepted',
          value: '${u.accepted}',
          note: '${u.needsEdits} need edits · ${u.rejected} rejected',
          kind: StatusKind.success,
          icon: Icons.verified_outlined,
        ),
      ],
    );
  }
}

/// Reads the lines field: a JSON array of objects, an object with `lines`, or one object per line.
List<Json> parseImportLines(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) throw const FormatException('Paste the lines first');
  List<Json> objects(List<dynamic> list) {
    final out = <Json>[];
    for (final (i, e) in list.indexed) {
      if (e is! Map) throw FormatException('Line ${i + 1} is not a JSON object');
      out.add(Map<String, dynamic>.from(e));
    }
    return out;
  }

  try {
    final v = jsonDecode(trimmed);
    if (v is List) return objects(v);
    if (v is Map && v['lines'] is List) return objects(v['lines'] as List);
    if (v is Map) return [Map<String, dynamic>.from(v)];
  } on FormatException {
    // Not one document: try one object per line.
  }
  final lines = trimmed.split('\n').where((l) => l.trim().isNotEmpty).toList();
  final out = <Json>[];
  for (final (i, l) in lines.indexed) {
    final Object? v;
    try {
      v = jsonDecode(l);
    } on FormatException catch (e) {
      throw FormatException('Line ${i + 1} is not valid JSON: ${e.message}');
    }
    if (v is! Map) throw FormatException('Line ${i + 1} is not a JSON object');
    out.add(Map<String, dynamic>.from(v));
  }
  return out;
}

class _ImportCard extends StatefulWidget {
  const _ImportCard({required this.batchId, required this.draft, required this.onImported});
  final String batchId;

  /// Media can only be uploaded while the batch is a draft.
  final bool draft;
  final Future<void> Function() onImported;

  @override
  State<_ImportCard> createState() => _ImportCardState();
}

class _ImportCardState extends State<_ImportCard> {
  final _lines = TextEditingController();
  ImportReport? _report;
  String _reportFor = '';
  bool _busy = false;
  String? _error;
  int? _imported;

  @override
  void dispose() {
    _lines.dispose();
    super.dispose();
  }

  bool get _canImport => _report != null && _report!.dryRun && _report!.clean && _reportFor == _lines.text;

  /// Media uploaded this session: its name and the ref a unit's payload carries.
  final List<({String name, String ref})> _media = [];

  /// Reads a `.jsonl`, `.json` or `.csv` file into the box and dry-runs it. A CSV needs an `external_ref`
  /// column; every other column becomes a payload field.
  Future<void> _fromFile() async {
    final scope = AppScope.of(context);
    final file = await scope.files.pick(accept: '.jsonl,.json,.csv,application/json,text/csv');
    if (file == null || !mounted) return;
    final text = utf8.decode(file.bytes, allowMalformed: true);
    try {
      _lines.text = file.name.toLowerCase().endsWith('.csv') ? csvToJsonLines(text) : text;
    } on FormatException catch (e) {
      setState(() => _error = '${file.name}: ${e.message}');
      return;
    }
    setState(() => _error = null);
    await _send(dryRun: true);
  }

  /// Uploads one media file straight to storage and offers a line that points at it.
  Future<void> _uploadMedia() async {
    final scope = AppScope.of(context);
    final file = await scope.files.pick(accept: 'audio/*,image/*,video/*,application/pdf,text/plain');
    if (file == null || !mounted) return;
    final mime = file.mime.isEmpty ? 'application/octet-stream' : file.mime;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final uploads = await withActionKey(
        scope.keys,
        'media:${widget.batchId}:${file.name}:${file.bytes.length}',
        (key) => scope.ops.payloadUploads(widget.batchId, [
          (name: safeMediaName(file.name), contentType: mime, size: file.bytes.length),
        ], key: key),
      );
      final up = uploads.single;
      await scope.uploader.put(up.target, file.bytes);
      if (!mounted) return;
      final field = mime.startsWith('audio/') ? 'audio_ref' : (mime.startsWith('image/') ? 'image_ref' : 'file_ref');
      final stem = up.name.contains('.') ? up.name.substring(0, up.name.lastIndexOf('.')) : up.name;
      final line = jsonEncode({
        'external_ref': stem,
        'payload': {field: up.ref},
      });
      setState(() {
        _media.add((name: up.name, ref: up.ref));
        _lines.text = _lines.text.trim().isEmpty ? line : '${_lines.text.trimRight()}\n$line';
      });
      toast(context, '${up.name} uploaded; its line is in the box');
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send({required bool dryRun}) async {
    final scope = AppScope.of(context);
    final List<Json> lines;
    try {
      lines = parseImportLines(_lines.text);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    final action = 'import:${widget.batchId}:${dryRun ? 'dry' : 'commit'}';
    setState(() {
      _busy = true;
      _error = null;
      _imported = null;
    });
    try {
      final report = await scope.ops.importUnits(widget.batchId, lines, dryRun: dryRun, key: scope.keys.start(action));
      scope.keys.finish(action);
      if (!mounted) return;
      if (dryRun) {
        setState(() {
          _report = report;
          _reportFor = _lines.text;
        });
      } else {
        setState(() {
          _imported = report.accepted;
          _report = null;
          _lines.clear();
        });
        scope.stale.mark([Destination.projects, Destination.opsOverview]);
        toast(context, '${report.accepted} units imported');
        await widget.onImported();
      }
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
    final report = _report;
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Import units', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x4),
          Text(
            'Paste the lines (a JSON array or one object per line), or load a .jsonl or .csv file; each line needs an external_ref and a payload. Upload media first and its line is added for you. A dry run checks every line before anything lands.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Space.x12),
          ErrorBanner(_error),
          if (_imported != null) StatusBanner('$_imported units imported', kind: StatusKind.success, icon: Icons.check_circle_outline),
          TextField(
            key: const Key('import-lines'),
            controller: _lines,
            maxLines: 8,
            minLines: 4,
            style: AppTheme.mono(context),
            decoration: const InputDecoration(hintText: '[{"external_ref": "row-1", "payload": {"text": "…"}}]'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Space.x12),
          if (_media.isNotEmpty) ...[
            for (final m in _media) Text('${m.name} → ${m.ref}', key: Key('media-${m.name}'), style: AppTheme.mono(context, fontSize: 12)),
            const SizedBox(height: Space.x8),
          ],
          Wrap(
            spacing: Space.x8,
            runSpacing: Space.x8,
            children: [
              OutlinedButton.icon(
                key: const Key('import-file'),
                onPressed: _busy ? null : _fromFile,
                icon: const Icon(Icons.upload_file_outlined, size: Sizes.iconSm),
                label: const Text('Load a file'),
              ),
              if (widget.draft)
                OutlinedButton.icon(
                  key: const Key('media-upload'),
                  onPressed: _busy ? null : _uploadMedia,
                  icon: const Icon(Icons.perm_media_outlined, size: Sizes.iconSm),
                  label: const Text('Upload media'),
                ),
              OutlinedButton.icon(
                key: const Key('import-dry-run'),
                onPressed: _busy ? null : () => _send(dryRun: true),
                icon: const Icon(Icons.fact_check_outlined, size: Sizes.iconSm),
                label: const Text('Dry run'),
              ),
              FilledButton.icon(
                key: const Key('import-commit'),
                onPressed: _busy || !_canImport ? null : () => _send(dryRun: false),
                icon: const Icon(Icons.upload_outlined, size: Sizes.iconSm),
                label: Text(_canImport ? 'Import ${report!.accepted} units' : 'Import'),
              ),
            ],
          ),
          if (report != null) ...[
            const SizedBox(height: Space.x12),
            StatusBanner(
              report.errors.isEmpty
                  ? 'Dry run: all ${report.accepted} lines accepted. Import to create the units.'
                  : 'Dry run: ${report.accepted} of ${report.total} lines accepted · ${report.errors.length} ${report.errors.length == 1 ? 'problem' : 'problems'} below. Fix the lines and run again.',
              key: const Key('import-report'),
              kind: report.errors.isEmpty ? StatusKind.success : StatusKind.warn,
              icon: report.errors.isEmpty ? Icons.check_circle_outline : Icons.warning_amber_rounded,
            ),
            if (report.errors.isNotEmpty)
              PortalTable(
                key: const Key('import-errors'),
                minWidth: 320,
                columns: const [
                  PortalColumn('Line', width: 70, numeric: true),
                  PortalColumn('External ref'),
                  PortalColumn('Reason', flex: 2),
                ],
                rows: [
                  for (final e in report.errors)
                    PortalRow([
                      Text('${e.line}'),
                      Text(e.externalRef.isEmpty ? '—' : e.externalRef, style: AppTheme.mono(context, fontSize: 12)),
                      Text(e.reason),
                    ]),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

class _ManifestCard extends StatefulWidget {
  const _ManifestCard({required this.batch, required this.onBuilt});
  final BatchSummary batch;
  final Future<void> Function() onBuilt;

  @override
  State<_ManifestCard> createState() => _ManifestCardState();
}

class _ManifestCardState extends State<_ManifestCard> {
  bool _busy = false;
  String? _gate;
  Manifest? _built;
  Deliverable? _deliverable;

  /// The delivered files come from storage through five-minute links; the first call writes them.
  Future<void> _download({required bool manifest}) async {
    final scope = AppScope.of(context);
    setState(() {
      _busy = true;
      _gate = null;
    });
    try {
      final d = await scope.ops.deliverable(widget.batch.id);
      if (!mounted) return;
      setState(() => _deliverable = d);
      scope.downloader.open(Uri.parse(manifest ? d.manifestUrl : d.jsonlUrl));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(
        () => _gate = e.code == 'batch_purged'
            ? purgedCopy(widget.batch.purgedAt)
            : (e.isConflict ? withDetails('The deliverable waits for the manifest.', e) : describeError(e)),
      );
    } on Object catch (e) {
      if (mounted) setState(() => _gate = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _build() async {
    final ops = AppScope.of(context).ops;
    setState(() {
      _busy = true;
      _gate = null;
    });
    try {
      final m = await ops.manifest(widget.batch.id);
      if (!mounted) return;
      setState(() => _built = m);
      toast(context, 'Manifest built');
      await widget.onBuilt();
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _gate = e.isConflict ? withDetails('The batch is not fully accepted yet.', e) : describeError(e));
      }
    } on Object catch (e) {
      if (mounted) setState(() => _gate = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = widget.batch;
    final m = b.manifest ?? _built;
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Manifest', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x4),
          Text('The delivery: built once every unit is accepted, then handed to the client.', style: theme.textTheme.bodySmall),
          const SizedBox(height: Space.x12),
          if (_gate != null) StatusBanner(_gate!, key: const Key('manifest-gate'), kind: StatusKind.warn, icon: Icons.lock_outline),
          if (m == null)
            Text('No manifest yet', style: theme.textTheme.bodyMedium?.copyWith(color: PortalTokens.of(context).textSecondary))
          else ...[
            LabelValue(label: 'Digest', value: m.digest, mono: true, selectable: true),
            LabelValue(label: 'Accepted units', value: '${m.acceptedUnits}', mono: true),
            LabelValue(
              label: 'Total price',
              value: formatMoney(m.totalPrice, currency: b.currency),
              mono: true,
            ),
            if (m.createdAt != null) LabelValue(label: 'Built', value: dateTime(m.createdAt!)),
            if (_deliverable != null)
              LabelValue(
                label: 'Deliverable',
                value:
                    '${_deliverable!.lineCount} lines · ${(_deliverable!.bytes / 1024).ceil()} KB · sha256 ${_deliverable!.jsonlSha256.length > 12 ? _deliverable!.jsonlSha256.substring(0, 12) : _deliverable!.jsonlSha256}',
                mono: true,
              ),
          ],
          const SizedBox(height: Space.x12),
          Wrap(
            spacing: Space.x8,
            runSpacing: Space.x8,
            children: [
              OutlinedButton.icon(
                key: const Key('manifest-build'),
                onPressed: _busy ? null : _build,
                icon: const Icon(Icons.inventory_outlined, size: Sizes.iconSm),
                label: Text(m == null ? 'Build manifest' : 'Rebuild manifest'),
              ),
              if (m != null) ...[
                FilledButton.icon(
                  key: const Key('deliverable-jsonl'),
                  onPressed: _busy ? null : () => _download(manifest: false),
                  icon: const Icon(Icons.download_outlined, size: Sizes.iconSm),
                  label: const Text('Deliverable (JSONL)'),
                ),
                OutlinedButton.icon(
                  key: const Key('deliverable-manifest'),
                  onPressed: _busy ? null : () => _download(manifest: true),
                  icon: const Icon(Icons.description_outlined, size: Sizes.iconSm),
                  label: const Text('Manifest (JSON)'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

const _unitStatuses = {
  'All': null,
  'Available': 'available',
  'Claimed': 'claimed',
  'Submitted': 'submitted',
  'In review': 'in_review',
  'Accepted': 'accepted',
  'Rejected': 'rejected',
  'Needs edits': 'needs_edits',
};

class _UnitsCard extends StatefulWidget {
  const _UnitsCard({required this.batchId, required this.token, required this.hasPool});
  final String batchId;

  /// An open batch has a pool: a unit waiting for one worker can go back to it. An assigned batch has none.
  final bool hasPool;

  /// Bumped by the parent after a change; the table loads again.
  final int token;

  @override
  State<_UnitsCard> createState() => _UnitsCardState();
}

class _UnitsCardState extends State<_UnitsCard> {
  static const limit = 50;
  String? _status;
  int _offset = 0;
  late Future<ListPage<UnitRow>> _future = _load();

  Future<ListPage<UnitRow>> _load() => AppScope.of(context).ops.units(widget.batchId, status: _status, limit: limit, offset: _offset);

  void _refresh() {
    final next = _load();
    setState(() {
      _future = next;
    });
  }

  bool _busy = false;

  /// An available unit waiting for its one assigned worker (a rework author who left or is held).
  bool _waitsForOne(UnitRow u) => widget.hasPool && u.status == 'available' && u.assignedWorkerId.isNotEmpty;

  Future<void> _unassign(UnitRow u) async {
    final ok = await confirm(
      context,
      title: 'Return this unit to the pool?',
      body:
          '${u.externalRef.isEmpty ? 'The unit' : u.externalRef} is waiting for ${personLabel(context, u.assignedWorkerId)}. '
          'It goes back to the pool and any eligible worker can claim it. The change is signed with your name.',
      confirmLabel: 'Return to pool',
    );
    if (!ok || !mounted) return;
    final scope = AppScope.of(context);
    setState(() => _busy = true);
    try {
      await withActionKey(scope.keys, 'unassign:${u.id}', (key) => scope.ops.unassignUnit(u.id, key: key));
      if (!mounted) return;
      toast(context, 'Unit back in the pool');
      _refresh();
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void didUpdateWidget(_UnitsCard old) {
    super.didUpdateWidget(old);
    // Already rebuilding: swap the future without another setState.
    if (old.token != widget.token) _future = _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('Units', subtitle: 'Fifty a page, newest first'),
        Toolbar(
          children: [
            FilterChips<String>(
              values: _unitStatuses,
              selected: _status,
              onSelected: (v) {
                _status = v;
                _offset = 0;
                _refresh();
              },
            ),
          ],
        ),
        FutureBuilder<ListPage<UnitRow>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const PortalCard(child: Skeleton(lines: 4));
            if (snap.hasError) {
              return PortalCard(
                child: ErrorView(message: describeError(snap.error!), onRetry: () async => _refresh()),
              );
            }
            final page = snap.data ?? const ListPage<UnitRow>(total: 0, items: []);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PortalTable(
                  minWidth: 760,
                  emptyMessage: _status == null ? 'No units yet. Import some above.' : 'No ${humanize(_status!).toLowerCase()} units',
                  columns: const [
                    PortalColumn('External ref', flex: 2),
                    PortalColumn('Unit'),
                    PortalColumn('Status', width: 150),
                    PortalColumn('Worker'),
                    PortalColumn('Claim'),
                    PortalColumn('Created', width: 110),
                    PortalColumn('', width: 150),
                  ],
                  rows: [
                    for (final u in page.items)
                      PortalRow(key: Key('unit-${u.id}'), [
                        Text(u.externalRef, style: AppTheme.mono(context, fontSize: 13)),
                        Tooltip(
                          message: u.id,
                          child: Text(shortId(u.id), style: AppTheme.mono(context, fontSize: 12, color: t.textSecondary)),
                        ),
                        ConsoleStatus(u.status),
                        Text(u.assignedWorkerId.isEmpty ? '—' : shortId(u.assignedWorkerId), style: AppTheme.mono(context, fontSize: 12)),
                        Text(u.currentClaimId.isEmpty ? '—' : shortId(u.currentClaimId), style: AppTheme.mono(context, fontSize: 12)),
                        Text(u.createdAt == null ? '—' : shortDate(u.createdAt!)),
                        if (_waitsForOne(u))
                          TextButton(
                            key: Key('unit-unassign-${u.id}'),
                            onPressed: _busy ? null : () => _unassign(u),
                            child: Text(
                              'Return to pool',
                              semanticsLabel: 'Return ${u.externalRef} to the pool from ${personLabel(context, u.assignedWorkerId)}',
                            ),
                          )
                        else
                          const SizedBox.shrink(),
                      ]),
                  ],
                ),
                Pager(
                  offset: _offset,
                  limit: limit,
                  total: page.total,
                  onPage: (o) {
                    _offset = o;
                    _refresh();
                  },
                ),
                if (page.total > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.x8),
                    child: Text(
                      '${page.total} ${page.total == 1 ? 'unit' : 'units'}${_status == null ? '' : ' ${humanize(_status!).toLowerCase()}'}',
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Publishing under the floor: who approved it and why, both sent with the publish.
class _ApprovalDialog extends StatefulWidget {
  const _ApprovalDialog({required this.batch, required this.floor});
  final BatchSummary batch;
  final double floor;

  @override
  State<_ApprovalDialog> createState() => _ApprovalDialogState();
}

class _ApprovalDialogState extends State<_ApprovalDialog> {
  final _by = TextEditingController();
  final _note = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _by.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    final by = _by.text.trim();
    final note = _note.text.trim();
    if (by.isEmpty || note.isEmpty) {
      setState(() => _error = 'Both the approver and a note are required to publish under the floor');
      return;
    }
    Navigator.of(context).pop((by, note));
  }

  @override
  Widget build(BuildContext context) {
    return FormSheet(
      title: 'Publish under the floor',
      saveLabel: 'Publish',
      saveKey: const Key('publish-confirm'),
      error: ErrorBanner(_error),
      onSave: _submit,
      children: [
        StatusBanner(
          'Margin ${percent(widget.batch.margin)} is under the project\'s ${percent(widget.floor)} floor. The approval is recorded on the batch.',
          kind: StatusKind.warn,
          icon: Icons.warning_amber_rounded,
        ),
        TextField(
          key: const Key('publish-approved-by'),
          controller: _by,
          decoration: const InputDecoration(labelText: 'Approved by'),
        ),
        fieldGap,
        TextField(
          key: const Key('publish-note'),
          controller: _note,
          maxLines: 3,
          minLines: 2,
          decoration: const InputDecoration(labelText: 'Note', alignLabelWithHint: true),
        ),
      ],
    );
  }
}

/// Turns a CSV (first row the header, an `external_ref` column) into one JSON line per row; every other
/// column becomes a payload field. Quoted fields may hold commas and doubled quotes.
String csvToJsonLines(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"' && i + 1 < text.length && text[i + 1] == '"') {
        cell.write('"');
        i++;
      } else if (c == '"') {
        quoted = false;
      } else {
        cell.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == ',') {
      row.add(cell.toString());
      cell.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      if (row.any((x) => x.isNotEmpty)) rows.add(row);
      row = <String>[];
    } else {
      cell.write(c);
    }
  }
  row.add(cell.toString());
  if (row.any((x) => x.isNotEmpty)) rows.add(row);
  if (rows.isEmpty) throw const FormatException('the file is empty');
  final header = [for (final h in rows.first) h.trim()];
  final refAt = header.indexOf('external_ref');
  if (refAt < 0) throw const FormatException('the header needs an external_ref column');
  return [
    for (final r in rows.skip(1))
      jsonEncode({
        'external_ref': refAt < r.length ? r[refAt] : '',
        'payload': {
          for (final (i, h) in header.indexed)
            if (i != refAt && h.isNotEmpty) h: i < r.length ? r[i] : '',
        },
      }),
  ].join('\n');
}

/// A file name the storage accepts: letters, digits, dot, dash and underscore, starting with a letter or digit.
String safeMediaName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
  final trimmed = cleaned.replaceFirst(RegExp(r'^[^A-Za-z0-9]+'), '');
  final out = trimmed.isEmpty ? 'file' : trimmed;
  return out.length > 120 ? out.substring(0, 120) : out;
}

/// The due date of a batch: picked or typed, or cleared.
class _DueDialog extends StatefulWidget {
  const _DueDialog({this.current});
  final DateTime? current;

  @override
  State<_DueDialog> createState() => _DueDialogState();
}

class _DueDialogState extends State<_DueDialog> {
  late final _day = TextEditingController(text: dayText(widget.current));
  String? _error;

  @override
  void dispose() {
    _day.dispose();
    super.dispose();
  }

  void _save() {
    try {
      Navigator.of(context).pop((due: parseDay(_day.text, label: 'Due date')));
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FormSheet(
      title: 'Due date',
      saveLabel: 'Save',
      saveKey: const Key('due-save'),
      error: ErrorBanner(_error),
      onSave: _save,
      children: [
        Text('When the client expects this delivery. Their overview shows the next one due.', style: Theme.of(context).textTheme.bodySmall),
        fieldGap,
        DateField(
          controller: _day,
          label: 'Due date',
          helper: 'Empty clears it',
          fieldKey: const Key('due-day'),
          pickKey: const Key('due-pick'),
        ),
      ],
    );
  }
}
