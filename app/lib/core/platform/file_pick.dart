import 'file_pick_stub.dart' if (dart.library.js_interop) 'file_pick_web.dart' as impl;

/// A file the person picked: its name, its type as the browser reports it, and its bytes.
typedef PickedFile = ({String name, String mime, List<int> bytes});

/// Opens the browser's file chooser. Null when the person cancelled. [accept] is the input's accept list
/// (`.jsonl,.csv`, `image/*,application/pdf`).
abstract class FilePicker {
  Future<PickedFile?> pick({String accept = ''});
}

FilePicker platformFilePicker() => impl.create();

/// The picker tests use: hands back [next] (and clears it), or null for "cancelled".
class MemoryFilePicker implements FilePicker {
  PickedFile? next;
  final List<String> asked = [];

  @override
  Future<PickedFile?> pick({String accept = ''}) async {
    asked.add(accept);
    final f = next;
    next = null;
    return f;
  }
}
