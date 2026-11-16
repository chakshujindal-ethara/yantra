/// Wire fixtures for the talent and assess screens.
library;

String inFuture(Duration d) => DateTime.now().add(d).toUtc().toIso8601String();

Map<String, Object?> listing({
  String id = 'l1',
  String title = 'Hindi audio transcription',
  String domain = 'transcription',
  String status = 'open',
  int slotsTotal = 10,
  int slotsFilled = 8,
  String paperId = 'pp1',
  String certGate = 'transcription',
  String commitment = 'task_based',
  int hours = 10,
  String payMin = '28.00',
  String payMax = '40.00',
  bool prequalified = false,
  String? applicationStatus,
  String? applicationId,
  bool sensitive = false,
  List<Map<String, Object?>>? questions,
  Map<String, Object?>? redirect,
}) => {
  'id': id,
  'title': title,
  'domain': domain,
  'summary': 'Transcribe short Hindi clips',
  'description': 'Listen to 10–30 second clips and type exactly what is said.',
  'pay_min': payMin,
  'pay_max': payMax,
  'pay_unit': 'per_unit',
  'currency': 'INR',
  'commitment': commitment,
  'hours_per_week': hours,
  'slots_total': slotsTotal,
  'slots_filled': slotsFilled,
  'cert_gate': certGate,
  'paper_id': paperId,
  'requirements': ['Native Hindi speaker', 'Quiet workspace'],
  'questions':
      questions ??
      [
        {'key': 'why', 'prompt': 'Why this pool?', 'kind': 'text', 'required': true},
        {
          'key': 'shift',
          'prompt': 'Preferred shift',
          'kind': 'choice',
          'options': ['day', 'night'],
          'required': true,
        },
        {'key': 'extra', 'prompt': 'Anything else', 'kind': 'text', 'required': false},
      ],
  'llm_policy': 'No LLM assistance; every transcript is typed by you.',
  'sensitive': sensitive,
  'status': status,
  'posted_at': '2026-11-01T10:00:00Z',
  'closes_at': inFuture(const Duration(days: 10)),
  'created_at': '2026-11-01T10:00:00Z',
  'viewer': {'prequalified': prequalified, 'application_id': applicationId, 'application_status': applicationStatus, 'redirect': ?redirect},
};

Map<String, Object?> application({
  String id = 'a1',
  String listingId = 'l1',
  String listingTitle = 'Hindi audio transcription',
  String status = 'screening',
  List<Map<String, Object?>>? steps,
  String? offerExpiresAt,
  String note = '',
}) => {
  'id': id,
  'listing_id': listingId,
  'listing_title': listingTitle,
  'worker_id': 'worker-1',
  'status': status,
  'steps':
      steps ??
      [
        {'kind': 'form', 'status': 'done'},
        {'kind': 'paper', 'status': status == 'assessment' ? 'pending' : 'done'},
        {'kind': 'availability', 'status': 'pending'},
      ],
  'answers': {'why': 'I like it'},
  'note': note,
  'offer_expires_at': offerExpiresAt,
  'decided_by': null,
  'created_at': '2026-11-02T10:00:00Z',
  'updated_at': '2026-11-02T10:00:00Z',
};

Map<String, Object?> onboarding({Set<String> done = const {}, bool? complete}) => {
  'complete': complete ?? done.length == 6,
  'eligible_sent_at': (complete ?? done.length == 6) ? '2026-11-03T10:00:00Z' : null,
  'steps': [
    for (final key in ['profile', 'agreement', 'consent', 'identity', 'bank', 'payout_ack'])
      {
        'key': key,
        'status': done.contains(key) ? 'done' : 'pending',
        'done_at': done.contains(key) ? '2026-11-02T10:00:00Z' : null,
        'group': switch (key) {
          'profile' => 'Profile',
          'agreement' || 'consent' => 'Documents',
          'identity' => 'Identity',
          _ => 'Payment',
        },
      },
  ],
};

Map<String, Object?> brief({
  String id = 'pp1',
  String gate = 'transcription',
  int attemptsLeft = 2,
  int attemptsUsed = 1,
  bool certified = false,
  Map<String, Object?>? current,
  Object? proctoring,
  List<String> questionTypes = const ['mcq', 'msq'],
}) => {
  'id': id,
  'gate': gate,
  'title': 'Hindi transcription basics',
  'description': 'Twelve questions on spelling, numerals and tags.',
  'duration_minutes': 20,
  'pass_mark': 0.7,
  'question_count': 3,
  'attempts_used': attemptsUsed,
  'attempts_left': attemptsLeft,
  'certified': certified,
  'question_types': questionTypes,
  'proctoring': proctoring ?? {'webcam': true, 'fullscreen': true, 'ai_proctor': false},
  'current': current,
};

/// One attempt at a paper as `GET /v1/assess/sittings/me` and the brief's `current` carry it.
Map<String, Object?> workerSitting({
  String id = 's1',
  String paperId = 'pp1',
  String status = 'passed',
  int attemptNo = 1,
  double score = 0.83,
  bool released = true,
  String heldReason = '',
}) => {
  'id': id,
  'paper_id': paperId,
  'paper_title': 'Hindi transcription basics',
  'gate': 'transcription',
  'attempt_no': attemptNo,
  'status': status,
  'score': score,
  'released': released,
  'held_reason': heldReason,
  'started_at': '2026-11-10T09:00:00Z',
  'submitted_at': status == 'assigned' || status == 'in_progress' ? null : '2026-11-10T09:18:00Z',
  'deadline': '2026-11-10T09:20:00Z',
};

/// What `POST /v1/assess/papers/{id}/launch` answers: a one-time signed-in link into the exam app.
Map<String, Object?> launchTicket({String url = 'http://localhost:8096/yantra/launch#ticket=t-1'}) => {
  'launch_url': url,
  'expires_at': '2026-11-10T09:02:00Z',
  'sitting': workerSitting(status: 'assigned', score: 0, released: false),
};
