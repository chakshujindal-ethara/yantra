import '../core/json.dart';

/// Wire shapes of the assess module (docs/PRODUCT.md 5.3). A paper is sat in Assessment v2, the exam app the
/// worker is sent to; Yantra keeps the brief, the sittings and the result. Pass marks and scores are fractions
/// (0..1).

double _readFraction(Json m, String key) {
  final v = m[key];
  final n = v is num ? v.toDouble() : (v is String ? double.tryParse(v) ?? 0 : 0.0);
  return n.clamp(0, 1).toDouble();
}

/// What the exam app will ask of the worker while they sit: each rule the paper turns on.
class Proctoring {
  const Proctoring(this.rules);

  /// Rule name (`webcam`, `fullscreen`, `ai_proctor`, `seb`, `block_tab_switch`, ...) to on/off.
  final Map<String, bool> rules;

  List<String> get on => [
    for (final e in rules.entries)
      if (e.value) e.key,
  ];

  bool get isEmpty => on.isEmpty;

  factory Proctoring.fromJson(Object? v) {
    if (v is Map) {
      return Proctoring({for (final e in v.entries) '${e.key}': e.value == true});
    }
    if (v is List) {
      return Proctoring({for (final e in v) '$e': true});
    }
    return const Proctoring({});
  }

  /// The rule in the worker's words; an unknown rule is spelled out from its name.
  static String label(String rule) => switch (rule) {
    'webcam' || 'camera' => 'Your camera stays on',
    'ai_proctor' => 'An AI proctor watches the camera (one face, no phone)',
    'fullscreen' => 'The exam runs full screen',
    'seb' || 'require_seb' => 'Safe Exam Browser is required',
    'block_tab_switch' || 'tab_switch' => 'Switching tabs is recorded',
    'block_copy_paste' || 'copy_paste' => 'Copy and paste are off',
    'block_right_click' || 'right_click' => 'Right click is off',
    'block_devtools' || 'devtools' => 'Developer tools are off',
    'gaze_review' => 'Eye movement is reviewed',
    'watermark' => 'Your name is watermarked on the screen',
    _ => rule.replaceAll('_', ' ').replaceFirstMapped(RegExp(r'^\w'), (m) => m[0]!.toUpperCase()),
  };
}

/// One attempt at a paper as Yantra tracks it. `assigned` (the exam is ready), `in_progress`,
/// `awaiting_result` (submitted; the score is being marked or waits for release), `passed`, `failed`,
/// `void` (the exam was never started and was withdrawn; not counted as an attempt).
class WorkerSitting {
  const WorkerSitting({
    required this.id,
    required this.paperId,
    required this.paperTitle,
    required this.gate,
    required this.status,
    required this.attemptNo,
    required this.score,
    required this.released,
    required this.heldReason,
    this.startedAt,
    this.submittedAt,
    this.deadline,
  });

  final String id;
  final String paperId;
  final String paperTitle;
  final String gate;
  final String status;
  final int attemptNo;

  /// 0..1; meaningful once released.
  final double score;
  final bool released;

  /// Why a submitted sitting has no result yet: `llm_scoring`, `needs_release`, `integrity_review`, ...
  final String heldReason;
  final DateTime? startedAt;
  final DateTime? submittedAt;
  final DateTime? deadline;

  bool get isOpen => const {'assigned', 'in_progress'}.contains(status);
  bool get awaitingResult => status == 'awaiting_result';
  bool get passed => status == 'passed';
  bool get failed => status == 'failed';
  bool get isVoid => status == 'void';
  int get scorePercent => (score * 100).round();

  factory WorkerSitting.fromJson(Json m) => WorkerSitting(
    id: readString(m, 'id'),
    paperId: readString(m, 'paper_id'),
    paperTitle: readString(m, 'paper_title'),
    gate: readString(m, 'gate'),
    status: readString(m, 'status'),
    attemptNo: readInt(m, 'attempt_no'),
    score: _readFraction(m, 'score'),
    released: readBool(m, 'released'),
    heldReason: readString(m, 'held_reason'),
    startedAt: readDateTime(m, 'started_at'),
    submittedAt: readDateTime(m, 'submitted_at'),
    deadline: readDateTime(m, 'deadline'),
  );
}

/// What a worker sees before sitting a paper.
class PaperBrief {
  const PaperBrief({
    required this.id,
    required this.gate,
    required this.title,
    required this.description,
    required this.durationMinutes,
    required this.passMark,
    required this.questionCount,
    required this.attemptsUsed,
    required this.attemptsLeft,
    required this.certified,
    this.proctoring = const Proctoring({}),
    this.questionTypes = const [],
    this.current,
  });

  final String id;
  final String gate;
  final String title;
  final String description;

  /// 0 when the paper has no time limit.
  final int durationMinutes;

  /// 0..1.
  final double passMark;
  final int questionCount;
  final int attemptsUsed;
  final int attemptsLeft;
  final bool certified;
  final Proctoring proctoring;

  /// Assessment v2's question types on this paper (`mcq`, `msq`, `subjective_rubric`, `transcription`, ...).
  final List<String> questionTypes;

  /// The open sitting when there is one, else the latest (passed, failed, void): Resume, "awaiting result", or
  /// the last result.
  final WorkerSitting? current;

  int get passMarkPercent => (passMark * 100).round();

  /// An attempt the worker still has to finish, or whose result is on its way: nothing new can start.
  bool get _busy => (current?.isOpen ?? false) || awaitingResult;
  bool get attemptsExhausted => !certified && attemptsLeft <= 0 && !_busy;
  bool get canStart => !certified && attemptsLeft > 0 && !_busy;
  bool get canResume => !certified && (current?.isOpen ?? false);
  bool get awaitingResult => current?.awaitingResult ?? false;

  factory PaperBrief.fromJson(Json m) => PaperBrief(
    id: readString(m, 'id'),
    gate: readString(m, 'gate'),
    title: readString(m, 'title'),
    description: readString(m, 'description'),
    durationMinutes: readInt(m, 'duration_minutes'),
    passMark: _readFraction(m, 'pass_mark'),
    questionCount: readInt(m, 'question_count'),
    attemptsUsed: readInt(m, 'attempts_used'),
    attemptsLeft: readInt(m, 'attempts_left'),
    certified: readBool(m, 'certified'),
    proctoring: Proctoring.fromJson(m['proctoring']),
    questionTypes: readList(m, 'question_types').map((e) => '$e').toList(),
    current: m['current'] is Map ? WorkerSitting.fromJson(readMap(m, 'current')) : null,
  );
}

/// A one-time link into Assessment v2, already signed in: open it in this tab.
class LaunchTicket {
  const LaunchTicket({required this.launchUrl, this.expiresAt, this.sitting});
  final Uri launchUrl;
  final DateTime? expiresAt;
  final WorkerSitting? sitting;

  factory LaunchTicket.fromJson(Json m) => LaunchTicket(
    launchUrl: Uri.parse(readString(m, 'launch_url')),
    expiresAt: readDateTime(m, 'expires_at'),
    sitting: m['sitting'] is Map ? WorkerSitting.fromJson(readMap(m, 'sitting')) : null,
  );
}

/// Assessment v2's question types in plain words.
String questionTypeLabel(String type) => switch (type) {
  'mcq' => 'Single choice',
  'msq' => 'Multiple choice',
  'subjective_rubric' => 'Written answer',
  'image_ab' => 'Image comparison',
  'image_prompt' => 'Image prompt writing',
  'image_label' => 'Image annotation',
  'video_prompt' => 'Video prompt writing',
  'transcription' => 'Audio transcription',
  _ => type.replaceAll('_', ' '),
};

/// Why a submitted sitting has no result yet, in the worker's words.
String heldReasonLabel(String reason) => switch (reason) {
  'llm_scoring' => 'Your written answers are being marked',
  'needs_release' => 'Ops review the results before they are released',
  'integrity_review' || 'integrity_alert' => 'Ops are reviewing the proctoring record',
  'violation_limit' || 'violation_limit_breached' => 'Ops are reviewing the proctoring record',
  '' => 'Your result is on its way',
  _ => reason.replaceAll('_', ' '),
};
