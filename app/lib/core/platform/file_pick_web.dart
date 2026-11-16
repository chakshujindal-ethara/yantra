import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'file_pick.dart';

FilePicker create() => _WebFilePicker();

class _WebFilePicker implements FilePicker {
  @override
  Future<PickedFile?> pick({String accept = ''}) {
    final done = Completer<PickedFile?>();
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = accept
      ..style.display = 'none';
    input.addEventListener(
      'change',
      ((web.Event _) {
        final file = input.files?.item(0);
        input.remove();
        if (file == null) {
          done.complete(null);
          return;
        }
        file.arrayBuffer().toDart.then(
          (buffer) => done.complete((name: file.name, mime: file.type, bytes: buffer.toDart.asUint8List())),
          onError: (Object e) => done.completeError(e),
        );
      }).toJS,
    );
    input.addEventListener(
      'cancel',
      ((web.Event _) {
        input.remove();
        if (!done.isCompleted) done.complete(null);
      }).toJS,
    );
    web.document.body?.append(input);
    input.click();
    return done.future;
  }
}
