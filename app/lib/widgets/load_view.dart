import 'package:flutter/material.dart';

import '../core/errors.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/portal_tokens.dart';
import '../core/widgets/cards.dart';
import '../core/widgets/loader.dart';

/// What a [LoadView] shows while its first answer is in flight: the brand loader for a page waiting on
/// its first data, skeleton rows for a section inside a page that has already loaded.
enum LoadWait { brand, skeleton }

/// Loads once; shows the first wait, an error with Retry, an empty message, or the data. A reload keeps
/// the data on screen until the new answer arrives: a refresh never flashes the page back to a loader.
/// Give it a new [key] to load afresh.
class LoadView<T> extends StatefulWidget {
  const LoadView({
    super.key,
    required this.load,
    required this.builder,
    this.isEmpty,
    this.emptyMessage = 'Nothing here yet',
    this.emptyAction,
    this.firstWait = LoadWait.skeleton,
    this.wrapInCard = false,
  });

  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data, Future<void> Function() reload) builder;
  final bool Function(T data)? isEmpty;
  final String emptyMessage;

  /// Shown under the empty message: what to do next.
  final Widget? emptyAction;
  final LoadWait firstWait;

  /// Error and empty states inside a [PortalCard]: for a section that sits among other cards.
  final bool wrapInCard;

  @override
  State<LoadView<T>> createState() => LoadViewState<T>();
}

class LoadViewState<T> extends State<LoadView<T>> {
  late Future<T> _future = widget.load();
  T? _last;
  bool _hasLast = false;

  /// Loads again. The data already on screen stays there until the new answer arrives.
  Future<void> reload() async {
    final next = widget.load();
    setState(() {
      _future = next;
    });
    try {
      await next;
    } on Object {
      // Shown by the FutureBuilder; nothing to do here.
    }
  }

  Widget _card(Widget child) => widget.wrapInCard ? PortalCard(child: child) : child;

  Widget get _firstWait => switch (widget.firstWait) {
    LoadWait.brand => const Padding(padding: EdgeInsets.all(48), child: BrandLoader()),
    LoadWait.skeleton => const Skeleton(lines: 4),
  };

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          if (_hasLast) return widget.builder(context, _last as T, reload);
          return _firstWait;
        }
        final error = snap.error;
        if (error != null) return _card(ErrorView(message: describeError(error), onRetry: reload));
        if (!snap.hasData) return _card(ErrorView(message: 'No data', onRetry: reload));
        final data = snap.data as T;
        _last = data;
        _hasLast = true;
        if (widget.isEmpty?.call(data) ?? false) {
          final action = widget.emptyAction;
          return _card(
            action == null
                ? EmptyView(message: widget.emptyMessage, onRetry: reload)
                : Column(
                    children: [
                      EmptyView(message: widget.emptyMessage, onRetry: reload),
                      action,
                      const SizedBox(height: Space.x8),
                    ],
                  ),
          );
        }
        return widget.builder(context, data, reload);
      },
    );
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, this.onRetry});
  final String message;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: t.destDot, size: 40),
            const SizedBox(height: 12),
            Text(
              splitDetails(message).$1,
              textAlign: TextAlign.center,
              style: TextStyle(color: t.destText),
            ),
            if (splitDetails(message).$2 case final details?) ...[
              const SizedBox(height: Space.x4),
              Text(
                'Details: $details',
                key: const Key('error-details'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: t.destText),
              ),
            ],
            if (onRetry != null) ...[const SizedBox(height: 12), OutlinedButton(onPressed: onRetry, child: const Text('Retry'))],
          ],
        ),
      ),
    );
  }
}

class EmptyView extends StatelessWidget {
  const EmptyView({super.key, required this.message, this.onRetry});
  final String message;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined, size: 40, color: PortalTokens.of(context).textMuted),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: PortalTokens.of(context).textSecondary),
            ),
            if (onRetry != null) ...[const SizedBox(height: 12), OutlinedButton(onPressed: onRetry, child: const Text('Refresh'))],
          ],
        ),
      ),
    );
  }
}

/// A one-line error above a form.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner(this.message, {super.key});
  final String? message;

  @override
  Widget build(BuildContext context) {
    final text = message;
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    return StatusBanner(text, kind: StatusKind.dest, icon: Icons.error_outline);
  }
}
