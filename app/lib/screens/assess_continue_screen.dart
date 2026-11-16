import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/errors.dart';
import '../core/theme/portal_tokens.dart';
import '../core/widgets/action_dialog.dart';
import '../core/widgets/loader.dart';
import 'package:go_router/go_router.dart';

import '../app_router.dart';

/// "Continue with Yantra" from the exam app's sign-in page lands here (`/assess/continue?exam=<token>`, or
/// `?admin=1&next=/assessments/12` for staff). The worker is signed in to Yantra by now, so a fresh one-time
/// link is minted and the browser goes straight back into the exam, signed in there too.
class AssessContinueScreen extends StatefulWidget {
  const AssessContinueScreen({super.key, required this.query});

  /// The route's query parameters.
  final Map<String, String> query;

  @override
  State<AssessContinueScreen> createState() => _AssessContinueScreenState();
}

class _AssessContinueScreenState extends State<AssessContinueScreen> {
  String? _error;

  /// The link the browser was sent to; shown in case the browser stays on this page.
  Uri? _launched;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _go());
  }

  /// The same route opened with another exam (or admin page) starts over for that one.
  @override
  void didUpdateWidget(AssessContinueScreen old) {
    super.didUpdateWidget(old);
    if (old.query.toString() != widget.query.toString()) {
      _launched = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _go());
    }
  }

  String get _exam => (widget.query['exam'] ?? '').trim();
  bool get _admin => widget.query['admin'] == '1';

  Future<void> _go() async {
    final scope = AppScope.of(context);
    if (_exam.isEmpty && !_admin) {
      setState(() => _error = 'This link does not say which exam to open. Start it again from your application.');
      return;
    }
    setState(() => _error = null);
    try {
      final ticket = _admin
          ? await withActionKey(
              scope.keys,
              'assess:continue:admin',
              (key) => scope.assess.adminLaunch(next: widget.query['next'] ?? '/', key: key),
            )
          : await withActionKey(scope.keys, 'assess:continue:$_exam', (key) => scope.assess.launchByExam(_exam, key: key));
      scope.session.openExternal(ticket.launchUrl);
      if (mounted) setState(() => _launched = ticket.launchUrl);
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = _error;
    final launched = _launched;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(Space.x24),
            child: launched != null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Opening your exam…', key: Key('assess-continue-opened')),
                      const SizedBox(height: Space.x8),
                      TextButton(
                        key: const Key('assess-continue-open'),
                        onPressed: () => AppScope.of(context).session.openExternal(launched),
                        child: const Text('Open the exam'),
                      ),
                    ],
                  )
                : error == null
                ? const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      BrandLoader(),
                      SizedBox(height: Space.x16),
                      Text('Taking you back to your exam…', key: Key('assess-continue-wait')),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('The exam could not be opened', style: theme.textTheme.titleMedium),
                      const SizedBox(height: Space.x8),
                      Text(error, key: const Key('assess-continue-error'), style: theme.textTheme.bodyMedium),
                      const SizedBox(height: Space.x16),
                      Wrap(
                        spacing: Space.x12,
                        children: [
                          FilledButton(key: const Key('assess-continue-retry'), onPressed: _go, child: const Text('Try again')),
                          TextButton(
                            key: const Key('assess-continue-home'),
                            onPressed: () => context.go(Paths.loading),
                            child: const Text('Back to Yantra'),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
