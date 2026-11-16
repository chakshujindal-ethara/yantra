// A candidate must see WHOSE sitting the instructions page is describing.
//
// THE BUG: the consent line read
// `store.personById(ev.employeeId)?.name ?? 'the invited candidate'`, and for a
// candidate that lookup fails twice over - `AppStore.people` is filled only by
// the admin `/api/v1/attempts` load, and `employeeId` is empty on rows that
// came from `/me/assessments` in the first place. So it was an empty-key lookup
// against an empty list, and EVERY real candidate read "the invited candidate".
//
// The data was already on the wire and thrown away in two places: the
// `applicant` block on `/api/v1/me/assessments` (`serializers.py:183-191`), and
// `email` on `auth/me`'s `session_user` (`serializers.py:143-156`). Both writers
// are needed, not just the first: a candidate arriving on an emailed invitation
// link may never call `/me/assessments`, because `/exam/<token>/state` carries
// no applicant block at all.
//
// These are store-level tests on purpose. The rendering is asserted in
// `exam_start_from_list_test.dart`, which mounts the real screen against the
// real payload; what is easy to regress is the parsing precedence, and that is
// what is pinned here.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// `/api/v1/me/assessments` with whatever `applicant` block a case needs, and
/// no attempts - the buckets are irrelevant to identity.
http.Client server(Object? applicant, {bool includeKey = true}) =>
    MockClient((http.Request req) async {
      final Map<String, dynamic> data = <String, dynamic>{
        if (includeKey) 'applicant': applicant,
        'buckets': <String, dynamic>{
          'available': <dynamic>[],
          'in_progress': <dynamic>[],
          'upcoming': <dynamic>[],
          'completed': <dynamic>[],
          'closed': <dynamic>[],
        },
        'total_count': 0,
      };
      return http.Response(
        jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

AppStore store(http.Client c) =>
    AppStore(api: ApiClient(baseUrl: 'http://stub', client: c, bearer: 'stub'))
      ..portal = Portal.member
      ..source = DataSource.live
      ..meId = '2';

/// What `_InstructionsState` computes, kept in one place so a change to the
/// join has to be made here too.
String identityOf(AppStore s, {Person? roster}) {
  final String name = (roster?.name ?? '').trim().isNotEmpty
      ? roster!.name.trim()
      : s.meName.trim();
  final String email = (roster?.email ?? '').trim().isNotEmpty
      ? roster!.email.trim()
      : s.meEmail.trim();
  return <String>[
    if (name.isNotEmpty) name,
    if (email.isNotEmpty) email,
  ].join('  -  ');
}

void main() {
  testWidgets('the applicant block reaches the page', (WidgetTester t) async {
    final AppStore s = store(
      server(<String, dynamic>{
        'id': 2,
        'name': 'Utkarsh Jain E',
        'email': 'utkarsh@example.com',
      }),
    );
    await t.runAsync(() => s.refresh());

    // Both halves. Before the fix this method read only `buckets`, so both of
    // these were '' and the page had nothing to print.
    expect(s.meName, 'Utkarsh Jain E');
    expect(s.meEmail, 'utkarsh@example.com');
    expect(identityOf(s), 'Utkarsh Jain E  -  utkarsh@example.com');
  });

  testWidgets('a null applicant does not blank what auth already set', (
    WidgetTester t,
  ) async {
    final AppStore s = store(server(null));
    // The auth path ran first, as it does for every signed-in session.
    s.meName = 'Ops Manager';
    s.meEmail = 'ops@example.com';
    await t.runAsync(() => s.refresh());

    // `applicant` is null for a signed-in user who is not a candidate.
    // Overwriting unconditionally would trade one empty line for another.
    expect(s.meName, 'Ops Manager');
    expect(s.meEmail, 'ops@example.com');
  });

  testWidgets('a half-populated applicant keeps the half it has', (
    WidgetTester t,
  ) async {
    // The real shape in `exam_start_from_list_test.dart`: a name and no email.
    final AppStore s = store(
      server(<String, dynamic>{'id': 2, 'name': 'Utkarsh Jain E'}),
    );
    await t.runAsync(() => s.refresh());

    expect(s.meName, 'Utkarsh Jain E');
    expect(s.meEmail, '');
    // The separator is joined, not concatenated, so a missing half cannot leave
    // "Utkarsh Jain E  -  " dangling on the page.
    expect(identityOf(s), 'Utkarsh Jain E');
    expect(identityOf(s), isNot(contains('-')));
  });

  test('a direct-link candidate is named by adoptSession alone', () {
    // `/exam/<token>/state` carries no applicant block, so on an emailed
    // invitation this is the ONLY source. `refresh()` is deliberately not
    // called: this is the path where `/me/assessments` never answers.
    final AppStore s = AppStore(
      api: ApiClient(baseUrl: 'http://stub', client: server(null)),
    );
    s.adoptSession(
      orgRole: 'member',
      name: 'Direct Link',
      uid: '9',
      email: 'direct@example.com',
    );
    expect(identityOf(s), 'Direct Link  -  direct@example.com');
  });

  test('no identity at all renders nothing rather than whitespace', () {
    final AppStore s = AppStore(
      api: ApiClient(baseUrl: 'http://stub', client: server(null)),
    );
    // `identity.isEmpty` is what the page guards on, so this must be exactly
    // empty - a '  -  ' or a ' ' would print a blank line with a separator in
    // it, and the consent sentence would still claim there is a name above.
    expect(identityOf(s), isEmpty);
  });

  test('a roster Person wins over the signed-in fallback', () {
    // Admin preview and the seed fixtures are the only cases where `people` is
    // populated on this screen. There the roster row is the subject of the
    // attempt being previewed; `meName` is the ADMIN, and printing that under
    // the candidate's assessment title would misattribute the sitting.
    final AppStore s = AppStore(
      api: ApiClient(baseUrl: 'http://stub', client: server(null)),
    );
    s.meName = 'Admin Viewer';
    s.meEmail = 'admin@example.com';
    const Person roster = Person(
      id: '2',
      name: 'Utkarsh Jain E',
      email: 'utkarsh@example.com',
    );
    expect(
      identityOf(s, roster: roster),
      'Utkarsh Jain E  -  utkarsh@example.com',
    );
  });
}
