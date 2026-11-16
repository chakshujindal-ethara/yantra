// A refused publish is a WORK LIST, and it has to still be there when you read it.
//
// `/forms/publish` refuses with `unpublishable` and a message that names ONE ITEM
// PER LINE - '"Q4 MCQ grid" (section "Part 2"): rows without an answer key: R1,
// R2.' A 47-item form can fail on a dozen at once. All of it was handed to
// `toaster.bad`, and a toast is short-lived (`feedback.dart`) inside a container
// that is `pointer-events: none` - so it cannot be clicked, cannot be held open,
// and cannot be re-read.
//
// The fix hands the parsed problems back on the store so the caller renders them
// in the same durable sheet the succeeded-with-notes path already uses. These
// tests pin the PARSE and the routing decision; that the sheet stays open is a
// property of `showSheet`, which every other sheet in the app already relies on.
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// What the module really answers when a form is not ready. Copied from a live
/// stage refusal, heading line and leading hyphens included - the parse exists to
/// handle exactly this shape, so inventing a tidier one would test nothing.
const String kRefusal =
    'The form is not ready to publish:\n'
    '- "Q1 plain MCQ" (section "All kinds"): no option is marked correct - set '
    'the answer key in the designer.\n'
    '- "Q4 MCQ grid" (section "All kinds"): rows without an answer key: Row 1, '
    'Row 2.\n'
    '- "Q6 linear scale" (section "All kinds"): set the correct value (1-5) as '
    'the golden answer so the scale can be scored.';

MockClient _client({
  required String code,
  required String message,
  int status = 422,
}) => MockClient((http.Request req) async {
  if (req.url.path.endsWith('/forms/publish')) {
    return http.Response(
      jsonEncode(<String, dynamic>{
        'ok': false,
        'error': <String, dynamic>{'code': code, 'message': message},
      }),
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }
  // Everything else (the pre-publish flush, the refresh) succeeds emptily.
  return http.Response(
    '{"ok": true, "data": {}}',
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );
});

AppStore _liveStore(MockClient client) {
  final AppStore store = AppStore(
    api: ApiClient(
      baseUrl: 'http://stub',
      client: client,
      bearer: 'access_token_stub',
    ),
  );
  store.source = DataSource.live;
  store.forms = <FormDef>[
    FormDef(
      'form-1',
      title: 'Quality Assessment',
      sections: <FormSection>[FormSection('s1', title: 'All kinds')],
    ),
  ];
  return store;
}

void main() {
  test('a refusal is handed back as one entry per item to fix', () async {
    final AppStore store = _liveStore(
      _client(code: 'unpublishable', message: kRefusal),
    );

    final (String, List<String>)? res = await store.publishForm('form-1');

    expect(res, isNull, reason: 'nothing was published');
    expect(
      store.publishProblems.length,
      3,
      reason: 'three items failed, so the examiner has three things to go and '
          'fix - a single blob of text is not a work list',
    );
    expect(store.publishProblems.first, startsWith('"Q1 plain MCQ"'));
    expect(
      store.publishProblems.every((String p) => !p.startsWith('-')),
      isTrue,
      reason: 'the wire carries "- " bullets; the sheet draws its own',
    );
  });

  test("the server's heading is not mistaken for an item to fix", () async {
    final AppStore store = _liveStore(
      _client(code: 'unpublishable', message: kRefusal),
    );

    await store.publishForm('form-1');

    expect(
      store.publishProblems.any((String p) => p.contains('not ready to publish')),
      isFalse,
      reason: 'the heading is the sheet\'s title, and listing it as a problem '
          'would put an un-fixable line at the top of every refusal',
    );
  });

  test('an ORDINARY error still toasts rather than opening a sheet', () async {
    // The split that keeps the fix proportionate. `unpublishable` is the one
    // error on this route whose message is a list; a transport failure or a
    // permission error is one sentence, and a modal for it would be worse than
    // the toast it replaced.
    final AppStore store = _liveStore(
      _client(
        code: 'server_error',
        message: 'Something went wrong.',
        status: 500,
      ),
    );

    final (String, List<String>)? res = await store.publishForm('form-1');

    expect(res, isNull);
    expect(store.publishProblems, isEmpty);
  });

  test('a fresh attempt cannot show the previous attempt\'s problems', () async {
    // The list is cleared at the START of every publish, so a second attempt
    // never renders the first one's problems beside its own outcome. Driven with
    // a client that refuses ONCE and then answers a listless error, because the
    // store's `_api` is private and cannot be swapped mid-test.
    int calls = 0;
    final MockClient flaky = MockClient((http.Request req) async {
      if (req.url.path.endsWith('/forms/publish')) {
        calls++;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ok': false,
            'error': calls == 1
                ? <String, dynamic>{
                    'code': 'unpublishable',
                    'message': kRefusal,
                  }
                : <String, dynamic>{
                    'code': 'server_error',
                    'message': 'Something went wrong.',
                  },
          }),
          calls == 1 ? 422 : 500,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }
      return http.Response(
        '{"ok": true, "data": {}}',
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

    final AppStore store = _liveStore(flaky);
    await store.publishForm('form-1');
    expect(store.publishProblems, isNotEmpty);

    await store.publishForm('form-1');
    expect(
      store.publishProblems,
      isEmpty,
      reason: 'a stale work list shown next to a fresh failure sends the '
          'examiner to fix items that may already be fixed',
    );
  });

  test('a single-problem refusal is still a list of one', () async {
    final AppStore store = _liveStore(
      _client(
        code: 'unpublishable',
        message: 'The form is not ready to publish:\n'
            '- "Q9 written" (section "All kinds"): write the golden answer.',
      ),
    );

    await store.publishForm('form-1');

    expect(store.publishProblems, hasLength(1));
    expect(store.publishProblems.single, startsWith('"Q9 written"'));
  });

  test('a refusal with no bullet lines does not come back empty', () async {
    // Defensive: a future refusal that is one bare sentence must still reach the
    // sheet, or the examiner gets a dialog with nothing in it and no toast
    // either - strictly worse than the bug being fixed.
    final AppStore store = _liveStore(
      _client(
        code: 'unpublishable',
        message: 'This form has no questions on it.',
      ),
    );

    await store.publishForm('form-1');

    expect(store.publishProblems, hasLength(1));
    expect(store.publishProblems.single, 'This form has no questions on it.');
  });
}
