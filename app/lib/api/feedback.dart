import '../core/json.dart';

/// One note of a project's feedback thread (`ProjectDetail.feedback`, `ClientProjectDetail.feedback`, the
/// answer of `POST …/feedback`). [authorKind] `staff` is a Yantra answer, `client` the client's note.
class FeedbackEntry {
  const FeedbackEntry({
    required this.id,
    required this.authorId,
    required this.body,
    this.authorName = '',
    this.authorKind = 'client',
    this.createdAt,
  });

  final String id;
  final String authorId;
  final String authorName;
  final String authorKind;
  final String body;
  final DateTime? createdAt;

  bool get fromStaff => authorKind == 'staff';

  factory FeedbackEntry.fromJson(Json m) => FeedbackEntry(
    id: readString(m, 'id'),
    authorId: readString(m, 'author_id'),
    authorName: readString(m, 'author_name'),
    authorKind: readString(m, 'author_kind').isEmpty ? 'client' : readString(m, 'author_kind'),
    body: readString(m, 'body'),
    createdAt: readDateTime(m, 'created_at'),
  );
}
