import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../api/ops_models.dart';
import '../../app_scope.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/portal_tokens.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/loader.dart';
import '../../core/widgets/people.dart';
import '../../core/widgets/portal_page.dart';
import '../../core/widgets/stage_bar.dart';
import '../../core/widgets/tables.dart';
import '../../widgets/load_view.dart';
import '../../app_router.dart';
import 'package:go_router/go_router.dart';

/// The bench: every worker with name, status, onboarding, hold, gates and availability; search by id
/// prefix (300 ms after the last key), filter by status and by gate, fifty a page.
class WorkersScreen extends StatefulWidget {
  const WorkersScreen({super.key});

  @override
  State<WorkersScreen> createState() => _WorkersScreenState();
}

const _statuses = {
  'All': null,
  'Unknown': 'unknown',
  'Eligible': 'eligible',
  'Active': 'active',
  'Suspended': 'suspended',
  'Offboarded': 'offboarded',
};

/// `20 h/wk`, `paused until 6 Nov`, or a dash.
String availabilityLabel(Availability? a, {DateTime? now}) {
  if (a == null) return '—';
  if (a.isPaused(now: now)) return 'paused until ${shortDate(a.pausedUntil!, now: now)}';
  return '${a.weeklyHours} h/wk';
}

/// The id search accepts the start of a uuid only (what the bench query can match).
final _idPrefix = RegExp(r'^[0-9a-fA-F-]+$');

class _WorkersScreenState extends State<WorkersScreen> {
  static const limit = 50;
  static const debounce = Duration(milliseconds: 300);
  String _q = '';
  String? _status;
  String _gate = '';
  int _offset = 0;
  Future<ListPage<WorkerRow>>? _future;
  bool _first = true;
  Timer? _typing;
  final _gateField = TextEditingController();

  @override
  void dispose() {
    _typing?.cancel();
    _gateField.dispose();
    super.dispose();
  }

  bool get _badQuery => _q.isNotEmpty && !_idPrefix.hasMatch(_q);

  Future<ListPage<WorkerRow>> _load() =>
      AppScope.of(context).ops.workers(q: _badQuery ? null : _q, status: _status, gate: _gate, limit: limit, offset: _offset);

  /// Waits for a pause in typing so a fast search sends one request, not one per key.
  void _later(VoidCallback change) {
    change();
    _typing?.cancel();
    _typing = Timer(debounce, () {
      if (!mounted) return;
      _offset = 0;
      _refresh();
    });
  }

  void _refresh() {
    final next = _load();
    setState(() {
      _future = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final future = _future ??= _load();
    return PortalPage(
      kicker: 'Operate · Workers',
      title: 'Workers',
      subtitle: 'The bench',
      onRefresh: () async => _refresh(),
      children: [
        Toolbar(
          search: TextField(
            key: const Key('workers-search'),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Worker id starts with…',
              errorText: _badQuery ? 'Search by the start of a worker id (0-9, a-f)' : null,
            ),
            onChanged: (v) => _later(() => setState(() => _q = v.trim())),
          ),
          children: [
            SizedBox(
              width: 180,
              child: TextField(
                key: const Key('workers-gate'),
                controller: _gateField,
                decoration: const InputDecoration(prefixIcon: Icon(Icons.verified_outlined, size: 18), hintText: 'Holds gate…'),
                onChanged: (v) => _later(() => _gate = v.trim()),
              ),
            ),
            FilterChips<String>(
              values: _statuses,
              selected: _status,
              onSelected: (v) {
                _status = v;
                _offset = 0;
                _refresh();
              },
            ),
          ],
        ),
        FutureBuilder<ListPage<WorkerRow>>(
          future: future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return _first
                  ? const Padding(padding: EdgeInsets.all(48), child: BrandLoader())
                  : const PortalCard(child: Skeleton(lines: 5));
            }
            _first = false;
            if (snap.hasError) return ErrorView(message: describeError(snap.error!), onRetry: () async => _refresh());
            final page = snap.data ?? const ListPage<WorkerRow>(total: 0, items: []);
            if (page.total == 0 && _q.isEmpty && _status == null && _gate.isEmpty) {
              return const PortalCard(child: EmptyView(message: 'No workers yet. They appear here once onboarding marks them eligible.'));
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PortalTable(
                  minWidth: 1040,
                  emptyMessage: 'No worker matches',
                  columns: const [
                    PortalColumn('Worker', flex: 2),
                    PortalColumn('Status', width: 130),
                    PortalColumn('Onboarding', width: 120),
                    PortalColumn('Pay', width: 130),
                    PortalColumn('Gates', flex: 2),
                    PortalColumn('Availability', flex: 1),
                    PortalColumn('Updated', width: 110),
                  ],
                  rows: [
                    for (final w in page.items)
                      PortalRow(
                        [
                          NameOf(w.id, name: w.name),
                          ConsoleStatus(w.status),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: StatusChip(
                              w.onboarded ? 'Done' : 'In progress',
                              kind: w.onboarded ? StatusKind.success : StatusKind.warn,
                            ),
                          ),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: w.held
                                ? StatusChip(
                                    w.holdUntil == null ? 'Held' : 'Held to ${shortDate(w.holdUntil!)}',
                                    key: Key('worker-held-${w.id}'),
                                    kind: StatusKind.warn,
                                  )
                                : const Text('—'),
                          ),
                          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: TagChips(w.certGates)),
                          Text(availabilityLabel(w.availability)),
                          Text(w.updatedAt == null ? '—' : relative(w.updatedAt!), style: TextStyle(color: t.textSecondary)),
                        ],
                        key: Key('worker-${w.id}'),
                        onTap: () => context.push(Paths.worker(w.id)),
                      ),
                  ],
                ),
                Pager(
                  offset: _offset,
                  limit: limit,
                  total: page.total,
                  onPage: (o) {
                    _offset = o;
                    _refresh();
                  },
                ),
                Padding(
                  padding: const EdgeInsets.only(top: Space.x8),
                  child: Text('${page.total} ${page.total == 1 ? 'worker' : 'workers'}', style: Theme.of(context).textTheme.labelSmall),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
