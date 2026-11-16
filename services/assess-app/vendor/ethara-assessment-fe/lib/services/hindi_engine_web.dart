/// The web half of Hindi typing: loads Strix's files from `web/hindi/` once and
/// calls `window.EtpHindi` (see `web/hindi/etp_hindi.js`).
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'hindi_engine.dart';

/// In load order: three word lists, Strix's ranking, then our wrapper.
const List<String> _files = <String>[
  'hindi/hindi_dictionary.js',
  'hindi/hindi_english.js',
  'hindi/hindi_romanizations.js',
  'hindi/hindi_typing.js',
  'hindi/etp_hindi.js',
];

@JS('EtpHindi')
external _EtpHindiJs? get _etpHindi;

extension type _EtpHindiJs._(JSObject _) implements JSObject {
  external JSArray<JSString> suggestions(String latin);
  external JSArray<JSString> englishWords(String latin);
}

class _WebHindiEngine implements HindiEngine {
  _WebHindiEngine(this._js);

  final _EtpHindiJs _js;

  @override
  List<String> suggestions(String latin) => <String>[
    for (final JSString s in _js.suggestions(latin).toDart) s.toDart,
  ];

  @override
  List<String> englishWords(String latin) => <String>[
    for (final JSString s in _js.englishWords(latin).toDart) s.toDart,
  ];
}

Future<HindiEngine?>? _loading;

/// The engine, loading it on first use. Null when a file failed to load (a
/// blocked network): the box then says so and the candidate can still type
/// with a Hindi keyboard or the letter panel. A failure is not cached, so the
/// next question tries again.
Future<HindiEngine?> loadHindiEngine() => _loading ??= _load();

Future<HindiEngine?> _load() async {
  try {
    for (final String file in _files) {
      await _script(file);
    }
    final _EtpHindiJs? js = _etpHindi;
    if (js == null) throw StateError('EtpHindi missing');
    return _WebHindiEngine(js);
  } catch (_) {
    _loading = null;
    return null;
  }
}

Future<void> _script(String src) {
  final Completer<void> done = Completer<void>();
  final web.HTMLScriptElement tag = web.HTMLScriptElement()
    ..src = src
    ..async = false;
  tag.onload = (web.Event _) {
    done.complete();
  }.toJS;
  tag.onerror = (web.Event _) {
    tag.remove();
    done.completeError(StateError('failed to load $src'));
  }.toJS;
  web.document.head!.appendChild(tag);
  return done.future;
}

web.EventListener? _pasteListener;

/// Blocks paste anywhere on the page while [on]: the transcription box turns it
/// on while it has focus, so a candidate cannot paste a machine transcription
/// (the client's guide forbids one). The same page-level listener the
/// proctoring copy/paste rule uses.
void blockPaste(bool on, {void Function()? onBlocked}) {
  final web.EventListener? held = _pasteListener;
  if (held != null) {
    web.document.removeEventListener('paste', held);
    _pasteListener = null;
  }
  if (!on) return;
  final web.EventListener listener = (web.Event e) {
    e.preventDefault();
    onBlocked?.call();
  }.toJS;
  _pasteListener = listener;
  web.document.addEventListener('paste', listener);
}
