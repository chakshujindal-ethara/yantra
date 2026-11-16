import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';

void main() {
  test('the DETAIL payload keeps its id so the merge can match', () {
    // loadDraft replaces the row whose id matches. If fromJson loses or
    // rewrites the id, the merge silently no-ops and the card keeps the thin
    // list row - which is exactly a blank image over a server that sent one.
    final Question q = Question.fromJson(const <String, dynamic>{
      'id': 76,
      'name': 'Task: Label Wikipedia Homepage UI',
      'question_type': 'image_label',
      'state': 'draft',
      'images': <dynamic>[
        <String, dynamic>{'slot': 'single', 'data': 'data:image/png;base64,AA'},
      ],
      'label_boxes': <dynamic>[
        <String, dynamic>{
          'number': 1,
          'box_2d': <int>[0, 0, 500, 500],
        },
      ],
    });
    expect(q.id, '76');
    expect(q.images.length, 1);
    expect(q.state.name, 'draft');
  });
}
