import '../core/json.dart';

/// Support tickets (docs/PRODUCT.md 5.6). A missing field reads as empty, never as a throw.

const ticketCategories = ['bug', 'payment', 'work', 'account', 'other'];
const ticketStatuses = ['open', 'in_progress', 'resolved'];

class Ticket {
  const Ticket({
    required this.id,
    required this.authorId,
    required this.category,
    required this.title,
    required this.body,
    required this.screen,
    required this.context,
    required this.status,
    required this.note,
    this.createdAt,
    this.updatedAt,
    this.authorName = '',
  });

  final String id;
  final String authorId;

  /// Who reported it, by name, once talent knows them.
  final String authorName;

  /// `bug`, `payment`, `work`, `account`, `other`.
  final String category;
  final String title;
  final String body;

  /// The page the person was on when they reported it.
  final String screen;
  final Json context;

  /// `open`, `in_progress`, `resolved`.
  final String status;

  /// What ops wrote when they moved it.
  final String note;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isOpen => status == 'open';
  bool get isInProgress => status == 'in_progress';
  bool get isResolved => status == 'resolved';

  factory Ticket.fromJson(Json m) => Ticket(
    id: readString(m, 'id'),
    authorId: readString(m, 'author_id'),
    category: readString(m, 'category'),
    title: readString(m, 'title'),
    body: readString(m, 'body'),
    screen: readString(m, 'screen'),
    context: readMap(m, 'context'),
    status: readString(m, 'status'),
    note: readString(m, 'note'),
    createdAt: readDateTime(m, 'created_at'),
    updatedAt: readDateTime(m, 'updated_at'),
    authorName: readString(m, 'author_name'),
  );

  /// True when [q] (lower case) is in the title, body, author name, page or category.
  bool matches(String q) => q.isEmpty || [title, body, authorName, screen, category].any((f) => f.toLowerCase().contains(q));
}

/// What a person sends to open a ticket.
class TicketInput {
  const TicketInput({required this.category, required this.title, required this.body, required this.screen, this.context = const {}});

  final String category;
  final String title;
  final String body;
  final String screen;
  final Json context;

  Json toJson() => {'category': category, 'title': title, 'body': body, 'screen': screen, 'context': context};
}
