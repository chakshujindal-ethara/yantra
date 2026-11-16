// Call ledger - HANDOVER 4.3, `#/admin/ledger`.
//
// One row per model call. Every figure on the budget screen is summed from
// this table, which is why the ledger is a route rather than a fold-out: a
// cost nobody can trace back to its calls is a cost nobody can dispute.
import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../state/app_store.dart';
import '../../widgets/data_grid.dart';
import '../../widgets/buttons.dart';
import '../../widgets/controls.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import 'budget_screen.dart';
import '../../nav.dart';
import '../../theme.dart';

class LedgerScreen extends StatefulWidget {
  final AppStore store;

  const LedgerScreen({super.key, required this.store});

  @override
  State<LedgerScreen> createState() => _LedgerScreenState();
}

class _LedgerScreenState extends State<LedgerScreen> {
  // The page STARTS from the address bar (`/ledger?page=3`); `build` writes
  // it back.
  late int _page = int.tryParse(context.navQuery['page'] ?? '') ?? 1;
  late int _pageSize = int.tryParse(context.navQuery['size'] ?? '') ?? 20;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  /// SERVER-SIDE, so the last page is the last row rather than the cap.
  ///
  /// This screen used to slice `store.ledger` - the console bootstrap's walk,
  /// stopped at `maxPages: 5` - so its pagination control offered pages of a
  /// 1,000-row sample of the fastest-growing table on the platform. Past that
  /// the ledger simply ended, and the only hint was a chip.
  void _fetch() =>
      widget.store.loadLedgerPage(page: _page, pageSize: _pageSize);

  /// Who a call is billed to. Authoring calls carry a generator; evaluation
  /// calls carry an attempt, which resolves through its candidate. A call that
  /// resolves to neither is shown as unattributed rather than quietly dropped.
  String _attributedTo(LedgerRow r) {
    if (r.genId != null) {
      return widget.store.genById(r.genId)?.name ?? r.genId!;
    }
    if (r.evId != null) {
      final Attempt? ev = widget.store.attemptById(r.evId);
      final String? who = ev == null
          ? null
          : widget.store.personById(ev.employeeId)?.name;
      return who ?? r.evId!;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final AppStore s = widget.store;
    final AppTokens t = context.tokens;
    context.setNavQuery(<String, Object?>{
      'page': _page == 1 ? null : _page,
      'size': _pageSize == 20 ? null : _pageSize,
    });

    return ListenableBuilder(
      listenable: s,
      builder: (BuildContext context, _) {
        // The page the SERVER sent, and the server's own count of the whole
        // table. `rows` is now one page rather than a walk, so `total` has to
        // come from `meta` - `rows.length` would make every page the last one.
        final List<LedgerRow> slice = s.ledgerPageRows;
        final int total = s.ledgerPageTotal;
        final int page = s.ledgerPageNumber;

        return PageBody(
          children: <Widget>[
            // WHERE YOU ARE, NOT WHO YOU ARE. The first crumb read "Admin",
            // which is an assertion about the reader rather than a location -
            // and a false one for a read-only Manager, who has LLM Budget on
            // their rail and arrives here from it. "Platform" is the sidebar
            // group that both this screen and Budget sit under, so the trail
            // now names its section the way every other breadcrumb on the
            // console does, and it stays true whoever is reading it.
            Crumbs(const <Crumb>[
              Crumb('Platform'),
              Crumb('LLM budget'),
              Crumb('Ledger'),
            ]),
            PageHead(
              'Spend Ledger',
              sub:
                  'One row per model call. This is what every figure on the '
                  'budget screen is summed from.',
              // Not on the rail - reached from Budget, where "what did we pay
              // for" is already being asked, and the two link both ways.
              actions: <Widget>[
                Btn(
                  'LLM Budget',
                  onPressed: () => context.nav.go(const BudgetAdmin()),
                ),
              ],
            ),
            Panel(
              flush: true,
              // THE WHOLE TABLE, not a denominator for a sample. The count
              // is the server's `meta.total` and the pages now walk to it, so
              // this reads as a population rather than as a disclaimer.
              headActions: <Widget>[TagChip('$total calls')],
              title: 'Model Calls',
              footer: Pagination(
                page: page,
                pageSize: _pageSize,
                total: total,
                onPage: (int p) {
                  setState(() => _page = p);
                  _fetch();
                },
                onPageSize: (int n) {
                  setState(() {
                    _pageSize = n;
                    _page = 1;
                  });
                  _fetch();
                },
              ),
              child: DataGrid(
                minWidth: 980,
                // A FAILED READ AND AN EMPTY LEDGER LOOK IDENTICAL otherwise,
                // and only one of them is a reason to retry. The screen now
                // pages from the server, so a dropped request empties the
                // grid where it used to leave the console-wide walk on
                // screen - which makes saying which one this is load-bearing
                // rather than tidy.
                emptyMessage: s.ledgerPageError.isNotEmpty
                    ? 'The ledger could not be read: ${s.ledgerPageError}'
                    : s.ledgerPageLoading
                    ? 'Loading model calls...'
                    : 'No model calls recorded yet. They appear here as soon '
                          'as a generator runs or an answer is graded.',
                emptyIcon: s.ledgerPageError.isNotEmpty
                    ? Icons.error_outline
                    : Icons.receipt_long_outlined,
                cols: const <Col>[
                  Col('Operation', flex: 2),
                  Col('Model', flex: 2),
                  Col('Attributed to', flex: 2),
                  Col('In', width: 84, numeric: true),
                  Col('Out', width: 84, numeric: true),
                  Col('Thinking', width: 88, numeric: true),
                  Col('Images', width: 76, numeric: true),
                  Col('Cost', width: 88, numeric: true),
                ],
                rows: slice.map((LedgerRow r) {
                  final String who = _attributedTo(r);
                  return GridRow(
                    onTap: () => _openCall(context, r, who),
                    <Widget>[
                      // The row opens a sheet: the grid cannot fit the token
                      // split, video seconds, the server's attribution note or
                      // the exact timestamp. Odoo's LLM Usage list opens a
                      // record the same way.
                      GridLink.plain(r.op.label),
                      Mono(r.model, size: 11.5, color: t.textSecondary),
                      who.isEmpty
                          ? Text('Unattributed', style: context.type.bodyMuted)
                          : Text(
                              who,
                              style: context.type.tableCell.copyWith(
                                color: t.textSecondary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                      Mono(nf(r.tokensIn)),
                      Mono(nf(r.tokensOut)),
                      // A zero here is an absence, not a quantity: this model
                      // returned no thinking tokens at all.
                      r.thoughts > 0
                          ? Mono(nf(r.thoughts))
                          : Mono('-', color: t.textMuted),
                      r.images > 0
                          ? Mono('${r.images}')
                          : Mono('-', color: t.textMuted),
                      Mono(usd(r.cost)),
                    ],
                  );
                }).toList(),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One ledger line, in full.
void _openCall(BuildContext context, LedgerRow r, String who) {
  showSheet<void>(
    context,
    title: r.op.label,
    sub: '${r.model}  ·  ${usd(r.cost)}',
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FieldGrid(<Widget>[
          Field.readonly('Operation', r.op.label),
          Field.readonly('Model', r.model),
          Field.readonly(
            'Attributed to',
            who.isEmpty ? (r.note.isEmpty ? 'Unattributed' : r.note) : who,
            help: r.genId != null
                ? 'Generator ${r.genId}'
                : (r.evId != null
                      ? 'Attempt ${r.evId}'
                      : 'No record claimed '
                            'this call, so it is not counted against any one budget.'),
          ),
          Field.readonly('When', istTimestamp(r.at)),
        ]),
        const SizedBox(height: 16),
        Panel(
          title: 'Tokens',
          note: '${nf(r.tokensIn + r.tokensOut + r.thoughts)} total',
          child: FieldGrid(<Widget>[
            Field.readonly(
              'Input',
              nf(r.tokensIn),
              help: 'The prompt, the SOP and any media sent up.',
            ),
            Field.readonly(
              'Output',
              nf(r.tokensOut),
              help: 'What the model wrote back.',
            ),
            // Zero here is an ABSENCE, not a quantity: some models return no
            // thinking tokens at all, which is different from thinking for
            // free.
            Field.readonly(
              'Thinking',
              r.thoughts > 0 ? nf(r.thoughts) : 'none returned',
              help: 'Billed as output when the model reports it.',
            ),
          ]),
        ),
        if (r.images > 0 || r.videoSeconds > 0) ...<Widget>[
          const SizedBox(height: 16),
          Panel(
            title: 'Media',
            child: FieldGrid(<Widget>[
              if (r.images > 0) Field.readonly('Images rendered', nf(r.images)),
              if (r.videoSeconds > 0)
                Field.readonly('Video seconds', nf(r.videoSeconds)),
            ]),
          ),
        ],
        const SizedBox(height: 16),
        Panel(
          title: 'Cost',
          child: FieldGrid(<Widget>[
            Field.readonly('This call', usd(r.cost)),
            Field.readonly(
              'Ledger id',
              r.id,
              help: 'The same row Odoo shows under LLM Usage.',
            ),
          ]),
        ),
      ],
    ),
  );
}
