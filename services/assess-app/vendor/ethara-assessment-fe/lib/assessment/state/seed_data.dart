// Seed data.
//
// Determinism (HANDOVER §5.6): there is NO random number generation here.
// Every value that varies - a score, a token count, a judge payload - comes
// from a stable hash of an identifier, so a defect is always reproducible.
// See `util/seed.dart`.
//
// The set is chosen to make every designed state reachable without hunting:
// all four assessment states, every answer layout, a failed render, a
// terminal scoring error, an unreleased result, a duplicate generator, a
// failed invite and a near-duplicate tag are all present.
import '../domain/enums.dart';
import '../domain/models.dart';
import '../util/seed.dart';

class SeedData {
  final List<Generator> generators;
  final List<Question> drafts;
  final List<Question> bank;
  final List<Assessment> assessments;
  final List<Attempt> attempts;
  final List<Person> people;
  final List<Job> jobs;
  final List<LedgerRow> ledger;
  final List<Tag> tags;

  const SeedData({
    required this.generators,
    required this.drafts,
    required this.bank,
    required this.assessments,
    required this.attempts,
    required this.people,
    required this.jobs,
    required this.ledger,
    required this.tags,
  });

  static SeedData build() {
    final List<Person> people = _people();
    final List<Generator> gens = _generators();
    final List<Question> bank = _bank();
    final List<Question> drafts = _drafts();
    final List<Assessment> asms = _assessments(bank);
    final List<Attempt> attempts = _attempts(asms, people);
    return SeedData(
      generators: gens,
      drafts: drafts,
      bank: bank,
      assessments: asms,
      attempts: attempts,
      people: people,
      jobs: _jobs(),
      ledger: _ledger(gens, attempts),
      tags: _tags(),
    );
  }

  // ── People ──────────────────────────────────────────────────────────────
  static List<Person> _people() => const <Person>[
    Person(
      id: 'P-1',
      name: 'Sana Kapoor',
      email: 'sana.kapoor@ethara.io',
      pod: 'Pod A',
    ),
    Person(
      id: 'P-2',
      name: 'Rohit Verma',
      email: 'rohit.verma@ethara.io',
      pod: 'Pod A',
    ),
    Person(
      id: 'P-3',
      name: 'Ananya Iyer',
      email: 'ananya.iyer@ethara.io',
      pod: 'Pod B',
    ),
    Person(
      id: 'P-4',
      name: 'Kabir Shah',
      email: 'kabir.shah@ethara.io',
      pod: 'Pod B',
    ),
    Person(
      id: 'P-5',
      name: 'Meera Nambiar',
      email: 'meera.n@ethara.io',
      pod: 'Pod C',
    ),
    Person(
      id: 'P-6',
      name: 'Arjun Rao',
      email: 'arjun.rao@ethara.io',
      pod: 'Pod C',
    ),
    Person(
      id: 'P-7',
      name: 'Divya Menon',
      email: 'divya.menon@ethara.io',
      pod: 'Pod A',
    ),
    Person(
      id: 'P-8',
      name: 'Farhan Qureshi',
      email: 'farhan.q@ethara.io',
      pod: 'Pod B',
    ),
    Person(
      id: 'P-9',
      name: 'Nikhil Joshi',
      email: 'nikhil.joshi@ethara.io',
      pod: 'Pod C',
    ),
    Person(
      id: 'P-10',
      name: 'Tara Bhatt',
      email: 'tara.bhatt@ethara.io',
      pod: 'Pod A',
    ),
  ];

  // ── Generators ──────────────────────────────────────────────────────────
  static List<Generator> _generators() => <Generator>[
    Generator(
      id: 'GEN-1',
      name: 'Warehouse annotation SOP',
      owner: 'Aarav Mehta',
      created: '2 days ago',
      sopFile: 'warehouse-annotation-v4.pdf',
      questionCount: 34,
      plannedCount: 12,
      tagExtractState: TagExtractState.done,
      sopGenState: GenState.done,
      allowedTypes: const <QType>[
        QType.mcq,
        QType.msq,
        QType.subjectiveRubric,
        QType.imageLabel,
      ],
      tags: const <String>[
        'domain:logistics',
        'domain:warehousing',
        'skill:bounding-box',
        'skill:occlusion-handling',
        'skill:class-taxonomy',
        'policy:quality-gate',
      ],
      meta: _meta1,
      resources: const <Resource>[
        Resource(
          id: 'R-1',
          kind: ResourceKind.sop,
          file: 'warehouse-annotation-v4.pdf',
          size: '2.4 MB',
          pages: 38,
        ),
        Resource(
          id: 'R-2',
          kind: ResourceKind.reference,
          file: 'class-taxonomy-2026.xlsx',
          size: '188 KB',
          pages: 6,
        ),
        Resource(
          id: 'R-3',
          kind: ResourceKind.vendor,
          file: 'vendor-guidelines.zip',
          size: '11.2 MB',
          status: ResourceStatus.native,
        ),
      ],
      similar: const <Similarity>[
        Similarity(
          id: 'GEN-3',
          name: 'Warehouse annotation SOP (v3 archive)',
          band: SimBand.nearDuplicate,
          score: 91,
          why: 'Shares 5 of 6 skill tags and 82% of extracted requirements.',
        ),
      ],
    ),
    Generator(
      id: 'GEN-2',
      name: 'Product imagery review SOP',
      owner: 'Priya Nair',
      created: '5 hours ago',
      sopFile: 'product-imagery-review.docx',
      questionCount: 18,
      plannedCount: 16,
      tagExtractState: TagExtractState.done,
      sopGenState: GenState.done,
      allowedTypes: const <QType>[
        QType.imageAb,
        QType.imagePrompt,
        QType.subjectiveRubric,
      ],
      tags: const <String>[
        'domain:e-commerce',
        'skill:visual-quality',
        'skill:prompt-writing',
        'skill:instruction-fidelity',
      ],
      meta: _meta2,
      resources: const <Resource>[
        Resource(
          id: 'R-4',
          kind: ResourceKind.sop,
          file: 'product-imagery-review.docx',
          size: '840 KB',
          pages: 22,
        ),
        Resource(
          id: 'R-5',
          kind: ResourceKind.sample,
          file: 'golden-examples.json',
          size: '64 KB',
          pages: 1,
        ),
        Resource(
          id: 'R-6',
          kind: ResourceKind.client,
          file: 'client-brief-scan.pdf',
          size: '5.1 MB',
          status: ResourceStatus.failed,
          error: 'The scan carries no text layer. Re-upload with OCR.',
        ),
      ],
    ),
    Generator(
      id: 'GEN-3',
      name: 'Warehouse annotation SOP (v3 archive)',
      owner: 'Aarav Mehta',
      created: '3 weeks ago',
      sopFile: 'warehouse-annotation-v3.pdf',
      questionCount: 27,
      plannedCount: 12,
      tagExtractState: TagExtractState.done,
      sopGenState: GenState.done,
      allowedTypes: const <QType>[QType.mcq, QType.subjectiveRubric],
      tags: const <String>[
        'domain:logistics',
        'domain:warehousing',
        'skill:bounding-box',
        'skill:occlusion-handling',
        'skill:class-taxonomy',
      ],
      meta: _meta1,
      resources: const <Resource>[
        Resource(
          id: 'R-7',
          kind: ResourceKind.sop,
          file: 'warehouse-annotation-v3.pdf',
          size: '2.1 MB',
          pages: 34,
        ),
      ],
      similar: const <Similarity>[
        Similarity(
          id: 'GEN-1',
          name: 'Warehouse annotation SOP',
          band: SimBand.nearDuplicate,
          score: 91,
          why: 'Shares 5 of 6 skill tags and 82% of extracted requirements.',
        ),
      ],
    ),
    Generator(
      id: 'GEN-4',
      name: 'Video continuity SOP',
      owner: 'Aarav Mehta',
      created: 'just now',
      sopFile: 'video-continuity.pdf',
      questionCount: 0,
      plannedCount: 12,
      tagExtractState: TagExtractState.idle,
      sopGenState: GenState.idle,
      resources: const <Resource>[
        Resource(
          id: 'R-8',
          kind: ResourceKind.sop,
          file: 'video-continuity.pdf',
          size: '1.7 MB',
          pages: 19,
        ),
      ],
    ),
  ];

  static const Map<String, String> _meta1 = <String, String>{
    'SOP title': 'Warehouse object annotation, revision 4',
    'Summary':
        'How to draw, class and quality-check bounding boxes on warehouse '
        'floor imagery, including occlusion and truncation rules.',
    'Owner team': 'Annotation Ops',
    'Effective from': '2026-04-01',
    'Skills covered': '6',
    'Required elements': '19',
    'Rating scheme': 'Binary per element, aggregated to a 0-100 raw score',
    'Question spec': 'Two per skill, at least one applied',
    'Quality criteria': 'Box tightness, class correctness, occlusion flags',
    'Failure modes': 'Loose boxes, missing small objects, wrong class',
    'Gaps': 'No guidance on reflective surfaces',
    'Conflicts': 'Vendor guide contradicts SOP on truncation at 10%',
    'Injection flags': 'None detected',
    'Golden examples': '8 supplied',
  };

  static const Map<String, String> _meta2 = <String, String>{
    'SOP title': 'Product imagery review',
    'Summary':
        'How to judge generated product imagery against a written brief, and '
        'how to write a prompt that closes a gap.',
    'Owner team': 'Creative QA',
    'Effective from': '2026-06-15',
    'Skills covered': '4',
    'Required elements': '12',
    'Rating scheme': 'Six dimensions, A/B verdict plus justification',
    'Question spec': 'Three per skill, image-led',
    'Quality criteria': 'Instruction fidelity, visual quality, label accuracy',
    'Failure modes': 'Verdict without evidence, prompt that restates the brief',
    'Gaps': 'No rule for brand-colour drift',
    'Conflicts': 'None',
    'Injection flags': 'None detected',
    'Golden examples': '12 supplied',
  };

  static Map<String, String> metaFor(Generator g) => _meta1;

  static List<String> tagsFor(Generator g) => const <String>[
    'domain:media',
    'skill:continuity',
    'skill:shot-matching',
    'policy:quality-gate',
  ];

  // ── Questions ───────────────────────────────────────────────────────────
  static const List<QOption> _abScale = <QOption>[
    QOption(id: 'a', label: 'Response A'),
    QOption(id: 'b', label: 'Response B'),
    QOption(id: 'both', label: 'Both good'),
    QOption(id: 'neither', label: 'Both bad'),
  ];

  /// The six construction dimensions an image A/B question is rated on.
  static List<QDimension> _abDims() => <QDimension>[
    const QDimension(
      code: 'IF',
      name: 'Instruction fidelity',
      options: _abScale,
    ),
    const QDimension(code: 'VQ', name: 'Visual quality', options: _abScale),
    const QDimension(
      code: 'LAI',
      name: 'Label accuracy & integrity',
      options: _abScale,
    ),
    const QDimension(
      code: 'IDP',
      name: 'Image detail preservation',
      options: _abScale,
    ),
    const QDimension(
      code: 'CP',
      name: 'Consistency of practice',
      options: _abScale,
    ),
    // Overall choice is restricted to the two responses: "both" is not a
    // call, it is an evasion.
    const QDimension(
      code: 'OC',
      name: 'Overall choice',
      options: <QOption>[
        QOption(id: 'a', label: 'Response A', correct: true),
        QOption(id: 'b', label: 'Response B'),
      ],
    ),
  ];

  static List<Question> _bank() => <Question>[
    Question(
      id: 'Q-1',
      genId: 'GEN-1',
      type: QType.mcq,
      name: 'Box tightness threshold',
      prompt:
          'A pallet is partially hidden behind a forklift. How tight should '
          'the bounding box be drawn?',
      desc:
          'Refer to section 4.2 of the SOP, which covers occlusion and '
          'truncation.',
      dims: <QDimension>[
        const QDimension(
          code: 'D1',
          name: 'Answer',
          options: <QOption>[
            QOption(
              id: 'D1-0',
              label: 'Around the visible extent only',
              correct: true,
            ),
            QOption(id: 'D1-1', label: 'Around the estimated full object'),
            QOption(id: 'D1-2', label: 'Around the forklift as well'),
            QOption(id: 'D1-3', label: 'Skip the object entirely'),
          ],
        ),
      ],
      difficulty: Difficulty.medium,
      state: DraftState.approved,
      usedIn: 3,
      tags: const <String>['skill:bounding-box', 'skill:occlusion-handling'],
    ),
    Question(
      id: 'Q-2',
      genId: 'GEN-1',
      type: QType.msq,
      name: 'Occlusion flags',
      prompt: 'Which conditions require the occlusion flag to be set?',
      desc: 'Select all that apply.',
      dims: <QDimension>[
        const QDimension(
          code: 'D1',
          name: 'Answer',
          options: <QOption>[
            QOption(
              id: 'D1-0',
              label: 'Another object covers more than 25% of it',
              correct: true,
            ),
            QOption(
              id: 'D1-1',
              label: 'The object leaves the frame',
              correct: true,
            ),
            QOption(id: 'D1-2', label: 'The object is blurry'),
            QOption(id: 'D1-3', label: 'A shadow falls across it'),
          ],
        ),
      ],
      difficulty: Difficulty.easy,
      state: DraftState.approved,
      usedIn: 3,
      tags: const <String>['skill:occlusion-handling'],
    ),
    Question(
      id: 'Q-3',
      genId: 'GEN-1',
      type: QType.subjectiveRubric,
      name: 'Explain a rejected batch',
      prompt:
          'A batch of 400 annotations was rejected at quality gate. Explain '
          'the three checks you would run first, and why that order.',
      desc: 'Write in your own words. There is no single right answer.',
      rubric: const <String>[
        'Names at least three concrete checks from the SOP.',
        'Orders them by how cheaply they eliminate a cause.',
        'Refers to the quality-gate thresholds rather than to feel.',
        'Distinguishes a systemic fault from a per-annotator one.',
      ],
      difficulty: Difficulty.hard,
      rubricReviewed: true,
      state: DraftState.approved,
      usedIn: 2,
      tags: const <String>['policy:quality-gate'],
    ),
    Question(
      id: 'Q-4',
      genId: 'GEN-1',
      type: QType.imageLabel,
      name: 'Name each marked region',
      prompt: 'Label each numbered box on the warehouse floor frame.',
      desc: 'Use the class names from the taxonomy. One short phrase per box.',
      images: <Asset>[
        Asset(
          id: 'A-1',
          label: 'Warehouse floor frame with annotation boxes',
          regions: const <LabelRegion>[
            LabelRegion(number: 1, x: .06, y: .18, w: .20, h: .30),
            LabelRegion(number: 2, x: .32, y: .12, w: .16, h: .24),
            LabelRegion(number: 3, x: .54, y: .22, w: .22, h: .34),
            LabelRegion(number: 4, x: .10, y: .58, w: .18, h: .26),
            LabelRegion(number: 5, x: .38, y: .52, w: .14, h: .22),
            LabelRegion(number: 6, x: .60, y: .62, w: .20, h: .24),
            LabelRegion(number: 7, x: .82, y: .30, w: .13, h: .40),
            LabelRegion(number: 8, x: .80, y: .74, w: .15, h: .18),
            LabelRegion(number: 9, x: .26, y: .78, w: .12, h: .16),
            LabelRegion(number: 10, x: .46, y: .80, w: .12, h: .14),
          ],
        ),
      ],
      boxKey: const <int, String>{
        1: 'Pallet, wrapped',
        2: 'Forklift',
        3: 'Shelving unit',
        4: 'Carton stack',
        5: 'Floor marking',
        6: 'Pallet, unwrapped',
        7: 'Safety barrier',
        8: 'Trolley',
        9: 'Spill hazard',
        10: 'Signage',
      },
      imageState: AssetState.rendered,
      difficulty: Difficulty.medium,
      state: DraftState.approved,
      usedIn: 1,
      tags: const <String>['skill:class-taxonomy'],
    ),
    Question(
      id: 'Q-5',
      genId: 'GEN-2',
      type: QType.imageAb,
      name: 'Which render follows the brief',
      prompt:
          'Two renders were produced from the same brief. Which one follows '
          'it more closely?',
      desc: 'Rate each dimension, then make the overall call and justify it.',
      images: <Asset>[
        const Asset(id: 'A-2', label: 'Response A'),
        const Asset(id: 'A-3', label: 'Response B'),
      ],
      dims: _abDims(),
      imageState: AssetState.rendered,
      difficulty: Difficulty.hard,
      state: DraftState.approved,
      usedIn: 1,
      tags: const <String>['skill:instruction-fidelity'],
    ),
    Question(
      id: 'Q-6',
      genId: 'GEN-2',
      type: QType.imagePrompt,
      name: 'Fix the primary defect',
      prompt:
          'Identify the primary defect in this render, then write the '
          'image-generation prompt that fixes it.',
      desc: 'Name the defect first; the prompt is scored against your call.',
      images: <Asset>[const Asset(id: 'A-4', label: 'Source frame')],
      dims: <QDimension>[
        const QDimension(
          code: 'D1',
          name: 'Primary defect',
          options: <QOption>[
            QOption(id: 'D1-0', label: 'Loose boxes', correct: true),
            QOption(id: 'D1-1', label: 'Missing object'),
            QOption(id: 'D1-2', label: 'Wrong class'),
          ],
        ),
      ],
      imageState: AssetState.rendered,
      difficulty: Difficulty.medium,
      state: DraftState.approved,
      usedIn: 1,
      tags: const <String>['skill:prompt-writing'],
    ),
    Question(
      id: 'Q-7',
      genId: 'GEN-2',
      type: QType.videoPrompt,
      name: 'Close the continuity gap',
      prompt:
          'The output clip drifts from the reference. Write the prompt that '
          'closes the gap.',
      desc:
          'Watch both clips. Your prompt is judged on whether it names the '
          'specific drift.',
      videos: <Asset>[
        const Asset(id: 'A-5', label: 'Reference'),
        const Asset(id: 'A-6', label: 'Output'),
      ],
      videoState: AssetState.rendered,
      difficulty: Difficulty.hard,
      state: DraftState.approved,
      usedIn: 1,
      tags: const <String>['skill:continuity'],
    ),
    Question(
      id: 'Q-8',
      genId: 'GEN-1',
      type: QType.mcq,
      name: 'Truncation at the frame edge',
      prompt:
          'An object is cut off by the right edge of the frame. What do you '
          'do?',
      dims: <QDimension>[
        const QDimension(
          code: 'D1',
          name: 'Answer',
          options: <QOption>[
            QOption(
              id: 'D1-0',
              label: 'Box the visible part and set truncated',
              correct: true,
            ),
            QOption(id: 'D1-1', label: 'Extend the box past the frame'),
            QOption(id: 'D1-2', label: 'Leave it unannotated'),
            QOption(id: 'D1-3', label: 'Box it and set occluded'),
          ],
        ),
      ],
      difficulty: Difficulty.easy,
      state: DraftState.approved,
      usedIn: 2,
      tags: const <String>['skill:bounding-box'],
    ),
    // A bank row with an invalid key, so the "invalid answer key" banner on
    // the bank screen has something to report.
    Question(
      id: 'Q-9',
      genId: 'GEN-3',
      type: QType.mcq,
      name: 'Legacy: shelf depth rule',
      prompt: 'How is shelf depth recorded on a v3 annotation?',
      dims: <QDimension>[
        const QDimension(
          code: 'D1',
          name: 'Answer',
          options: <QOption>[
            QOption(id: 'D1-0', label: 'In centimetres'),
            QOption(id: 'D1-1', label: 'As a bucket'),
            QOption(id: 'D1-2', label: 'It is not recorded'),
          ],
        ),
      ],
      difficulty: Difficulty.easy,
      state: DraftState.approved,
      answerKeyValid: false,
      active: false,
      usedIn: 0,
      tags: const <String>['domain:warehousing'],
    ),
    Question(
      id: 'Q-10',
      genId: 'GEN-1',
      type: QType.subjectiveRubric,
      name: 'Conflicting guidance',
      prompt:
          'The vendor guide and the SOP disagree on truncation at 10%. '
          'Which do you follow, and how do you record the decision?',
      rubric: const <String>[
        'States that the SOP governs.',
        'Records the conflict rather than silently choosing.',
        'Names who is told and through what channel.',
      ],
      difficulty: Difficulty.hard,
      rubricReviewed: true,
      state: DraftState.approved,
      usedIn: 1,
      tags: const <String>['policy:quality-gate'],
    ),
  ];

  static List<Question> _drafts() => <Question>[
    Question(
      id: 'D-1',
      genId: 'GEN-1',
      type: QType.mcq,
      name: 'Small object minimum size',
      prompt:
          'What is the minimum pixel size at which a small object must '
          'still be annotated?',
      desc: 'Section 4.5 of the SOP.',
      dims: <QDimension>[
        const QDimension(
          code: 'D1',
          name: 'Answer',
          options: <QOption>[
            QOption(id: 'D1-0', label: '8 x 8 pixels', correct: true),
            QOption(id: 'D1-1', label: '16 x 16 pixels'),
            QOption(id: 'D1-2', label: '32 x 32 pixels'),
            QOption(id: 'D1-3', label: 'There is no minimum'),
          ],
        ),
      ],
      difficulty: Difficulty.easy,
    ),
    // A draft whose distractor gives the answer away: a BLOCKING warning,
    // so approving it requires an explicit acknowledgement.
    Question(
      id: 'D-2',
      genId: 'GEN-1',
      type: QType.mcq,
      name: 'Class of a wrapped pallet',
      prompt: 'A pallet is shrink-wrapped. Which class applies?',
      dims: <QDimension>[
        const QDimension(
          code: 'D1',
          name: 'Answer',
          options: <QOption>[
            QOption(id: 'D1-0', label: 'Pallet, wrapped', correct: true),
            QOption(id: 'D1-1', label: 'Not "Pallet, wrapped"'),
            QOption(id: 'D1-2', label: 'Carton stack'),
          ],
        ),
      ],
      hasRevealingOption: true,
      difficulty: Difficulty.easy,
    ),
    // A draft that points the candidate at a document they will never be
    // given: blocking, because it cannot be answered from what is on screen.
    Question(
      id: 'D-3',
      genId: 'GEN-1',
      type: QType.subjectiveRubric,
      name: 'Describe an escalation',
      prompt:
          'Per Section 4.2 of the SOP, describe how you would escalate a '
          'systemic annotation fault.',
      rubric: const <String>[
        'Names the first responder.',
        'States the evidence attached to the escalation.',
      ],
      citesSource: true,
      difficulty: Difficulty.hard,
    ),
    Question(
      id: 'D-4',
      genId: 'GEN-2',
      type: QType.imageAb,
      name: 'Colour drift comparison',
      prompt: 'Which render holds the brand colour more faithfully?',
      desc: 'Rate each dimension before making the overall call.',
      images: <Asset>[
        const Asset(id: 'A-7', label: 'Response A'),
        const Asset(id: 'A-8', label: 'Response B'),
      ],
      dims: _abDims(),
      imageState: AssetState.rendered,
      difficulty: Difficulty.hard,
    ),
    // A draft whose stimulus failed to render: blocking, because the
    // candidate would be shown an empty plate.
    Question(
      id: 'D-5',
      genId: 'GEN-2',
      type: QType.imagePrompt,
      name: 'Recover a blown highlight',
      prompt:
          'The highlight on the product is blown out. Write the prompt that '
          'recovers it.',
      images: const <Asset>[],
      dims: <QDimension>[
        const QDimension(
          code: 'D1',
          name: 'Primary defect',
          options: <QOption>[
            QOption(id: 'D1-0', label: 'Blown highlight', correct: true),
            QOption(id: 'D1-1', label: 'Crushed shadow'),
            QOption(id: 'D1-2', label: 'Colour cast'),
          ],
        ),
      ],
      imageState: AssetState.failed,
      imageError: 'The renderer returned a safety block on attempt 3 of 3.',
      difficulty: Difficulty.medium,
    ),
    Question(
      id: 'D-6',
      genId: 'GEN-2',
      type: QType.subjectiveRubric,
      name: 'Why a prompt failed',
      prompt:
          'A prompt produced the same defect three times. What does that '
          'tell you, and what do you change?',
      rubric: const <String>[
        'Recognises that repetition points at the brief, not the model.',
        'Proposes one change at a time.',
      ],
      difficulty: Difficulty.hard,
    ),
    Question(
      id: 'D-7',
      genId: 'GEN-1',
      type: QType.msq,
      name: 'Quality gate triggers',
      prompt: 'Which of these send a batch back to the annotator?',
      dims: <QDimension>[
        const QDimension(
          code: 'D1',
          name: 'Answer',
          options: <QOption>[
            QOption(
              id: 'D1-0',
              label: 'More than 5% loose boxes',
              correct: true,
            ),
            QOption(
              id: 'D1-1',
              label: 'Any wrong class on a safety item',
              correct: true,
            ),
            QOption(id: 'D1-2', label: 'A single missing small object'),
            QOption(id: 'D1-3', label: 'Slow throughput'),
          ],
        ),
      ],
      difficulty: Difficulty.medium,
    ),
    Question(
      id: 'D-8',
      genId: 'GEN-1',
      type: QType.imageLabel,
      name: 'Label the loading bay',
      prompt: 'Name each numbered region in the loading bay frame.',
      images: <Asset>[
        Asset(
          id: 'A-9',
          label: 'Loading bay frame with annotation boxes',
          regions: const <LabelRegion>[
            LabelRegion(number: 1, x: .08, y: .20, w: .22, h: .32),
            LabelRegion(number: 2, x: .36, y: .16, w: .18, h: .28),
            LabelRegion(number: 3, x: .60, y: .26, w: .24, h: .30),
            LabelRegion(number: 4, x: .14, y: .62, w: .20, h: .24),
            LabelRegion(number: 5, x: .44, y: .58, w: .16, h: .26),
            LabelRegion(number: 6, x: .68, y: .66, w: .18, h: .22),
          ],
        ),
      ],
      boxKey: const <int, String>{
        1: 'Dock leveller',
        2: 'Roll cage',
        3: 'Delivery vehicle',
        4: 'Floor marking',
        5: 'Pallet jack',
        6: 'Safety bollard',
      },
      imageState: AssetState.rendered,
      difficulty: Difficulty.medium,
    ),
    Question(
      id: 'D-9',
      genId: 'GEN-2',
      type: QType.videoPrompt,
      name: 'Lighting continuity',
      prompt:
          'The lighting shifts between the reference and the output. Write '
          'the prompt that holds it steady.',
      videos: <Asset>[
        const Asset(id: 'A-10', label: 'Reference'),
        const Asset(id: 'A-11', label: 'Output'),
      ],
      videoState: AssetState.partial,
      difficulty: Difficulty.hard,
    ),
    Question(
      id: 'D-10',
      genId: 'GEN-1',
      type: QType.mcq,
      name: 'Reflective surface handling',
      prompt: 'A shelf has a mirrored face. How is the reflection treated?',
      dims: <QDimension>[
        const QDimension(
          code: 'D1',
          name: 'Answer',
          options: <QOption>[
            QOption(
              id: 'D1-0',
              label: 'Reflections are never annotated',
              correct: true,
            ),
            QOption(id: 'D1-1', label: 'Annotate with a reflection flag'),
            QOption(id: 'D1-2', label: 'Annotate as the real object'),
          ],
        ),
      ],
      difficulty: Difficulty.medium,
    ),
    // Already decided, so the review-queue counts and the undo path have
    // something behind them.
    Question(
      id: 'D-11',
      genId: 'GEN-1',
      type: QType.mcq,
      name: 'Batch size limit',
      prompt: 'What is the maximum batch size for a single reviewer?',
      dims: <QDimension>[
        const QDimension(
          code: 'D1',
          name: 'Answer',
          options: <QOption>[
            QOption(id: 'D1-0', label: '500', correct: true),
            QOption(id: 'D1-1', label: '1000'),
          ],
        ),
      ],
      state: DraftState.approved,
      difficulty: Difficulty.easy,
    ),
    Question(
      id: 'D-12',
      genId: 'GEN-2',
      type: QType.mcq,
      name: 'Duplicate of D-2',
      prompt: 'A pallet is shrink-wrapped. Which class applies?',
      dims: <QDimension>[
        const QDimension(
          code: 'D1',
          name: 'Answer',
          options: <QOption>[
            QOption(id: 'D1-0', label: 'Pallet, wrapped', correct: true),
            QOption(id: 'D1-1', label: 'Carton stack'),
          ],
        ),
      ],
      state: DraftState.denied,
      denyReason: 'Duplicate of D-2.',
      difficulty: Difficulty.easy,
    ),
  ];

  /// Drafts produced by a completed generation run.
  static List<Question> generateDrafts(Generator g, int n, int offset) {
    final List<Question> out = <Question>[];
    for (int i = 0; i < n; i++) {
      final String id = 'D-${offset + i + 1}';
      final QType type = g.allowedTypes.isEmpty
          ? QType.mcq
          : seededPick<QType>('$id|type', g.allowedTypes);
      out.add(
        Question(
          id: id,
          genId: g.id,
          type: type,
          name: 'Generated question ${offset + i + 1}',
          prompt:
              'A question drawn from ${g.sopFile} covering '
              '${g.tags.isEmpty ? 'the document' : seededPick<String>('$id|tag', g.tags)}.',
          desc: 'Generated on this run and awaiting review.',
          dims: type.isObjective
              ? <QDimension>[
                  QDimension(
                    code: 'D1',
                    name: 'Answer',
                    options: <QOption>[
                      const QOption(
                        id: 'D1-0',
                        label: 'The correct option',
                        correct: true,
                      ),
                      const QOption(
                        id: 'D1-1',
                        label: 'A plausible distractor',
                      ),
                      const QOption(id: 'D1-2', label: 'Another distractor'),
                    ],
                  ),
                ]
              : const <QDimension>[],
          rubric: type.isSubjective
              ? const <String>[
                  'Names the governing rule.',
                  'Gives one concrete example.',
                ]
              : const <String>[],
          // 20, where the old spelling said 80 for the inverse property: the
          // same one-in-five drafts carry the smell.
          citesSource: seededBool('$id|src', 20),
          hasRevealingOption: seededBool('$id|rev', 12),
          difficulty: seededPick<Difficulty>('$id|diff', Difficulty.values),
          imageState: type.needsImage ? AssetState.rendered : null,
          videoState: type.needsVideo ? AssetState.rendered : null,
        ),
      );
    }
    return out;
  }

  // ── Assessments ─────────────────────────────────────────────────────────
  static List<Assessment> _assessments(List<Question> bank) {
    List<Question> pick(String genId, int n) => bank
        .where((Question q) => q.genId == genId && q.launchReady)
        .take(n)
        .toList();

    final DateTime now = DateTime(2026, 8, 4, 9);
    return <Assessment>[
      Assessment(
        id: 'A-1',
        name: 'Warehouse annotation - Pod A certification',
        state: AsmState.inProgress,
        generatorId: 'GEN-1',
        generatorName: 'Warehouse annotation SOP',
        projectId: 'P-1',
        startDate: now.subtract(const Duration(days: 2)),
        endDate: now.add(const Duration(days: 5)),
        durationMinutes: 45,
        questions: pick('GEN-1', 6),
        passThreshold: 60,
        subjectiveThreshold: 60,
        requireReviewedRubric: true,
        violationAction: ViolationAction.autoSubmit,
        maxViolations: 3,
      ),
      Assessment(
        id: 'A-2',
        name: 'Product imagery review - onboarding',
        state: AsmState.inProgress,
        generatorId: 'GEN-2',
        generatorName: 'Product imagery review SOP',
        projectId: 'P-2',
        startDate: now.subtract(const Duration(days: 1)),
        endDate: now.add(const Duration(days: 9)),
        durationMinutes: 60,
        questions: pick('GEN-2', 3),
        passThreshold: 50,
        subjectiveThreshold: 55,
        violationAction: ViolationAction.logOnly,
        maxViolations: 5,
      ),
      Assessment(
        id: 'A-3',
        name: 'Warehouse annotation - Pod B refresher',
        state: AsmState.draft,
        generatorId: 'GEN-1',
        generatorName: 'Warehouse annotation SOP',
        projectId: 'P-4',
        startDate: now.add(const Duration(days: 3)),
        endDate: now.add(const Duration(days: 14)),
        durationMinutes: 30,
        questions: pick('GEN-1', 4),
        passThreshold: 60,
        subjectiveThreshold: 60,
      ),
      Assessment(
        id: 'A-4',
        name: 'Video continuity - pilot',
        state: AsmState.done,
        generatorId: 'GEN-2',
        generatorName: 'Product imagery review SOP',
        startDate: now.subtract(const Duration(days: 30)),
        endDate: now.subtract(const Duration(days: 16)),
        durationMinutes: 40,
        questions: pick('GEN-2', 2),
        passThreshold: 50,
        subjectiveThreshold: 50,
      ),
      Assessment(
        id: 'A-5',
        name: 'Legacy v3 recertification',
        state: AsmState.cancelled,
        generatorId: 'GEN-3',
        generatorName: 'Warehouse annotation SOP (v3 archive)',
        startDate: now.subtract(const Duration(days: 60)),
        endDate: now.subtract(const Duration(days: 45)),
        durationMinutes: 30,
        questions: const <Question>[],
        passThreshold: 60,
        subjectiveThreshold: 60,
      ),
    ];
  }

  /// One seeded answer's option picks, and how many KEYED dimensions it got
  /// right.
  ///
  /// PER DIMENSION, because the mark is. A keyed dimension is one component
  /// and is won or lost on its own, so the fixture rolls the dice once per
  /// axis rather than once per question - otherwise demo mode could only ever
  /// show a full mark or a zero, and the partial credit the module now awards
  /// would appear nowhere a reviewer could see it.
  ///
  /// An UNKEYED dimension still gets a pick, so the answer renders, but is not
  /// counted: it is not a component (see `Question.componentCount`), and an
  /// A/B rating axis with no correct option is a request for an opinion.
  static ({List<String> lines, int passed}) _picks(Question q, String key) {
    final List<String> lines = <String>[];
    int passed = 0;
    for (final QDimension d in q.dims) {
      if (d.options.isEmpty) continue;
      final Set<String> want = d.correctIds;
      if (want.isEmpty) {
        lines.add(
          d.options[seededInt('$key|${d.code}', 0, d.options.length)].id,
        );
        continue;
      }
      if (seededBool('$key|${d.code}', 64)) {
        lines.addAll(want);
        passed++;
      } else {
        lines.add(
          d.options
              .firstWhere(
                (QOption o) => !o.correct,
                orElse: () => d.options.first,
              )
              .id,
        );
      }
    }
    return (lines: lines, passed: passed);
  }

  // ── Attempts ────────────────────────────────────────────────────────────
  static List<Attempt> _attempts(List<Assessment> asms, List<Person> people) {
    final List<Attempt> out = <Attempt>[];

    Attempt make(
      Assessment asm,
      Person p, {
      required AttemptState state,
      bool released = false,
      InviteState invite = InviteState.sent,
      bool errorAnswer = false,
      bool pendingAnswer = false,
      bool autoSubmitted = false,
      int violations = 0,
      bool integrity = false,
      bool outlier = false,
    }) {
      final String id = 'EV-${asm.id}-${p.id}';
      final bool done = state == AttemptState.submitted;
      final Map<String, Response> resp = <String, Response>{};

      if (state != AttemptState.pending) {
        // How many of the questions this person reached. A partial attempt is
        // the interesting case, so the seed spreads across the range rather
        // than filling every one.
        final int reach = done
            ? asm.questions.length
            : seededInt('$id|reach', 1, asm.questions.length + 1);

        // The error and still-grading flags land on the FIRST SUBJECTIVE
        // answer, not on question index 0. An objective answer has no grader
        // state to be in, so keying on the index would silently produce an
        // attempt with no unresolved answer at all - which is exactly the
        // state these flags exist to create.
        bool subjectiveSeen = false;

        for (int i = 0; i < reach; i++) {
          final Question q = asm.questions[i];
          final String key = '$id|${q.id}';

          if (q.type.isObjective) {
            final ({List<String> lines, int passed}) picked = _picks(q, key);
            resp[q.id] = Response(
              lines: picked.lines,
              score: done ? picked.passed : 0,
              maxScore: q.componentCount,
              state: done ? 'submitted' : 'draft',
              llmState: LlmState.notNeeded,
            );
          } else {
            final double raw = seededDouble(key, 22, 94);
            // Only the types whose answer HAS option axes get picks; a rubric
            // or a video answer is prose alone and must not acquire lines.
            final ({List<String> lines, int passed}) abPicks =
                q.type == QType.imageAb || q.type == QType.imagePrompt
                ? _picks(q, key)
                : (lines: const <String>[], passed: 0);
            final bool graded = done && !errorAnswer && !pendingAnswer;
            final bool isFirstSubjective = !subjectiveSeen;
            subjectiveSeen = true;
            final LlmState ls = !done
                ? LlmState.pending
                : errorAnswer && isFirstSubjective
                ? LlmState.error
                : pendingAnswer && isFirstSubjective
                ? LlmState.scoring
                : LlmState.scored;
            resp[q.id] = Response(
              justification: _answerText(q, key),
              labels: q.boxKey.isEmpty
                  ? null
                  : <int, String>{
                      for (final int n in q.boxKey.keys)
                        if (seededBool('$key|$n', 78)) n: q.boxKey[n]!,
                    },
              // REAL OPTION IDS, not `'IF-2'`. These were synthesised from
              // the dimension code and an index, so they matched nothing the
              // question actually holds: the answer sheet's `chosen` join
              // found no labels and an A/B answer read as nothing selected -
              // and now that each keyed axis is a MARK, an unmatchable pick is
              // a component the seeded candidate could never earn.
              lines: abPicks.lines,
              score: ls == LlmState.scored
                  ? abPicks.passed + (raw >= asm.subjectiveThreshold ? 1 : 0)
                  : 0,
              maxScore: q.componentCount,
              state: done ? 'submitted' : 'draft',
              llmState: ls,
              llmRaw100: graded || ls == LlmState.scored ? raw : null,
              llmError: ls == LlmState.error
                  ? 'Vertex returned RESOURCE_EXHAUSTED on attempt 3 of 3.'
                  : null,
              judge: ls == LlmState.scored ? judgeFor(asm, q, raw) : null,
            );
          }
        }
      }

      return Attempt(
        id: id,
        assessmentId: asm.id,
        employeeId: p.id,
        token: 'tok-${stableHash(id).toRadixString(36)}',
        state: state,
        isLocked: done,
        questionOrder: asm.questions.map((Question q) => q.id).toList(),
        // A SUBMITTED attempt is stamped in the past, because that is where it
        // happened. An IN-PROGRESS one is anchored to the clock: an attempt
        // whose start is a fixed date in the past is not in progress, it is
        // expired, and the exam would open straight onto the "time is up"
        // overlay. Time is the one thing the seed is allowed to read.
        startedAt: switch (state) {
          AttemptState.pending => null,
          AttemptState.inProgress => DateTime.now().subtract(
            Duration(minutes: seededInt('$id|elapsed', 2, 9)),
          ),
          AttemptState.submitted => DateTime(
            2026,
            8,
            3,
            10,
            seededInt('$id|min', 0, 59),
          ),
        },
        submittedAt: done
            ? DateTime(2026, 8, 3, 11, seededInt('$id|smin', 0, 59))
            : null,
        inviteState: invite,
        violationCount: violations,
        violationReason: violations > 0 ? 'Tab switched' : '',
        violationAt: violations > 0 ? DateTime(2026, 8, 3, 10, 40) : null,
        autoSubmitted: autoSubmitted,
        resultsReleased: released,
        integrityAlert: integrity,
        scoreOutlier: outlier,
        resp: resp,
      );
    }

    final Assessment a1 = asms[0];
    final Assessment a2 = asms[1];
    final Assessment a3 = asms[2];
    final Assessment a4 = asms[3];

    // A-1: live, a spread of every attempt state including a terminal scoring
    // error (which holds that attempt's result on pending) and an unreleased
    // completed attempt.
    out.addAll(<Attempt>[
      make(a1, people[0], state: AttemptState.inProgress),
      make(a1, people[1], state: AttemptState.submitted, released: true),
      make(
        a1,
        people[2],
        state: AttemptState.submitted,
        errorAnswer: true,
        released: false,
      ),
      make(
        a1,
        people[3],
        state: AttemptState.submitted,
        released: true,
        outlier: true,
      ),
      make(
        a1,
        people[4],
        state: AttemptState.pending,
        invite: InviteState.failed,
      ),
      make(
        a1,
        people[5],
        state: AttemptState.submitted,
        autoSubmitted: true,
        violations: 3,
        integrity: true,
        released: true,
      ),
      make(
        a1,
        people[6],
        state: AttemptState.pending,
        invite: InviteState.queued,
      ),
      // Fully graded, NOT yet released. Without at least one of these the
      // release action is unreachable in the seed: every resolved attempt
      // would already be released and every unreleased one would be held on
      // grading, so the release sheet could never be opened or demonstrated.
      make(a1, people[7], state: AttemptState.submitted, released: false),
    ]);

    // A-2: live, image-led, one still grading.
    out.addAll(<Attempt>[
      make(a2, people[0], state: AttemptState.pending),
      make(a2, people[2], state: AttemptState.inProgress, violations: 1),
      make(a2, people[7], state: AttemptState.submitted, pendingAnswer: true),
      make(a2, people[8], state: AttemptState.submitted, released: true),
    ]);

    // A-3: a draft, so nothing is invited yet.
    out.addAll(<Attempt>[
      make(
        a3,
        people[3],
        state: AttemptState.pending,
        invite: InviteState.none,
      ),
      make(
        a3,
        people[4],
        state: AttemptState.pending,
        invite: InviteState.none,
      ),
      make(
        a3,
        people[9],
        state: AttemptState.pending,
        invite: InviteState.none,
      ),
    ]);

    // A-4: closed and fully released, so the analytics have history.
    out.addAll(<Attempt>[
      make(a4, people[0], state: AttemptState.submitted, released: true),
      make(a4, people[1], state: AttemptState.submitted, released: true),
      make(a4, people[5], state: AttemptState.submitted, released: true),
    ]);

    return out;
  }

  static String _answerText(Question q, String key) => switch (q.type) {
    QType.subjectiveRubric =>
      'I would start with the cheapest check that can eliminate a whole '
          'cause. First the class distribution against the taxonomy, because '
          'a systemic mis-class shows up immediately there. Then box '
          'tightness on a sample of 40, since that is where the gate '
          'threshold bites. Last the occlusion flags, which are slower to '
          'verify and rarely the sole cause.',
    QType.imageAb =>
      'Response A holds the brief more closely on label placement and '
          'keeps the product edge clean. B looks better at a glance but '
          'moves the label, which the brief fixes explicitly.',
    QType.imagePrompt =>
      'Tighten the bounding boxes to the visible extent of each object; '
          'keep the existing classes; do not extend past the frame edge.',
    QType.videoPrompt =>
      'Hold the key light at the same angle and intensity across the cut; '
          'match the colour temperature to the reference and keep the '
          'camera height fixed.',
    QType.imageLabel => '',
    _ => '',
  };

  /// A judge payload derived from the identifiers, so an audit sheet always
  /// shows the same numbers for the same answer.
  static Judge judgeFor(Assessment asm, Question q, double raw) {
    final String k = '${asm.id}|${q.id}|judge';
    final bool passed = raw >= asm.barFor(q.type);
    return Judge(
      profile: q.type == QType.imageAb
          ? 'image_ab_v3'
          : q.type == QType.videoPrompt
          ? 'video_prompt_v2'
          : 'rubric_generic_v5',
      gate: passed ? 'passed' : 'below_threshold',
      verdict: passed
          ? 'The answer meets the rubric on every required element.'
          : 'The answer covers part of the rubric but misses a required element.',
      raw100: raw,
      keyCloseness: seededDouble('$k|key', .35, .97),
      sopCoverage: seededDouble('$k|sop', .30, .95),
      clarity: seededPick<String>('$k|clarity', const <String>[
        'high',
        'medium',
        'low',
      ]),
      aiConfidence: seededPick<String>('$k|ai', const <String>[
        'unlikely',
        'possible',
        'likely',
      ]),
      verdictConsistency: seededPick<String>('$k|vc', const <String>[
        'consistent',
        'mixed',
      ]),
      rubricSource: q.rubric.isNotEmpty
          ? 'question rubric'
          : 'generator default',
      deductions: passed
          ? const <JudgeNote>[]
          : <JudgeNote>[
              JudgeNote(
                points: -seededDouble('$k|d1', 8, 22),
                reason: 'Does not name the governing threshold.',
                evidence:
                    'The answer refers to "the usual bar" without a figure.',
              ),
              JudgeNote(
                points: -seededDouble('$k|d2', 5, 15),
                reason:
                    'No distinction between a systemic and a per-person fault.',
                evidence: 'Both are treated as the same escalation.',
              ),
            ],
      credit: <JudgeNote>[
        JudgeNote(
          points: seededDouble('$k|c1', 10, 30),
          reason: 'Orders the checks by elimination cost.',
          evidence: 'Class distribution first, then tightness, then flags.',
        ),
      ],
      claims: <JudgeNote>[
        JudgeNote(
          reason: 'Names at least three concrete checks',
          verdict: 'hit',
          kind: 'required',
          evidence: 'Three checks are named in order.',
        ),
        JudgeNote(
          reason: 'Refers to the quality-gate thresholds',
          verdict: passed ? 'hit' : 'partial',
          kind: 'required',
          evidence: passed
              ? 'The 5% loose-box gate is cited.'
              : 'The gate is alluded to but not quantified.',
        ),
        JudgeNote(
          reason: 'Distinguishes systemic from per-annotator',
          verdict: passed ? 'hit' : 'miss',
          kind: 'desirable',
          evidence: passed ? 'Both paths are separated.' : 'Not addressed.',
        ),
      ],
      referenceAnswer:
          'A model answer runs the class distribution first because a '
          'mis-class is systemic and cheap to spot, then samples box tightness '
          'against the 5% gate, then verifies occlusion flags. It separates a '
          'systemic fault, which goes to the SOP owner, from a per-annotator '
          'one, which goes to the pod lead.',
      // Demo text, but it must describe the marking the product actually
      // does: the old weighted sum (0.60 key closeness / 0.25 SOP coverage /
      // 0.15 clarity) was retired with the drop-2 prompt, which stopped
      // emitting the inputs it needed. Seed prose that teaches a retired
      // model is worse than none - an operator reads this while learning the
      // screen.
      reasoning:
          'The response was matched against the rubric element by element. '
          'Each shortfall was itemised as a deduction with the evidence for '
          'it, and the raw score was rebuilt from those deductions rather '
          'than taken from the grader headline. The assessment threshold '
          'then decides whether this component earned its mark.',
      judgeModel: 'gemini-2.5-pro',
      attempts: seededInt('$k|att', 1, 3),
      scoredHash: stableHash(k).toRadixString(16),
    );
  }

  // ── Jobs ────────────────────────────────────────────────────────────────
  static List<Job> _jobs() => const <Job>[
    Job(
      id: 'JOB-1',
      genId: 'GEN-2',
      name: 'Creating images',
      state: JobState.running,
      progress: 62,
      meta: '11 / 17',
      detail: 'Rendering the A/B pairs. Drafts appear as each batch lands.',
      kind: JobKind.image,
      want: 17,
    ),
    Job(
      id: 'JOB-2',
      genId: 'GEN-2',
      name: 'Rendering video clips',
      state: JobState.partial,
      progress: 100,
      meta: '2 / 3',
      detail: 'Clip 3 failed with a safety block. The other two landed.',
      kind: JobKind.video,
      retry: 'retry-video',
      want: 3,
    ),
    Job(
      id: 'JOB-3',
      genId: 'GEN-1',
      name: 'Detecting label regions',
      state: JobState.done,
      progress: 100,
      meta: '17 / 17',
      detail: 'All images rendered.',
      kind: JobKind.detect,
      want: 17,
    ),
  ];

  // ── Ledger ──────────────────────────────────────────────────────────────
  static List<LedgerRow> _ledger(List<Generator> gens, List<Attempt> attempts) {
    final List<LedgerRow> out = <LedgerRow>[];
    const List<String> models = <String>[
      'gemini-2.5-pro',
      'gemini-2.5-flash',
      'imagen-4.0',
      'veo-3.0',
    ];

    int n = 0;
    for (final Generator g in gens) {
      for (final LedgerOp op in <LedgerOp>[
        LedgerOp.extractTags,
        LedgerOp.generateQuestions,
        LedgerOp.renderImage,
        LedgerOp.similarity,
      ]) {
        final String id = 'L-${++n}';
        out.add(
          LedgerRow(
            id: id,
            op: op,
            model: seededPick<String>('$id|m', models),
            genId: g.id,
            tokensIn: seededInt('$id|in', 1200, 48000),
            tokensOut: seededInt('$id|out', 300, 9000),
            thoughts: seededInt('$id|th', 0, 4200),
            images: op == LedgerOp.renderImage
                ? seededInt('$id|img', 1, 18)
                : 0,
            cost: seededDouble('$id|c', .02, 2.4),
            at: DateTime(2026, 8, 1 + (n % 3), 9 + (n % 8)),
          ),
        );
      }
    }

    for (final Attempt ev in attempts.take(12)) {
      final String id = 'L-${++n}';
      out.add(
        LedgerRow(
          id: id,
          op: LedgerOp.scoreSubjective,
          model: 'gemini-2.5-pro',
          evId: ev.id,
          tokensIn: seededInt('$id|in', 800, 16000),
          tokensOut: seededInt('$id|out', 200, 3000),
          thoughts: seededInt('$id|th', 0, 2600),
          cost: seededDouble('$id|c', .01, .7),
          at: DateTime(2026, 8, 3, 10 + (n % 6)),
        ),
      );
    }

    // Two unattributed calls, so the budget screen's "Unattributed" card is
    // never an empty theoretical case.
    for (int i = 0; i < 2; i++) {
      final String id = 'L-${++n}';
      out.add(
        LedgerRow(
          id: id,
          op: LedgerOp.summarize,
          model: 'gemini-2.5-flash',
          tokensIn: seededInt('$id|in', 400, 3000),
          tokensOut: seededInt('$id|out', 100, 900),
          cost: seededDouble('$id|c', .005, .08),
          at: DateTime(2026, 8, 2, 14 + i),
        ),
      );
    }

    return out;
  }

  // ── Tags ────────────────────────────────────────────────────────────────
  static List<Tag> _tags() => const <Tag>[
    Tag(name: 'domain:logistics', uses: 34),
    Tag(name: 'domain:warehousing', uses: 27),
    Tag(name: 'domain:e-commerce', uses: 18),
    Tag(name: 'domain:media', uses: 4),
    Tag(name: 'skill:bounding-box', uses: 22),
    Tag(name: 'skill:occlusion-handling', uses: 19),
    Tag(name: 'skill:class-taxonomy', uses: 16),
    Tag(name: 'skill:visual-quality', uses: 12),
    Tag(name: 'skill:prompt-writing', uses: 11),
    Tag(name: 'skill:instruction-fidelity', uses: 9),
    Tag(name: 'skill:continuity', uses: 3),
    Tag(name: 'policy:quality-gate', uses: 15),
    // Near-duplicates, so the merge banner has something to fold.
    Tag(name: 'skill:boundingbox', uses: 3, mergeInto: 'skill:bounding-box'),
    Tag(name: 'domain:warehouse', uses: 2, mergeInto: 'domain:warehousing'),
    Tag(
      name: 'skill:prompt writing',
      uses: 1,
      mergeInto: 'skill:prompt-writing',
    ),
  ];
}
