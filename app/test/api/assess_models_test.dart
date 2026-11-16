import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/api/assess_models.dart';

void main() {
  test('PaperBrief reads the pass mark as a fraction and knows whether it can start, resume or only wait', () {
    final b = PaperBrief.fromJson({
      'id': 'pp1',
      'gate': 'transcription',
      'title': 'Hindi transcription basics',
      'duration_minutes': 20,
      'pass_mark': 0.7,
      'question_count': 12,
      'attempts_used': 1,
      'attempts_left': 2,
      'certified': false,
      'question_types': ['mcq', 'transcription'],
      'proctoring': {'webcam': true, 'fullscreen': false},
    });
    expect(b.passMarkPercent, 70);
    expect((b.canStart, b.canResume, b.awaitingResult, b.attemptsExhausted), (true, false, false, false));
    expect(b.questionTypes, ['mcq', 'transcription']);
    expect(b.proctoring.on, ['webcam']);
    expect(PaperBrief.fromJson({'id': 'p', 'attempts_left': 0}).attemptsExhausted, isTrue);
    expect(PaperBrief.fromJson({'id': 'p', 'attempts_left': 0, 'certified': true}).attemptsExhausted, isFalse);
    expect(PaperBrief.fromJson({'id': 'p', 'attempts_left': 3, 'certified': true}).canStart, isFalse);
    expect(PaperBrief.fromJson({'pass_mark': '0.5'}).passMarkPercent, 50);
    expect(PaperBrief.fromJson({'pass_mark': 7}).passMark, 1, reason: 'clamped to a fraction');

    final open = PaperBrief.fromJson({
      'attempts_left': 1,
      'current': {'status': 'in_progress', 'attempt_no': 2},
    });
    expect((open.canStart, open.canResume, open.attemptsExhausted), (false, true, false));
    final waiting = PaperBrief.fromJson({
      'attempts_left': 0,
      'current': {'status': 'awaiting_result', 'held_reason': 'llm_scoring'},
    });
    expect((waiting.awaitingResult, waiting.canStart, waiting.attemptsExhausted), (true, false, false));
    final lastFailed = PaperBrief.fromJson({
      'attempts_left': 1,
      'current': {'status': 'failed', 'attempt_no': 1},
    });
    expect((lastFailed.canStart, lastFailed.canResume), (true, false), reason: 'current is the latest when nothing is open');
    expect(waiting.current!.heldReason, 'llm_scoring');
  });

  test('WorkerSitting reads its status, attempt and result', () {
    final s = WorkerSitting.fromJson({
      'id': 's1',
      'paper_id': 'pp1',
      'status': 'passed',
      'attempt_no': 2,
      'score': 0.834,
      'released': true,
      'submitted_at': '2026-11-10T09:18:00Z',
    });
    expect((s.passed, s.scorePercent, s.attemptNo, s.released), (true, 83, 2, true));
    expect(s.submittedAt!.toUtc(), DateTime.utc(2026, 11, 10, 9, 18));
    for (final (status, open, waiting, failed, isVoid) in [
      ('assigned', true, false, false, false),
      ('in_progress', true, false, false, false),
      ('awaiting_result', false, true, false, false),
      ('failed', false, false, true, false),
      ('void', false, false, false, true),
    ]) {
      final w = WorkerSitting.fromJson({'status': status});
      expect((w.isOpen, w.awaitingResult, w.failed, w.isVoid), (open, waiting, failed, isVoid), reason: status);
    }
  });

  test('a launch ticket carries the link and the sitting it opens', () {
    final t = LaunchTicket.fromJson({
      'launch_url': 'http://localhost:8096/yantra/launch#ticket=abc',
      'expires_at': '2026-11-10T09:02:00Z',
      'sitting': {'id': 's1', 'status': 'assigned'},
    });
    expect(t.launchUrl.fragment, 'ticket=abc');
    expect(t.sitting!.isOpen, isTrue);
    expect(LaunchTicket.fromJson({'launch_url': 'http://x/'}).sitting, isNull);
  });

  test('proctoring rules read from a map or a list and read plainly', () {
    expect(Proctoring.fromJson({'webcam': true, 'seb': false}).on, ['webcam']);
    expect(Proctoring.fromJson(['fullscreen', 'ai_proctor']).on, ['fullscreen', 'ai_proctor']);
    expect(Proctoring.fromJson(null).isEmpty, isTrue);
    expect(Proctoring.label('webcam'), 'Your camera stays on');
    expect(Proctoring.label('seb'), 'Safe Exam Browser is required');
    expect(Proctoring.label('watch_the_clock'), 'Watch the clock');
    // the adapter's snapshot names the rules without the engine's block_ prefix
    expect(Proctoring.label('devtools'), 'Developer tools are off');
    expect(Proctoring.label('right_click'), 'Right click is off');
  });

  test('question types and held reasons read in plain words', () {
    expect(questionTypeLabel('subjective_rubric'), 'Written answer');
    expect(questionTypeLabel('transcription'), 'Audio transcription');
    expect(questionTypeLabel('new_kind'), 'new kind');
    expect(heldReasonLabel('llm_scoring'), 'Your written answers are being marked');
    expect(heldReasonLabel('needs_release'), 'Ops review the results before they are released');
    expect(heldReasonLabel(''), 'Your result is on its way');
    expect(heldReasonLabel('odd_reason'), 'odd reason');
  });
}
