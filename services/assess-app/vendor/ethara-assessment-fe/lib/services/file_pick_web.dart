import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'file_pick_stub.dart' show PickedFile;

export 'file_pick_stub.dart' show PickedFile;

/// Opens the browser's file chooser and returns the chosen file's bytes.
///
/// Returns null when the user cancels. There is no reliable cancel event on
/// `<input type=file>`, so a cancelled dialog simply never completes the
/// change listener - the caller sees the future settle only on a real pick,
/// via the `cancel` event where the browser supports it.
///
/// Bytes rather than a data URL: the API takes base64 in a JSON body, and
/// re-encoding a data URL means holding the file twice in memory and stripping
/// a prefix. `FileReader.readAsArrayBuffer` gives the raw bytes directly.
Future<PickedFile?> pickFile({String accept = ''}) {
  final Completer<PickedFile?> done = Completer<PickedFile?>();

  final web.HTMLInputElement input =
      web.document.createElement('input') as web.HTMLInputElement
        ..type = 'file'
        ..accept = accept
        ..style.display = 'none';

  void finish(PickedFile? value) {
    if (!done.isCompleted) done.complete(value);
    input.remove();
  }

  input.onchange = (web.Event _) {
    final web.FileList? files = input.files;
    if (files == null || files.length == 0) {
      finish(null);
      return;
    }
    final web.File file = files.item(0)!;
    final web.FileReader reader = web.FileReader();

    reader.onload = (web.Event _) {
      final JSAny? result = reader.result;
      if (result == null) {
        finish(null);
        return;
      }
      final ByteBuffer buffer = (result as JSArrayBuffer).toDart;
      finish(PickedFile(file.name, buffer.asUint8List()));
    }.toJS;

    // A read failure is reported as "cancelled" rather than thrown: the caller
    // treats null as "no file", and a browser that cannot read a file the user
    // just chose is not something the UI can act on differently.
    reader.onerror = (web.Event _) {
      finish(null);
    }.toJS;
    reader.readAsArrayBuffer(file);
  }.toJS;

  // Supported in Chrome/Edge/Firefox; where it is missing the future simply
  // stays pending on a cancel, which is harmless - the sheet stays open.
  input.addEventListener('cancel', ((web.Event _) => finish(null)).toJS);

  web.document.body!.appendChild(input);
  input.click();
  return done.future;
}
