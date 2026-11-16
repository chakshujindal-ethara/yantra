/// The audio plate, resolved per platform.
///
/// Same shape as `video_plate.dart`: `package:web` cannot compile under the VM
/// test runner, so the browser half hides behind a conditional export and a
/// caller imports only this file. Which of the two plates a clip gets is decided
/// by `clipPlateFor` in `video_plate.dart`, not here.
library;

export 'audio_plate_stub.dart'
    if (dart.library.js_interop) 'audio_plate_web.dart';
