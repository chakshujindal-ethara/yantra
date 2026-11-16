/// Hindi typing for the Transcription question, resolved per platform.
///
/// The words come from the Strix workbench's own engine (`web/hindi/`): the
/// English letters a candidate types (mera) are offered as Devanagari (मेरा),
/// ranked against a 122,184-word list. Nothing is a model and nothing leaves
/// the browser. The files are 0.85 MB gzipped, so they load only when an exam
/// or a form actually has a Hindi Transcription question.
library;

export 'hindi_engine_stub.dart'
    if (dart.library.js_interop) 'hindi_engine_web.dart';

/// What the transcription box asks of the engine.
abstract interface class HindiEngine {
  /// Up to five spellings for one typed word, best first. The English letters
  /// as typed are always one of them (first when the word stays English).
  List<String> suggestions(String latin);

  /// English words starting with [latin], most common first; empty when the
  /// letters already spell a Hindi word.
  List<String> englishWords(String latin);
}
