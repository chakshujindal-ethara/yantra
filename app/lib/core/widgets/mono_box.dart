import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../theme/portal_tokens.dart';
import 'loader.dart';

/// A block of mono text (a bank file, a manifest) in a muted well with a copy button. The text is
/// selectable; the button copies all of it.
class MonoBox extends StatelessWidget {
  const MonoBox(this.text, {super.key, this.maxHeight = 320});
  final String text;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          constraints: BoxConstraints(maxHeight: maxHeight),
          padding: const EdgeInsets.all(Space.x12),
          decoration: BoxDecoration(
            color: t.bgMuted,
            borderRadius: Radii.rMd,
            border: Border.all(color: t.borderSubtle),
          ),
          child: SingleChildScrollView(
            child: SelectableText(text, key: const Key('mono-text'), style: AppTheme.mono(context, fontSize: 12)),
          ),
        ),
        const SizedBox(height: Space.x8),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            key: const Key('mono-copy'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (context.mounted) toast(context, 'Copied');
            },
            icon: const Icon(Icons.copy_outlined, size: Sizes.iconSm),
            label: const Text('Copy'),
          ),
        ),
      ],
    );
  }
}

/// A dialog around a [MonoBox]: the way a file is "downloaded" on the web build (copied, not saved).
Future<void> showMonoDialog(BuildContext context, {required String title, required String text}) => showDialog<void>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: Text(title),
    content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: MonoBox(text)),
    actions: [TextButton(key: const Key('mono-close'), onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close'))],
  ),
);
