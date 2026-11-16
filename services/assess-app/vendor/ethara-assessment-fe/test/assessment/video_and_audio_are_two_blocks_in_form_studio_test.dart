// FORM STUDIO OFFERS VIDEO AND AUDIO AS TWO BLOCKS, ON ONE WIRE KIND.
//
// The owner's words: "instead of media (video or audio), rename it back to
// video while keep audio as another type". The ruling keeps the wire exactly as
// it was: both blocks are a `videoBlock`, and `media_kind` ('video' or 'audio')
// is what tells them apart. So no server change, no `-u`, and every form saved
// before this keeps working - an old `videoBlock` with no `media_kind` reads
// Video until a file is attached, then whatever that file is.
//
// WHAT THIS PINS:
//   * the insert row offers Video and Audio, and no "Video or audio";
//   * each preset its `media_kind`, and the saved item is still `videoBlock`;
//   * the editor header names the block Video or Audio, never "Media (...)";
//   * each picker accepts only its own files;
//   * an upload, by either path the store picks (direct to S3, or base64 on an
//     older server), leaves the declared `media_kind` in the form save;
//   * leaving Audio for another kind drops the 'audio' (or an image would
//     publish as a clip).
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/screens/admin/form_designer_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/form_item_editor.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/controls.dart';
import 'package:ethara_assessment/services/file_pick_stub.dart';

const List<String> _audioExts = <String>[
  '.mp3',
  '.wav',
  '.m4a',
  '.ogg',
  '.aac',
  '.flac',
];
const List<String> _videoExts = <String>['.mp4', '.webm', '.mov'];

typedef _KindPick = (FormItemKind, bool);

/// What the closed kind picker shows: the label of the option whose value is
/// the picker's value - exactly what `DropdownButton` renders.
String _header(WidgetTester t) {
  final SelectField<_KindPick> sf = t.widget<SelectField<_KindPick>>(
    find.byType(SelectField<_KindPick>),
  );
  return sf.options.firstWhere(((_KindPick, String) o) => o.$1 == sf.value).$2;
}

Future<void> _pumpEditor(
  WidgetTester t,
  FormItem item, {
  AppStore? store,
  VoidCallback? afterEdit,
}) async {
  t.view.physicalSize = const Size(1400, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) =>
                FormItemEditor(
                  store: store ?? AppStore(),
                  item: item,
                  index: 0,
                  onEdit: (VoidCallback mutate) {
                    setState(mutate);
                    afterEdit?.call();
                  },
                  onDuplicate: () {},
                  onDelete: () {},
                ),
          ),
        ),
      ),
    ),
  );
  await t.pump();
}

/// The accept string the picker is handed for [item].
Future<String> _acceptFor(WidgetTester t, FormItem item) async {
  final List<String> accepts = <String>[];
  FormItemEditor.pick = ({String accept = ''}) async {
    accepts.add(accept);
    return null;
  };
  addTearDown(() => FormItemEditor.pick = pickFile);
  await _pumpEditor(t, item);
  await t.tap(find.text('Upload'));
  await t.pump();
  await t.tap(find.text('Choose a file'));
  await t.pump();
  return accepts.single;
}

http.Response _ok(Object data) => http.Response(
  jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

/// One fake backend that answers both upload paths and records the form save.
class _Backend {
  _Backend({required this.presignExists}) {
    store = AppStore(
      api: ApiClient(
        bearer: 'ADMIN-TOKEN',
        baseUrl: 'http://localhost:8069',
        client: MockClient(_api),
      ),
      s3Client: MockClient((http.Request r) async {
        calls.add('s3');
        return http.Response('', 204);
      }),
    );
  }

  final bool presignExists;
  late final AppStore store;
  final List<String> calls = <String>[];
  Map<String, dynamic>? savedForm;

  Future<http.Response> _api(http.Request req) async {
    final String path = req.url.path;
    final Map<String, dynamic> body =
        jsonDecode(req.body) as Map<String, dynamic>;
    if (path.endsWith('/forms/media/presign')) {
      calls.add('presign');
      if (!presignExists) {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ok': false,
            'error': <String, dynamic>{'code': 'nf', 'message': 'not found'},
          }),
          404,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }
      return _ok(<String, dynamic>{
        'upload': <String, dynamic>{
          'url': 'https://bucket.s3.amazonaws.com/',
          'fields': <String, dynamic>{'policy': 'P', 'x-amz-signature': 'S'},
          'prefix': 'form_studio/u1/',
          'expires_at': '2026-10-07T12:00:00Z',
        },
        'key': 'form_studio/u1/call.mp3',
      });
    }
    if (path.endsWith('/forms/media/complete')) {
      calls.add('complete');
      return _ok(<String, dynamic>{
        'url': '/api/v1/forms/media/form_studio/u1/call.mp3',
        'storage': 's3',
        'public': true,
      });
    }
    if (path.endsWith('/forms/media')) {
      calls.add('base64');
      return _ok(<String, dynamic>{
        'url': '/api/v1/forms/media/form_studio/legacy/call.mp3',
        'storage': 's3',
        'public': true,
      });
    }
    if (path.endsWith('/forms/save')) {
      calls.add('save');
      savedForm = body['form'] as Map<String, dynamic>;
      return _ok(body['form'] as Object);
    }
    return http.Response('', 404);
  }
}

void main() {
  group('the insert row', () {
    Future<FormDef> openDesigner(WidgetTester t) async {
      t.view.physicalSize = const Size(1600, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      final FormDef f = FormDef(
        'form-1',
        sections: <FormSection>[FormSection('sec-1', items: <FormItem>[])],
      );
      final AppStore store = AppStore()..forms = <FormDef>[f];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FormDesignerScreen(store: store, formId: f.id),
          ),
        ),
      );
      await t.pump();
      return f;
    }

    testWidgets('offers Video and Audio, and no "Video or audio"', (
      WidgetTester t,
    ) async {
      await openDesigner(t);

      expect(find.text('Video'), findsOneWidget);
      expect(find.text('Audio'), findsOneWidget);
      expect(find.text('Video or audio'), findsNothing);
      expect(find.byTooltip('Insert a display video block.'), findsOneWidget);
      expect(find.byTooltip('Insert a display audio block.'), findsOneWidget);
    });

    testWidgets('Video inserts a videoBlock declared video, read as Video', (
      WidgetTester t,
    ) async {
      final FormDef f = await openDesigner(t);

      await t.tap(find.text('Video'));
      await t.pump();

      final FormItem it = f.sections.single.items.single;
      expect(it.kind, FormItemKind.videoBlock);
      expect(it.mediaKind, 'video');
      expect(it.toJson()['kind'], 'videoBlock');
      expect(it.toJson()['media_kind'], 'video');
      expect(_header(t), 'Video');
    });

    testWidgets('Audio inserts a videoBlock declared audio, read as Audio', (
      WidgetTester t,
    ) async {
      final FormDef f = await openDesigner(t);

      await t.tap(find.text('Audio'));
      await t.pump();

      final FormItem it = f.sections.single.items.single;
      expect(it.kind, FormItemKind.videoBlock);
      expect(it.mediaKind, 'audio');
      // THE WIRE IS UNCHANGED: the same kind string, and a JSON round trip
      // (how a duplicate is made) keeps the declared kind.
      expect(it.toJson()['kind'], 'videoBlock');
      expect(it.toJson()['media_kind'], 'audio');
      final FormItem back = FormItem.fromJson(it.toJson());
      expect(back.kind, FormItemKind.videoBlock);
      expect(back.mediaKind, 'audio');
      expect(_header(t), 'Audio');
    });
  });

  group('the label', () {
    test('never says "Media (video or audio)"', () {
      for (final FormItemKind k in FormItemKind.values) {
        expect(k.label, isNot(contains('Media (')), reason: k.name);
      }
      expect(FormItemKind.videoBlock.label, 'Video');
    });

    test('an old item with no media_kind reads Video, then by its file', () {
      final FormItem old = FormItem('old', FormItemKind.videoBlock);
      expect(formItemLabel(old), 'Video');
      expect(isAudioBlock(old), isFalse);

      old.mediaUrl = '/api/v1/forms/media/form_studio/u1/call.mp3';
      expect(formItemLabel(old), 'Audio');

      old.mediaUrl = '/api/v1/forms/media/form_studio/u1/clip.mp4';
      expect(formItemLabel(old), 'Video');
    });

    test('a declared kind wins over the file', () {
      final FormItem it = FormItem('d', FormItemKind.videoBlock)
        ..mediaKind = 'video'
        ..mediaUrl = 'https://cdn.test/call.mp3';
      expect(formItemLabel(it), 'Video');
      it.mediaKind = 'audio';
      it.mediaUrl = 'https://cdn.test/stream/abc';
      expect(formItemLabel(it), 'Audio');
    });

    test('other kinds keep their own label', () {
      expect(formItemLabel(FormItem('i', FormItemKind.imageBlock)), 'Image');
      expect(
        formItemLabel(
          FormItem('i', FormItemKind.imageBlock)..mediaKind = 'audio',
        ),
        'Image',
      );
    });

    testWidgets('the editor header reads Video for an old item', (
      WidgetTester t,
    ) async {
      await _pumpEditor(t, FormItem('old', FormItemKind.videoBlock));
      expect(_header(t), 'Video');
    });

    testWidgets('the kind picker offers both Video and Audio', (
      WidgetTester t,
    ) async {
      await _pumpEditor(
        t,
        FormItem('a', FormItemKind.videoBlock)..mediaKind = 'audio',
      );
      final SelectField<_KindPick> sf = t.widget<SelectField<_KindPick>>(
        find.byType(SelectField<_KindPick>),
      );
      final List<String> labels =
          sf.options.map(((_KindPick, String) o) => o.$2).toList();
      expect(labels, containsAll(<String>['Video', 'Audio', 'Image']));
      expect(labels.where((String l) => l.contains('Media (')), isEmpty);
      expect(_header(t), 'Audio');
    });
  });

  group('each picker accepts only its own files', () {
    testWidgets('Audio is handed audio and no video', (WidgetTester t) async {
      final String accept = await _acceptFor(
        t,
        FormItem('a', FormItemKind.videoBlock)..mediaKind = 'audio',
      );
      for (final String e in _audioExts) {
        expect(accept, contains(e));
      }
      for (final String e in _videoExts) {
        expect(accept, isNot(contains(e)), reason: e);
      }
    });

    testWidgets('Video is handed video and no audio', (WidgetTester t) async {
      final String accept = await _acceptFor(
        t,
        FormItem('v', FormItemKind.videoBlock)..mediaKind = 'video',
      );
      for (final String e in _videoExts) {
        expect(accept, contains(e));
      }
      for (final String e in _audioExts) {
        expect(accept, isNot(contains(e)), reason: e);
      }
    });

    testWidgets('an old item with no media_kind is a Video picker', (
      WidgetTester t,
    ) async {
      final String accept = await _acceptFor(
        t,
        FormItem('o', FormItemKind.videoBlock),
      );
      expect(accept, contains('.mp4'));
      expect(accept, isNot(contains('.mp3')));
    });
  });

  group('an upload keeps the declared kind in the form save', () {
    for (final bool direct in <bool>[true, false]) {
      testWidgets(
        direct ? 'direct to S3' : 'base64, on a server with no presign route',
        (WidgetTester t) async {
          final _Backend be = _Backend(presignExists: direct);
          final FormItem it = FormItem('a', FormItemKind.videoBlock)
            ..mediaKind = 'audio';
          final FormDef f = FormDef(
            'form-1',
            sections: <FormSection>[
              FormSection('sec-1', items: <FormItem>[it]),
            ],
          );
          FormItemEditor.pick = ({String accept = ''}) async =>
              const PickedFile('call.mp3', <int>[1, 2, 3]);
          addTearDown(() => FormItemEditor.pick = pickFile);

          await _pumpEditor(
            t,
            it,
            store: be.store,
            afterEdit: () => be.store.persistForm(f),
          );
          await t.tap(find.text('Upload'));
          await t.pump();
          await t.tap(find.text('Choose a file'));
          for (int i = 0; i < 10; i++) {
            await t.pump(const Duration(milliseconds: 200));
          }

          expect(
            be.calls,
            direct
                ? <String>['presign', 's3', 'complete', 'save']
                : <String>['presign', 'base64', 'save'],
          );
          final Map<String, dynamic> saved =
              ((be.savedForm!['sections'] as List<dynamic>).single
                          as Map<String, dynamic>)['items']
                      .single
                  as Map<String, dynamic>;
          expect(saved['kind'], 'videoBlock');
          expect(saved['media_kind'], 'audio');
          expect(saved['media_url'], endsWith('/call.mp3'));
          // Let the "Uploaded" toast expire, so no timer outlives the test.
          await t.pump(const Duration(seconds: 4));
        },
      );
    }
  });

  group('switching kind in the picker', () {
    Future<void> choose(WidgetTester t, String label) async {
      await t.tap(find.byType(SelectField<_KindPick>));
      await t.pumpAndSettle();
      await t.tap(find.text(label).last);
      await t.pumpAndSettle();
    }

    testWidgets('Audio to Image drops the declared audio', (
      WidgetTester t,
    ) async {
      final FormItem it = FormItem('a', FormItemKind.videoBlock)
        ..mediaKind = 'audio';
      await _pumpEditor(t, it);

      await choose(t, 'Image');

      expect(it.kind, FormItemKind.imageBlock);
      expect(it.mediaKind, isEmpty);
      expect(it.toJson().containsKey('media_kind'), isFalse);
    });

    testWidgets('Video to Audio declares audio on the same wire kind', (
      WidgetTester t,
    ) async {
      final FormItem it = FormItem('v', FormItemKind.videoBlock)
        ..mediaKind = 'video';
      await _pumpEditor(t, it);

      await choose(t, 'Audio');

      expect(it.kind, FormItemKind.videoBlock);
      expect(it.mediaKind, 'audio');
      expect(_header(t), 'Audio');
    });
  });
}
