import 'package:flutter/material.dart';

import '../theme/portal_tokens.dart';
import 'portal_page.dart';

/// Vertical space between two form fields.
const fieldGap = SizedBox(height: Space.x12);

/// A dialog that holds a form: a title, a scrollable body (an error line first), Cancel and a primary
/// Save that shows a spinner while busy. Fits a phone (the body scrolls) and caps at 560 on a desktop.
class FormSheet extends StatelessWidget {
  const FormSheet({
    super.key,
    required this.title,
    required this.children,
    required this.onSave,
    this.saveLabel = 'Save',
    this.saveKey,
    this.busy = false,
    this.error,
    this.maxWidth = 560,
    this.onCancel,
  });

  final String title;
  final List<Widget> children;
  final VoidCallback onSave;
  final String saveLabel;
  final Key? saveKey;
  final bool busy;
  final Widget? error;
  final double maxWidth;

  /// What Cancel does; by default it pops with nothing.
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      insetPadding: const EdgeInsets.symmetric(horizontal: Space.x16, vertical: Space.x24),
      content: SizedBox(
        width: maxWidth,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [?error, ...children]),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('form-cancel'),
          onPressed: busy ? null : (onCancel ?? () => Navigator.of(context).pop()),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: saveKey,
          onPressed: busy ? null : onSave,
          child: busy
              ? SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text(saveLabel),
        ),
      ],
    );
  }
}

/// Two fields side by side where they fit (480 and up), stacked below.
class FieldPair extends StatelessWidget {
  const FieldPair(this.left, this.right, {super.key});
  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => c.maxWidth < 480
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [left, fieldGap, right])
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: left),
                const SizedBox(width: Layout.gap),
                Expanded(child: right),
              ],
            ),
    );
  }
}

/// A labelled switch row inside a form.
class SwitchRow extends StatelessWidget {
  const SwitchRow({super.key, required this.label, required this.value, required this.onChanged, this.hint, this.switchKey});
  final String label;
  final String? hint;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Key? switchKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodyMedium),
                if (hint != null) Text(hint!, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          Switch(key: switchKey, value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
