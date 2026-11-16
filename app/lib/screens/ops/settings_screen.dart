import 'package:flutter/material.dart';

import '../../api/settings_models.dart';
import '../../api/settings_repository.dart';
import '../../app_scope.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/page_commands.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/portal_tokens.dart';
import '../../core/widgets/action_dialog.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/form_sheet.dart';
import '../../core/widgets/loader.dart';
import '../../core/widgets/page_tabs.dart';
import '../../core/widgets/people.dart';
import '../../core/widgets/portal_page.dart';
import '../../core/widgets/side_sheet.dart';
import '../../core/widgets/tables.dart';
import '../../widgets/load_view.dart';

extension on AppScope {
  SettingsRepository get settings => SettingsRepository(client.gateway);
}

enum _Tab {
  orgs('Client organisations'),
  policies('Policies'),
  reasons('Reason codes'),
  caps('Hour caps'),
  erasures('Erasure requests');

  const _Tab(this.label);
  final String label;
}

final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// Settings (ops): the platform's reference data. Client organisations and who belongs to them, the
/// policies workers accept (each change is a new version), the reason codes reviewers pick, weekly hour
/// caps for the tracker, and requests to erase a worker's personal data.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  _Tab _tab = _Tab.orgs;
  final _loader = GlobalKey<LoadViewState<Object>>();

  SettingsRepository get _repo => AppScope.of(context).settings;

  Future<void> _reload() async => _loader.currentState?.reload();

  /// Runs [call] with an idempotency key, toasts [done] or the error, reloads the tab.
  Future<bool> _act(String action, Future<void> Function(String key) call, String done) async {
    final scope = AppScope.of(context);
    try {
      await withActionKey(scope.keys, action, call);
      if (mounted) toast(context, done);
      await _reload();
      return true;
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e));
      return false;
    }
  }

  Future<Object> _load() async => switch (_tab) {
    _Tab.orgs => await _repo.orgs(),
    _Tab.policies => await _repo.policies(),
    _Tab.reasons => await _repo.reasons(),
    _Tab.caps => _Caps(await _repo.caps(), await _projectNames()),
    _Tab.erasures => await _repo.erasures(),
  };

  /// Project names for the caps table; without them a project cap shows its short id.
  Future<Map<String, String>> _projectNames() async {
    try {
      return {for (final p in await AppScope.of(context).ops.projects()) p.id: p.name};
    } on AppException {
      return const {};
    }
  }

  Future<void> _newOrg() async {
    final created = await showActionDialog<OrgRow>(
      context,
      title: 'New client organisation',
      fieldLabel: 'Name',
      confirmLabel: 'Create',
      minLength: 2,
      maxLines: 1,
      fieldKey: const Key('org-name'),
      sendKey: const Key('org-create'),
      onSend: (name) {
        final scope = AppScope.of(context);
        return withActionKey(scope.keys, 'org:$name', (key) => _repo.createOrg(name, key: key));
      },
    );
    if (created != null && mounted) {
      toast(context, '${created.name} created');
      await _reload();
    }
  }

  Future<void> _addMember(OrgRow org) async {
    final added = await showActionDialog<bool>(
      context,
      title: 'Add a member to ${org.name}',
      body: "They see this organisation's projects after their next sign-in.",
      fieldLabel: 'User id (from Keycloak → Users)',
      fieldHelper: 'In the Keycloak admin console open Users, pick the person and copy their ID.',
      validate: (id) => _uuid.hasMatch(id) ? null : 'A user id looks like 00000000-0000-4000-8000-0000000000c1',
      confirmLabel: 'Add',
      maxLines: 1,
      fieldKey: const Key('member-id'),
      sendKey: const Key('member-add'),
      onSend: (id) async {
        final trimmed = id.trim();
        final scope = AppScope.of(context);
        await withActionKey(scope.keys, 'member:${org.id}:$trimmed', (key) => _repo.addMember(org.id, trimmed, key: key));
        return true;
      },
    );
    if (added == true && mounted) {
      toast(context, 'Member added');
      await _reload();
    }
  }

  Future<void> _removeMember(OrgRow org, String userId) async {
    final ok = await confirm(
      context,
      title: 'Remove this member?',
      body: 'They stop seeing ${org.name} and its projects at their next request.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _act('member-out:${org.id}:$userId', (key) => _repo.removeMember(org.id, userId, key: key), 'Member removed');
  }

  Future<void> _viewPolicy(PolicyDoc p) => showSideSheet<void>(context, title: p.title, width: 560, builder: (context) => _PolicyBody(p));

  Future<void> _publishPolicy(PolicyDoc p) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _PolicySheet(p, repo: _repo),
    );
    if (saved == true && mounted) {
      toast(context, 'New version of ${p.title} published');
      await _reload();
    }
  }

  Future<void> _editReason(ReasonRow? r) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ReasonSheet(r, repo: _repo),
    );
    if (saved == true && mounted) {
      toast(context, r == null ? 'Reason code added' : 'Reason code saved');
      await _reload();
    }
  }

  Future<void> _setCap() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _CapSheet(repo: _repo),
    );
    if (saved == true && mounted) {
      toast(context, 'Cap saved');
      await _reload();
    }
  }

  Future<void> _approveErasure(ErasureRow e) async {
    final ok = await confirm(
      context,
      title: 'Erase this worker now?',
      body:
          'Their name, phone, city, documents and email are erased within the hour instead of on the due date. Pay owed is still paid; '
          'ledger rows keep the account id only. This cannot be undone.',
      confirmLabel: 'Approve erasure',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _act('erase:${e.workerId}', (key) => _repo.approveErasure(e.workerId, key: key), 'Erasure approved');
  }

  @override
  Widget build(BuildContext context) {
    return PortalPage(
      kicker: 'Admin · Settings',
      title: 'Settings',
      subtitle: 'Client organisations, policies, reason codes, hour caps and erasure requests',
      onRefresh: _reload,
      commands: [
        PageCommand('New client organisation', Icons.domain_add_outlined, _newOrg),
        PageCommand('New reason code', Icons.playlist_add, () => _editReason(null)),
        PageCommand('Set an hour cap', Icons.timer_outlined, _setCap),
      ],
      children: [
        PageTabs<_Tab>(
          tabs: {for (final t in _Tab.values) t: t.label},
          selected: _tab,
          onSelected: (t) {
            setState(() => _tab = t);
            _reload();
          },
        ),
        LoadView<Object>(
          key: _loader,
          wrapInCard: true,
          load: _load,
          builder: (context, data, _) => switch (data) {
            final List<OrgRow> orgs when _tab == _Tab.orgs => _orgs(orgs),
            final List<PolicyDoc> policies when _tab == _Tab.policies => _policies(policies),
            final List<ReasonRow> reasons when _tab == _Tab.reasons => _reasons(reasons),
            final _Caps caps when _tab == _Tab.caps => _caps(caps.rows, caps.projects),
            final List<ErasureRow> erasures when _tab == _Tab.erasures => _erasures(erasures),
            _ => const Skeleton(lines: 4), // the tab changed while its data loads
          },
        ),
      ],
    );
  }

  Widget _toolbar(String text, Widget action) => Padding(
    padding: const EdgeInsets.only(bottom: Space.x12),
    child: Row(
      children: [
        Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
        const SizedBox(width: Space.x12),
        action,
      ],
    ),
  );

  Widget _orgs(List<OrgRow> orgs) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _toolbar(
        'A client sees the projects of the organisations they belong to: progress, prices, deliveries. Never pay.',
        FilledButton.icon(
          key: const Key('org-new'),
          onPressed: _newOrg,
          icon: const Icon(Icons.add, size: Sizes.iconSm),
          label: const Text('New organisation'),
        ),
      ),
      if (orgs.isEmpty) const PortalCard(child: EmptyView(message: 'No client organisation yet. Create one, then add its people.')),
      for (final o in orgs)
        PortalCard(
          key: Key('org-${o.id}'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(o.name, style: Theme.of(context).textTheme.titleMedium)),
                  TextButton.icon(
                    key: Key('org-add-${o.id}'),
                    onPressed: () => _addMember(o),
                    icon: const Icon(Icons.person_add_alt, size: Sizes.iconSm),
                    label: const Text('Add member'),
                  ),
                ],
              ),
              Text(
                '${o.members.length} ${o.members.length == 1 ? 'member' : 'members'}${o.createdAt == null ? '' : ' · since ${shortDate(o.createdAt!.toLocal())}'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (o.members.isNotEmpty) ...[
                const SizedBox(height: Space.x8),
                Wrap(
                  spacing: Space.x8,
                  runSpacing: Space.x8,
                  children: [
                    for (final m in o.members)
                      InputChip(
                        key: Key('member-${o.id}-$m'),
                        label: NameOf(m),
                        onDeleted: () => _removeMember(o, m),
                        deleteIcon: const Icon(Icons.close, size: Sizes.iconSm),
                        deleteButtonTooltipMessage: 'Remove',
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
    ],
  );

  Widget _policies(List<PolicyDoc> policies) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _toolbar(
        'Workers accept these during onboarding. Publishing a change makes a new version; workers accept it on their next step.',
        const SizedBox.shrink(),
      ),
      PortalTable(
        minWidth: 760,
        emptyMessage: 'No policy is published.',
        columns: const [
          PortalColumn('Policy', flex: 3),
          PortalColumn('Version', width: 110),
          PortalColumn('Updated', width: 110),
          PortalColumn('', width: 220),
        ],
        rows: [
          for (final p in policies)
            PortalRow(key: Key('policy-${p.slug}'), [
              Text(p.title, overflow: TextOverflow.ellipsis),
              Text('${p.version} (rev ${p.revision})', style: AppTheme.mono(context, fontSize: 12)),
              Text(p.updatedAt == null ? '—' : shortDate(p.updatedAt!.toLocal())),
              Wrap(
                spacing: Space.x4,
                children: [
                  TextButton(key: Key('policy-view-${p.slug}'), onPressed: () => _viewPolicy(p), child: const Text('View')),
                  TextButton(key: Key('policy-publish-${p.slug}'), onPressed: () => _publishPolicy(p), child: const Text('New version')),
                ],
              ),
            ]),
        ],
      ),
    ],
  );

  Widget _reasons(List<ReasonRow> reasons) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _toolbar(
        'What reviewers pick when they send work back. Retire a code instead of deleting it: old verdicts keep their meaning.',
        FilledButton.icon(
          key: const Key('reason-new'),
          onPressed: () => _editReason(null),
          icon: const Icon(Icons.add, size: Sizes.iconSm),
          label: const Text('New code'),
        ),
      ),
      PortalTable(
        minWidth: 860,
        emptyMessage: 'No reason code yet.',
        columns: const [
          PortalColumn('Code', flex: 2),
          PortalColumn('Label', flex: 3),
          PortalColumn('Used for', flex: 2),
          PortalColumn('Billing', width: 130),
          PortalColumn('State', width: 110),
          PortalColumn('', width: 80),
        ],
        rows: [
          for (final r in reasons)
            PortalRow(key: Key('reason-${r.code}'), [
              Text(r.code, style: AppTheme.mono(context, fontSize: 12)),
              Text(r.label, overflow: TextOverflow.ellipsis),
              Text(r.appliesTo.map(humanize).join(', ')),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: r.billable
                    ? const StatusChip('Billable', kind: StatusKind.warn)
                    : const StatusChip('Not billed', kind: StatusKind.info),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: r.active ? const StatusChip('Active', kind: StatusKind.success) : const StatusChip('Retired', kind: StatusKind.info),
              ),
              TextButton(key: Key('reason-edit-${r.code}'), onPressed: () => _editReason(r), child: const Text('Edit')),
            ]),
        ],
      ),
    ],
  );

  Widget _caps(List<CapRow> caps, Map<String, String> projects) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _toolbar(
        'Active hours a week before the tracker flags a worker. A worker cap beats a project cap; without either the default applies.',
        FilledButton.icon(
          key: const Key('cap-new'),
          onPressed: _setCap,
          icon: const Icon(Icons.add, size: Sizes.iconSm),
          label: const Text('Set a cap'),
        ),
      ),
      PortalTable(
        minWidth: 640,
        emptyMessage: 'No cap set: every worker has the default.',
        columns: const [
          PortalColumn('For', width: 100),
          PortalColumn('Who', flex: 3),
          PortalColumn('Hours a week', numeric: true, width: 130),
          PortalColumn('Updated', width: 110),
        ],
        rows: [
          for (final c in caps)
            PortalRow(key: Key('cap-${c.scope}-${c.scopeId}'), [
              Text(humanize(c.scope)),
              switch (c.scope) {
                'worker' => NameOf(c.scopeId),
                _ when projects[c.scopeId] != null => Tooltip(
                  message: c.scopeId,
                  excludeFromSemantics: true,
                  child: Text(projects[c.scopeId]!, overflow: TextOverflow.ellipsis),
                ),
                _ => ShortId(c.scopeId),
              },
              Text(c.weeklyCapHours),
              Text(c.updatedAt == null ? '—' : shortDate(c.updatedAt!.toLocal())),
            ]),
        ],
      ),
    ],
  );

  Widget _erasures(List<ErasureRow> rows) {
    final waiting = rows.where((e) => e.status == 'requested').length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(
          '${waiting == 0 ? 'Nothing waits for you.' : '$waiting waiting.'} A request is carried out on its due date (30 days) or as soon as you approve it.',
          const SizedBox.shrink(),
        ),
        PortalTable(
          minWidth: 760,
          emptyMessage: 'No worker has asked to be erased.',
          columns: const [
            PortalColumn('Worker', flex: 3),
            PortalColumn('State', width: 130),
            PortalColumn('Asked', width: 110),
            PortalColumn('Due', width: 110),
            PortalColumn('', width: 120),
          ],
          rows: [
            for (final e in rows)
              PortalRow(key: Key('erasure-${e.workerId}'), [
                NameOf(e.workerId),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: StatusChip(
                    humanize(e.status),
                    kind: e.status == 'done' ? StatusKind.success : (e.status == 'approved' ? StatusKind.info : StatusKind.warn),
                  ),
                ),
                Text(e.requestedAt == null ? '—' : shortDate(e.requestedAt!.toLocal())),
                Text(e.dueAt == null ? '—' : shortDate(e.dueAt!.toLocal())),
                e.status == 'requested'
                    ? TextButton(
                        key: Key('erasure-approve-${e.workerId}'),
                        onPressed: () => _approveErasure(e),
                        child: const Text('Approve'),
                      )
                    : const SizedBox.shrink(),
              ]),
          ],
        ),
      ],
    );
  }
}

class _PolicyBody extends StatelessWidget {
  const _PolicyBody(this.p);
  final PolicyDoc p;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Version ${p.version} · revision ${p.revision}', style: AppTheme.mono(context, fontSize: 12)),
        const SizedBox(height: Space.x8),
        Text(p.summary, style: theme.textTheme.bodyMedium),
        for (final s in p.sections) ...[
          const SizedBox(height: Space.x16),
          Text(s.title, style: theme.textTheme.titleSmall),
          for (final para in s.paragraphs)
            Padding(
              padding: const EdgeInsets.only(top: Space.x6),
              child: Text(para),
            ),
          for (final b in s.bullets)
            Padding(
              padding: const EdgeInsets.only(top: Space.x4),
              child: Text('•  $b'),
            ),
        ],
      ],
    );
  }
}

class _PolicySheet extends StatefulWidget {
  const _PolicySheet(this.p, {required this.repo});
  final PolicyDoc p;
  final SettingsRepository repo;

  @override
  State<_PolicySheet> createState() => _PolicySheetState();
}

class _PolicySheetState extends State<_PolicySheet> {
  late final _title = TextEditingController(text: widget.p.title);
  late final _summary = TextEditingController(text: widget.p.summary);
  final _label = TextEditingController();
  late final _body = TextEditingController(text: sectionsToText(widget.p.sections));
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_title, _summary, _label, _body]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final sections = sectionsFromText(_body.text);
    if (_title.text.trim().isEmpty || _summary.text.trim().isEmpty) {
      setState(() => _error = 'A title and a summary are needed');
      return;
    }
    if (sections.isEmpty) {
      setState(() => _error = 'Write at least one section: a line starting with "## " is its title');
      return;
    }
    final scope = AppScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final label = _label.text.trim();
      await withActionKey(
        scope.keys,
        'policy:${widget.p.slug}:${_body.text.hashCode}:$label',
        (key) => widget.repo.publishPolicy(
          widget.p.slug,
          title: _title.text.trim(),
          summary: _summary.text.trim(),
          sections: sections,
          label: label.isEmpty ? null : label,
          key: key,
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => FormSheet(
    title: 'New version: ${widget.p.title}',
    saveLabel: 'Publish',
    saveKey: const Key('policy-save'),
    busy: _busy,
    error: ErrorBanner(_error),
    maxWidth: 720,
    onSave: _save,
    children: [
      Text(
        'Now version ${widget.p.version}. Workers accept the new version on their next onboarding step; earlier acceptances stay on record.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      fieldGap,
      TextField(
        key: const Key('policy-title'),
        controller: _title,
        decoration: const InputDecoration(labelText: 'Title'),
      ),
      fieldGap,
      TextField(
        key: const Key('policy-summary'),
        controller: _summary,
        maxLines: 2,
        decoration: const InputDecoration(labelText: 'Summary'),
      ),
      fieldGap,
      TextField(
        key: const Key('policy-label'),
        controller: _label,
        decoration: const InputDecoration(
          labelText: 'Version label (optional)',
          helperText: 'What workers see, like 2026-12; the revision number when empty',
        ),
      ),
      fieldGap,
      TextField(
        key: const Key('policy-body'),
        controller: _body,
        minLines: 10,
        maxLines: 20,
        style: AppTheme.mono(context, fontSize: 13),
        decoration: const InputDecoration(
          labelText: 'Sections',
          helperText: '"## " starts a section, "- " a bullet, a blank line ends a paragraph',
        ),
      ),
    ],
  );
}

class _ReasonSheet extends StatefulWidget {
  const _ReasonSheet(this.r, {required this.repo});
  final ReasonRow? r;
  final SettingsRepository repo;

  @override
  State<_ReasonSheet> createState() => _ReasonSheetState();
}

class _ReasonSheetState extends State<_ReasonSheet> {
  late final _code = TextEditingController(text: widget.r?.code ?? '');
  late final _label = TextEditingController(text: widget.r?.label ?? '');
  late final _detail = TextEditingController(text: widget.r?.detail ?? '');
  late bool _billable = widget.r?.billable ?? false;
  late bool _active = widget.r?.active ?? true;
  late final Set<String> _applies = {
    ...?widget.r?.appliesTo,
    if (widget.r == null) ...['needs_edits', 'reject'],
  };
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_code, _label, _detail]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final code = _code.text.trim();
    if (!RegExp(r'^[a-z][a-z0-9_]{1,39}$').hasMatch(code)) {
      setState(() => _error = 'The code is lower case letters, digits and underscores, like client_glossary_change');
      return;
    }
    if (_label.text.trim().isEmpty || _applies.isEmpty) {
      setState(() => _error = 'A label and at least one verdict are needed');
      return;
    }
    final row = ReasonRow(
      code: code,
      label: _label.text.trim(),
      detail: _detail.text.trim(),
      billable: _billable,
      appliesTo: [
        for (final v in const ['needs_edits', 'reject'])
          if (_applies.contains(v)) v,
      ],
      sort: widget.r?.sort ?? 0,
      active: _active,
    );
    final scope = AppScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await withActionKey(scope.keys, 'reason:$code:${row.toJson()}', (key) => widget.repo.putReason(code, row, key: key));
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => FormSheet(
    title: widget.r == null ? 'New reason code' : 'Edit ${widget.r!.code}',
    saveKey: const Key('reason-save'),
    busy: _busy,
    error: ErrorBanner(_error),
    onSave: _save,
    children: [
      TextField(
        key: const Key('reason-code'),
        controller: _code,
        enabled: widget.r == null,
        decoration: const InputDecoration(labelText: 'Code'),
      ),
      fieldGap,
      TextField(
        key: const Key('reason-label'),
        controller: _label,
        decoration: const InputDecoration(labelText: 'Label reviewers see'),
      ),
      fieldGap,
      TextField(
        key: const Key('reason-detail'),
        controller: _detail,
        maxLines: 2,
        decoration: const InputDecoration(labelText: 'When to use it'),
      ),
      fieldGap,
      Wrap(
        spacing: Space.x8,
        children: [
          for (final v in const ['needs_edits', 'reject'])
            FilterChip(
              key: Key('reason-applies-$v'),
              label: Text(humanize(v)),
              selected: _applies.contains(v),
              onSelected: (on) => setState(() => on ? _applies.add(v) : _applies.remove(v)),
            ),
        ],
      ),
      SwitchRow(
        label: 'Billable to the client',
        hint: 'Rework the client caused, such as a changed brief',
        value: _billable,
        switchKey: const Key('reason-billable'),
        onChanged: (v) => setState(() => _billable = v),
      ),
      SwitchRow(
        label: 'Active',
        hint: 'Retired codes stay on old verdicts but are not offered',
        value: _active,
        switchKey: const Key('reason-active'),
        onChanged: (v) => setState(() => _active = v),
      ),
    ],
  );
}

class _CapSheet extends StatefulWidget {
  const _CapSheet({required this.repo});
  final SettingsRepository repo;

  @override
  State<_CapSheet> createState() => _CapSheetState();
}

class _CapSheetState extends State<_CapSheet> {
  String _scope = 'worker';
  final _id = TextEditingController();
  final _hours = TextEditingController(text: '40');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _id.dispose();
    _hours.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final id = _id.text.trim();
    final hours = double.tryParse(_hours.text.trim());
    if (!_uuid.hasMatch(id)) {
      setState(
        () => _error = 'The ${_scope == 'worker' ? "worker's account" : "project's"} id looks like 00000000-0000-4000-8000-000000000001',
      );
      return;
    }
    if (hours == null || hours < 0 || hours > 168) {
      setState(() => _error = 'Hours a week is a number from 0 to 168');
      return;
    }
    final scope = AppScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await withActionKey(scope.keys, 'cap:$_scope:$id:$hours', (key) => widget.repo.putCap(_scope, id, _hours.text.trim(), key: key));
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => FormSheet(
    title: 'Weekly hour cap',
    saveKey: const Key('cap-save'),
    busy: _busy,
    error: ErrorBanner(_error),
    onSave: _save,
    children: [
      DropdownButtonFormField<String>(
        key: const Key('cap-scope'),
        initialValue: _scope,
        decoration: const InputDecoration(labelText: 'For'),
        items: const [
          DropdownMenuItem(value: 'worker', child: Text('One worker')),
          DropdownMenuItem(value: 'project', child: Text('Everyone on a project')),
        ],
        onChanged: (v) => setState(() => _scope = v ?? 'worker'),
      ),
      fieldGap,
      TextField(
        key: const Key('cap-id'),
        controller: _id,
        decoration: InputDecoration(labelText: _scope == 'worker' ? "Worker's account id" : 'Project id'),
      ),
      fieldGap,
      TextField(
        key: const Key('cap-hours'),
        controller: _hours,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Hours a week'),
      ),
    ],
  );
}

/// The caps tab's data: the caps and the names of the projects they may name.
class _Caps {
  const _Caps(this.rows, this.projects);
  final List<CapRow> rows;
  final Map<String, String> projects;
}
