import 'dart:async';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart' hide StepState;
import 'package:flutter/services.dart';

import '../api/talent_models.dart';
import '../app_scope.dart';
import '../core/action_keys.dart';
import '../core/errors.dart';
import '../core/format.dart';
import '../core/json.dart';
import '../core/upload.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/portal_tokens.dart';
import '../core/widgets/cards.dart';
import '../core/widgets/loader.dart';
import '../core/widgets/portal_page.dart';
import '../core/widgets/steps.dart';
import '../widgets/load_view.dart';
import 'policies_screen.dart';
import 'shell.dart';
import '../core/widgets/detail_frame.dart';

/// The agreement version shipped with the app; the server's label wins whenever it is reachable.
const agreementVersion = '2026-11';

final panPattern = RegExp(r'^[A-Z]{5}[0-9]{4}[A-Z]$');
final ifscPattern = RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$');
final phonePattern = RegExp(r'^[6-9][0-9]{9}$');
final accountPattern = RegExp(r'^[0-9]{9,18}$');
final last4Pattern = RegExp(r'^[0-9]{4}$');

/// The grouped onboarding checklist as a full-screen route. Each pending step opens into its form; steps
/// save one at a time and may be finished later.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, this.from = Destination.home});

  /// The page that opened it: the breadcrumb leads back there.
  final Destination from;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  Onboarding? _data;
  bool _loading = true;
  String? _loadError;

  /// The step whose form is open.
  String? _open;

  /// The legal name typed in this session, to prefill the bank account name.
  String _legalName = '';

  /// The payout account as payout keeps it (null: none registered yet, or it could not be read).
  BankAccount? _bank;

  /// The agreement and consent texts as the server holds them (shipped copies when it cannot be reached).
  List<Policy> _policies = shippedPolicies;

  /// While the bank check runs, the page asks again every few seconds for up to two minutes.
  Timer? _poll;
  int _polls = 0;
  static const _pollEvery = Duration(seconds: 5);
  static const _maxPolls = 24;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final scope = AppScope.of(context);
    setState(() {
      _loading = true;
      _loadError = null;
    });
    final policies = loadPolicies(context);
    try {
      final data = await scope.talent.onboarding();
      if (mounted) setState(() => _data = data);
    } on ApiException catch (e) {
      // nothing on file yet reads as an empty checklist
      if (mounted) setState(() => e.status == 404 ? _data = Onboarding.notStarted : _loadError = describeError(e));
    } on Object catch (e) {
      if (mounted) setState(() => _loadError = describeError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    final served = await policies;
    if (mounted) setState(() => _policies = served);
    await _loadBank();
  }

  /// The bank account lives in payout; a failure to read it leaves the step as it is.
  Future<void> _loadBank() async {
    if (!mounted) return;
    try {
      final bank = await AppScope.of(context).payout.bankAccount();
      if (!mounted) return;
      setState(() => _bank = bank);
      _schedulePoll();
    } on Object {
      // the checklist still works; the bank row says what it knew
    }
  }

  /// While payout is still checking the account (or talent has not yet marked the step), ask again shortly.
  void _schedulePoll() {
    _poll?.cancel();
    final bank = _bank;
    final waiting = bank != null && (bank.isVerifying || (bank.isVerified && !(_data?.isDone('bank') ?? true)));
    if (!waiting || _polls >= _maxPolls) return;
    _poll = Timer(_pollEvery, () async {
      _polls++;
      try {
        final scope = AppScope.of(context);
        final bank = await scope.payout.bankAccount();
        final data = bank != null && bank.isVerified ? await scope.talent.onboarding() : _data;
        if (!mounted) return;
        setState(() {
          _bank = bank;
          _data = data;
        });
        if (data?.isDone('bank') ?? false) _changed();
      } on Object {
        // try again on the next tick
      }
      if (mounted) _schedulePoll();
    });
  }

  void _changed() => AppScope.of(context).stale.mark([Destination.home, Destination.applications]);

  void _saved(Onboarding next, {String? legalName}) {
    // Home's readiness and the Applications nudge read this checklist
    _changed();
    setState(() {
      _data = next;
      _open = null;
      if (legalName != null) _legalName = legalName;
    });
    toast(context, next.complete ? 'Onboarding complete' : 'Saved');
  }

  void _bankSaved(BankAccount bank) {
    _changed();
    setState(() {
      _bank = bank;
      _open = null;
      _polls = 0;
    });
    toast(context, bank.isFailed ? 'The bank could not confirm this account' : 'Checking your account with the bank');
    _schedulePoll();
  }

  /// A text changed while the worker was reading it: show the new one.
  Future<void> _policyChanged() async {
    final served = await loadPolicies(context);
    if (mounted) setState(() => _policies = served);
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final theme = Theme.of(context);
    return DetailFrame(
      crumbs: [
        const Crumb('Work'),
        Crumb(widget.from.label, path: widget.from.path),
        const Crumb('Onboarding'),
      ],
      body: data == null
          ? (_loading ? const Center(child: BrandLoader()) : ErrorView(message: _loadError ?? 'No data', onRetry: _load))
          : PortalPage(
              kicker: 'Work · Onboarding',
              title: 'Ready to work',
              subtitle: data.complete
                  ? 'All ${data.total} steps are done'
                  : '${data.left} ${data.left == 1 ? 'step' : 'steps'} left; you can finish later',
              onRefresh: _load,
              maxWidth: Layout.pageMaxNarrow,
              children: [
                if (data.complete)
                  const StatusBanner(
                    'You are eligible; pools you are certified for are open to you.',
                    key: Key('onboarding-complete'),
                    kind: StatusKind.success,
                    icon: Icons.verified_outlined,
                  ),
                _Header(data: data),
                for (final group in onboardingGroups)
                  PortalCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(group, style: theme.textTheme.titleMedium),
                        const SizedBox(height: Space.x4),
                        for (final step in data.steps.where((s) => s.group == group))
                          _StepRow(
                            step: step,
                            number: data.steps.indexOf(step) + 1,
                            open: _open == step.key,
                            blockedBy: step.key == 'bank' && !data.isDone('profile') ? 'Fill in your profile first' : null,
                            bank: step.key == 'bank' ? _bank : null,
                            onToggle: () => setState(() => _open = _open == step.key ? null : step.key),
                            form: _StepForm(
                              key: ValueKey('form-${step.key}'),
                              stepKey: step.key,
                              legalName: _legalName,
                              policy: _policyFor(step.key),
                              onSaved: _saved,
                              onBankSaved: _bankSaved,
                              onPolicyChanged: _policyChanged,
                            ),
                          ),
                      ],
                    ),
                  ),
                _DocumentsCard(documents: data.documents, onUploaded: _load),
              ],
            ),
    );
  }
}

extension on _OnboardingScreenState {
  Policy? _policyFor(String step) => switch (step) {
    'agreement' => Policy.bySlug('contractor-agreement', _policies),
    'consent' => Policy.bySlug('dpdp-consent', _policies),
    _ => null,
  };
}

/// "n of 6", the bar, and what still blocks the first claim.
class _Header extends StatelessWidget {
  const _Header({required this.data});
  final Onboarding data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final blocking = [
      for (final g in onboardingGroups)
        if (data.pending.any((s) => s.group == g)) g,
    ];
    return PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Your checklist', style: theme.textTheme.titleMedium)),
              Text(
                '${data.done} of ${data.total}',
                key: const Key('onboarding-progress'),
                style: AppTheme.mono(context, fontSize: 12, color: t.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: Space.x8),
          ProgressBar(value: data.done.toDouble(), total: data.total.toDouble()),
          const SizedBox(height: Space.x8),
          Text(
            data.complete ? 'Nothing blocks your first claim.' : 'Still blocking your first claim: ${blocking.join(', ')}.',
            key: const Key('onboarding-blocking'),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.step,
    required this.number,
    required this.open,
    required this.blockedBy,
    required this.onToggle,
    required this.form,
    this.bank,
  });
  final OnboardingStep step;
  final int number;
  final bool open;
  final String? blockedBy;
  final VoidCallback onToggle;
  final Widget form;

  /// The payout account, on the bank row only: its check decides the hint and the button.
  final BankAccount? bank;

  /// What the bank row says while payout checks the account.
  String? get _bankHint => switch (bank) {
    final b? when b.isVerifying => 'Checking the account ending ${b.accountLast4} with your bank. This usually takes under a minute.',
    final b? when b.isFailed => b.failureText,
    final b? when b.isVerified =>
      'Account ending ${b.accountLast4} is verified. This step completes once the name on it matches your legal name.',
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final done = step.isDone;
    final hint = done ? (step.doneAt == null ? 'Done' : 'Done ${relative(step.doneAt!)}') : (blockedBy ?? _bankHint ?? _hintFor(step.key));
    final checking = !done && (bank?.isVerifying ?? false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.x8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StepDisc(number: number, state: done ? StepState.done : (open ? StepState.active : StepState.pending)),
              const SizedBox(width: Space.x12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(step.title, style: theme.textTheme.bodyLarge?.copyWith(color: done ? t.textSecondary : t.textPrimary)),
                    Text(hint, style: theme.textTheme.bodySmall?.copyWith(color: t.textMuted)),
                  ],
                ),
              ),
              const SizedBox(width: Space.x12),
              if (done)
                const StatusChip('Done', kind: StatusKind.success)
              else if (checking && !open)
                const StatusChip('Checking', key: Key('bank-checking'), kind: StatusKind.info)
              else
                TextButton(
                  key: Key('step-${step.key}'),
                  onPressed: blockedBy == null ? onToggle : null,
                  child: Text(
                    open
                        ? 'Close'
                        : (bank?.isFailed ?? false)
                        ? 'Try again'
                        : (bank != null ? 'Change' : 'Fill in'),
                  ),
                ),
            ],
          ),
        ),
        if (open && !done)
          Padding(
            padding: const EdgeInsets.only(left: 40, bottom: Space.x12),
            child: form,
          ),
      ],
    );
  }

  static String _hintFor(String key) => switch (key) {
    'profile' => 'As on your PAN card',
    'agreement' => 'Read and accept the contractor agreement',
    'consent' => 'How your data is used',
    'identity' => 'PAN and the last four digits of your Aadhaar',
    'bank' => 'Where payouts go; the account name must match your legal name',
    'payout_ack' => 'When and how you are paid',
    _ => '',
  };
}

/// The form of one step. Saves with one idempotency key per step; a refusal is shown inline.
class _StepForm extends StatefulWidget {
  const _StepForm({
    super.key,
    required this.stepKey,
    required this.legalName,
    required this.onSaved,
    required this.onBankSaved,
    required this.onPolicyChanged,
    this.policy,
  });
  final String stepKey;
  final String legalName;
  final void Function(Onboarding next, {String? legalName}) onSaved;

  /// The bank step saves to payout, which answers with the account and its check, not the checklist.
  final void Function(BankAccount bank) onBankSaved;

  /// A 422 `policy_outdated`: the text changed while it was being read.
  final Future<void> Function() onPolicyChanged;

  /// The text the agreement and consent steps show and accept (its version is sent back).
  final Policy? policy;

  String get policyVersion => (policy?.version ?? '').isNotEmpty ? policy!.version : agreementVersion;

  @override
  State<_StepForm> createState() => _StepFormState();
}

class _StepFormState extends State<_StepForm> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _c = {
    'legal_name': TextEditingController(),
    'phone': TextEditingController(),
    'city': TextEditingController(),
    'pan': TextEditingController(),
    'aadhaar_last4': TextEditingController(),
    'account_name': TextEditingController(text: widget.legalName),
    'account_number': TextEditingController(),
    'ifsc': TextEditingController(),
  };
  bool _accepted = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Json? _body() {
    final ok = _form.currentState?.validate() ?? true;
    if (!ok) return null;
    switch (widget.stepKey) {
      case 'profile':
        return {'legal_name': _c['legal_name']!.text.trim(), 'phone': _c['phone']!.text.trim(), 'city': _c['city']!.text.trim()};
      case 'agreement':
        return _accepted ? {'accepted': true, 'version': widget.policyVersion} : null;
      case 'consent':
        final served = widget.policy?.version ?? '';
        return _accepted ? {'accepted': true, if (served.isNotEmpty) 'version': served} : null;
      case 'payout_ack':
        return _accepted ? {'accepted': true} : null;
      case 'identity':
        return {'pan': _c['pan']!.text.trim().toUpperCase(), 'aadhaar_last4': _c['aadhaar_last4']!.text.trim()};
      case 'bank':
        return {
          'account_name': _c['account_name']!.text.trim(),
          'account_number': _c['account_number']!.text.trim(),
          'ifsc': _c['ifsc']!.text.trim().toUpperCase(),
        };
      default:
        return null;
    }
  }

  Future<void> _save() async {
    final body = _body();
    if (body == null) {
      setState(() => _error = _needsCheckbox ? 'Tick the box to accept.' : 'Fix the highlighted fields first.');
      return;
    }
    final scope = AppScope.of(context);
    final action = 'onboarding:${widget.stepKey}:${bodyTag(body)}';
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.stepKey == 'bank') {
        final bank = await scope.payout.registerBank(
          name: body['account_name'] as String,
          number: body['account_number'] as String,
          ifsc: body['ifsc'] as String,
          key: scope.keys.start(action),
        );
        scope.keys.finish(action);
        if (mounted) widget.onBankSaved(bank);
        return;
      }
      final next = await scope.talent.putOnboardingStep(widget.stepKey, body, key: scope.keys.start(action));
      scope.keys.finish(action);
      if (mounted) widget.onSaved(next, legalName: widget.stepKey == 'profile' ? body['legal_name'] as String : null);
    } on ApiException catch (e) {
      scope.keys.settle(action, e);
      if (e.code == 'policy_outdated') {
        await widget.onPolicyChanged();
        if (mounted) setState(() => _accepted = false);
      }
      if (mounted) setState(() => _error = _message(e));
    } on Object catch (e) {
      scope.keys.settle(action, e);
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _needsCheckbox => const {'agreement', 'consent', 'payout_ack'}.contains(widget.stepKey) && !_accepted;

  static String _message(ApiException e) => switch (e.code) {
    'pan_in_use' => 'This PAN is already on another account. One PAN per person; contact ops if it is yours.',
    'name_mismatch' => 'The account name must match your legal name exactly as you entered it in Profile.',
    'account_in_use' => 'This bank account is already registered to another worker. One account per person.',
    'validation_limit' => 'The bank has been asked to check accounts three times today. Try again tomorrow.',
    'policy_outdated' => 'This text was updated while you were reading it. Read the new version and accept again.',
    _ => describeError(e),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ErrorBanner(_error),
          ..._fields(theme),
          const SizedBox(height: Space.x12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(key: Key('save-${widget.stepKey}'), onPressed: _busy ? null : _save, child: const Text('Save')),
          ),
        ],
      ),
    );
  }

  List<Widget> _fields(ThemeData theme) {
    switch (widget.stepKey) {
      case 'profile':
        return [
          _text(
            'legal_name',
            'Legal name',
            helper: 'Exactly as on your PAN card',
            validator: (v) => v.length < 2 ? 'Enter your legal name' : null,
          ),
          _text(
            'phone',
            'Mobile number',
            helper: '10 digits, starting 6 to 9',
            keyboard: TextInputType.phone,
            validator: (v) => phonePattern.hasMatch(v) ? null : 'Enter a 10-digit Indian mobile number',
          ),
          _text('city', 'City', validator: (v) => v.isEmpty ? 'Enter your city' : null),
        ];
      case 'agreement':
        return [
          _ScrollBox(
            key: const Key('agreement-text'),
            text: '${widget.policy?.title ?? 'Contractor agreement'}, version ${widget.policyVersion}.\n\n${_plain(widget.policy)}',
          ),
          _check('agreement', 'I have read and accept the contractor agreement (version ${widget.policyVersion})'),
        ];
      case 'consent':
        return [
          _ScrollBox(key: const Key('consent-text'), text: _plain(widget.policy)),
          _check('consent', 'I consent to this use of my personal data'),
        ];
      case 'identity':
        return [
          _text(
            'pan',
            'PAN',
            helper: 'ABCDE1234F',
            formatters: [const _UpperCaseFormatter(), LengthLimitingTextInputFormatter(10)],
            validator: (v) => panPattern.hasMatch(v.toUpperCase()) ? null : 'PAN looks like ABCDE1234F',
          ),
          _text(
            'aadhaar_last4',
            'Aadhaar, last 4 digits',
            keyboard: TextInputType.number,
            formatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
            validator: (v) => last4Pattern.hasMatch(v) ? null : 'Enter the last 4 digits',
          ),
        ];
      case 'bank':
        return [
          Text(
            'We send ₹1 to check the account is open and in your name; it is yours to keep. Only the last four digits '
            'are shown after this.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Space.x8),
          _text(
            'account_name',
            'Account holder name',
            helper: 'Must match your legal name exactly',
            validator: (v) => v.isEmpty ? 'Enter the name on the account' : null,
          ),
          _text(
            'account_number',
            'Account number',
            keyboard: TextInputType.number,
            formatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(18)],
            validator: (v) => accountPattern.hasMatch(v) ? null : '9 to 18 digits',
          ),
          _text(
            'ifsc',
            'IFSC',
            helper: 'HDFC0001234',
            formatters: [const _UpperCaseFormatter(), LengthLimitingTextInputFormatter(11)],
            validator: (v) => ifscPattern.hasMatch(v.toUpperCase()) ? null : 'IFSC looks like HDFC0001234',
          ),
        ];
      case 'payout_ack':
        return [
          Text(
            'Pay week: Saturday 00:00 to Friday 23:59 IST. Only an accepted unit creates an earning. The week closes on '
            'Friday night, ops approves it as two people, and the bank transfer lands in the following days. Your first '
            'payout may be held while your account is verified.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Space.x8),
          _check('payout_ack', 'I understand when and how I am paid'),
        ];
      default:
        return [Text('This step has no form.', style: theme.textTheme.bodySmall)];
    }
  }

  /// A policy's sections as plain reading text for the scrolling box.
  static String _plain(Policy? policy) {
    if (policy == null) return '';
    return [
      for (final s in policy.sections) ...[...s.paragraphs, for (final b in s.bullets) '• $b'],
    ].join('\n\n');
  }

  Widget _text(
    String name,
    String label, {
    String? helper,
    TextInputType? keyboard,
    List<TextInputFormatter>? formatters,
    required String? Function(String) validator,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: Space.x12),
    child: TextFormField(
      key: Key('f-$name'),
      controller: _c[name],
      enabled: !_busy,
      keyboardType: keyboard,
      inputFormatters: formatters,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      decoration: InputDecoration(labelText: label, helperText: helper),
      validator: (v) => validator((v ?? '').trim()),
    ),
  );

  Widget _check(String name, String label) => CheckboxListTile(
    key: Key('f-$name'),
    value: _accepted,
    contentPadding: EdgeInsets.zero,
    controlAffinity: ListTileControlAffinity.leading,
    title: Text(label, style: Theme.of(context).textTheme.bodyMedium),
    onChanged: _busy ? null : (v) => setState(() => _accepted = v ?? false),
  );
}

/// Identity documents (optional in Stage 1; ops check them against the PAN): what is on file, and an upload
/// per kind. The file goes straight to object storage through a presigned link, then is registered with its
/// SHA-256 so the server can check what arrived.
class _DocumentsCard extends StatefulWidget {
  const _DocumentsCard({required this.documents, required this.onUploaded});
  final List<DocumentBrief> documents;
  final Future<void> Function() onUploaded;

  @override
  State<_DocumentsCard> createState() => _DocumentsCardState();
}

class _DocumentsCardState extends State<_DocumentsCard> {
  String? _busy;
  String? _error;

  Future<void> _upload(String kind) async {
    final scope = AppScope.of(context);
    setState(() => _error = null);
    final file = await scope.files.pick(accept: 'image/jpeg,image/png,application/pdf');
    if (file == null || !mounted) return;
    final mime = _mimeOf(file.name, file.mime);
    if (mime == null) {
      setState(() => _error = '${file.name} is not a JPEG, PNG or PDF.');
      return;
    }
    if (file.bytes.isEmpty || file.bytes.length > documentMaxBytes) {
      setState(() => _error = '${file.name} is ${fileSize(file.bytes.length)}; documents must be under 10 MB.');
      return;
    }
    final digest = crypto.sha256.convert(file.bytes).toString();
    final presignAction = 'document:presign:$kind:${bodyTag([mime, file.bytes.length, digest])}';
    final registerAction = 'document:register:$kind:$digest';
    setState(() => _busy = kind);
    try {
      final target = await scope.talent.presignDocument(
        kind,
        contentType: mime,
        size: file.bytes.length,
        key: scope.keys.start(presignAction),
      );
      scope.keys.finish(presignAction);
      final upload = PresignedUpload.fromJson(target);
      await scope.uploader.put(upload, file.bytes);
      await scope.talent.registerDocument(
        kind,
        objectKey: upload.key,
        sha256: digest,
        size: file.bytes.length,
        key: scope.keys.start(registerAction),
      );
      scope.keys.finish(registerAction);
      if (!mounted) return;
      toast(context, '${documentKindLabel(kind)} uploaded');
      await widget.onUploaded();
    } on Object catch (e) {
      scope.keys.settle(presignAction, e);
      scope.keys.settle(registerAction, e);
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  static String? _mimeOf(String name, String reported) {
    if (documentTypes.values.contains(reported)) return reported;
    final dot = name.lastIndexOf('.');
    return dot < 0 ? null : documentTypes[name.substring(dot + 1).toLowerCase()];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    final onFile = {for (final d in widget.documents) d.kind: d};
    return PortalCard(
      key: const Key('documents-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Identity documents', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.x4),
          Text(
            'Optional for now. Ops may ask for them to confirm your PAN. JPEG, PNG or PDF, up to 10 MB each.',
            style: theme.textTheme.bodySmall?.copyWith(color: t.textSecondary),
          ),
          const SizedBox(height: Space.x8),
          ErrorBanner(_error),
          for (final kind in documentKinds)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.x4),
              child: Row(
                children: [
                  Icon(
                    onFile.containsKey(kind) ? Icons.check_circle_outline : Icons.description_outlined,
                    size: Sizes.iconMd,
                    color: onFile.containsKey(kind) ? t.successText : t.textMuted,
                  ),
                  const SizedBox(width: Space.x12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(documentKindLabel(kind), style: theme.textTheme.bodyMedium),
                        Text(
                          switch (onFile[kind]) {
                            final d? when d.uploadedAt != null => 'Uploaded ${relative(d.uploadedAt!)}',
                            final _? => 'Uploaded',
                            _ => 'Not uploaded',
                          },
                          key: Key('document-state-$kind'),
                          style: theme.textTheme.bodySmall?.copyWith(color: t.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    key: Key('upload-$kind'),
                    onPressed: _busy == null ? () => _upload(kind) : null,
                    child: Text(
                      _busy == kind ? 'Uploading…' : (onFile.containsKey(kind) ? 'Replace' : 'Upload'),
                      semanticsLabel:
                          '${_busy == kind ? 'Uploading' : (onFile.containsKey(kind) ? 'Replace' : 'Upload')} ${documentKindLabel(kind)}',
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A short document in a bordered, scrolling box with the scrollbar always shown.
class _ScrollBox extends StatefulWidget {
  const _ScrollBox({super.key, required this.text});
  final String text;

  @override
  State<_ScrollBox> createState() => _ScrollBoxState();
}

class _ScrollBoxState extends State<_ScrollBox> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return Container(
      height: 160,
      margin: const EdgeInsets.only(bottom: Space.x8),
      padding: const EdgeInsets.all(Space.x12),
      decoration: BoxDecoration(
        color: t.bgMuted,
        borderRadius: Radii.rMd,
        border: Border.all(color: t.border),
      ),
      child: Scrollbar(
        controller: _controller,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _controller,
          child: Text(widget.text, style: Theme.of(context).textTheme.bodySmall),
        ),
      ),
    );
  }
}

class _UpperCaseFormatter extends TextInputFormatter {
  const _UpperCaseFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}
