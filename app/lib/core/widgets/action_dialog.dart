import 'package:flutter/material.dart';

import '../../widgets/load_view.dart';
import '../action_keys.dart';
import '../errors.dart';
import '../theme/app_theme.dart';
import '../theme/portal_tokens.dart';

/// Runs one user action under its idempotency key: the same key for every retry of [action], dropped on
/// success, kept after a failure only when a retry may safely reuse it (see [ActionKeys.settle]).
Future<T> withActionKey<T>(ActionKeys keys, String action, Future<T> Function(String key) call) async {
  try {
    final result = await call(keys.start(action));
    keys.finish(action);
    return result;
  } on Object catch (e) {
    keys.settle(action, e);
    rethrow;
  }
}

/// A short dialog that takes one text (a note, an answer, a reference) and sends it. Returns what
/// [onSend] returned, or null when cancelled. An error stays in the dialog so the person can retry;
/// [messageFor] turns a gateway code into a sentence.
Future<T?> showActionDialog<T>(
  BuildContext context, {
  required String title,
  String? body,
  required String fieldLabel,
  required String confirmLabel,
  required Future<T> Function(String text) onSend,
  String? fieldHelper,
  String? Function(String text)? validate,
  String initial = '',
  int minLength = 1,
  int maxLines = 4,
  String Function(ApiException e)? messageFor,
  Key fieldKey = const Key('action-text'),
  Key sendKey = const Key('action-send'),
  bool destructive = false,
}) => showDialog<T>(
  context: context,
  builder: (_) => _ActionDialog<T>(
    title: title,
    body: body,
    fieldLabel: fieldLabel,
    confirmLabel: confirmLabel,
    onSend: onSend,
    fieldHelper: fieldHelper,
    validate: validate,
    initial: initial,
    minLength: minLength,
    maxLines: maxLines,
    messageFor: messageFor,
    fieldKey: fieldKey,
    sendKey: sendKey,
    destructive: destructive,
  ),
);

class _ActionDialog<T> extends StatefulWidget {
  const _ActionDialog({
    required this.title,
    required this.body,
    required this.fieldLabel,
    required this.confirmLabel,
    required this.onSend,
    required this.fieldHelper,
    required this.validate,
    required this.initial,
    required this.minLength,
    required this.maxLines,
    required this.messageFor,
    required this.fieldKey,
    required this.sendKey,
    required this.destructive,
  });

  final String title;
  final String? body;
  final String fieldLabel;
  final String confirmLabel;
  final Future<T> Function(String text) onSend;

  /// A line under the field: where the value comes from, what it looks like.
  final String? fieldHelper;

  /// Checks the trimmed text before sending; a message shows under the field and nothing is sent.
  final String? Function(String text)? validate;
  final String initial;
  final int minLength;
  final int maxLines;
  final String Function(ApiException e)? messageFor;
  final Key fieldKey;
  final Key sendKey;
  final bool destructive;

  @override
  State<_ActionDialog<T>> createState() => _ActionDialogState<T>();
}

class _ActionDialogState<T> extends State<_ActionDialog<T>> {
  late final _text = TextEditingController(text: widget.initial);
  String? _validation;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.length < widget.minLength) {
      setState(() => _validation = widget.minLength == 1 ? 'Required' : 'Give at least ${widget.minLength} characters');
      return;
    }
    final problem = widget.validate?.call(text);
    if (problem != null) {
      setState(() => _validation = problem);
      return;
    }
    setState(() {
      _validation = null;
      _error = null;
      _busy = true;
    });
    try {
      final result = await widget.onSend(text);
      if (mounted) Navigator.of(context).pop(result);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = widget.messageFor?.call(e) ?? describeError(e));
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ErrorBanner(_error),
            if (widget.body != null) ...[Text(widget.body!, style: theme.textTheme.bodySmall), const SizedBox(height: Space.x12)],
            TextField(
              key: widget.fieldKey,
              controller: _text,
              autofocus: true,
              minLines: widget.maxLines > 1 ? 2 : 1,
              maxLines: widget.maxLines,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: widget.fieldLabel,
                helperText: widget.fieldHelper,
                helperMaxLines: 3,
                errorText: _validation,
                errorMaxLines: 3,
              ),
              onChanged: (_) {
                if (_validation != null) setState(() => _validation = null);
              },
              onSubmitted: widget.maxLines == 1 ? (_) => _busy ? null : _send() : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('action-cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: widget.sendKey,
          style: widget.destructive ? AppTheme.destructive(t) : null,
          onPressed: _busy ? null : _send,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
