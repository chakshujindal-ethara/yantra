import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// A record's name, edited where it is read.
///
/// Click it (or arrive with [startEditing]) and it becomes a text box at the
/// same size and weight, so nothing moves. Enter or clicking away commits;
/// Escape puts back what was there.
///
/// ONE CONTROLLER FOR THE WIDGET'S LIFETIME, created in the field initialiser
/// and disposed in `dispose`. Creating one per edit and disposing it on commit
/// would have to dispose while the field it feeds is still on screen for a
/// frame - the same "used after being disposed" shape the deleted Rename sheet
/// had, where `showDialog`'s future completes on pop and the sheet goes on
/// rebuilding through its exit animation.
///
/// EXTRACTED FROM `generator_detail_screen.dart`, where it was private, so the
/// assessment title could be edited the same way. It is deliberately one widget
/// rather than two copies: five of its behaviours each fix a real bug (see the
/// notes on `_commit`, `_armEditor` and the `Focus` wrapper), and a copy would
/// drift away from them one screen at a time.
class EditableTitle extends StatefulWidget {
  const EditableTitle({
    required this.value,
    required this.onCommit,
    this.startEditing = false,
    this.enabled = true,
    this.tooltip = 'Rename',
    super.key,
  });

  /// The name as stored. The editor re-seeds from this every time it opens, so
  /// a rename that the server rejected does not linger in the box.
  final String value;

  /// Called with the trimmed new name, only when it is non-empty AND changed.
  final ValueChanged<String> onCommit;

  final bool startEditing;

  /// False renders the plain title with no affordance - for a read-only role,
  /// or a state where the record may not be renamed.
  final bool enabled;

  final String tooltip;

  @override
  State<EditableTitle> createState() => _EditableTitleState();
}

class _EditableTitleState extends State<EditableTitle> {
  late final TextEditingController _c = TextEditingController(
    text: widget.value,
  );
  final FocusNode _focus = FocusNode(debugLabel: 'editable-title');
  late bool _editing = widget.startEditing && widget.enabled;

  @override
  void initState() {
    super.initState();
    // Commit on blur. An inline field has no Save button, so clicking away IS
    // the commit - abandoning the edit silently would lose the typing without
    // saying so.
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing && mounted) _commit();
    });
    if (_editing) _armEditor();
  }

  @override
  void dispose() {
    _focus.dispose();
    _c.dispose();
    super.dispose();
  }

  /// Seed the box with the current name, SELECTED, and take focus next frame.
  ///
  /// Selected because the name this opens on is often the placeholder the
  /// create step supplied - typing should replace it rather than append to it.
  /// Focus is requested post-frame because the field does not exist until this
  /// rebuild lands.
  void _armEditor() {
    _c.text = widget.value;
    _c.selection = TextSelection(baseOffset: 0, extentOffset: _c.text.length);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _begin() {
    setState(() => _editing = true);
    _armEditor();
  }

  void _commit() {
    final String next = _c.text.trim();
    setState(() => _editing = false);
    // An empty name is a refusal, not a rename: the route answers 422 on a
    // blank one, and a record with no name cannot be picked out of a list.
    // Unchanged is not a write either - it would cost a round trip and a toast
    // to say nothing happened.
    if (next.isEmpty || next == widget.value) {
      _c.text = widget.value;
      return;
    }
    widget.onCommit(next);
  }

  void _cancel() {
    _c.text = widget.value;
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    if (!_editing) {
      final Widget label = Text(
        widget.value,
        style: context.type.pageTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
      if (!widget.enabled) return label;
      return InkWell(
        onTap: _begin,
        borderRadius: Radii.input,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(child: label),
              const SizedBox(width: 8),
              // The affordance. A title that silently happens to be editable is
              // one nobody finds.
              Tooltip(
                message: widget.tooltip,
                child: Icon(Icons.edit_outlined, size: 15, color: t.textMuted),
              ),
            ],
          ),
        ),
      );
    }

    // Escape is read on an ANCESTOR of the field. `EditableText` does not
    // handle it, so the event bubbles up to here.
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (FocusNode _, KeyEvent e) {
        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
          _cancel();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      // BOUNDED. A `TextField` in a Column fills its width, and this Column is
      // `PageHead`'s `Expanded(child: heading)` - so a 19-character name got a
      // ~990px box, five times the text it holds, and the header read as a
      // form rather than as a title. The resting label is content-width; this
      // caps the editor near the longest name anyone would type instead of
      // letting it swallow half the page.
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: TextField(
          controller: _c,
          focusNode: _focus,
          // Same size and weight as the label it replaces, so committing does
          // not make the page jump.
          style: context.type.pageTitle,
          maxLines: 1,
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 2,
            ),
            border: OutlineInputBorder(
              borderRadius: Radii.input,
              borderSide: BorderSide(color: t.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: Radii.input,
              borderSide: BorderSide(color: t.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: Radii.input,
              borderSide: BorderSide(color: t.primary.o(.55)),
            ),
          ),
          onSubmitted: (_) => _commit(),
        ),
      ),
    );
  }
}
