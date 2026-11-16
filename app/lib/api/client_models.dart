import '../core/json.dart';
import 'feedback.dart';

export 'feedback.dart' show FeedbackEntry;

/// Wire shapes of the client console (docs/PRODUCT.md 5.1, the `/v1/client/...` rows). Prices only: a
/// client never sees a pay rate, and nothing here reads one. A missing field is empty, never a throw.

double _double(Json m, String key) {
  final v = m[key];
  return v is num ? v.toDouble() : (v is String ? double.tryParse(v) ?? 0 : 0);
}

/// `0.83` or `83` both read as 83 percent.
int _percent(double v) => (v <= 1 ? v * 100 : v).round();

/// Units by stage: the `units: {...counts}` block every project and batch carries.
class UnitCounts {
  const UnitCounts({
    required this.total,
    required this.available,
    required this.claimed,
    required this.submitted,
    required this.inReview,
    required this.accepted,
    required this.rejected,
    required this.needsEdits,
  });

  final int total;
  final int available;
  final int claimed;
  final int submitted;
  final int inReview;
  final int accepted;
  final int rejected;
  final int needsEdits;

  /// Claimed or submitted: someone is on it.
  int get inProgress => claimed + submitted;

  static const none = UnitCounts(total: 0, available: 0, claimed: 0, submitted: 0, inReview: 0, accepted: 0, rejected: 0, needsEdits: 0);

  factory UnitCounts.fromJson(Json m) => UnitCounts(
    total: readInt(m, 'total'),
    available: readInt(m, 'available'),
    claimed: readInt(m, 'claimed'),
    submitted: readInt(m, 'submitted'),
    inReview: readInt(m, 'in_review'),
    accepted: readInt(m, 'accepted'),
    rejected: readInt(m, 'rejected'),
    needsEdits: readInt(m, 'needs_edits'),
  );
}

class ClientOrg {
  const ClientOrg({required this.id, required this.name});
  final String id;
  final String name;

  factory ClientOrg.fromJson(Json m) => ClientOrg(id: readString(m, 'id'), name: readString(m, 'name'));
}

/// The open batch due first across the client's projects (`next_delivery` on the overview).
class NextDelivery {
  const NextDelivery({
    required this.batchId,
    required this.title,
    required this.projectId,
    required this.projectName,
    required this.accepted,
    required this.total,
    this.dueAt,
  });

  final String batchId;
  final String title;
  final String projectId;
  final String projectName;
  final DateTime? dueAt;
  final int accepted;
  final int total;

  factory NextDelivery.fromJson(Json m) => NextDelivery(
    batchId: readString(m, 'batch_id'),
    title: readString(m, 'title'),
    projectId: readString(m, 'project_id'),
    projectName: readString(m, 'project_name'),
    dueAt: readDateTime(m, 'due_at'),
    accepted: readInt(m, 'accepted'),
    total: readInt(m, 'total'),
  );
}

/// A presigned link to one stored file and when it stops working.
class FileLink {
  const FileLink({required this.url, this.expiresAt});
  final String url;
  final DateTime? expiresAt;

  factory FileLink.fromJson(Json m) => FileLink(url: readString(m, 'url'), expiresAt: readDateTime(m, 'expires_at'));
}

/// `GET …/batches/{id}/deliverable`: the delivery as files, `units.jsonl` (one accepted unit per line)
/// and `manifest.json`, each behind a five-minute link to object storage.
class Deliverable {
  const Deliverable({
    required this.manifestId,
    required this.batchId,
    required this.digest,
    required this.jsonl,
    required this.manifest,
    required this.sha256,
    required this.bytes,
    required this.lineCount,
  });

  final String manifestId;
  final String batchId;
  final String digest;
  final FileLink jsonl;
  final FileLink manifest;
  final String sha256;
  final int bytes;
  final int lineCount;

  factory Deliverable.fromJson(Json m) {
    final jsonl = readMap(m, 'jsonl');
    return Deliverable(
      manifestId: readString(m, 'manifest_id'),
      batchId: readString(m, 'batch_id'),
      digest: readString(m, 'digest'),
      jsonl: FileLink.fromJson(jsonl),
      manifest: FileLink.fromJson(readMap(m, 'manifest')),
      sha256: readString(jsonl, 'sha256'),
      bytes: readInt(jsonl, 'bytes'),
      lineCount: readInt(jsonl, 'line_count'),
    );
  }
}

/// `GET /v1/client/overview`, across the caller's orgs.
class ClientOverview {
  const ClientOverview({
    required this.orgs,
    required this.units,
    required this.acceptanceRate,
    required this.billableRework,
    required this.deliveries,
    required this.invoiceTotal,
    this.nextDelivery,
  });

  final List<ClientOrg> orgs;
  final UnitCounts units;
  final double acceptanceRate;

  /// Units of rework billed to the client.
  final int billableRework;
  final int deliveries;

  /// currency → amount.
  final Map<String, String> invoiceTotal;

  /// The open batch due first; null when nothing open has a due date.
  final NextDelivery? nextDelivery;

  int get acceptancePercent => _percent(acceptanceRate);

  factory ClientOverview.fromJson(Json m) => ClientOverview(
    orgs: readList(m, 'orgs').whereType<Map>().map((x) => ClientOrg.fromJson(Map<String, dynamic>.from(x))).toList(),
    units: UnitCounts.fromJson(readMap(m, 'units')),
    acceptanceRate: _double(m, 'acceptance_rate'),
    billableRework: readInt(m, 'billable_rework'),
    deliveries: readInt(m, 'deliveries'),
    invoiceTotal: {for (final e in readMap(m, 'invoice_total').entries) e.key: e.value?.toString() ?? '0.00'},
    nextDelivery: m['next_delivery'] is Map ? NextDelivery.fromJson(readMap(m, 'next_delivery')) : null,
  );
}

/// A manifest: what one delivery contained and its digest.
class Manifest {
  const Manifest({
    required this.id,
    required this.batchId,
    required this.digest,
    required this.acceptedUnits,
    required this.totalPrice,
    this.createdAt,
  });

  final String id;
  final String batchId;
  final String digest;
  final int acceptedUnits;
  final String totalPrice;
  final DateTime? createdAt;

  factory Manifest.fromJson(Json m, {String batchId = ''}) => Manifest(
    id: readString(m, 'id'),
    batchId: readString(m, 'batch_id').isEmpty ? batchId : readString(m, 'batch_id'),
    digest: readString(m, 'digest'),
    acceptedUnits: readInt(m, 'accepted_units'),
    totalPrice: readString(m, 'total_price'),
    createdAt: readDateTime(m, 'created_at'),
  );
}

/// A batch as the client sees it: price per unit, progress, the manifest once delivered. No pay.
class ClientBatch {
  const ClientBatch({
    required this.id,
    required this.title,
    required this.status,
    required this.unitPrice,
    required this.units,
    this.manifest,
  });

  final String id;
  final String title;
  final String status;
  final String unitPrice;
  final UnitCounts units;
  final Manifest? manifest;

  factory ClientBatch.fromJson(Json m) => ClientBatch(
    id: readString(m, 'id'),
    title: readString(m, 'title'),
    status: readString(m, 'status'),
    unitPrice: readString(m, 'unit_price'),
    units: UnitCounts.fromJson(readMap(m, 'units')),
    manifest: m['manifest'] is Map ? Manifest.fromJson(readMap(m, 'manifest'), batchId: readString(m, 'id')) : null,
  );
}

/// A reason code's share of rework, and whether that rework is billed to the client.
class ReworkReason {
  const ReworkReason({required this.reasonCode, required this.count, required this.billable});

  final String reasonCode;
  final int count;
  final bool billable;

  factory ReworkReason.fromJson(Json m) =>
      ReworkReason(reasonCode: readString(m, 'reason_code'), count: readInt(m, 'count'), billable: readBool(m, 'billable'));
}

/// A note of the project's thread; see [FeedbackEntry].
typedef FeedbackItem = FeedbackEntry;

/// One row of `GET /v1/client/projects`.
class ClientProject {
  const ClientProject({
    required this.id,
    required this.name,
    required this.currency,
    required this.status,
    required this.rubricVersion,
    required this.units,
    required this.acceptanceRate,
    required this.invoiceTotal,
  });

  final String id;
  final String name;
  final String currency;
  final String status;
  final String rubricVersion;
  final UnitCounts units;
  final double acceptanceRate;
  final String invoiceTotal;

  int get acceptancePercent => _percent(acceptanceRate);

  factory ClientProject.fromJson(Json m) => ClientProject(
    id: readString(m, 'id'),
    name: readString(m, 'name'),
    currency: readString(m, 'currency'),
    status: readString(m, 'status'),
    rubricVersion: readString(m, 'rubric_version'),
    units: UnitCounts.fromJson(readMap(m, 'units')),
    acceptanceRate: _double(m, 'acceptance_rate'),
    invoiceTotal: readString(m, 'invoice_total'),
  );
}

/// `GET /v1/client/projects/{id}`: the row plus batches, reasons, deliveries and the feedback thread.
class ClientProjectDetail extends ClientProject {
  const ClientProjectDetail({
    required super.id,
    required super.name,
    required super.currency,
    required super.status,
    required super.rubricVersion,
    required super.units,
    required super.acceptanceRate,
    required super.invoiceTotal,
    required this.batches,
    required this.reasons,
    required this.deliveries,
    required this.feedback,
  });

  final List<ClientBatch> batches;
  final List<ReworkReason> reasons;
  final List<Manifest> deliveries;
  final List<FeedbackItem> feedback;

  /// The batch a manifest belongs to, for its title.
  ClientBatch? batchOf(Manifest m) {
    for (final b in batches) {
      if (b.id == m.batchId || b.manifest?.id == m.id) return b;
    }
    return null;
  }

  factory ClientProjectDetail.fromJson(Json m) {
    final base = ClientProject.fromJson(m);
    List<Json> rows(String key) => readList(m, key).whereType<Map>().map((x) => Map<String, dynamic>.from(x)).toList();
    final batches = rows('batches').map(ClientBatch.fromJson).toList();
    final listed = rows('deliveries').map(Manifest.fromJson).toList();
    // an older gateway lists no deliveries: the batches' manifests are the deliveries
    final deliveries = listed.isNotEmpty
        ? listed
        : [
            for (final b in batches)
              if (b.manifest != null) b.manifest!,
          ];
    return ClientProjectDetail(
      id: base.id,
      name: base.name,
      currency: base.currency,
      status: base.status,
      rubricVersion: base.rubricVersion,
      units: base.units,
      acceptanceRate: base.acceptanceRate,
      invoiceTotal: base.invoiceTotal,
      batches: batches,
      reasons: rows('reasons').map(ReworkReason.fromJson).toList(),
      deliveries: deliveries,
      feedback: rows('feedback').map(FeedbackItem.fromJson).toList(),
    );
  }
}

/// A manifest with the project and batch it came from, for the org-wide deliveries table.
class Delivery {
  const Delivery({
    required this.projectId,
    required this.projectName,
    required this.batchTitle,
    required this.currency,
    required this.manifest,
  });

  final String projectId;
  final String projectName;
  final String batchTitle;
  final String currency;
  final Manifest manifest;
}
