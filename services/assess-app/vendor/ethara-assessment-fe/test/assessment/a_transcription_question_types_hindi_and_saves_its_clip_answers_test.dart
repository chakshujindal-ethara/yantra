// The Transcription question: Hindi typing, the clip controls, the exam layout
// and the wire.
//
// Hindi typing is Strix's engine in the browser (`web/hindi/`); a VM test has
// no browser, so the box is given a small fake engine and the rule that turns a
// typed word into Devanagari (`convertHindiWord`) is tested on its own.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/domain/transcription.dart';
import 'package:ethara_assessment/assessment/screens/exam/answer_layouts.dart';
import 'package:ethara_assessment/assessment/screens/exam/audio_plate.dart';
import 'package:ethara_assessment/assessment/screens/exam/clip_controls.dart';
import 'package:ethara_assessment/assessment/screens/exam/transcription_box.dart';
import 'package:ethara_assessment/assessment/screens/exam/transcription_layout.dart'
    show transcriptionClip;
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/services/hindi_engine.dart';

/// Three words, as the real engine ranks them.
class _FakeEngine implements HindiEngine {
  static const Map<String, List<String>> _words = <String, List<String>>{
    'mera': <String>['मेरा', 'मरा', 'mera'],
    'naam': <String>['नाम', 'naam'],
    'meet': <String>['मीत', 'meet'],
  };

  @override
  List<String> suggestions(String latin) =>
      _words[latin.toLowerCase()] ?? <String>[latin];

  @override
  List<String> englishWords(String latin) =>
      latin == 'meet' ? <String>['meeting', 'meet'] : const <String>[];
}

TextEditingValue _v(String text) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: text.length),
);

const String _qid = 'q-tx';

Question _question({String language = 'hi'}) =>
    Question.fromJson(<String, dynamic>{
      'id': _qid,
      'question_type': 'transcription',
      'name': 'Clip 1',
      'prompt': 'Listen to the clip and type exactly what is said.',
      'transcription_language': language,
      'videos': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 1,
          'slot': 'single',
          'url': 'https://example.invalid/clip.mp3',
          'kind': 'audio',
        },
      ],
    });

void main() {
  group('Hindi typing: the conversion rule', () {
    List<String> suggest(String w) => _FakeEngine().suggestions(w);

    test('finds the English-letter word that ends at the caret', () {
      expect(latinWordBefore('mera naam', 9), (start: 5, latin: 'naam'));
      expect(latinWordBefore('mera naam', 7), isNull, reason: 'inside a word');
      expect(latinWordBefore('मेरा ', 5), isNull);
    });

    test('space takes the first spelling and keeps its space', () {
      final TextEditingValue out = convertHindiWord(
        _v('mera'),
        _v('mera '),
        suggest,
      );
      expect(out.text, 'मेरा ');
      expect(out.selection.baseOffset, 'मेरा '.length);
    });

    test('a number takes that spelling, Enter the first with no newline', () {
      expect(convertHindiWord(_v('mera'), _v('mera2'), suggest).text, 'मरा ');
      expect(convertHindiWord(_v('mera'), _v('mera\n'), suggest).text, 'मेरा');
    });

    test('a word Esc kept, a paste and IME composing pass through', () {
      expect(
        convertHindiWord(_v('mera'), _v('mera '), suggest, keptAt: 0).text,
        'mera ',
      );
      expect(
        convertHindiWord(_v(''), _v('mera naam '), suggest).text,
        'mera naam ',
        reason: 'more than one character arrived at once',
      );
      const TextEditingValue composing = TextEditingValue(
        text: 'mera ',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 4),
      );
      expect(convertHindiWord(_v('mera'), composing, suggest).text, 'mera ');
    });
  });

  group('the transcription box', () {
    Future<List<String>> pump(
      WidgetTester tester, {
      String language = 'hi',
      bool tools = true,
    }) async {
      final List<String> sent = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TranscriptionBox(
                language: language,
                initialText: '',
                tools: tools,
                engine: _FakeEngine(),
                onChanged: sent.add,
              ),
            ),
          ),
        ),
      );
      return sent;
    }

    testWidgets('typing mera and a space writes मेरा', (WidgetTester t) async {
      final List<String> sent = await pump(t);
      await t.enterText(find.byType(TextField), 'mera');
      await t.pump();
      expect(find.text('मेरा'), findsWidgets, reason: 'offered while typing');
      await t.enterText(find.byType(TextField), 'mera ');
      await t.pump();
      expect(sent.last, 'मेरा ');
    });

    testWidgets('a Hindi keyboard\'s digits are written as English ones', (
      WidgetTester t,
    ) async {
      final List<String> sent = await pump(t);
      await t.enterText(find.byType(TextField), 'नंबर ९८');
      await t.pump();
      expect(sent.last, 'नंबर 98');
      expect(englishDigits('०१२३४५६७८९ 2026'), '0123456789 2026');
    });

    testWidgets('Esc keeps the word in English letters', (
      WidgetTester t,
    ) async {
      final List<String> sent = await pump(t);
      await t.enterText(find.byType(TextField), 'mera');
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.enterText(find.byType(TextField), 'mera ');
      await t.pump();
      expect(sent.last, 'mera ');
    });

    testWidgets('Tab takes the English word', (WidgetTester t) async {
      final List<String> sent = await pump(t);
      await t.enterText(find.byType(TextField), 'meet');
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(sent.last, 'meeting ');
    });

    testWidgets('a backchannel and a marker go in at the caret', (
      WidgetTester t,
    ) async {
      final List<String> sent = await pump(t);
      await t.tap(find.text('म्हम्'));
      await t.pump();
      expect(sent.last, 'म्हम् ');
      await t.tap(find.textContaining('unintelligible'));
      await t.pump();
      expect(sent.last, 'म्हम् (()) ');
    });

    testWidgets('English has no Hindi typing and English backchannels', (
      WidgetTester t,
    ) async {
      final List<String> sent = await pump(t, language: 'en');
      expect(find.text('Hindi typing'), findsNothing);
      expect(find.text('mm-hm'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'mera ');
      await t.pump();
      expect(sent.last, 'mera ');
      expect(
        find.text('1 word'),
        findsOneWidget,
        reason: 'the count follows the text',
      );
    });

    testWidgets('Form Studio draws the box without the guide buttons', (
      WidgetTester t,
    ) async {
      await pump(t, tools: false);
      expect(find.text('Devanagari letters'), findsNothing);
      expect(find.text('म्हम्'), findsNothing);
    });
  });

  group('the clip controls', () {
    test('speed steps stop at 0.5 and 1.5; jumps reach the element', () {
      final List<double> seeks = <double>[];
      final List<double> rates = <double>[];
      final ClipControls c = ClipControls()
        ..bind(seek: seeks.add, applyRate: rates.add, toggle: () {});
      c
        ..stepRate(-1)
        ..stepRate(-1)
        ..stepRate(-1);
      expect(c.rate, 0.5);
      c
        ..stepRate(1)
        ..stepRate(1)
        ..stepRate(1)
        ..stepRate(1)
        ..stepRate(1);
      expect(c.rate, 1.5);
      c.seekBy(-ClipControls.jumpSeconds);
      expect(seeks, <double>[-3]);
      expect(rates.first, 1, reason: 'the chosen speed applies on bind');
    });

    testWidgets('the bar\'s buttons drive the clip', (WidgetTester t) async {
      final List<double> seeks = <double>[];
      final ClipControls c = ClipControls()
        ..bind(seek: seeks.add, applyRate: (_) {}, toggle: () {});
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ClipControlsBar(
              controls: c,
              player: const SizedBox(height: 54),
            ),
          ),
        ),
      );
      await t.tap(find.text('+3 s'));
      await t.tap(find.text('−3 s'));
      expect(seeks, <double>[3, -3]);
    });
  });

  group('the exam', () {
    Future<(AppStore, Attempt)> pumpExam(WidgetTester t, Question q) async {
      t.view.physicalSize = const Size(1200, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      final AppStore store = AppStore();
      final Attempt ev = Attempt(
        id: 'att-1',
        assessmentId: 'a-1',
        employeeId: 'e-1',
        token: 'tok',
        resp: <String, Response>{_qid: Response.seed(q)},
      );
      store.attempts = <Attempt>[ev];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AnswerArea(store: store, ev: ev, q: q),
            ),
          ),
        ),
      );
      await t.pump();
      return (store, ev);
    }

    testWidgets('shows the clip, the box and the clip questions', (
      WidgetTester t,
    ) async {
      await pumpExam(t, _question());
      expect(find.text('+3 s'), findsOneWidget);
      expect(find.text('Your answer'), findsOneWidget);
      expect(find.text('About this clip'), findsOneWidget);
      expect(find.text('TRANSCRIPTION (DEVANAGARI)'), findsOneWidget);
    });

    testWidgets('a category other than None hides the box and sends no text', (
      WidgetTester t,
    ) async {
      final Question q = _question();
      final (AppStore store, Attempt ev) = await pumpExam(t, q);
      await t.enterText(find.byType(TextField), 'kuch bhi');
      await t.pump();
      expect(store.responseFor(ev, q).justification, 'kuch bhi');

      await t.tap(find.text('None · कोई नहीं'));
      await t.pumpAndSettle();
      await t.tap(find.text('No Speech · कोई भाषण नहीं').last);
      await t.pumpAndSettle();

      final Response r = store.responseFor(ev, q);
      expect(r.clip?.category, 'no_speech');
      expect(r.justification, '', reason: 'such a clip is not transcribed');
      expect(r.satisfiesProse(q), isTrue);
      expect(find.byType(TextField), findsNothing);
      expect(
        find.text(
          'With this category the clip is not transcribed, so there is '
          'nothing to type. To transcribe it, set the category to None.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a clip carried in from an earlier block is shown too', (
      WidgetTester t,
    ) async {
      final Question q = Question.fromJson(<String, dynamic>{
        'id': _qid,
        'question_type': 'transcription',
        'transcription_language': 'hi',
        'videos': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 1,
            'slot': 'single',
            'url': 'https://example.invalid/clip.mp3',
            'kind': 'audio',
          },
          <String, dynamic>{
            'id': 2,
            'slot': 'single',
            'url': 'https://example.invalid/example.mp3',
            'kind': 'audio',
          },
        ],
      });
      await pumpExam(t, q);
      expect(find.byType(AudioPlate), findsNWidgets(2));
      expect(transcriptionClip(q)?.url, 'https://example.invalid/clip.mp3');
      // Above the clip to transcribe, as it was placed before the question.
      final List<AudioPlate> plates = t
          .widgetList<AudioPlate>(find.byType(AudioPlate))
          .toList();
      expect(plates.first.asset.url, 'https://example.invalid/example.mp3');
      expect(
        t.getTopLeft(find.byWidget(plates.first)).dy,
        lessThan(t.getTopLeft(find.byWidget(plates.last)).dy),
      );
    });

    testWidgets('ticks and speakers land in the answer', (
      WidgetTester t,
    ) async {
      final Question q = _question();
      final (AppStore store, Attempt ev) = await pumpExam(t, q);
      await t.tap(find.text('Laughter'));
      await t.pump();
      expect(store.responseFor(ev, q).clip?.characteristics, <String>[
        'laughter',
      ]);
    });
  });

  group('the wire', () {
    test('clip answers are posted, and changing only them re-posts', () async {
      final _Backend backend = _Backend();
      final AppStore store = AppStore(
        api: ApiClient(
          client: backend,
          baseUrl: 'https://example.invalid',
          bearer: 't',
        ),
        answerDebounce: const Duration(milliseconds: 100),
        answerMaxWait: const Duration(milliseconds: 300),
      );
      store.portal = Portal.member;
      store.source = DataSource.live;
      store.meId = '2';
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': '1',
        'assessment_id': '55',
        'access_token': 'tok-1',
        'state': 'in_progress',
      });
      store.attempts = <Attempt>[ev];

      final ClipAnswers clip = ClipAnswers(category: 'none')
        ..characteristics.add('laughter')
        ..setSpeakerCount(1);
      store.saveAnswerQuiet(
        ev.id,
        _qid,
        Response(justification: 'मेरा नाम', clip: clip),
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(backend.bodies, hasLength(1));
      expect(backend.bodies.last['justification'], 'मेरा नाम');
      expect(
        (backend.bodies.last['clip_answers'] as Map)['characteristics'],
        <String>['laughter'],
      );

      store.saveAnswerQuiet(
        ev.id,
        _qid,
        Response(
          justification: 'मेरा नाम',
          clip: clip.copy()..category = 'no_speech',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(backend.bodies, hasLength(2), reason: 'only the clip changed');
    });
  });

  group('the models', () {
    test('a Transcription item keeps its language and correct answers', () {
      final FormItem it = formNewItem(FormItemKind.transcription)
        ..mediaUrl = 'https://example.invalid/clip.mp3'
        ..goldenAnswer = 'तो ये देखो'
        ..transcriptionLanguage = 'en';
      it.goldenClip
        ..characteristics.add('background_speech')
        ..setSpeakerCount(2);
      it.goldenClip.speakers[1].gender = 'feminine';
      expect(it.mediaKind, 'audio');

      final Map<String, dynamic> wire =
          jsonDecode(jsonEncode(it.toJson())) as Map<String, dynamic>;
      expect(wire['kind'], 'transcription');
      expect(wire['golden_clip']['characteristics'], <String>[
        'background_speech',
      ]);
      final FormItem back = FormItem.fromJson(wire);
      expect(back.transcriptionLanguage, 'en');
      expect(back.goldenAnswer, 'तो ये देखो');
      expect(
        back.goldenClip.speakers.map((SpeakerAnswer s) => s.gender),
        <String>['unknown', 'feminine'],
      );
    });

    test('the question type and the admin review parse', () {
      expect(_question(language: 'en').transcriptionLanguage, 'en');
      expect(QType.parse('transcription'), QType.transcription);
      expect(QType.transcription.isGeneratable, isFalse);

      final Response r = Response.fromJson(<String, dynamic>{
        'justification': 'मेरा नाम',
        'clip_answers': <String, dynamic>{'category': 'none'},
        'transcription': <String, dynamic>{
          'language': 'hi',
          'correct': <String, dynamic>{
            'transcription': 'मेरा नाम म्हम्',
            'category': 'none',
            'characteristics': <String>[],
            'speakers': <Map<String, String>>[],
          },
          'answer': <String, dynamic>{'transcription': 'मेरा नाम'},
          'differences': <Map<String, String>>[
            <String, String>{
              'kind': 'missing',
              'answer': '',
              'correct': 'म्हम्',
              'after': 'नाम',
            },
          ],
          'critical': 1,
          'minor': 0,
          'client_rule_passed': false,
        },
      });
      expect(r.clip?.category, 'none');
      expect(r.transcriptionReview?.critical, 1);
      expect(r.transcriptionReview?.clientRulePassed, isFalse);
      expect(r.transcriptionReview?.differences.single.correct, 'म्हम्');
    });
  });
}

/// Answers `/answer` and keeps every body.
class _Backend extends http.BaseClient {
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request &&
        request.url.path.endsWith('/answer') &&
        request.body.isNotEmpty) {
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
    }
    final List<int> bytes = utf8.encode(
      jsonEncode(<String, dynamic>{
        'ok': true,
        'data': <String, dynamic>{'saved': true, 'next': null},
      }),
    );
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      200,
      headers: <String, String>{'content-type': 'application/json'},
      request: request,
    );
  }
}
