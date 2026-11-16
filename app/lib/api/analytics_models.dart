import '../core/json.dart';

/// Wire shapes of the leadership page (docs/PRODUCT.md 5.8, `/v1/analytics/...`). Money and ratios are
/// strings as the API sends them; a missing field is empty, never a throw.

List<Json> _rows(Json m, String key) => readList(m, key).whereType<Map>().map((x) => Map<String, dynamic>.from(x)).toList();

String? _maybe(Json m, String key) => m[key] == null ? null : '${m[key]}';

/// One number on the leadership page: its value now, the baseline it is judged against, which way is
/// better, what it is made of ([basis]) and the destination that explains it ([href]).
class LeadershipTile {
  const LeadershipTile({
    required this.key,
    required this.label,
    required this.unit,
    required this.better,
    required this.href,
    this.value,
    this.baseline,
    this.currency,
    this.basis = const {},
    this.note,
  });

  final String key;
  final String label;

  /// `days`, `money`, `ratio`, `count` or `per_1000`.
  final String unit;

  /// `lower` or `higher`.
  final String better;

  /// A destination name: `projects`, `workers`, `quality`, `finance`, `system`.
  final String href;
  final String? value;
  final String? baseline;
  final String? currency;
  final Json basis;
  final String? note;

  /// Whether the value beats the baseline; null when either is missing or not a number.
  bool? get beatsBaseline {
    final v = double.tryParse(value ?? ''), b = double.tryParse(baseline ?? '');
    if (v == null || b == null) return null;
    return better == 'lower' ? v <= b : v >= b;
  }

  factory LeadershipTile.fromJson(Json m) => LeadershipTile(
    key: readString(m, 'key'),
    label: readString(m, 'label'),
    unit: readString(m, 'unit'),
    better: readString(m, 'better'),
    href: readString(m, 'href'),
    value: _maybe(m, 'value'),
    baseline: _maybe(m, 'baseline'),
    currency: _maybe(m, 'currency'),
    basis: readMap(m, 'basis'),
    note: _maybe(m, 'note'),
  );
}

/// Gross margin of one project over the window.
class MarginRow {
  const MarginRow({
    required this.projectId,
    required this.currency,
    required this.accepted,
    required this.price,
    required this.pay,
    required this.review,
    required this.audit,
    required this.margin,
    this.marginPerUnit,
    this.marginFraction,
  });

  final String projectId;
  final String currency;
  final int accepted;
  final String price;
  final String pay;
  final String review;
  final String audit;
  final String margin;
  final String? marginPerUnit;
  final String? marginFraction;

  factory MarginRow.fromJson(Json m) => MarginRow(
    projectId: readString(m, 'project_id'),
    currency: readString(m, 'currency'),
    accepted: readInt(m, 'accepted'),
    price: readString(m, 'price'),
    pay: readString(m, 'pay'),
    review: readString(m, 'review'),
    audit: readString(m, 'audit'),
    margin: readString(m, 'margin'),
    marginPerUnit: _maybe(m, 'margin_per_unit'),
    marginFraction: _maybe(m, 'margin_fraction'),
  );
}

/// `GET /v1/analytics/leadership`.
class Leadership {
  const Leadership({
    required this.windowDays,
    required this.currency,
    required this.numbers,
    required this.margin,
    required this.watch,
    this.asOf,
    this.baselineSetAt,
  });

  final int windowDays;
  final String currency;
  final DateTime? asOf;
  final DateTime? baselineSetAt;
  final List<LeadershipTile> numbers;
  final List<MarginRow> margin;
  final List<LeadershipTile> watch;

  factory Leadership.fromJson(Json m) => Leadership(
    windowDays: readInt(m, 'window_days'),
    currency: readString(m, 'currency'),
    asOf: readDateTime(m, 'as_of'),
    baselineSetAt: readDateTime(m, 'baseline_set_at'),
    numbers: _rows(m, 'numbers').map(LeadershipTile.fromJson).toList(),
    margin: _rows(m, 'margin').map(MarginRow.fromJson).toList(),
    watch: _rows(m, 'watch').map(LeadershipTile.fromJson).toList(),
  );
}

/// `GET /v1/analytics/funnel`: applicants per stage. [stagesAvailable] lists the stages the platform can
/// count at all; the others read as unknown, not zero.
class Funnel {
  const Funnel({required this.windowDays, required this.stagesAvailable, required this.stages});

  final int windowDays;
  final List<String> stagesAvailable;
  final Map<String, int> stages;

  factory Funnel.fromJson(Json m) => Funnel(
    windowDays: readInt(m, 'window_days'),
    stagesAvailable: readList(m, 'stages_available').map((x) => '$x').toList(),
    stages: {for (final e in readMap(m, 'stages').entries) e.key: e.value is num ? (e.value as num).toInt() : 0},
  );
}

class WorkforceRow {
  const WorkforceRow({
    required this.workerId,
    required this.activeHours,
    required this.unitsAccepted,
    required this.unitsJudged,
    required this.earnings,
    this.acceptanceRate,
  });

  final String workerId;
  final String activeHours;
  final int unitsAccepted;
  final int unitsJudged;
  final String? acceptanceRate;

  /// currency → amount.
  final Map<String, String> earnings;

  factory WorkforceRow.fromJson(Json m) => WorkforceRow(
    workerId: readString(m, 'worker_id'),
    activeHours: readString(m, 'active_hours'),
    unitsAccepted: readInt(m, 'units_accepted'),
    unitsJudged: readInt(m, 'units_judged'),
    acceptanceRate: _maybe(m, 'acceptance_rate'),
    earnings: {for (final e in readMap(m, 'earnings').entries) e.key: '${e.value}'},
  );
}

/// `GET /v1/analytics/workforce`: one ISO week, IST.
class Workforce {
  const Workforce({required this.workers, this.weekStart});
  final DateTime? weekStart;
  final List<WorkforceRow> workers;

  factory Workforce.fromJson(Json m) =>
      Workforce(weekStart: readDateTime(m, 'week_start'), workers: _rows(m, 'workers').map(WorkforceRow.fromJson).toList());
}

/// What leadership compares against (`GET/PUT /v1/analytics/baselines`). Every PUT is a new row.
class LeadBaseline {
  const LeadBaseline({
    this.currency = 'INR',
    this.daysToStaff,
    this.idleCostWeekly,
    this.firstPassAcceptance,
    this.costPerAcceptedUnit,
    this.idleHourlyCost = '0',
    this.idleHoursPerWeek = 10,
    this.staffingWorkers = 5,
    this.railFeePerPayout = '0',
    this.levyRate = '0',
    this.payoutSlaDays = 7,
    this.note,
    this.setAt,
  });

  final String currency;
  final String? daysToStaff;
  final String? idleCostWeekly;
  final String? firstPassAcceptance;
  final String? costPerAcceptedUnit;
  final String idleHourlyCost;
  final int idleHoursPerWeek;
  final int staffingWorkers;
  final String railFeePerPayout;
  final String levyRate;
  final int payoutSlaDays;
  final String? note;
  final DateTime? setAt;

  factory LeadBaseline.fromJson(Json m) => LeadBaseline(
    currency: readString(m, 'currency').isEmpty ? 'INR' : readString(m, 'currency'),
    daysToStaff: _maybe(m, 'days_to_staff'),
    idleCostWeekly: _maybe(m, 'idle_cost_weekly'),
    firstPassAcceptance: _maybe(m, 'first_pass_acceptance'),
    costPerAcceptedUnit: _maybe(m, 'cost_per_accepted_unit'),
    idleHourlyCost: _maybe(m, 'idle_hourly_cost') ?? '0',
    idleHoursPerWeek: m['idle_hours_per_week'] is int ? m['idle_hours_per_week'] as int : 10,
    staffingWorkers: m['staffing_workers'] is int ? m['staffing_workers'] as int : 5,
    railFeePerPayout: _maybe(m, 'rail_fee_per_payout') ?? '0',
    levyRate: _maybe(m, 'levy_rate') ?? '0',
    payoutSlaDays: m['payout_sla_days'] is int ? m['payout_sla_days'] as int : 7,
    note: _maybe(m, 'note'),
    setAt: readDateTime(m, 'set_at'),
  );

  Json toJson() => {
    'currency': currency,
    'days_to_staff': daysToStaff,
    'idle_cost_weekly': idleCostWeekly,
    'first_pass_acceptance': firstPassAcceptance,
    'cost_per_accepted_unit': costPerAcceptedUnit,
    'idle_hourly_cost': idleHourlyCost,
    'idle_hours_per_week': idleHoursPerWeek,
    'staffing_workers': staffingWorkers,
    'rail_fee_per_payout': railFeePerPayout,
    'levy_rate': levyRate,
    'payout_sla_days': payoutSlaDays,
    'note': ?note,
  };
}

/// The warehouse rebuild (`GET/POST /v1/analytics/rebuild`).
class RebuildState {
  const RebuildState({required this.generation, required this.status, this.mode, this.requestedAt, this.finishedAt, this.events});

  final int generation;

  /// `idle`, `requested`, `running` or `done`.
  final String status;
  final String? mode;
  final String? requestedAt;
  final String? finishedAt;
  final int? events;

  bool get busy => status == 'requested' || status == 'running';

  factory RebuildState.fromJson(Json m) => RebuildState(
    generation: readInt(m, 'generation'),
    status: readString(m, 'status').isEmpty ? 'idle' : readString(m, 'status'),
    mode: _maybe(m, 'mode'),
    requestedAt: _maybe(m, 'requested_at'),
    finishedAt: _maybe(m, 'finished_at'),
    events: m['events'] is int ? m['events'] as int : null,
  );
}
