/// The transcription text box: Hindi typing, the Devanagari letters panel, and
/// the marker and backchannel buttons of the client's guide.
///
/// Ported from the Strix workbench (custom_addons/strix/static/src/workbench):
/// the candidate types Hindi in English letters and each word becomes
/// Devanagari when they press space; 1-5 pick another spelling, Esc keeps the
/// English letters, Tab takes the English word, Enter takes the first spelling
/// with no space. The spellings come from Strix's own engine
/// (`services/hindi_engine.dart`). Form Studio uses the same box, without the
/// buttons, for the correct transcription.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/hindi_engine.dart';
import '../../domain/transcription.dart';
import '../../theme.dart';
import 'clip_controls.dart';

/// [text] with every Devanagari digit (०-९) as its English digit (0-9). A
/// number in a transcription is written in English digits only.
String englishDigits(String text) => text.replaceAllMapped(
  RegExp('[०-९]'),
  (Match m) => '${m[0]!.codeUnitAt(0) - 0x0966}',
);

/// The English-letter word that ends at [end] in [text], or null when [end] is
/// inside a word (letters follow it) or no English letter precedes it.
({int start, String latin})? latinWordBefore(String text, int end) {
  if (end < 0 || end > text.length) return null;
  if (end < text.length && RegExp(r'[A-Za-z]').hasMatch(text[end])) return null;
  final RegExpMatch? m = RegExp(
    r"[A-Za-z']*[A-Za-z]$",
  ).firstMatch(text.substring(0, end));
  return m == null ? null : (start: m.start, latin: m.group(0)!);
}

/// What a key typed straight after an English-letter word does with Hindi
/// typing on: space and Enter take the first spelling (space keeps its space),
/// 1-5 take that spelling. Anything else, or a word Esc kept in English, is
/// left exactly as typed. Pure, so it is tested without a browser.
TextEditingValue convertHindiWord(
  TextEditingValue before,
  TextEditingValue after,
  List<String> Function(String latin) suggest, {
  int? keptAt,
}) {
  if (after.composing.isValid && !after.composing.isCollapsed) return after;
  final TextSelection sel = after.selection;
  if (!sel.isValid || !sel.isCollapsed) return after;
  if (after.text.length != before.text.length + 1) return after;
  final int caret = sel.baseOffset;
  if (caret < 1) return after;
  final String typed = after.text[caret - 1];
  if (before.text !=
      after.text.substring(0, caret - 1) + after.text.substring(caret)) {
    return after;
  }
  final int pick = typed == ' ' || typed == '\n'
      ? 0
      : (RegExp(r'^[1-5]$').hasMatch(typed) ? int.parse(typed) - 1 : -1);
  if (pick < 0) return after;
  final ({int start, String latin})? word = latinWordBefore(
    before.text,
    caret - 1,
  );
  if (word == null || word.start == keptAt) return after;
  final List<String> options = suggest(word.latin);
  if (pick >= options.length) return after;
  final String insert = options[pick] + (typed == '\n' ? '' : ' ');
  final String head = before.text.substring(0, word.start);
  final String text = head + insert + before.text.substring(caret - 1);
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: head.length + insert.length),
  );
}

class TranscriptionBox extends StatefulWidget {
  const TranscriptionBox({
    super.key,
    required this.language,
    required this.initialText,
    required this.onChanged,
    this.readOnly = false,
    this.tools = true,
    this.blockPaste = false,
    this.controls,
    this.engine,
    this.minLines = 6,
    this.label,
  });

  /// 'hi' (Devanagari, with Hindi typing) or 'en' (small English letters).
  final String language;
  final String initialText;
  final ValueChanged<String> onChanged;
  final bool readOnly;

  /// The letters panel, the marker and backchannel buttons and the guide's
  /// one-line reminders. The exam shows them; Form Studio does not.
  final bool tools;

  /// The exam blocks paste while the box has focus: a pasted transcription is
  /// a machine one, which the client's guide forbids. An author pastes freely.
  final bool blockPaste;

  /// The clip, for Esc as play/pause when no spelling is offered.
  final ClipControls? controls;

  /// A test's engine. Otherwise the browser's is loaded on first use.
  final HindiEngine? engine;
  final int minLines;
  final String? label;

  @override
  State<TranscriptionBox> createState() => _TranscriptionBoxState();
}

class _TranscriptionBoxState extends State<TranscriptionBox> {
  late final TextEditingController _c = TextEditingController(
    text: widget.initialText,
  );
  late final FocusNode _focus = FocusNode()..addListener(_onFocus);

  HindiEngine? _engine;
  bool _loading = false;
  bool _typing = true;
  bool _letters = false;

  /// A word Esc kept in English letters, by where it starts.
  int? _keptAt;

  ({int start, String latin})? _word;
  List<String> _options = const <String>[];
  List<String> _english = const <String>[];
  String _sent = '';

  bool get _hindi => widget.language == 'hi';
  bool get _typingOn =>
      _hindi && _typing && _engine != null && !widget.readOnly;

  @override
  void initState() {
    super.initState();
    _sent = widget.initialText;
    _c.addListener(_onText);
    _engine = widget.engine;
    if (_hindi && _engine == null) _load();
  }

  @override
  void didUpdateWidget(TranscriptionBox old) {
    super.didUpdateWidget(old);
    if (_hindi && _engine == null && !_loading) _load();
    if (!_hindi) {
      _word = null;
      _options = const <String>[];
      _english = const <String>[];
    }
  }

  Future<void> _load() async {
    _loading = true;
    final HindiEngine? engine = await loadHindiEngine();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _engine = engine;
    });
  }

  @override
  void dispose() {
    if (_focus.hasFocus && widget.blockPaste) blockPaste(false);
    _focus.dispose();
    _c.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (!widget.blockPaste || widget.readOnly) return;
    blockPaste(
      _focus.hasFocus,
      onBlocked: () {
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('Paste is off in this box: type what you hear.'),
          ),
        );
      },
    );
  }

  void _onText() {
    if (_c.text != _sent) {
      _sent = _c.text;
      widget.onChanged(_c.text);
    }
    _refresh();
  }

  /// Recompute the spellings offered for the word at the caret.
  void _refresh() {
    final TextSelection sel = _c.selection;
    final ({int start, String latin})? word =
        _typingOn && sel.isValid && sel.isCollapsed
        ? latinWordBefore(_c.text, sel.baseOffset)
        : null;
    // Esc keeps ONE word in English letters; the next word is offered again.
    if (word?.start != _keptAt) _keptAt = null;
    _setWord(word == null || word.start == _keptAt ? null : word);
  }

  void _setWord(({int start, String latin})? word) {
    if (word?.start == _word?.start && word?.latin == _word?.latin) return;
    final HindiEngine? e = _engine;
    setState(() {
      _word = word;
      _options = word == null || e == null
          ? const <String>[]
          : e.suggestions(word.latin);
      _english = word == null || e == null
          ? const <String>[]
          : e.englishWords(word.latin);
    });
  }

  /// Put [text] in place of the word at the caret, with a space after it.
  void _take(String text) {
    final ({int start, String latin})? word = _word;
    if (word == null) return;
    final int end = word.start + word.latin.length;
    final String head = _c.text.substring(0, word.start);
    final String insert = '$text ';
    _keptAt = null;
    _c.value = TextEditingValue(
      text: head + insert + _c.text.substring(end),
      selection: TextSelection.collapsed(offset: head.length + insert.length),
    );
    _focus.requestFocus();
  }

  /// Insert [text] at the caret with a space either side as needed; with
  /// [caretBack], the caret lands that many characters back (inside a marker).
  void _insert(String text, {int caretBack = 0}) {
    final TextSelection sel = _c.selection.isValid
        ? _c.selection
        : TextSelection.collapsed(offset: _c.text.length);
    final String v = _c.text;
    final String pre =
        sel.start > 0 && !RegExp(r'\s$').hasMatch(v.substring(0, sel.start))
        ? ' '
        : '';
    final String post =
        caretBack > 0 || RegExp(r'^\s').hasMatch(v.substring(sel.end))
        ? ''
        : ' ';
    final String out = pre + text + post;
    _c.value = TextEditingValue(
      text: v.substring(0, sel.start) + out + v.substring(sel.end),
      selection: TextSelection.collapsed(
        offset: sel.start + out.length - caretBack,
      ),
    );
    _focus.requestFocus();
  }

  /// `((word))` / `{{word}}`: wrap the selection, or leave the caret inside.
  void _wrap(String open, String close) {
    final TextSelection sel = _c.selection;
    if (!sel.isValid || sel.isCollapsed) {
      _insert(open + close, caretBack: close.length);
      return;
    }
    final String v = _c.text;
    final String out = open + v.substring(sel.start, sel.end) + close;
    _c.value = TextEditingValue(
      text: v.substring(0, sel.start) + out + v.substring(sel.end),
      selection: TextSelection.collapsed(offset: sel.start + out.length),
    );
    _focus.requestFocus();
  }

  /// A letter from the panel goes in exactly as clicked, no spaces.
  void _letter(String letter) {
    final TextSelection sel = _c.selection.isValid
        ? _c.selection
        : TextSelection.collapsed(offset: _c.text.length);
    final String v = _c.text;
    _c.value = TextEditingValue(
      text: v.substring(0, sel.start) + letter + v.substring(sel.end),
      selection: TextSelection.collapsed(offset: sel.start + letter.length),
    );
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final ({int start, String latin})? word = _word;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      if (word != null) {
        _keptAt = word.start;
        _setWord(null);
        return KeyEventResult.handled;
      }
      final ClipControls? c = widget.controls;
      if (c != null) {
        c.togglePlay();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (e.logicalKey == LogicalKeyboardKey.tab &&
        word != null &&
        _english.isNotEmpty &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _take(_english.first);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final String label =
        widget.label ??
        (_hindi
            ? 'Transcription (Devanagari)'
            : 'Transcription (small English letters)');
    return TextFieldTapRegion(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 6,
            children: <Widget>[
              Text(label.toUpperCase(), style: context.type.fieldLabel),
              if (_hindi && !widget.readOnly)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _Tick(
                      label: 'Hindi typing',
                      checked: _typing,
                      onChanged: (bool v) {
                        setState(() => _typing = v);
                        _refresh();
                        _focus.requestFocus();
                      },
                    ),
                    if (widget.tools) ...<Widget>[
                      const SizedBox(width: 12),
                      OutlinedButton(
                        onPressed: () => setState(() => _letters = !_letters),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _letters ? t.primary : t.textPrimary,
                          backgroundColor: _letters ? t.primarySubtle : null,
                          side: BorderSide(
                            color: _letters ? t.borderHover : t.border,
                          ),
                          shape: const RoundedRectangleBorder(
                            borderRadius: Radii.button,
                          ),
                        ),
                        child: const Text('Devanagari letters'),
                      ),
                    ],
                  ],
                ),
            ],
          ),
          const SizedBox(height: 8),
          Focus(
            onKeyEvent: _onKey,
            // The label above is a separate Text, so the field itself is named
            // here for a screen reader.
            child: Semantics(
              label: label,
              child: TextField(
                controller: _c,
                focusNode: _focus,
                readOnly: widget.readOnly,
                minLines: widget.minLines,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                // 8000 is where the server truncates an answer; refusing the
                // next keystroke here beats losing the end of a long clip.
                maxLength: 8000,
                maxLengthEnforcement: MaxLengthEnforcement.enforced,
                autocorrect: false,
                enableSuggestions: false,
                smartQuotesType: SmartQuotesType.disabled,
                smartDashesType: SmartDashesType.disabled,
                inputFormatters: <TextInputFormatter>[
                  // Numbers in English digits only: a Hindi keyboard's ०-९
                  // become 0-9 as they are typed (one character for one, so
                  // the caret does not move).
                  TextInputFormatter.withFunction(
                    (TextEditingValue before, TextEditingValue after) =>
                        after.copyWith(text: englishDigits(after.text)),
                  ),
                  TextInputFormatter.withFunction(
                    (TextEditingValue before, TextEditingValue after) =>
                        _typingOn
                        ? convertHindiWord(
                            before,
                            after,
                            _engine!.suggestions,
                            keptAt: _keptAt,
                          )
                        : after,
                  ),
                ],
                style: context.type.body.copyWith(fontSize: 17, height: 1.6),
                cursorColor: t.primary,
                // NO HINT TEXT in a box a candidate answers in (owner,
                // 2026-09-29): a placeholder is a suggestion of what to write.
                decoration: InputDecoration(
                  counterText: '',
                  filled: true,
                  fillColor: t.bgApp,
                  contentPadding: const EdgeInsets.all(14),
                  border: OutlineInputBorder(
                    borderRadius: Radii.option,
                    borderSide: BorderSide(color: t.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: Radii.option,
                    borderSide: BorderSide(color: t.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: Radii.option,
                    borderSide: BorderSide(color: t.primary.o(.55)),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          // Listens to the text itself: the box only rebuilds when the
          // offered spellings change, so a count read in build went stale.
          ListenableBuilder(
            listenable: _c,
            builder: (BuildContext context, _) {
              final String text = _c.text.trim();
              final int words = text.isEmpty
                  ? 0
                  : text.split(RegExp(r'\s+')).length;
              return Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '$words word${words == 1 ? '' : 's'}',
                  style: context.type.tiny,
                ),
              );
            },
          ),
          // ALWAYS PRESENT, in a semantics container of its own. When the row
          // came and went as a plain sibling, a screen reader's tree around the
          // box was rebuilt each time an English row vanished, the box's own
          // input element with it, and the caret was lost mid-sentence.
          Semantics(
            container: true,
            liveRegion: true,
            child: _word != null && _options.isNotEmpty
                ? _Suggestions(
                    latin: _word!.latin,
                    options: _options,
                    english: _english,
                    onPick: _take,
                  )
                : const SizedBox(width: double.infinity),
          ),
          if (_hindi && widget.tools && _letters && !widget.readOnly)
            _LettersPanel(onLetter: _letter),
          if (widget.tools && !widget.readOnly) ...<Widget>[
            const SizedBox(height: 8),
            Text(_hint(), style: context.type.small.copyWith(height: 1.5)),
            const SizedBox(height: 8),
            _ChipRow(
              label: 'Markers',
              chips: <(String, String, VoidCallback)>[
                for (final (String m, String what) in kTranscriptionMarkers)
                  (
                    '$m  $what',
                    what,
                    () => switch (m) {
                      '((word))' => _wrap('((', '))'),
                      '{{word}}' => _wrap('{{', '}}'),
                      _ => _insert(m),
                    },
                  ),
              ],
            ),
            _ChipRow(
              label: 'Backchannels: use these exact spellings',
              chips: <(String, String, VoidCallback)>[
                for (final (String b, String meaning) in backchannelsFor(
                  widget.language,
                ))
                  (b, meaning, () => _insert(b)),
              ],
            ),
            Text(
              'elev-  cut off  ·  a. b. c.  spelled letters',
              style: context.type.monoSmall,
            ),
          ] else if (_hindi && !widget.readOnly && _engine == null) ...<Widget>[
            const SizedBox(height: 6),
            Text(_hint(), style: context.type.tiny),
          ],
        ],
      ),
    );
  }

  String _hint() {
    final String paste = widget.blockPaste ? ' Paste is off in this box.' : '';
    if (!_hindi) {
      return 'Small letters only, numbers as words, no punctuation.$paste';
    }
    if (_loading) return 'Loading Hindi typing...$paste';
    if (_engine == null) {
      return 'Hindi typing could not load: type with a Hindi keyboard, or '
          'click the Devanagari letters.$paste';
    }
    if (!_typing) {
      return 'Hindi typing is off: type with a Hindi keyboard, or click the '
          'Devanagari letters.$paste';
    }
    // Esc is not advertised: in a fullscreen exam outside Chrome it leaves
    // fullscreen, a proctoring violation. The English letters are always one
    // of the numbered spellings, so a number keeps them.
    return 'Type Hindi in English letters (mera naam): each word becomes '
        'Devanagari (मेरा नाम) when you press space. Press 1 to 5 for another '
        'spelling (the English letters are one of them), or Tab for the '
        'English word.$paste';
  }
}

class _Tick extends StatelessWidget {
  const _Tick({
    required this.label,
    required this.checked,
    required this.onChanged,
  });

  final String label;
  final bool checked;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: Radii.button,
    onTap: () => onChanged(!checked),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(
              value: checked,
              onChanged: (bool? v) => onChanged(v ?? false),
              activeColor: context.tokens.primary,
              semanticLabel: label,
            ),
          ),
          const SizedBox(width: 6),
          Text(label, style: context.type.bodySecondary),
        ],
      ),
    ),
  );
}

/// The spellings for the word at the caret: English words first (Tab takes
/// the first), then the numbered Devanagari options (space takes 1).
class _Suggestions extends StatelessWidget {
  const _Suggestions({
    required this.latin,
    required this.options,
    required this.english,
    required this.onPick,
  });

  final String latin;
  final List<String> options;
  final List<String> english;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    Widget chip(String text, {String? number, bool first = false}) =>
        OutlinedButton(
          onPressed: () => onPick(text),
          style: OutlinedButton.styleFrom(
            foregroundColor: t.textPrimary,
            backgroundColor: first ? t.primarySubtle : t.bgApp,
            side: BorderSide(color: first ? t.borderHover : t.border),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(0, 34),
            shape: const RoundedRectangleBorder(borderRadius: Radii.button),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (number != null) ...<Widget>[
                Text(number, style: context.type.monoSmall),
                const SizedBox(width: 6),
              ],
              Text(text, style: context.type.body.copyWith(fontSize: 16)),
            ],
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          if (english.isNotEmpty) ...<Widget>[
            Text('English', style: context.type.tiny),
            for (final String w in english) chip(w),
            const SizedBox(width: 10),
          ],
          Text('$latin →', style: context.type.tiny),
          for (int i = 0; i < options.length; i++)
            chip(options[i], number: '${i + 1}', first: i == 0),
        ],
      ),
    );
  }
}

class _LettersPanel extends StatelessWidget {
  const _LettersPanel({required this.onLetter});

  final ValueChanged<String> onLetter;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: t.border),
        borderRadius: Radii.option,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final (String group, String letters) in kDevanagariLetters)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  SizedBox(
                    width: 92,
                    child: Text(group, style: context.type.tiny),
                  ),
                  for (final String l in letters.split(' '))
                    SizedBox(
                      width: 38,
                      height: 38,
                      child: OutlinedButton(
                        onPressed: () => onLetter(l),
                        style: OutlinedButton.styleFrom(
                          padding: EdgeInsets.zero,
                          foregroundColor: t.textPrimary,
                          backgroundColor: t.bgSubtle,
                          side: BorderSide(color: t.borderSubtle),
                          shape: const RoundedRectangleBorder(
                            borderRadius: Radii.button,
                          ),
                        ),
                        child: Text(
                          l,
                          style: context.type.body.copyWith(fontSize: 18),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ChipRow extends StatelessWidget {
  const _ChipRow({required this.label, required this.chips});

  final String label;

  /// (text on the chip, what it means, what it does).
  final List<(String, String, VoidCallback)> chips;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Text(label, style: context.type.bodySecondary),
          for (final (String text, String meaning, VoidCallback onTap) in chips)
            Tooltip(
              message: meaning,
              child: OutlinedButton(
                onPressed: onTap,
                style: OutlinedButton.styleFrom(
                  foregroundColor: t.textPrimary,
                  side: BorderSide(color: t.border),
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: const StadiumBorder(),
                ),
                child: Text(
                  text,
                  style: context.type.body.copyWith(fontSize: 15),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
