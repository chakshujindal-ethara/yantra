import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/file_pick_stub.dart'
    if (dart.library.js_interop) '../../services/file_pick_web.dart';
import '../data/api_client.dart';
import '../domain/enums.dart';
import '../domain/models.dart';
import '../state/app_store.dart';
import '../theme.dart';
import 'buttons.dart';
import 'controls.dart';
import 'panel.dart';
import 'skeleton.dart';

/// One audit line.
class ChatterEntry {
  const ChatterEntry({
    required this.id,
    required this.author,
    required this.text,
    required this.date,
    required this.subtype,
    this.attachments = const <ChatterFile>[],
  });

  final String id;
  final String author;
  final String text;
  final DateTime? date;
  final String subtype;
  final List<ChatterFile> attachments;

  factory ChatterEntry.fromJson(Map<String, dynamic> j) => ChatterEntry(
    id: '${jget(j, 'id') ?? ''}',
    author: jval(j, 'author', 'System'),
    text: jval(j, 'text', ''),
    date: DateTime.tryParse(jval(j, 'date', '')),
    subtype: jval(j, 'subtype', ''),
    attachments: <ChatterFile>[
      for (final Object? a
          in (jget(j, 'attachments') as List<dynamic>? ?? const <dynamic>[]))
        if (a is Map<String, dynamic>) ChatterFile.fromJson(a),
    ],
  );
}

class ChatterFile {
  const ChatterFile({required this.name, required this.url});

  final String name;
  final String url;

  factory ChatterFile.fromJson(Map<String, dynamic> j) =>
      ChatterFile(name: jval(j, 'name', 'attachment'), url: jval(j, 'url', ''));
}

/// The record's history, as the module already writes it.
///
/// Fetches on its own rather than through the store: this is a leaf detail
/// panel that several screens embed, and threading it through the store would
/// put an unrelated list on the global refresh path.
class ChatterPanel extends StatefulWidget {
  const ChatterPanel({
    super.key,
    required this.store,
    required this.kind,
    required this.recordId,
    this.title = 'History',
  });

  /// One of `assessment`, `generator`, `attempt` - the server's allow-list.
  final String kind;
  final String recordId;
  final AppStore store;
  final String title;

  /// Kinds whose history can be READ but not added to.
  ///
  /// An attempt (`etp.assessment.pro.evaluator`) does not inherit mail.thread:
  /// Odoo writes messages against it directly, so the trail is real, but
  /// `message_post` does not exist and posting returns 422. Offering a composer
  /// that can only fail is worse than not offering one.
  static const Set<String> _readOnlyKinds = <String>{'attempt'};

  /// Whether the COMPOSER is offered. The timeline is shown either way.
  ///
  /// Two unrelated reasons to withhold it, both ending in the same dead POST.
  /// The kinds above have no `message_post` to call; and
  /// `/api/v1/chatter/<kind>/<id>/post` is Admin-only server-side, so a
  /// read-only Manager on the assessment or generator dock was given a box to
  /// type into and a Send that answered 403 after they had written the note.
  /// Reading the trail is what the dock is FOR, so only the writing half is
  /// withdrawn - the history, the search and the full-screen view all stay.
  bool get canPost =>
      !_readOnlyKinds.contains(kind) && store.can(Capability.configure);

  @override
  State<ChatterPanel> createState() => _ChatterPanelState();
}

class _ChatterPanelState extends State<ChatterPanel> {
  List<ChatterEntry> _entries = const <ChatterEntry>[];

  /// The record's REAL message count, per `meta.total`.
  ///
  /// The header printed `_entries.length`, but the route caps a page at 40,
  /// so a busy record reported 40 as though that were its whole history.
  int _total = 0;
  bool _hasMore = false;
  bool _loading = true;
  String? _error;

  final TextEditingController _composer = TextEditingController();
  final TextEditingController _search = TextEditingController();
  final FocusNode _composerFocus = FocusNode();

  bool _posting = false;

  /// Search is a TOGGLE, not a permanent field - only a long history needs it.
  bool _searching = false;

  final List<({String name, String b64})> _staged =
      <({String name, String b64})>[];

  /// The store's [AppStore.historyRevision] this panel last loaded at.
  int _revision = 0;

  @override
  void dispose() {
    widget.store.removeListener(_onStore);
    _composer.dispose();
    _search.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _revision = widget.store.historyRevision;
    widget.store.addListener(_onStore);
    _load();
  }

  /// An action landed (Release, Cancel, Reset...): its line is in the trail
  /// now, so re-read quietly - no spinner, composer untouched.
  void _onStore() {
    if (widget.store.historyRevision == _revision) return;
    _revision = widget.store.historyRevision;
    _load();
  }

  @override
  void didUpdateWidget(ChatterPanel old) {
    super.didUpdateWidget(old);
    // Reload when the panel is pointed at a DIFFERENT record.
    //
    // Flutter reuses an element whose widget type and position match, so
    // navigating from one generator to another kept this State alive and
    // `initState` never ran again - the panel went on showing the first
    // record's history under the second record's name. Silently wrong, and
    // wrong in the one direction an audit trail must never be.
    if (old.recordId != widget.recordId || old.kind != widget.kind) {
      _entries = const <ChatterEntry>[];
      _total = 0;
      _hasMore = false;
      _error = null;
      _loading = true;
      _composer.clear();
      _search.clear();
      _searching = false;
      _staged.clear();
      _load();
    }
  }

  Future<void> _load() async {
    final ApiClient? api = widget.store.api;
    if (api == null) {
      // Seed mode has no server to ask. Say so rather than showing an empty
      // list that looks like a record with no history.
      setState(() {
        _loading = false;
        _error = 'History is only available against a live backend.';
      });
      return;
    }
    try {
      final Map<String, dynamic> res = await api.chatter(
        widget.kind,
        widget.recordId,
      );
      final Object? data = jget(res, 'data');
      final List<dynamic> list = data is List<dynamic>
          ? data
          : const <dynamic>[];
      final Object? meta = res['meta'];
      final Map<String, dynamic> m = meta is Map<String, dynamic>
          ? meta
          : const <String, dynamic>{};
      if (!mounted) return;
      setState(() {
        _total = (m['total'] as num?)?.toInt() ?? list.length;
        _hasMore = m['has_more'] == true;
        _entries = list
            .map(
              (dynamic e) => ChatterEntry.fromJson(e as Map<String, dynamic>),
            )
            .where((ChatterEntry e) => e.text.isNotEmpty)
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load the history: $e';
      });
    }
  }

  /// Log the composer's text, then reload so the new line appears in place.
  ///
  /// ONE VERB: the internal note only, never `mail.mt_comment` - the server
  /// still accepts `post_kind` for anyone who means to mail the followers.
  Future<void> _post() async {
    final ApiClient? api = widget.store.api;
    final String body = _composer.text.trim();
    if (api == null || _posting) return;
    if (body.isEmpty && _staged.isEmpty) {
      widget.store.toaster.warn('Write something first.');
      return;
    }
    setState(() => _posting = true);
    try {
      await api.postChatter(
        widget.kind,
        widget.recordId,
        body: body.isEmpty ? '(file attached)' : body,
        attachments: <Map<String, String>>[
          for (final ({String name, String b64}) f in _staged)
            <String, String>{'name': f.name, 'content': f.b64},
        ],
      );
      _composer.clear();
      _staged.clear();
      // Reload rather than appending locally: the server decides the author,
      // the timestamp and the subtype label, and inventing them here would
      // show a line that differs from the one everyone else sees.
      await _load();
      if (!mounted) return;
      widget.store.toaster.ok('Note logged');
      // Keep the caret where it was so a second note needs no click.
      _composerFocus.requestFocus();
    } catch (e) {
      if (!mounted) return;
      widget.store.toaster.bad('Could not post: $e');
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _attach() async {
    final PickedFile? file = await pickFile();
    if (file == null) return;
    setState(
      () => _staged.add((name: file.name, b64: base64Encode(file.bytes))),
    );
  }

  /// The lines actually shown, oldest first and filtered by the search box.
  List<ChatterEntry> get _visible {
    final String q = _search.text.trim().toLowerCase();
    final List<ChatterEntry> rows = q.isEmpty
        ? List<ChatterEntry>.of(_entries)
        : _entries
              .where(
                (ChatterEntry e) =>
                    e.text.toLowerCase().contains(q) ||
                    e.author.toLowerCase().contains(q),
              )
              .toList();
    // OLDEST FIRST, newest at the bottom - the order Odoo's chatter uses and
    // the order a conversation reads in. The route returns newest-first
    // because that is what a paged API should do; the display order is a
    // separate decision and it was simply inheriting the wire order.
    return rows.reversed.toList();
  }

  /// The panel's count, honest about paging: "40 of 112 entries" when the
  /// server capped the page, plain "7 entries" when the list is whole. It used
  /// to print the page length alone, so a busy record silently understated its
  /// own history.
  String get _countNote {
    final int shown = _entries.length;
    if (_hasMore && _total > shown) return '$shown of $_total entries';
    final int n = _total > shown ? _total : shown;
    return '$n entr${n == 1 ? 'y' : 'ies'}';
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final List<ChatterEntry> rows = _visible;
    final bool composable =
        widget.store.api != null &&
        widget.canPost &&
        !_loading &&
        _error == null;

    return Panel(
      title: widget.title,
      note: _loading ? 'loading' : _countNote,
      headActions: <Widget>[
        IconBtn(
          _searching ? Icons.search_off : Icons.search,
          tooltip: _searching ? 'Close search' : 'Search the history',
          onPressed: _loading
              ? null
              : () => setState(() {
                  _searching = !_searching;
                  if (!_searching) _search.clear();
                }),
        ),
        IconBtn(
          Icons.open_in_full,
          tooltip: 'Open full screen',
          onPressed: _loading ? null : () => _openFullScreen(context),
        ),
      ],
      child: _body(context, t, rows, composable),
    );
  }

  Widget _body(
    BuildContext context,
    AppTokens t,
    List<ChatterEntry> rows,
    bool composable,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      if (_searching) ...<Widget>[
        TextField(
          controller: _search,
          autofocus: true,
          style: context.type.body.copyWith(fontSize: 13),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Search this history...',
            hintStyle: context.type.bodyMuted,
            prefixIcon: Icon(Icons.search, size: 16, color: t.textMuted),
            border: OutlineInputBorder(
              borderRadius: Radii.input,
              borderSide: BorderSide(color: t.border),
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
      switch ((_loading, _error)) {
        (true, _) => const ChatterSkeleton(),
        (_, final String e?) => Text(e, style: context.type.bodyMuted),
        _ when rows.isEmpty && _search.text.trim().isNotEmpty => Text(
          'Nothing in this history matches "${_search.text.trim()}".',
          style: context.type.bodyMuted,
        ),
        _ when rows.isEmpty => Text(
          'Nothing has been recorded against this record yet.',
          style: context.type.bodyMuted,
        ),
        _ => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < rows.length; i++)
              _Line(entry: rows[i], last: i == rows.length - 1, t: t),
          ],
        ),
      },
      // THE COMPOSER SITS BELOW THE TIMELINE: the history runs oldest-first,
      // so the newest line is directly above this box and what you write
      // next appears where you are already looking.
      if (composable) ...<Widget>[
        const SizedBox(height: 16),
        _Composer(
          controller: _composer,
          focus: _composerFocus,
          posting: _posting,
          staged: _staged,
          onSend: _post,
          onAttach: _attach,
          onDrop: (int i) => setState(() => _staged.removeAt(i)),
          onEmoji: (String e) {
            final TextEditingValue v = _composer.value;
            final int at = v.selection.baseOffset < 0
                ? v.text.length
                : v.selection.baseOffset;
            final String next =
                v.text.substring(0, at) + e + v.text.substring(at);
            _composer.value = TextEditingValue(
              text: next,
              selection: TextSelection.collapsed(offset: at + e.length),
            );
            _composerFocus.requestFocus();
          },
        ),
      ],
    ],
  );

  /// The whole history, full screen: a 380px dock is fine for a glance and
  /// wrong for reading a long trail, which is when an operator needs it.
  void _openFullScreen(BuildContext context) {
    showSheet<void>(
      context,
      wide: true,
      title: widget.title,
      sub: _countNote,
      body: StatefulBuilder(
        builder: (BuildContext ctx, void Function(void Function()) setLocal) =>
            SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.7,
              child: SingleChildScrollView(
                child: _body(ctx, ctx.tokens, _visible, false),
              ),
            ),
      ),
    );
  }
}

/// The message box and its one verb.
///
/// ONE BUTTON: the internal note. The second used to post with
/// `mail.mt_comment`, which emails every follower - a materially different
/// act one keystroke away, so it is left to Odoo. Enter sends, Shift+Enter
/// starts a new line.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focus,
    required this.posting,
    required this.staged,
    required this.onSend,
    required this.onAttach,
    required this.onDrop,
    required this.onEmoji,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final bool posting;
  final List<({String name, String b64})> staged;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final ValueChanged<int> onDrop;
  final ValueChanged<String> onEmoji;

  /// A small, deliberately boring set. A full picker is a package and a
  /// megabyte; these are the ones that get used on a work record.
  static const List<String> emoji = <String>[
    '\u{1F44D}',
    '\u{1F44E}',
    '\u{2705}',
    '\u{274C}',
    '\u{26A0}\u{FE0F}',
    '\u{1F389}',
    '\u{1F525}',
    '\u{1F440}',
    '\u{1F64F}',
    '\u{1F4A1}',
    '\u{1F4CC}',
    '\u{1F680}',
  ];

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Enter sends; Shift+Enter falls through to the field and inserts a
        // newline, which is why this checks the modifier rather than
        // swallowing every Enter.
        Focus(
          onKeyEvent: (FocusNode _, KeyEvent e) {
            final bool isEnter =
                e.logicalKey == LogicalKeyboardKey.enter ||
                e.logicalKey == LogicalKeyboardKey.numpadEnter;
            if (e is! KeyDownEvent || !isEnter) return KeyEventResult.ignored;
            if (HardwareKeyboard.instance.isShiftPressed) {
              return KeyEventResult.ignored;
            }
            if (!posting) onSend();
            return KeyEventResult.handled;
          },
          child: TextField(
            controller: controller,
            focusNode: focus,
            minLines: 2,
            maxLines: 6,
            style: context.type.body,
            cursorColor: t.primary,
            decoration: InputDecoration(
              isDense: true,
              hintText:
                  'Log an internal note...  '
                  '(Enter to log, Shift+Enter for a new line)',
              hintStyle: context.type.bodyMuted,
              filled: true,
              fillColor: t.bgApp,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 9,
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
                borderSide: BorderSide(color: t.primary),
              ),
            ),
          ),
        ),
        if (staged.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (int i = 0; i < staged.length; i++)
                Chip(
                  label: Text(staged[i].name, style: context.type.tiny),
                  onDeleted: posting ? null : () => onDrop(i),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            _EmojiBtn(onPick: onEmoji),
            IconBtn(
              Icons.attach_file,
              tooltip: 'Attach a file',
              onPressed: posting ? null : onAttach,
            ),
            const Spacer(),
            Btn.primary(
              posting ? 'Logging...' : 'Log note',
              size: BtnSize.sm,
              onPressed: posting ? null : onSend,
            ),
          ],
        ),
      ],
    );
  }
}

/// A compact emoji menu that inserts at the caret.
class _EmojiBtn extends StatelessWidget {
  const _EmojiBtn({required this.onPick});

  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Insert an emoji',
    itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
      PopupMenuItem<String>(
        enabled: false,
        child: SizedBox(
          width: 214,
          child: Wrap(
            children: <Widget>[
              for (final String e in _Composer.emoji)
                // The MENU's context: `ctx` is the button's, under the menu.
                Builder(
                  builder: (BuildContext item) => InkWell(
                    onTap: () {
                      if (popIfCurrent(item)) onPick(e);
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text(e, style: const TextStyle(fontSize: 18)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ],
    child: Padding(
      padding: const EdgeInsets.all(6),
      child: Icon(
        Icons.emoji_emotions_outlined,
        size: 18,
        color: context.tokens.textSecondary,
      ),
    ),
  );
}

/// One row of the timeline: a rail, a dot, the text.
class _Line extends StatelessWidget {
  const _Line({required this.entry, required this.last, required this.t});

  final ChatterEntry entry;
  final bool last;
  final AppTokens t;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Column(
            children: <Widget>[
              Container(
                width: 9,
                height: 9,
                margin: const EdgeInsets.only(top: 5),
                decoration: BoxDecoration(
                  color: t.primary,
                  borderRadius: Radii.pill,
                ),
              ),
              // The rail makes the lines read as a sequence; omitted on the
              // last row so the timeline ends rather than trailing off.
              if (!last) Expanded(child: Container(width: 1, color: t.border)),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(entry.text, style: context.type.body),
                  // Shown rather than dropped: an attachment visible in Odoo
                  // and invisible here makes the two accounts disagree.
                  if (entry.attachments.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: <Widget>[
                        for (final ChatterFile f in entry.attachments)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                Icons.attach_file,
                                size: 12,
                                color: t.textSecondary,
                              ),
                              const SizedBox(width: 3),
                              Text(f.name, style: context.type.tiny),
                            ],
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 3),
                  Text(
                    '${entry.author}${entry.date == null ? '' : '  \u00b7  ${istTimestamp(entry.date!)}'}',
                    style: context.type.tiny,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
