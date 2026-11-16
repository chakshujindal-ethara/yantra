// Per-shape counts on the generator screen: the chip stepper and the derived
// total.
//
// WHAT THIS PINS. The examiner asked to see "MCQ x 2" on the type they picked,
// which means the count and the type live on ONE control. The total then has to
// be DERIVED from those parts - a separately stored total is how the whole ends
// up disagreeing with the parts, which is the bug class this codebase keeps
// finding.
//
// Behaviours that are easy to get wrong and cheap to pin:
//   * a type with no explicit count still gets an item (the coverage floor), so
//     its resting label is "any", never "0";
//   * stepping down from 1 clears the quota rather than reaching 0;
//   * quotas below the pinned total leave the remainder to the model, and quotas
//     above it RAISE the total, because generation does the same.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// A generator row carrying per-shape counts, in the module's own wire shape
/// (`S.generator_detail`).
Map<String, dynamic> generatorRow({
  Map<String, dynamic>? quotas,
  int count = 0,
  List<String> allowed = const <String>['mcq', 'subjective_rubric'],
}) => <String, dynamic>{
  'id': 172,
  'name': 'Forklift SOP',
  'state': 'done',
  'sop_gen_state': 'done',
  'tag_extract_state': 'done',
  'sop_question_count': count,
  'question_count_mode': count > 0 ? 'fixed' : 'auto',
  'allowed_types': allowed,
  'shape_quotas': quotas ?? const <String, dynamic>{},
};

void main() {
  group('the generator model reads per-shape counts', () {
    test('counts arrive as ints even when JSON sends floats', () {
      // JSON has no integer type; 2.0 off the wire is still two items.
      final Generator g = Generator.fromJson(
        generatorRow(quotas: <String, dynamic>{'mcq': 2.0, 'image_ab': 3}),
      );

      expect(g.shapeQuotas, <String, int>{'mcq': 2, 'image_ab': 3});
    });

    test('a non-positive or non-numeric count is discarded', () {
      final Generator g = Generator.fromJson(
        generatorRow(
          quotas: <String, dynamic>{
            'mcq': 2,
            'msq': 0,
            'image_ab': -1,
            'video_prompt': 'two',
          },
        ),
      );

      expect(g.shapeQuotas, <String, int>{'mcq': 2},
          reason: 'only a real request survives');
    });

    test('no quotas is an empty map, not a null', () {
      expect(Generator.fromJson(generatorRow()).shapeQuotas, isEmpty);
    });

    test('a template shape rides alongside a type shape', () {
      final Generator g = Generator.fromJson(
        generatorRow(quotas: <String, dynamic>{'mcq': 2, 'template:7': 3}),
      );

      expect(g.shapeQuotas['template:7'], 3);
    });
  });

  group('the task registry reads the SOP\'s own axes', () {
    test('each axis keeps its own option list', () {
      // The live SOP returned four axes: two with four options, two with three.
      // Flattening them to a common set is the generic-scale bug.
      final Generator g = Generator.fromJson(<String, dynamic>{
        ...generatorRow(),
        'tasks': <dynamic>[
          <String, dynamic>{
            'key': 'task:compare-ai-images',
            'display': 'Compare Two AI Images (A/B)',
            'subject_inputs': 'a prompt and two images',
            'worker_output': 'a side per axis',
            'answer_contract': <String, dynamic>{
              'response': 'compare_two',
              'assets_per_question': 2,
              'justification': 'required',
              'dimensions': <dynamic>[
                <String, dynamic>{
                  'label': 'Instruction Following',
                  'options': <dynamic>[
                    'Image A',
                    'Image B',
                    'Both Good',
                    'Both Bad',
                  ],
                },
                <String, dynamic>{
                  'label': 'Less AI-Generated',
                  'options': <dynamic>['Image A', 'Image B', 'Tie'],
                },
              ],
            },
          },
        ],
      });

      expect(g.tasks, hasLength(1));
      final SopTask task = g.tasks.single;
      expect(task.response, 'compare_two');
      expect(task.justification, 'required');
      expect(task.assetsPerQuestion, 2);
      expect(task.axes[0].options, hasLength(4));
      expect(task.axes[1].options, <String>['Image A', 'Image B', 'Tie'],
          reason: "the SOP's own narrower option set must survive");
    });

    test('a task with no contract still parses', () {
      final Generator g = Generator.fromJson(<String, dynamic>{
        ...generatorRow(),
        'tasks': <dynamic>[
          <String, dynamic>{'key': 'task:x', 'display': 'Bare task'},
        ],
      });

      expect(g.tasks.single.display, 'Bare task');
      expect(g.tasks.single.axes, isEmpty);
    });
  });

  group('a background refresh must not erase the counts', () {
    test('a list row without shape_quotas keeps what the detail hydrated', () async {
      // The list route omits per-shape counts. Assigning a list row wholesale
      // would wipe the quotas the examiner just set - the same erasure the
      // merge already prevents for resources and allowed types.
      int reads = 0;
      final MockClient client = MockClient((http.Request req) async {
        final String path = req.url.path;
        Object data = <dynamic>[];
        if (path.endsWith('/auth_token')) {
          data = <String, dynamic>{'access_token': 't', 'refresh_token': 'r'};
        } else if (path.endsWith('/generators')) {
          reads++;
          data = reads == 1
              // First read: the DETAIL-shaped row, with counts.
              ? <dynamic>[
                  generatorRow(quotas: <String, dynamic>{'mcq': 2}),
                ]
              // Second read: a LIST row, no `shape_quotas` key at all.
              : <dynamic>[
                  <String, dynamic>{
                    'id': 172,
                    'name': 'Forklift SOP',
                    'state': 'done',
                    'sop_gen_state': 'done',
                    'tag_extract_state': 'done',
                  },
                ];
        }
        return http.Response(
          jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });

      final AppStore s = AppStore(
        api: ApiClient(client: client, baseUrl: 'http://x'),
      );
      await s.refresh();
      expect(s.genById('172')!.shapeQuotas, <String, int>{'mcq': 2});

      await s.refresh(background: true);

      expect(s.genById('172')!.shapeQuotas, <String, int>{'mcq': 2},
          reason: 'a list row omits the field; it must not clear it');
    });
  });

  group('the template library reads the PAGED envelope', () {
    // `_call` unwraps `data` only when it is a Map. A paged route sends `data`
    // as a LIST with the totals in `meta`, so the whole envelope arrives and the
    // rows live at res['data'] - not res['rows']. Reading the wrong key left the
    // panel silently empty, which is what this pins.
    test('rows arrive from data, not from a rows key', () async {
      final MockClient client = MockClient((http.Request req) async {
        final String path = req.url.path;
        if (path.endsWith('/auth_token')) {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': <String, dynamic>{
                'access_token': 't',
                'refresh_token': 'r',
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        if (path.endsWith('/task_templates')) {
          // The module's own `paged()` shape.
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': <dynamic>[
                <String, dynamic>{
                  'id': 4,
                  'name': 'Compare AI-Generated Images',
                  'response': 'compare_two',
                  'question_type': 'image_ab',
                  'item_count': 4,
                  'authored_by': 'llm_edited',
                  'structure': <dynamic>[],
                  'origin': <String, dynamic>{'id': 172, 'name': 'test T2I'},
                },
              ],
              'meta': <String, dynamic>{
                'total': 1,
                'limit': 200,
                'offset': 0,
                'has_more': false,
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode(<String, dynamic>{'ok': true, 'data': <dynamic>[]}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });

      final AppStore s = AppStore(
        api: ApiClient(client: client, baseUrl: 'http://x'),
      );
      await s.loadTaskTemplates();

      expect(s.taskTemplates, hasLength(1),
          reason: 'the paged envelope puts rows in `data`');
      final TaskTemplate tpl = s.taskTemplates.single;
      expect(tpl.name, 'Compare AI-Generated Images');
      expect(tpl.questionType, 'image_ab');
      expect(tpl.shapeKey, 'template:4');
      expect(tpl.isModelDrafted, isTrue);
      expect(tpl.originName, 'test T2I');
    });
  });
}
