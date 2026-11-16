// Browser campaign, 8 Oct 2026, BR-D3: the network goes down mid-exam.
//
// The failure toast named the host and "CORS origin" - a sentence written for
// whoever runs the server. A candidate can only check their connection, so
// that is what they are told, on the load banner and on begin, question load,
// Next and Submit. Admin screens and the logs keep the technical sentence.
//
// Ported from stage's `a_submit_is_shown_only_once_the_server_takes_it_test`
// (its BR-D3 group), without the write-behind batch main does not have.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';

const String kToken = 'tok-d3';

/// The network is down: no request gets an answer.
Future<http.Response> _offline(http.Request _) =>
    Future<http.Response>.error(http.ClientException('Failed to fetch'));

/// A live sitting on question 1 of 2, with every request failing in transport
/// unless [client] answers otherwise.
AppStore _store({MockClient? client}) {
  final AppStore s = AppStore(
    api: ApiClient(
      baseUrl: 'https://x.invalid',
      bearer: 't',
      // The whole retry ladder runs, with no real sleeping.
      sleep: (Duration _) async {},
      client: client ?? MockClient(_offline),
    ),
  );
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': 1,
      'access_token': kToken,
      'assessment_id': 55,
      'state': 'in_progress',
      'started_at': DateTime.now().toUtc().toIso8601String(),
      'deadline': DateTime.now()
          .add(const Duration(hours: 1))
          .toUtc()
          .toIso8601String(),
      'total_questions': 2,
    }),
  ];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 55,
      'name': 'Paper',
      'state': 'in_progress',
      'duration_minutes': 60,
    }),
  ];
  s.examByToken[kToken] = ExamView.fromJson(<String, dynamic>{
    'outcome': 'question',
    'question': <String, dynamic>{
      'id': '10',
      'index': 1,
      'total': 2,
      'name': 'Q1',
      'prompt': 'Explain.',
      'question_type': 'subjective_rubric',
    },
  });
  return s;
}

List<String> _said(AppStore s) =>
    s.toaster.items.map((ToastMsg m) => m.message).toList();

void main() {
  test('the candidate wording, and only for a transport failure', () {
    const ApiError down = ApiError(
      'Could not reach the server at https://x. ... a CORS origin ...',
      isTransport: true,
    );
    const ApiError refused = ApiError('This assessment is not open');
    expect(down.candidateMessage, kNoConnection);
    expect(down.message, contains('CORS'), reason: 'kept for admin screens');
    expect(refused.candidateMessage, 'This assessment is not open');
    // Main keeps unsent answers in the open page, not on the device.
    expect(kNoConnection, contains('kept on this page'));
    // Nothing else warns before a reload after a failed save, and a reload
    // loses what the server has not taken.
    expect(kNoConnection, contains('do not reload'));
    expect(kNoConnection, isNot(contains('device')));
    expect(AppStore.reportsHeldMessage, kNoConnection);
  });

  test(
    'Next and a question load with the network down say so plainly',
    () async {
      final AppStore s = _store();
      await s.examAdvance(kToken, '10', const Response(justification: 'mine'));
      await s.loadExamQuestion(kToken, 2);

      expect(_said(s), <String>[kNoConnection, kNoConnection]);
      s.dispose();
    },
  );

  test('Begin with the network down says so plainly', () async {
    final AppStore s = _store();
    await s.beginExam('1');

    expect(_said(s), <String>[kNoConnection]);
    s.dispose();
  });

  test('Submit with the network down: NOT submitted, no host, no CORS, and '
      'not blamed on the answers', () async {
    final AppStore s = _store();
    s.saveAnswerQuiet('1', '10', const Response(justification: 'mine'));
    s.finishExam('1', force: true);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final String outcome = _said(s).join(' | ');
    expect(outcome, contains('Your exam was NOT submitted. $kNoConnection'));
    expect(outcome, isNot(contains('CORS')));
    expect(outcome, isNot(contains('x.invalid')));
    // The re-send failed for want of a connection too: that is not a
    // rejected answer to go and fix.
    expect(outcome, isNot(contains('rejected')));
    expect(s.attemptById('1')!.resp['10']!.justification, 'mine');
    s.dispose();
  });

  // THE WHOLE ROOM SUBMITTING AT ONCE: a server too busy to answer (503)
  // refused nothing. Counted as "rejected" it sent candidates to re-answer
  // questions that were fine.
  test(
    'a busy server: NOT submitted, "busy", and not blamed on the answers',
    () async {
      final AppStore s = _store(
        client: MockClient(
          (http.Request req) async => http.Response(
            jsonEncode(<String, dynamic>{
              'ok': false,
              'error': <String, dynamic>{
                'code': 'unavailable',
                'message': 'Busy',
              },
            }),
            503,
            headers: <String, String>{'content-type': 'application/json'},
          ),
        ),
      );
      s.saveAnswerQuiet('1', '10', const Response(justification: 'mine'));
      s.finishExam('1', force: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final String outcome = _said(s).join(' | ');
      expect(
        outcome,
        contains('Your exam was NOT submitted: the server is busy.'),
      );
      expect(outcome, isNot(contains('rejected')));
      expect(s.attemptById('1')!.resp['10']!.justification, 'mine');
      s.dispose();
    },
  );

  test('a refusal still says the server\'s reason, and which answers it '
      'would not take', () async {
    http.Response refuse(String message) => http.Response(
      jsonEncode(<String, dynamic>{
        'ok': false,
        'error': <String, dynamic>{'code': 'incomplete', 'message': message},
      }),
      422,
      headers: <String, String>{'content-type': 'application/json'},
    );
    final AppStore s = _store(
      client: MockClient(
        (http.Request req) async => req.url.path.endsWith('/submit')
            ? refuse('1 question(s) are still unanswered.')
            : refuse('This answer is incomplete.'),
      ),
    );
    s.saveAnswerQuiet('1', '10', const Response(justification: 'mine'));
    s.finishExam('1', force: true);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(
      _said(s).join(' | '),
      contains(
        'Your exam was NOT submitted: 1 question(s) are still unanswered. '
        '1 answer(s) were rejected when saving',
      ),
    );
    s.dispose();
  });

  test(
    'the load banner: plain for a candidate, technical for an admin',
    () async {
      for (final Portal p in Portal.values) {
        final AppStore s =
            AppStore(
                api: ApiClient(
                  baseUrl: 'https://x.invalid',
                  bearer: 't',
                  maxAttempts: 1,
                  client: MockClient(_offline),
                ),
              )
              ..portal = p
              ..source = DataSource.live;
        await s.refresh();
        expect(
          s.loadError,
          p == Portal.admin ? contains('CORS') : 'No connection.',
          reason: '$p',
        );
        s.dispose();
      }
    },
  );
}
