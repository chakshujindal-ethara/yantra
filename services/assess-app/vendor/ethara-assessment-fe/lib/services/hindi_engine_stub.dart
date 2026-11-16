/// The non-web half of Hindi typing: no browser, so no engine.
///
/// A VM test passes its own [HindiEngine] to the transcription box instead.
/// Every public name here must match `hindi_engine_web.dart`.
library;

import 'hindi_engine.dart';

Future<HindiEngine?> loadHindiEngine() async => null;

/// Turns the page-wide paste block on or off. Nothing to block off the web.
void blockPaste(bool on, {void Function()? onBlocked}) {}
