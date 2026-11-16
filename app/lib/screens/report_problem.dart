import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/support_models.dart';
import '../app_scope.dart';
import '../core/errors.dart';
import '../core/format.dart';
import '../core/widgets/action_dialog.dart';
import '../core/widgets/loader.dart';
import '../widgets/load_view.dart';
import '../core/theme/portal_tokens.dart';

/// Where the person is, in words ops can act on: the page title and the path (`Earnings · /work/earnings`).
String currentScreen(BuildContext context, {String? title}) {
  String path;
  try {
    path = GoRouter.of(context).routeInformationProvider.value.uri.path;
  } on Object {
    path = '';
  }
  final parts = [if ((title ?? '').isNotEmpty) title!, if (path.isNotEmpty) path];
  final screen = parts.isEmpty ? 'App' : parts.join(' · ');
  return screen.length > 200 ? screen.substring(0, 200) : screen;
}

/// Opens "Report a problem" with the screen filled in. Returns the ticket when one was sent; a toast says so.
Future<Ticket?> showReportProblem(BuildContext context, {String? title}) async {
  final screen = currentScreen(context, title: title);
  final sent = await showDialog<Ticket>(
    context: context,
    builder: (_) => ReportProblemDialog(screen: screen),
  );
  if (sent != null && context.mounted) toast(context, 'Ticket sent. Ops read it and answer in your inbox.');
  return sent;
}

/// The ticket form: a category, a title and what happened. [screen] is filled in for the person.
class ReportProblemDialog extends StatefulWidget {
  const ReportProblemDialog({super.key, required this.screen});
  final String screen;

  @override
  State<ReportProblemDialog> createState() => ReportProblemDialogState();
}

class ReportProblemDialogState extends State<ReportProblemDialog> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  String _category = 'bug';
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final title = _title.text.trim();
    final body = _body.text.trim();
    if (title.length < 3) {
      setState(() => _error = 'Give the problem a short title');
      return;
    }
    if (body.length < 10) {
      setState(() => _error = 'Say what happened, in at least 10 characters');
      return;
    }
    final scope = AppScope.of(context);
    final input = TicketInput(
      category: _category,
      title: title,
      body: body,
      screen: widget.screen,
      context: {
        'app': 'web',
        'theme': Theme.of(context).brightness == Brightness.dark ? 'dark' : 'light',
        'width': MediaQuery.sizeOf(context).width.round(),
      },
    );
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final t = await withActionKey(scope.keys, 'ticket:new:${title.hashCode}', (key) => scope.support.create(input, key: key));
      if (mounted) Navigator.of(context).pop(t);
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Report a problem'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ErrorBanner(_error),
              Text(
                'Sent from ${widget.screen}. Ops answer in your inbox; your ticket stays listed here.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: Space.x12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<String>(
                  key: const Key('ticket-category'),
                  showSelectedIcon: false,
                  segments: [for (final c in ticketCategories) ButtonSegment(value: c, label: Text(humanize(c)))],
                  selected: {_category},
                  onSelectionChanged: _busy ? null : (s) => setState(() => _category = s.first),
                ),
              ),
              const SizedBox(height: Space.x12),
              TextField(
                key: const Key('ticket-title'),
                controller: _title,
                autofocus: true,
                enabled: !_busy,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: Space.x12),
              TextField(
                key: const Key('ticket-body'),
                controller: _body,
                enabled: !_busy,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(labelText: 'What happened'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('ticket-cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(key: const Key('ticket-send'), onPressed: _busy ? null : _send, child: const Text('Send')),
      ],
    );
  }
}
