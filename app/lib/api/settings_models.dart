import '../core/json.dart';

/// Wire shapes of the Settings page (ops): client organisations, policies, reason codes, tracker caps and
/// erasure requests. A missing field is empty, never a throw.

/// A client organisation and the user ids of its members (`GET /v1/client-orgs`).
class OrgRow {
  const OrgRow({required this.id, required this.name, required this.members, this.createdAt});
  final String id;
  final String name;
  final List<String> members;
  final DateTime? createdAt;

  factory OrgRow.fromJson(Json m) => OrgRow(
    id: readString(m, 'id'),
    name: readString(m, 'name'),
    members: readList(m, 'members').map((x) => '$x').toList(),
    createdAt: readDateTime(m, 'created_at'),
  );
}

/// One titled part of a policy.
class PolicyPart {
  const PolicyPart(this.title, {this.paragraphs = const [], this.bullets = const []});
  final String title;
  final List<String> paragraphs;
  final List<String> bullets;

  factory PolicyPart.fromJson(Json m) => PolicyPart(
    readString(m, 'title'),
    paragraphs: readList(m, 'paragraphs').map((x) => '$x').toList(),
    bullets: readList(m, 'bullets').map((x) => '$x').toList(),
  );

  Json toJson() => {'title': title, 'paragraphs': paragraphs, 'bullets': bullets};
}

/// A policy at its latest revision (`GET /v1/talent/policies`). [version] is the label workers accept.
class PolicyDoc {
  const PolicyDoc({
    required this.slug,
    required this.version,
    required this.revision,
    required this.title,
    required this.summary,
    required this.sections,
    this.updatedAt,
  });

  final String slug;
  final String version;
  final int revision;
  final String title;
  final String summary;
  final List<PolicyPart> sections;
  final DateTime? updatedAt;

  factory PolicyDoc.fromJson(Json m) => PolicyDoc(
    slug: readString(m, 'slug'),
    version: readString(m, 'version'),
    revision: readInt(m, 'revision'),
    title: readString(m, 'title'),
    summary: readString(m, 'summary'),
    sections: readList(m, 'sections').whereType<Map>().map((x) => PolicyPart.fromJson(Map<String, dynamic>.from(x))).toList(),
    updatedAt: readDateTime(m, 'updated_at'),
  );
}

/// The sections as editable text: `## Title` starts a section, `- ` a bullet, a blank line ends a paragraph.
String sectionsToText(List<PolicyPart> parts) => [
  for (final p in parts)
    [
      '## ${p.title}',
      ...p.paragraphs.expand((x) => [x, '']),
      ...p.bullets.map((b) => '- $b'),
    ].join('\n').trim(),
].join('\n\n');

/// The inverse of [sectionsToText]. Text before the first `## ` heading is ignored; a section with no
/// heading text is dropped.
List<PolicyPart> sectionsFromText(String text) {
  final parts = <PolicyPart>[];
  String? title;
  var paragraphs = <String>[], bullets = <String>[], buffer = <String>[];
  void flushParagraph() {
    if (buffer.isNotEmpty) paragraphs.add(buffer.join(' '));
    buffer = [];
  }

  void flushSection() {
    flushParagraph();
    final heading = title ?? '';
    if (heading.isNotEmpty) parts.add(PolicyPart(heading, paragraphs: paragraphs, bullets: bullets));
    paragraphs = [];
    bullets = [];
  }

  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line == '##' || line.startsWith('## ')) {
      flushSection();
      title = line.substring(2).trim();
    } else if (title == null) {
      continue;
    } else if (line.startsWith('- ')) {
      flushParagraph();
      bullets.add(line.substring(2).trim());
    } else if (line.isEmpty) {
      flushParagraph();
    } else {
      buffer.add(line);
    }
  }
  flushSection();
  return parts;
}

/// A reason code reviewers pick (`GET /v1/quality/reasons?all=true`).
class ReasonRow {
  const ReasonRow({
    required this.code,
    required this.label,
    required this.detail,
    required this.billable,
    required this.appliesTo,
    required this.sort,
    required this.active,
  });

  final String code;
  final String label;
  final String detail;
  final bool billable;

  /// `needs_edits` and/or `reject`.
  final List<String> appliesTo;
  final int sort;
  final bool active;

  factory ReasonRow.fromJson(Json m) => ReasonRow(
    code: readString(m, 'code'),
    label: readString(m, 'label'),
    detail: readString(m, 'detail'),
    billable: readBool(m, 'billable'),
    appliesTo: readList(m, 'applies_to').map((x) => '$x').toList(),
    sort: readInt(m, 'sort'),
    active: m['active'] is bool ? m['active'] as bool : true,
  );

  Json toJson() => {'label': label, 'detail': detail, 'billable': billable, 'applies_to': appliesTo, 'sort': sort, 'active': active};
}

/// A weekly hour cap on a worker or a project (`GET /v1/tracker/caps`).
class CapRow {
  const CapRow({required this.scope, required this.scopeId, required this.weeklyCapHours, this.updatedAt});
  final String scope;
  final String scopeId;
  final String weeklyCapHours;
  final DateTime? updatedAt;

  factory CapRow.fromJson(Json m) => CapRow(
    scope: readString(m, 'scope'),
    scopeId: readString(m, 'scope_id'),
    weeklyCapHours: readString(m, 'weekly_cap_hours'),
    updatedAt: readDateTime(m, 'updated_at'),
  );
}

/// A worker's request to erase their personal data (`GET /v1/talent/erasures`).
class ErasureRow {
  const ErasureRow({required this.workerId, required this.status, this.requestedAt, this.dueAt, this.approvedBy = '', this.doneAt});
  final String workerId;

  /// `requested`, `approved` or `done`.
  final String status;
  final DateTime? requestedAt;
  final DateTime? dueAt;
  final String approvedBy;
  final DateTime? doneAt;

  factory ErasureRow.fromJson(Json m) => ErasureRow(
    workerId: readString(m, 'worker_id'),
    status: readString(m, 'status'),
    requestedAt: readDateTime(m, 'requested_at'),
    dueAt: readDateTime(m, 'due_at'),
    approvedBy: readString(m, 'approved_by'),
    doneAt: readDateTime(m, 'done_at'),
  );
}
