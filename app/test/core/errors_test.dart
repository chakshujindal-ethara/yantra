import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/errors.dart';
import 'package:yantra_app/core/format.dart';

void main() {
  tearDown(() => showErrorDetails = false);

  test('describeError names the wait for 429 and 503', () {
    expect(
      describeError(const ApiException(status: 429, code: 'rate_limited', message: 'x', retryAfter: Duration(seconds: 7))),
      contains('7s'),
    );
    expect(describeError(const ApiException(status: 503, code: 'upstream_unavailable', message: 'x')), contains('2s'));
  });

  test('a known code reads as plain copy, never the server text', () {
    const e = ApiException(status: 409, code: 'claim_not_live', message: 'claim is not live: status=submitted', requestId: 'req-9');
    expect(describeError(e), 'This claim is no longer live: it was submitted, released or it expired.');
    for (final code in errorCopy.keys) {
      final line = describeError(ApiException(status: 409, code: code, message: 'raw server words'));
      expect(line, isNot(contains('raw server words')), reason: code);
      expect(line, isNot(contains('_')), reason: '$code reads as words');
    }
    expect(describeError(const ApiException(status: 429, code: 'rate_limited', message: 'slow down')), startsWith('Too many requests'));
  });

  test('an unknown code falls back to a generic sentence with the request reference', () {
    const e = ApiException(status: 400, code: 'weird_thing', message: 'Traceback: KeyError', requestId: 'req-42');
    expect(describeError(e), 'Something went wrong. Try again; if it keeps happening, report it. Reference: req-42');
    expect(describeError(const ApiException(status: 400, code: 'weird_thing', message: '')), isNot(contains('Reference')));
    expect(describeError(StateError('boom')), contains('Something went wrong'));
  });

  test('a schema refusal names the fields, not the validator text', () {
    String line(String message) => describeError(ApiException(status: 422, code: 'invalid', message: message));
    expect(line("answer: label: 'xxxxxxxx' is too long"), "Some answers don't match what this unit asks for: label");
    expect(line("answer: 'score' is a required property"), "Some answers don't match what this unit asks for: score");
    expect(
      describeError(
        const ApiException(
          status: 422,
          code: 'invalid',
          message: 'x',
          context: {
            'fields': ['a', 'b'],
          },
        ),
      ),
      "Some answers don't match what this unit asks for: a, b",
    );
    expect(line('answer: is not of type object'), "Some answers don't match what this unit asks for.");
    expect(line('due_at must be in the future'), "Some of what you entered isn't valid. Check the form and try again.");
  });

  test('staff also see the server message on a Details line', () {
    const e = ApiException(status: 409, code: 'batch_held', message: 'manifest digest mismatch', requestId: 'req-1');
    expect(describeError(e), isNot(contains('manifest digest mismatch')));
    showErrorDetails = true;
    expect(describeError(e), 'This batch is still held at the delivery gate.\nDetails: manifest digest mismatch');
    expect(splitDetails(describeError(e)), ('This batch is still held at the delivery gate.', 'manifest digest mismatch'));
    expect(splitDetails('Just one line'), ('Just one line', null));
  });

  test('a transport failure reads as a person would say it, never the exception type', () {
    final line = describeError(const TransportException('Gateway unreachable (ClientException)'));
    expect(line, "Can't reach Yantra. Check your connection and try again.");
    expect(line, isNot(contains('ClientException')));
    expect(describeError(const TransportException('x', offline: true)), "You're offline. Check your connection and try again.");
  });

  test('an unexpected answer says so and asks for a report', () {
    expect(describeError(ShapeError('an object', '<html>')), startsWith('Yantra answered with something unexpected'));
    expect(ShapeError('an object', '<html>').toString(), contains('<html>'), reason: 'the technical text stays for logs');
  });

  test('a shape error keeps the key on retry like a transport error does not need to', () {
    expect(retryKeepsKey(ShapeError('an object', '')), isFalse);
    expect(retryKeepsKey(const TransportException('x', offline: true)), isTrue);
  });

  test('the new gateway codes read as plain copy', () {
    String line(String code, {int status = 409, Map<String, dynamic> context = const {}}) =>
        describeError(ApiException(status: status, code: code, message: 'raw', context: context));
    expect(
      line('consent_withdrawn', status: 403),
      "You withdrew consent, so you can't take new work. Give consent again in Profile → Your data.",
    );
    expect(line('paper_author', status: 403), "You wrote or published this paper, so you can't sit it.");
    expect(line('batch_purged', status: 410), "This delivery was purged under the project's retention policy.");
    expect(
      line('batch_purged', status: 410, context: {'purged_at': '2026-11-03T10:00:00Z'}),
      "This delivery was purged under the project's retention policy on ${shortDate(DateTime.utc(2026, 11, 3, 10))}.",
    );
    expect(purgedCopy(DateTime.utc(2026, 11, 3, 10)), contains(' on ${shortDate(DateTime.utc(2026, 11, 3, 10))}.'));
    expect(line('wrong_code', status: 422, context: {'attempts_left': 2}), 'That code is not the one we sent. 2 tries left.');
    expect(line('wrong_code', status: 422, context: {'attempts_left': 1}), 'That code is not the one we sent. 1 try left.');
    expect(line('wrong_code', status: 422), 'That code is not the one we sent.');
    for (final code in const [
      'nothing_to_verify',
      'code_expired',
      'too_many_attempts',
      'same_person',
      'worker_held',
      'rail_mismatch',
      'not_awaiting_confirmation',
      'window_over_cap',
      'self_action',
      'unit_not_assigned',
      'assignment_required',
      'line_not_failed',
      'account_unverified',
    ]) {
      expect(errorCopy, contains(code), reason: code);
    }
  });
}
