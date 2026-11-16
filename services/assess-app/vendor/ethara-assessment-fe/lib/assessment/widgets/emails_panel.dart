// Delivery history for one record.
//
// NOT THE CHATTER: the chatter is what PEOPLE did to a record, this is what
// the MAIL SERVER did with it, and the two have different audiences.
//
// The API route enforces the split too: /api/v1/chatter excludes emails,
// because an invitation body carries that candidate's access-token link.
// This panel therefore shows metadata, and the server only sends `body_html`
// to a manager.
import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../domain/enums.dart';
import '../domain/models.dart';
import '../state/app_store.dart';
import '../theme.dart';
import 'buttons.dart';
import 'loaders.dart';
import 'marks.dart';
import 'panel.dart';

/// One `mail.mail`, as the server reports it.
class EmailEntry {
  final String id;
  final String subject;
  final String state;
  final String stateLabel;
  final String failureReason;
  final String to;
  final DateTime? date;

  const EmailEntry({
    required this.id,
    required this.subject,
    required this.state,
    required this.stateLabel,
    required this.failureReason,
    required this.to,
    required this.date,
  });

  /// Colour follows the outcome, so an unknown future state reads as neutral.
  Tone get tone => switch (state) {
    'sent' || 'received' => Tone.ok,
    'exception' => Tone.bad,
    'outgoing' => Tone.info,
    'cancel' => Tone.inert,
    _ => Tone.inert,
  };

  factory EmailEntry.fromJson(Map<String, dynamic> j) {
    // `recipients` is used when the mail addressed partners rather than a
    // literal address - which is most of them, so falling back to email_to
    // alone would show a blank column on the majority of rows.
    final Object? rec = jget(j, 'recipients');
    String to = jval(j, 'emailTo', '');
    if (to.isEmpty && rec is List<dynamic> && rec.isNotEmpty) {
      to = rec
          .whereType<Map<String, dynamic>>()
          .map(
            (Map<String, dynamic> r) => jval(r, 'email', jval(r, 'name', '')),
          )
          .where((String s) => s.isNotEmpty)
          .join(', ');
    }
    return EmailEntry(
      id: jid(jget(j, 'id')),
      subject: jval(j, 'subject', '(no subject)'),
      state: jval(j, 'state', ''),
      stateLabel: jval(j, 'stateLabel', jval(j, 'state', '')),
      failureReason: jval(j, 'failureReason', ''),
      to: to,
      date: DateTime.tryParse(jval(j, 'date', '')),
    );
  }
}

class EmailsPanel extends StatefulWidget {
  final AppStore store;

  /// `assessment` | `generator` | `attempt` - the same vocabulary the chatter
  /// route uses.
  final String kind;
  final String recordId;

  const EmailsPanel({
    super.key,
    required this.store,
    required this.kind,
    required this.recordId,
  });

  @override
  State<EmailsPanel> createState() => _EmailsPanelState();
}

class _EmailsPanelState extends State<EmailsPanel> {
  List<EmailEntry> _rows = const <EmailEntry>[];
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(EmailsPanel old) {
    super.didUpdateWidget(old);
    // Flutter reuses the State when the same widget type rebuilds at the same
    // position, so without this the panel keeps showing the previous record's
    // mail after navigating to another one.
    if (old.recordId != widget.recordId || old.kind != widget.kind) _load();
  }

  // ONE PAGED CALL, WHATEVER THE KIND. An assessment's invitations are filed
  // against its attempts; the route includes them itself, so the panel only
  // pages instead of sending a request per candidate (652 on a real cohort).
  Future<void> _load() async {
    final ApiClient? api = widget.store.api;
    if (api == null) {
      setState(() {
        _loading = false;
        _error = 'Delivery history needs a live backend.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    await _fetch(api, reset: true);
  }

  Future<void> _loadMore() async {
    final ApiClient? api = widget.store.api;
    if (api == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    await _fetch(api, reset: false);
  }

  Future<void> _fetch(ApiClient api, {required bool reset}) async {
    final String kind = widget.kind;
    final String id = widget.recordId;
    try {
      final Map<String, dynamic> res = await api.emails(
        kind,
        id,
        offset: reset ? 0 : _rows.length,
      );
      // A page for the record this panel USED to show must not land on the
      // one it shows now.
      if (!mounted || kind != widget.kind || id != widget.recordId) return;
      final List<EmailEntry> page = _rowsOf(
        res,
      ).map(EmailEntry.fromJson).toList();
      final Object? meta = res['meta'];
      setState(() {
        _rows = reset ? page : <EmailEntry>[..._rows, ...page];
        _total = meta is Map<String, dynamic>
            ? jval<int>(meta, 'total', _rows.length)
            : _rows.length;
        _loading = false;
        _loadingMore = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = e.message;
      });
    }
  }

  List<Map<String, dynamic>> _rowsOf(Map<String, dynamic> res) {
    final Object? data = res['data'];
    return data is List<dynamic>
        ? data.whereType<Map<String, dynamic>>().toList()
        : const <Map<String, dynamic>>[];
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Panel(
      title: 'Emails',
      note: _rows.isEmpty ? null : '$_total total',
      headActions: <Widget>[
        IconBtn(Icons.refresh, tooltip: 'Reload', onPressed: _load),
      ],
      child: _loading
          ? const InlineBusy('Loading delivery history')
          : _error != null
          ? Text(
              _error!,
              style: context.type.small.copyWith(color: t.textMuted),
            )
          : _rows.isEmpty
          ? Text(
              'No email has been sent for this record yet.',
              style: context.type.small.copyWith(color: t.textMuted),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final EmailEntry e in _rows) _EmailRow(entry: e),
                if (_rows.length < _total)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Btn(
                      'Load more (${_total - _rows.length} left)',
                      size: BtnSize.sm,
                      busy: _loadingMore,
                      onPressed: _loadMore,
                    ),
                  ),
              ],
            ),
    );
  }
}

class _EmailRow extends StatelessWidget {
  final EmailEntry entry;

  const _EmailRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  entry.subject,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.body.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              StatusBadge(entry.stateLabel, entry.tone),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            <String>[
              if (entry.to.isNotEmpty) entry.to,
              if (entry.date != null) istTimestamp(entry.date!),
            ].join('  -  '),
            style: context.type.tiny.copyWith(color: t.textMuted),
          ),
          // The reason is what makes a failure actionable, so it is shown
          // rather than hidden behind a disclosure.
          if (entry.failureReason.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              entry.failureReason,
              style: context.type.tiny.copyWith(color: t.destText),
            ),
          ],
        ],
      ),
    );
  }
}
