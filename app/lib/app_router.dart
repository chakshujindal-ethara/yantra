import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'api/finance_models.dart';
import 'api/models.dart';
import 'app_scope.dart';
import 'auth/session.dart';
import 'core/widgets/loader.dart';
import 'screens/assess_continue_screen.dart';
import 'screens/assessment_screen.dart';
import 'screens/client/project_screen.dart';
import 'screens/listing_screen.dart';
import 'screens/login_screen.dart';
import 'screens/no_access_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/ops/batch_screen.dart';
import 'screens/ops/finance_screen.dart';
import 'screens/ops/listing_detail_screen.dart';
import 'screens/ops/paper_screen.dart';
import 'screens/ops/project_screen.dart';
import 'screens/ops/worker_screen.dart';
import 'screens/policies_screen.dart';
import 'screens/shell.dart';
import 'screens/work_route.dart';

/// Routes outside the shell.
abstract final class Paths {
  static const login = '/login';
  static const callback = '/auth/callback';
  static const noAccess = '/no-access';
  static const loading = '/';

  /// "Continue with Yantra" from the exam app: mints a fresh signed-in link back into the exam.
  static const assessContinue = '/assess/continue';

  static String listing(String id) => '${Destination.explore.path}/$id';
  static String onboarding({Destination from = Destination.home}) => '${from.path}/onboarding';
  static String unit(String claimId) => '${Destination.home.path}/unit/$claimId';
  static String assessment(String paperId) => '${Destination.applications.path}/assessment/$paperId';
  static String policy(String slug) => '${Destination.profile.path}/policies/$slug';
  static String project(String id) => '${Destination.projects.path}/$id';
  static String batch(String projectId, String batchId) => '${project(projectId)}/batches/$batchId';
  static String opsListing(String id) => '${Destination.listings.path}/$id';
  static String paper(String id) => '${Destination.papers.path}/$id';
  static String worker(String id) => '${Destination.workers.path}/$id';
  static String window(String id) => '${Destination.finance.path}/windows/$id';
  static String clientProject(String id) => '${Destination.clientProjects.path}/$id';
}

/// What a timed page answers when someone tries to leave it: true lets the route go. Work and Assessment
/// register one while a draft or a live sitting would be abandoned; [GoRoute.onExit] asks it for the
/// browser's back button, a crumb, the back arrow and any `go` away from the page.
typedef ExitGuard = Future<bool> Function(BuildContext context);

class ExitGuards {
  final Map<String, ExitGuard> _guards = {};

  void set(String route, ExitGuard? guard) {
    if (guard == null) {
      _guards.remove(route);
    } else {
      _guards[route] = guard;
    }
  }

  /// Whether [route] may be left. A signed-out person (they signed out, or the session expired) is never
  /// asked: the redirect to sign-in must not be trapped by a dialog; the page keeps its draft on the device.
  Future<bool> allow(String route, BuildContext context, {bool signedIn = true}) async =>
      !signedIn || (await _guards[route]?.call(context) ?? true);
}

/// Route names that carry an exit guard.
abstract final class GuardedRoute {
  static const unit = 'unit';
  static const assessment = 'assessment';
}

/// The app's routes: sign-in and its callback, the no-access page, and one shell branch per [Destination]
/// with the detail pages nested under the branch that opens them, so the sidebar stays and the list keeps
/// its scroll under the detail. Redirects follow the session: loading waits, signed-out goes to sign-in
/// (remembering where it was going), a signed-in person lands on the attempted page when their roles
/// allow it, else on their first destination, and a token with no Yantra role sees the no-access page.
GoRouter buildRouter({required Session session, required ExitGuards guards, String? initialLocation}) {
  String? redirect(BuildContext context, GoRouterState state) {
    final loc = state.uri.toString();
    final path = state.uri.path;
    switch (session.state) {
      case SessionState.loading:
        if (path != Paths.loading) session.rememberNext(loc);
        return path == Paths.loading ? null : Paths.loading;
      case SessionState.signedOut:
        if (path == Paths.login) return null;
        if (path != Paths.loading && path != Paths.callback && path != Paths.noAccess) session.rememberNext(loc);
        return Paths.login;
      case SessionState.signedIn:
        final roles = session.roles;
        final first = Destination.firstFor(roles);
        if (first == null) return path == Paths.noAccess ? null : Paths.noAccess;
        if (path == Paths.loading || path == Paths.login || path == Paths.callback || path == Paths.noAccess) {
          final next = session.takeNext();
          // back from sign-in on the way into an exam: carry on there (the gateway checks who may open it)
          if (next != null && Uri.parse(next).path == Paths.assessContinue) return next;
          final target = next == null ? null : Destination.byPath(next);
          return target != null && target.roles.any(roles.contains) ? next : first.path;
        }
        if (path == Paths.assessContinue) return null;
        final d = Destination.byPath(path);
        if (d == null || !d.roles.any(roles.contains)) return first.path;
        return null;
    }
  }

  GoRoute guarded(String path, String name, Widget Function(BuildContext, GoRouterState) build) => GoRoute(
    path: path,
    name: name,
    builder: build,
    onExit: (context, state) => guards.allow(name, context, signedIn: session.state == SessionState.signedIn),
  );

  List<RouteBase> details(Destination d) => switch (d) {
    Destination.home => [
      GoRoute(path: 'onboarding', builder: (_, _) => const OnboardingScreen()),
      guarded(
        'unit/:claimId',
        GuardedRoute.unit,
        (_, s) => WorkRoute(claimId: s.pathParameters['claimId']!, initial: s.extra as ActiveWork?),
      ),
    ],
    Destination.explore => [
      GoRoute(
        path: ':listingId',
        builder: (_, s) => ListingScreen(listingId: s.pathParameters['listingId']!),
      ),
    ],
    Destination.applications => [
      GoRoute(
        path: 'onboarding',
        builder: (_, _) => const OnboardingScreen(from: Destination.applications),
      ),
      guarded('assessment/:paperId', GuardedRoute.assessment, (_, s) => AssessmentScreen(paperId: s.pathParameters['paperId']!)),
    ],
    Destination.projects => [
      GoRoute(
        path: ':id',
        builder: (_, s) => ProjectScreen(projectId: s.pathParameters['id']!),
        routes: [
          GoRoute(
            path: 'batches/:batchId',
            builder: (_, s) =>
                BatchScreen(batchId: s.pathParameters['batchId']!, projectId: s.pathParameters['id']!, marginFloor: s.extra as double?),
          ),
        ],
      ),
    ],
    Destination.listings => [
      GoRoute(
        path: ':id',
        builder: (_, s) => ListingDetailScreen(listingId: s.pathParameters['id']!),
      ),
    ],
    Destination.papers => [
      GoRoute(
        path: ':id',
        builder: (_, s) => PaperScreen(paperId: s.pathParameters['id']!),
      ),
    ],
    Destination.workers => [
      GoRoute(
        path: ':id',
        builder: (_, s) => WorkerScreen(workerId: s.pathParameters['id']!),
      ),
    ],
    Destination.finance => [
      GoRoute(
        path: 'windows/:id',
        builder: (_, s) => WindowScreen(windowId: s.pathParameters['id']!, window: s.extra as PayWindowRow?),
      ),
    ],
    Destination.clientProjects => [
      GoRoute(
        path: ':id',
        builder: (_, s) => ClientProjectScreen(projectId: s.pathParameters['id']!, name: (s.extra as String?) ?? ''),
      ),
    ],
    Destination.profile => [
      GoRoute(
        path: 'policies/:slug',
        builder: (_, s) => PoliciesScreen(initial: s.pathParameters['slug']!),
      ),
    ],
    _ => const [],
  };

  // a pushed detail page is a place: the address bar shows it, so refresh and copy-link keep it
  GoRouter.optionURLReflectsImperativeAPIs = true;
  return GoRouter(
    initialLocation: initialLocation,
    refreshListenable: session,
    redirect: redirect,
    routes: [
      GoRoute(
        path: Paths.loading,
        builder: (_, _) => const Scaffold(
          body: Center(child: BrandLoader(label: 'Opening Yantra…')),
        ),
      ),
      GoRoute(path: Paths.login, builder: (_, _) => const LoginScreen()),
      GoRoute(
        path: Paths.callback,
        builder: (_, _) => const Scaffold(
          body: Center(child: BrandLoader(label: 'Signing you in…')),
        ),
      ),
      GoRoute(path: Paths.noAccess, builder: (_, _) => const NoAccessScreen()),
      GoRoute(
        path: Paths.assessContinue,
        builder: (_, s) => AssessContinueScreen(query: s.uri.queryParameters),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => Shell(navigationShell: shell),
        branches: [
          for (final d in Destination.values)
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: d.path,
                  pageBuilder: (_, _) => NoTransitionPage(child: ShellPage(d)),
                  routes: [for (final r in details(d)) r],
                ),
              ],
            ),
        ],
      ),
    ],
    errorBuilder: (context, state) => const _NotFound(),
  );
}

/// A URL that matches nothing: say so and offer the way home.
class _NotFound extends StatelessWidget {
  const _NotFound();

  @override
  Widget build(BuildContext context) {
    final session = AppScope.of(context).session;
    final first = Destination.firstFor(session.roles);
    return Scaffold(
      key: const Key('not-found'),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('This page does not exist', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            FilledButton(onPressed: () => context.go(first?.path ?? Paths.login), child: const Text('Go to your first page')),
          ],
        ),
      ),
    );
  }
}
