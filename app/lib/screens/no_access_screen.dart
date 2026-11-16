import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/theme/portal_tokens.dart';
import '../core/widgets/cards.dart';
import 'shell.dart';

/// Signed in, but the token carries no Yantra role: say so, name the account, offer sign-out. Nothing is
/// loaded, so a person without access never sees a page of refusals.
class NoAccessScreen extends StatelessWidget {
  const NoAccessScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    final session = AppScope.of(context).session;
    return Scaffold(
      key: const Key('no-access'),
      backgroundColor: t.bgSubtle,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Space.x24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: PortalCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const BrandMark(size: 36),
                  const SizedBox(height: Space.x16),
                  Text('No access yet', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: Space.x8),
                  Text(
                    'You are signed in as ${session.username.isEmpty ? 'this account' : session.username}, but the '
                    'account has no Yantra role yet. Ask your operator to give you access, then sign in again.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: t.textSecondary),
                  ),
                  const SizedBox(height: Space.x20),
                  FilledButton.icon(
                    key: const Key('no-access-sign-out'),
                    onPressed: session.logout,
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
