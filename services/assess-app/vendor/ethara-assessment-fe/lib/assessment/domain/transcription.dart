/// The Transcription question's fixed vocabulary, shared by Form Studio, the
/// exam and the marked-answer view.
///
/// The lists are the client's (the 0909 transcription conventions) with the
/// Hindi names the Strix workbench shows; the codes are what goes on the wire
/// and must match `constants.py` on the server. A code the server does not know
/// is dropped there, so a typo here loses an answer rather than inventing one.
library;

/// Whole-audio category: (code, English, Hindi). Anything but `none` means the
/// clip is not transcribed.
const List<(String, String, String)> kClipCategories =
    <(String, String, String)>[
      ('none', 'None', 'कोई नहीं'),
      ('no_audio', 'No Audio', 'कोई audio नहीं'),
      ('no_speech', 'No Speech', 'कोई भाषण नहीं'),
      (
        'sensitive_content',
        'Contains Sensitive Content',
        'इसमें संवेदनशील content शामिल है',
      ),
      (
        'synthetic_speech',
        'Contains Synthetic Speech',
        'इसमें synthetic speech शामिल है',
      ),
      (
        'primarily_non_target_language',
        'Primarily Non-Target Language',
        'मुख्य रूप से गैर-लक्षित भाषा',
      ),
    ];

/// Audio characteristics: (code, English, Hindi or '', what it means).
const List<(String, String, String, String)> kClipCharacteristics =
    <(String, String, String, String)>[
      (
        'overlapping_speech',
        'Overlapping Speech',
        '',
        'Intelligible speech from more than one speaker at once',
      ),
      (
        'cross_talk',
        'Cross Talk',
        '',
        'Unintelligible overlapping speech from several speakers',
      ),
      ('laughter', 'Laughter', 'हंसी', 'Laughter from an identified speaker'),
      (
        'human_noise',
        'Human Noise',
        'मानवीय शोर',
        'Yawn, cough, sneeze, sigh, singing',
      ),
      (
        'background_speech',
        'Background Speech',
        '',
        'Speech from a speaker you cannot identify',
      ),
      (
        'excessive_background_noise',
        'Excessive Background Noise',
        'अत्यधिक background शोर',
        'Persistent or disruptive noise',
      ),
      (
        'audio_artifact',
        'Audio Artifact',
        '',
        'A brief technical noise: static burst, pop, click',
      ),
      (
        'garbled_audio',
        'Garbled Audio',
        'विकृत audio',
        'Audio distorted by recording or microphone issues',
      ),
      (
        'non_target_language',
        'Non-Target Language',
        'गैर-लक्षित भाषा',
        'Speech in another language you can transcribe',
      ),
    ];

const List<(String, String)> kSpeakerGenders = <(String, String)>[
  ('masculine', 'Masculine-Sounding'),
  ('feminine', 'Feminine-Sounding'),
  ('unknown', 'Unknown'),
];

const List<(String, String)> kSpeakerNativities = <(String, String)>[
  ('native', 'Native'),
  ('non_native', 'Non-Native'),
  ('unknown', 'Unknown'),
];

/// The client asks 0, 1, 2, 3 or "4 or more", and describes at most four.
const int kMaxSpeakers = 4;

/// The inline markers: (what is inserted or wraps the selection, label).
const List<(String, String)> kTranscriptionMarkers = <(String, String)>[
  ('(())', 'unintelligible'),
  ('((word))', 'guessed word'),
  ('{{word}}', 'mis-spoken word'),
];

/// Backchannels in the guide's exact spellings, with what each one means.
List<(String, String)> backchannelsFor(String language) => language == 'en'
    ? const <(String, String)>[
        ('mm-hm', 'agreeing or listening, mouth closed'),
        ('uh-huh', 'agreeing or listening, mouth open'),
        ('hmm', 'thinking or considering'),
        ('uh', 'short hesitation, open vowel'),
        ('um', 'hesitation, closed lip'),
        ('mm-mm', 'disagreeing, mouth closed'),
        ('nuh-huh', 'disagreeing, mouth open'),
        ('oh', 'surprise or realisation'),
        ('ooh', 'excitement or impressed'),
        ('[fp]', 'any other filled pause'),
      ]
    : const <(String, String)>[
        ('म्हम्', 'agreeing or listening, mouth closed'),
        ('अहाँ', 'agreeing or listening, mouth open'),
        ('हम्म', 'thinking or considering'),
        ('अ', 'short hesitation, open vowel'),
        ('um', 'hesitation, closed lip'),
        ('म्म्-म्म्', 'disagreeing, mouth closed'),
        ('ना-ना', 'disagreeing, mouth open'),
        ('अरे', 'surprise or realisation'),
        ('वाह', 'excitement or impressed'),
        ('[fp]', 'any other filled pause'),
      ];

/// The Devanagari letters panel, as the Strix workbench lays it out.
const List<(String, String)> kDevanagariLetters = <(String, String)>[
  ('Vowels', 'अ आ इ ई उ ऊ ऋ ए ऐ ओ औ'),
  ('Vowel signs', 'ा ि ी ु ू ृ े ै ो ौ ं ँ ः ् ़'),
  (
    'Consonants',
    'क ख ग घ ङ च छ ज झ ञ ट ठ ड ढ ण त थ द ध न प फ ब भ म य र ल व श ष स ह',
  ),
  ('More', 'क्ष त्र ज्ञ श्र ड़ ढ़ फ़ ज़'),
];

String clipCategoryLabel(String code, {bool hindi = false}) {
  for (final (String c, String en, String hi) in kClipCategories) {
    if (c == code) return hindi ? '$en · $hi' : en;
  }
  return code;
}

String clipCharacteristicLabel(String code) {
  for (final (String c, String en, String _, String _)
      in kClipCharacteristics) {
    if (c == code) return en;
  }
  return code;
}

String _labelIn(List<(String, String)> list, String code) {
  for (final (String c, String label) in list) {
    if (c == code) return label;
  }
  return code;
}

String speakerGenderLabel(String code) => _labelIn(kSpeakerGenders, code);
String speakerNativityLabel(String code) => _labelIn(kSpeakerNativities, code);

class SpeakerAnswer {
  SpeakerAnswer({this.gender = 'unknown', this.nativity = 'unknown'});

  String gender;
  String nativity;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'gender': gender,
    'nativity': nativity,
  };

  static SpeakerAnswer fromJson(Object? raw) {
    final Map<Object?, Object?> j = raw is Map
        ? raw
        : const <Object?, Object?>{};
    return SpeakerAnswer(
      gender: (j['gender'] ?? 'unknown').toString(),
      nativity: (j['nativity'] ?? 'unknown').toString(),
    );
  }
}

/// Category, characteristics and speakers for one clip: what the candidate
/// answers beside the transcription, and what the author keys as correct.
class ClipAnswers {
  ClipAnswers({
    this.category = 'none',
    List<String>? characteristics,
    List<SpeakerAnswer>? speakers,
  }) : characteristics = characteristics ?? <String>[],
       speakers = speakers ?? <SpeakerAnswer>[];

  String category;
  final List<String> characteristics;
  final List<SpeakerAnswer> speakers;

  /// Anything but None: the clip is not transcribed, and the guide hides the
  /// box and the speaker questions.
  bool get transcribed => category == 'none';

  /// Grow or shrink the speaker list to [count], keeping who is already there.
  void setSpeakerCount(int count) {
    final int n = count.clamp(0, kMaxSpeakers);
    while (speakers.length > n) {
      speakers.removeLast();
    }
    while (speakers.length < n) {
      speakers.add(SpeakerAnswer());
    }
  }

  ClipAnswers copy() => ClipAnswers.fromJson(toJson());

  Map<String, dynamic> toJson() => <String, dynamic>{
    'category': category,
    'characteristics': List<String>.of(characteristics),
    'speakers': <Map<String, dynamic>>[
      for (final SpeakerAnswer s in speakers) s.toJson(),
    ],
  };

  /// One string per distinct answer, for "has this changed since it was sent".
  String get fingerprint =>
      '$category|${characteristics.join(',')}|'
      '${speakers.map((SpeakerAnswer s) => '${s.gender}/${s.nativity}').join(',')}';

  static ClipAnswers fromJson(Object? raw) {
    final Map<Object?, Object?> j = raw is Map
        ? raw
        : const <Object?, Object?>{};
    final Object? chars = j['characteristics'];
    final Object? spk = j['speakers'];
    return ClipAnswers(
      category: (j['category'] ?? 'none').toString().isEmpty
          ? 'none'
          : (j['category'] ?? 'none').toString(),
      characteristics: chars is List
          ? <String>[for (final Object? c in chars) c.toString()]
          : null,
      speakers: spk is List
          ? <SpeakerAnswer>[
              for (final Object? s in spk) SpeakerAnswer.fromJson(s),
            ]
          : null,
    );
  }
}

/// One place the candidate's transcription departs from the correct one, as
/// the server lined them up word by word (`services/transcript_diff.py`).
class TranscriptionDifference {
  const TranscriptionDifference({
    required this.kind,
    required this.answer,
    required this.correct,
    required this.after,
  });

  /// `missing`, `added` or `different`.
  final String kind;
  final String answer;
  final String correct;
  final String after;

  static TranscriptionDifference fromJson(Object? raw) {
    final Map<Object?, Object?> j = raw is Map
        ? raw
        : const <Object?, Object?>{};
    String s(String k) => (j[k] ?? '').toString();
    return TranscriptionDifference(
      kind: s('kind'),
      answer: s('answer'),
      correct: s('correct'),
      after: s('after'),
    );
  }
}

/// What an admin sees for one transcription answer: both texts, the clip
/// answers, the word differences and the client rule's counts. Sent only on
/// admin routes (`response_audit`), never to a candidate.
class TranscriptionReview {
  const TranscriptionReview({
    required this.language,
    required this.correctText,
    required this.correctClip,
    required this.answerText,
    required this.answerClip,
    required this.differences,
    required this.critical,
    required this.minor,
    required this.clientRulePassed,
  });

  final String language;
  final String correctText;
  final ClipAnswers correctClip;
  final String answerText;
  final ClipAnswers answerClip;
  final List<TranscriptionDifference> differences;
  final int critical;
  final int minor;
  final bool clientRulePassed;

  static TranscriptionReview? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? correct = raw['correct'];
    final Object? answer = raw['answer'];
    final Map<Object?, Object?> c = correct is Map
        ? correct
        : const <Object?, Object?>{};
    final Map<Object?, Object?> a = answer is Map
        ? answer
        : const <Object?, Object?>{};
    final Object? diffs = raw['differences'];
    int n(Object? v) => v is num ? v.toInt() : 0;
    return TranscriptionReview(
      language: raw['language'] == 'en' ? 'en' : 'hi',
      correctText: (c['transcription'] ?? '').toString(),
      correctClip: ClipAnswers.fromJson(c),
      answerText: (a['transcription'] ?? '').toString(),
      answerClip: ClipAnswers.fromJson(a),
      differences: diffs is List
          ? <TranscriptionDifference>[
              for (final Object? d in diffs)
                TranscriptionDifference.fromJson(d),
            ]
          : const <TranscriptionDifference>[],
      critical: n(raw['critical']),
      minor: n(raw['minor']),
      clientRulePassed: raw['client_rule_passed'] == true,
    );
  }
}
