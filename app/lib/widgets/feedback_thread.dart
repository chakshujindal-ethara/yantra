import 'package:flutter/material.dart';

import '../api/feedback.dart';
import '../core/errors.dart';
import '../core/format.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/portal_tokens.dart';
import '../core/widgets/cards.dart';
import '../core/widgets/people.dart';
import 'load_view.dart';

/// A project's feedback thread between the client and the Yantra team: notes oldest first, each with its
/// author's name (a "Yantra" badge on staff answers), then a composer. Used by the client's project page
/// and the ops project page; the caller decides who is writing by what [onSend] posts.
///
/// [onSend] gets the trimmed text and throws on failure (the error shows above the box, the text stays);
/// on success the box clears and the caller reloads [items].
class FeedbackThread extends StatefulWidget {
  const FeedbackThread({
    super.key,
    required this.items,
    required this.onSend,
    this.title = 'Feedback',
    this.subtitle,
    this.emptyMessage = 'Nothing yet.',
    this.composerLabel = 'Write a note',
    this.sendLabel = 'Send',
    this.minLength = 5,
  });

  final List<FeedbackEntry> items;
  final Future<void> Function(String body) onSend;
  final String title;
  final String? subtitle;
  final String emptyMessage;
  final String composerLabel;
  final String sendLabel;
  final int minLength;

  @override
  State<FeedbackThread> createState() => _FeedbackThreadState();
}

class _FeedbackThreadState extends State<FeedbackThread> {
  final _body = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _body.text.trim();
    if (text.length < widget.minLength) {
      setState(() => _error = 'Say a little more, at least ${widget.minLength} characters');
      return;
    }
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      await widget.onSend(text);
      if (!mounted) return;
      _body.clear();
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const Key('feedback-thread'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(widget.title, subtitle: widget.subtitle),
        if (widget.items.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.x12),
            child: Text(widget.emptyMessage, key: const Key('feedback-empty'), style: theme.textTheme.bodySmall),
          )
        else
          for (final f in widget.items) _Note(f),
        PortalCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ErrorBanner(_error),
              TextField(
                key: const Key('feedback-body'),
                controller: _body,
                enabled: !_busy,
                minLines: 2,
                maxLines: 5,
                decoration: InputDecoration(labelText: widget.composerLabel),
              ),
              const SizedBox(height: Space.x8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(key: const Key('feedback-send'), onPressed: _busy ? null : _send, child: Text(widget.sendLabel)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.f);
  final FeedbackEntry f;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PortalTokens.of(context);
    return PortalCard(
      key: Key('feedback-${f.id}'),
      color: f.fromStaff ? t.bgMuted : null,
      padding: const EdgeInsets.symmetric(horizontal: Space.x16, vertical: Space.x12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Avatar(f.authorName.isNotEmpty ? f.authorName : (f.authorId.isEmpty ? '?' : f.authorId), size: 24),
              const SizedBox(width: Space.x8),
              Flexible(
                child: f.authorId.isEmpty
                    ? Text('Someone', style: theme.textTheme.labelLarge)
                    : NameOf(f.authorId, name: f.authorName, style: theme.textTheme.labelLarge),
              ),
              if (f.fromStaff) ...[
                const SizedBox(width: Space.x8),
                const StatusChip('Yantra', kind: StatusKind.info, key: Key('feedback-staff-badge')),
              ],
              const SizedBox(width: Space.x8),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: f.createdAt == null ? const SizedBox.shrink() : Text(relative(f.createdAt!), style: theme.textTheme.labelSmall),
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.x6),
          Text(f.body, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
