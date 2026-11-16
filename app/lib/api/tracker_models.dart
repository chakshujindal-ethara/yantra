import '../core/json.dart';

/// The worker's week as the tracker counts it: active and idle seconds against the weekly cap. Weeks run
/// Monday 00:00 to Sunday 23:59 IST.
class TrackerWeek {
  const TrackerWeek({
    this.startsAt,
    this.endsAt,
    required this.activeSeconds,
    required this.idleSeconds,
    required this.capHours,
    required this.capSource,
    required this.overCap,
  });

  final DateTime? startsAt;
  final DateTime? endsAt;
  final int activeSeconds;
  final int idleSeconds;
  final double capHours;

  /// `worker`, `project` or `default`: where the cap came from.
  final String capSource;
  final bool overCap;

  double get activeHours => activeSeconds / 3600;

  factory TrackerWeek.fromJson(Json m) => TrackerWeek(
    startsAt: readDateTime(m, 'starts_at'),
    endsAt: readDateTime(m, 'ends_at'),
    activeSeconds: readInt(m, 'active_seconds'),
    idleSeconds: readInt(m, 'idle_seconds'),
    capHours: double.tryParse(readString(m, 'cap_hours')) ?? (m['cap_hours'] is num ? (m['cap_hours'] as num).toDouble() : 0),
    capSource: readString(m, 'cap_source'),
    overCap: readBool(m, 'over_cap'),
  );
}

/// One stretch of tracked time, normally one claim.
class TrackerSession {
  const TrackerSession({
    required this.id,
    required this.claimId,
    this.startedAt,
    this.endedAt,
    required this.activeSeconds,
    required this.idleSeconds,
    required this.endReason,
  });

  final String id;
  final String claimId;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final int activeSeconds;
  final int idleSeconds;
  final String endReason;

  factory TrackerSession.fromJson(Json m) => TrackerSession(
    id: readString(m, 'id'),
    claimId: readString(m, 'claim_id'),
    startedAt: readDateTime(m, 'started_at'),
    endedAt: readDateTime(m, 'ended_at'),
    activeSeconds: readInt(m, 'active_seconds'),
    idleSeconds: readInt(m, 'idle_seconds'),
    endReason: readString(m, 'end_reason'),
  );
}

/// `GET /v1/tracker/sessions/me`: this week, its sessions, and the one still open (if any).
class MyActivity {
  const MyActivity({required this.week, required this.sessions, required this.openSessionId});
  final TrackerWeek week;
  final List<TrackerSession> sessions;
  final String openSessionId;

  factory MyActivity.fromJson(Json m) => MyActivity(
    week: TrackerWeek.fromJson(readMap(m, 'week')),
    sessions: readList(m, 'sessions').whereType<Map>().map((s) => TrackerSession.fromJson(Map<String, dynamic>.from(s))).toList(),
    openSessionId: readString(m, 'open_session_id'),
  );
}

/// One 30-second sample: `active` (input in the last minute), `idle`, or `focus_lost` (the tab was hidden).
class ActivitySample {
  const ActivitySample(this.at, this.kind);
  final DateTime at;
  final String kind;

  Json toJson() => {'at': at.toUtc().toIso8601String(), 'kind': kind, 'label': 'yantra-web'};
}

/// A tracker session as started: its id and, when the tracker said, when it began on the server's clock.
class TrackerStart {
  const TrackerStart(this.id, {this.startedAt});
  final String id;
  final DateTime? startedAt;
}
