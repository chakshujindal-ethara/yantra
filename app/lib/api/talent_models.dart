import '../core/format.dart';
import '../core/json.dart';
import '../core/money.dart';

/// Wire shapes of the talent module (docs/PRODUCT.md 5.2), read with type tests: a missing field reads as
/// empty, never as a throw.

/// One question of a listing's application form.
class ListingQuestion {
  const ListingQuestion({required this.key, required this.prompt, required this.kind, required this.options, required this.required});

  final String key;
  final String prompt;

  /// `text` or `choice`.
  final String kind;
  final List<String> options;
  final bool required;

  bool get isChoice => kind == 'choice';

  factory ListingQuestion.fromJson(Json m) => ListingQuestion(
    key: readString(m, 'key'),
    prompt: readString(m, 'prompt'),
    kind: readString(m, 'kind').isEmpty ? 'text' : readString(m, 'kind'),
    options: readList(m, 'options').map((e) => e.toString()).toList(),
    required: readBool(m, 'required'),
  );
}

/// A closed listing points at the open pool of the same domain instead of a dead end.
class ListingRedirect {
  const ListingRedirect({required this.id, required this.title});
  final String id;
  final String title;

  factory ListingRedirect.fromJson(Json m) => ListingRedirect(id: readString(m, 'id'), title: readString(m, 'title'));
}

/// What the listing looks like to the worker reading it.
class ListingViewer {
  const ListingViewer({this.prequalified = false, this.applicationId = '', this.applicationStatus = '', this.redirect});

  final bool prequalified;
  final String applicationId;
  final String applicationStatus;
  final ListingRedirect? redirect;

  bool get hasApplied => applicationStatus.isNotEmpty;

  factory ListingViewer.fromJson(Json m) => ListingViewer(
    prequalified: readBool(m, 'prequalified'),
    applicationId: readString(m, 'application_id'),
    applicationStatus: readString(m, 'application_status'),
    redirect: m['redirect'] is Map ? ListingRedirect.fromJson(readMap(m, 'redirect')) : null,
  );
}

/// A pool a worker can apply to.
class Listing {
  const Listing({
    required this.id,
    required this.title,
    required this.domain,
    required this.summary,
    required this.description,
    required this.payMin,
    required this.payMax,
    required this.payUnit,
    required this.currency,
    required this.commitment,
    required this.hoursPerWeek,
    required this.slotsTotal,
    required this.slotsFilled,
    required this.certGate,
    required this.paperId,
    required this.requirements,
    required this.questions,
    required this.llmPolicy,
    required this.sensitive,
    required this.status,
    required this.viewer,
    this.postedAt,
    this.closesAt,
    this.createdAt,
    this.hiredThisWeek = 0,
    this.steps = const [],
  });

  final String id;
  final String title;
  final String domain;
  final String summary;
  final String description;
  final String payMin;
  final String payMax;
  final String payUnit;
  final String currency;

  /// `task_based` or `part_time`.
  final String commitment;
  final int hoursPerWeek;
  final int slotsTotal;
  final int slotsFilled;
  final String certGate;
  final String paperId;
  final List<String> requirements;
  final List<ListingQuestion> questions;
  final String llmPolicy;
  final bool sensitive;
  final String status;
  final ListingViewer viewer;
  final DateTime? postedAt;
  final DateTime? closesAt;
  final DateTime? createdAt;

  /// Offers accepted in the last seven days ("3 hired this week").
  final int hiredThisWeek;

  /// What applying involves, in order: a subset of `form`, `paper`, `availability`. Empty on an older server.
  final List<String> steps;

  int get slotsLeft => slotsTotal - slotsFilled < 0 ? 0 : slotsTotal - slotsFilled;
  bool get isFull => slotsTotal > 0 && slotsLeft == 0;
  bool get isOpen => status == 'open';
  bool get hasPaper => paperId.isNotEmpty;

  /// `₹28–40 per accepted unit`.
  String get payLabel => '${payRange(payMin, payMax, currency: currency)} ${payUnitLabel(payUnit)}'.trim();

  /// `Task-based` or `Part-time`.
  String get commitmentLabel => switch (commitment) {
    'task_based' => 'Task-based',
    'part_time' => 'Part-time',
    _ => humanize(commitment),
  };

  factory Listing.fromJson(Json m) => Listing(
    id: readString(m, 'id'),
    title: readString(m, 'title'),
    domain: readString(m, 'domain'),
    summary: readString(m, 'summary'),
    description: readString(m, 'description'),
    payMin: readString(m, 'pay_min'),
    payMax: readString(m, 'pay_max'),
    payUnit: readString(m, 'pay_unit'),
    currency: readString(m, 'currency'),
    commitment: readString(m, 'commitment'),
    hoursPerWeek: readInt(m, 'hours_per_week'),
    slotsTotal: readInt(m, 'slots_total'),
    slotsFilled: readInt(m, 'slots_filled'),
    certGate: readString(m, 'cert_gate'),
    paperId: readString(m, 'paper_id'),
    requirements: readList(m, 'requirements').map((e) => e.toString()).toList(),
    questions: readList(m, 'questions').whereType<Map>().map((q) => ListingQuestion.fromJson(Map<String, dynamic>.from(q))).toList(),
    llmPolicy: readString(m, 'llm_policy'),
    sensitive: readBool(m, 'sensitive'),
    status: readString(m, 'status'),
    viewer: ListingViewer.fromJson(readMap(m, 'viewer')),
    postedAt: readDateTime(m, 'posted_at'),
    closesAt: readDateTime(m, 'closes_at'),
    createdAt: readDateTime(m, 'created_at'),
    hiredThisWeek: readInt(m, 'hired_this_week'),
    steps: readList(m, 'steps').map((e) => e.toString()).where((e) => e.isNotEmpty).toList(),
  );
}

/// `per_unit` → `per accepted unit`.
String payUnitLabel(String unit) => switch (unit) {
  'per_unit' || '' => 'per accepted unit',
  'per_hour' => 'per hour',
  _ => humanize(unit).toLowerCase(),
};

/// One step of an application: `form`, `paper` or `availability`.
class ApplicationStep {
  const ApplicationStep({required this.kind, required this.status});
  final String kind;

  /// `pending`, `done` or `failed`.
  final String status;

  bool get isDone => status == 'done';
  bool get isFailed => status == 'failed';

  String get title => switch (kind) {
    'form' => 'Application form',
    'paper' => 'Assessment paper',
    'availability' => 'Availability check',
    _ => humanize(kind),
  };

  factory ApplicationStep.fromJson(Json m) => ApplicationStep(kind: readString(m, 'kind'), status: readString(m, 'status'));
}

/// The worker's application to a listing and where it stands.
class Application {
  const Application({
    required this.id,
    required this.listingId,
    required this.listingTitle,
    required this.workerId,
    required this.status,
    required this.steps,
    required this.answers,
    required this.note,
    this.offerExpiresAt,
    this.decidedBy = '',
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String listingId;
  final String listingTitle;
  final String workerId;

  /// `applied | assessment | screening | offered | accepted | declined | rejected | withdrawn | expired`.
  final String status;
  final List<ApplicationStep> steps;
  final Json answers;
  final String note;
  final DateTime? offerExpiresAt;
  final String decidedBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isOffered => status == 'offered';
  bool get needsPaper => status == 'assessment';
  bool get isInProgress => const {'applied', 'assessment', 'screening'}.contains(status);
  bool get canWithdraw => const {'applied', 'assessment', 'screening'}.contains(status);
  bool get isHistory => !isOffered && !isInProgress;

  int get stepsDone => steps.where((s) => s.isDone).length;

  Application copyWith({String? status, String? note}) => Application(
    id: id,
    listingId: listingId,
    listingTitle: listingTitle,
    workerId: workerId,
    status: status ?? this.status,
    steps: steps,
    answers: answers,
    note: note ?? this.note,
    offerExpiresAt: offerExpiresAt,
    decidedBy: decidedBy,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  factory Application.fromJson(Json m) => Application(
    id: readString(m, 'id'),
    listingId: readString(m, 'listing_id'),
    listingTitle: readString(m, 'listing_title'),
    workerId: readString(m, 'worker_id'),
    status: readString(m, 'status'),
    steps: readList(m, 'steps').whereType<Map>().map((s) => ApplicationStep.fromJson(Map<String, dynamic>.from(s))).toList(),
    answers: readMap(m, 'answers'),
    note: readString(m, 'note'),
    offerExpiresAt: readDateTime(m, 'offer_expires_at'),
    decidedBy: readString(m, 'decided_by'),
    createdAt: readDateTime(m, 'created_at'),
    updatedAt: readDateTime(m, 'updated_at'),
  );
}

/// The six onboarding steps in their fixed order, with the group each belongs to.
const onboardingStepOrder = ['profile', 'agreement', 'consent', 'identity', 'bank', 'payout_ack'];
const onboardingGroups = ['Profile', 'Documents', 'Identity', 'Payment'];

String onboardingGroupOf(String key) => switch (key) {
  'profile' => 'Profile',
  'agreement' || 'consent' => 'Documents',
  'identity' => 'Identity',
  'bank' || 'payout_ack' => 'Payment',
  _ => 'Other',
};

String onboardingStepTitle(String key) => switch (key) {
  'profile' => 'Legal name, phone and city',
  'agreement' => 'Contractor agreement',
  'consent' => 'Data consent (DPDP)',
  'identity' => 'PAN and Aadhaar',
  'bank' => 'Bank account',
  'payout_ack' => 'Payout policy',
  _ => humanize(key),
};

class OnboardingStep {
  const OnboardingStep({required this.key, required this.status, required this.group, this.doneAt});
  final String key;
  final String status;
  final String group;
  final DateTime? doneAt;

  bool get isDone => status == 'done';
  String get title => onboardingStepTitle(key);

  factory OnboardingStep.fromJson(Json m) {
    final key = readString(m, 'key');
    final group = readString(m, 'group');
    return OnboardingStep(
      key: key,
      status: readString(m, 'status'),
      group: group.isEmpty ? onboardingGroupOf(key) : group,
      doneAt: readDateTime(m, 'done_at'),
    );
  }
}

/// The worker's onboarding checklist. Steps missing from the wire are shown as pending so the page always
/// has six.
class Onboarding {
  const Onboarding({
    required this.complete,
    required this.steps,
    this.eligibleSentAt,
    this.agreementVersion = '',
    this.consentVersion = '',
    this.documents = const [],
    this.erasure,
  });

  final bool complete;
  final List<OnboardingStep> steps;
  final DateTime? eligibleSentAt;

  /// The contractor agreement and consent versions the worker accepted ('' when not yet).
  final String agreementVersion;
  final String consentVersion;

  /// Identity documents on file (kind and when), newest upload per kind.
  final List<DocumentBrief> documents;

  /// A pending or finished request to erase the worker's personal data.
  final Erasure? erasure;

  /// An empty checklist: nothing done yet (what a 404 from the talent module means).
  static final notStarted = Onboarding.fromJson(const {});

  int get total => steps.length;
  int get done => steps.where((s) => s.isDone).length;
  int get left => total - done;
  List<OnboardingStep> get pending => steps.where((s) => !s.isDone).toList();
  OnboardingStep? step(String key) => steps.where((s) => s.key == key).firstOrNull;
  bool isDone(String key) => step(key)?.isDone ?? false;

  factory Onboarding.fromJson(Json m) {
    final wire = {
      for (final s in readList(m, 'steps').whereType<Map>().map((s) => OnboardingStep.fromJson(Map<String, dynamic>.from(s)))) s.key: s,
    };
    final steps = [
      for (final key in onboardingStepOrder) wire[key] ?? OnboardingStep(key: key, status: 'pending', group: onboardingGroupOf(key)),
      for (final s in wire.values)
        if (!onboardingStepOrder.contains(s.key)) s,
    ];
    final erasure = readMap(m, 'erasure');
    return Onboarding(
      complete: readBool(m, 'complete'),
      steps: steps,
      eligibleSentAt: readDateTime(m, 'eligible_sent_at'),
      agreementVersion: readString(m, 'agreement_version'),
      consentVersion: readString(m, 'consent_version'),
      documents: readList(m, 'documents').whereType<Map>().map((d) => DocumentBrief.fromJson(Map<String, dynamic>.from(d))).toList(),
      erasure: erasure.isEmpty ? null : Erasure.fromJson(erasure),
    );
  }
}

/// The identity documents a worker may upload (all optional in Stage 1; ops verify them against the PAN).
const documentKinds = ['identity_front', 'identity_back', 'address_proof', 'signed_agreement'];

String documentKindLabel(String kind) => switch (kind) {
  'identity_front' => 'ID card, front',
  'identity_back' => 'ID card, back',
  'address_proof' => 'Proof of address',
  'signed_agreement' => 'Signed agreement',
  _ => humanize(kind),
};

/// What the server accepts for a document: JPEG, PNG or PDF, up to 10 MB.
const documentTypes = {'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'pdf': 'application/pdf'};
const documentMaxBytes = 10 * 1024 * 1024;

class DocumentBrief {
  const DocumentBrief({required this.kind, this.uploadedAt});
  final String kind;
  final DateTime? uploadedAt;

  factory DocumentBrief.fromJson(Json m) => DocumentBrief(kind: readString(m, 'kind'), uploadedAt: readDateTime(m, 'uploaded_at'));
}

/// A request to erase the worker's personal data: `requested` (done by [dueAt] at the latest),
/// `approved` (ops brought it forward) or `done`.
class Erasure {
  const Erasure({required this.status, this.requestedAt, this.dueAt, this.doneAt});
  final String status;
  final DateTime? requestedAt;
  final DateTime? dueAt;
  final DateTime? doneAt;

  bool get isDone => status == 'done';

  factory Erasure.fromJson(Json m) => Erasure(
    status: readString(m, 'status'),
    requestedAt: readDateTime(m, 'requested_at'),
    dueAt: readDateTime(m, 'due_at'),
    doneAt: readDateTime(m, 'done_at'),
  );
}

/// The account payouts go to, as payout keeps it: never the number, only the last four digits.
/// `status` is `verifying` (the penny drop is running), `verified` or `failed` (see [failureReason]).
class BankAccount {
  const BankAccount({
    required this.status,
    required this.verification,
    required this.accountName,
    required this.accountLast4,
    required this.ifsc,
    this.registeredNameMatch,
    this.verifiedAt,
    this.failureReason = '',
  });

  final String status;

  /// `penny_drop` (a ₹1 transfer confirmed the account) or `none` (the bank-file rail cannot check).
  final String verification;
  final String accountName;
  final String accountLast4;
  final String ifsc;
  final bool? registeredNameMatch;
  final DateTime? verifiedAt;
  final String failureReason;

  bool get isVerified => status == 'verified';
  bool get isVerifying => status == 'verifying';
  bool get isFailed => status == 'failed';

  /// What went wrong, in the worker's words.
  String get failureText => switch (failureReason) {
    'invalid_account' => 'The bank says this account number and IFSC do not match an open account.',
    'name_mismatch' => 'The name the bank holds for this account is not the name you gave. Use the account in your legal name.',
    'rail_error' => 'The bank could not be reached to check the account. Try again in a few minutes.',
    '' => 'The account could not be checked.',
    _ => 'The account could not be checked (${humanize(failureReason).toLowerCase()}).',
  };

  factory BankAccount.fromJson(Json m) => BankAccount(
    status: readString(m, 'status'),
    verification: readString(m, 'verification'),
    accountName: readString(m, 'account_name'),
    accountLast4: readString(m, 'account_last4'),
    ifsc: readString(m, 'ifsc'),
    registeredNameMatch: m['registered_name_match'] is bool ? m['registered_name_match'] as bool : null,
    verifiedAt: readDateTime(m, 'verified_at'),
    failureReason: readString(m, 'failure_reason'),
  );
}
