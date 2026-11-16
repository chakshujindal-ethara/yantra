// The control the examiner DREW is the control the candidate answers.
//
// Three defects reported from stage, one cause: `input_kind` arrives correctly on
// the candidate payload and the runner only read it for two of the kinds that
// set it.
//
//   * a `dropdown` rendered as a stack of radios - visually indistinguishable
//     from a plain multiple choice, which is how it was reported ("Dropdown does
//     not work. Visible as MCQ on candidate side");
//   * `rating` and `linearScale` both rendered through `_ScaleRow`, so the two
//     were pixel-identical on the candidate's screen while Form Studio previewed
//     them as different controls ("UI of Rating & Linear Scale is same and not
//     true to their design");
//   * and the badge on the admin screens printed the ENGINE type, so a dropdown,
//     a linear scale, a rating and a multiple choice all read "MCQ" ("Question
//     type is not rightly mapped for Form Studio Questions").
//
// THE BACKEND WAS CLEARED FIRST. A form carrying all nine kinds was published
// against live stage and every dimension came back with its `input_kind` set
// ('dropdown', 'linearScale', 'rating', 'choiceGrid', ...), so nothing here is
// compensating for a server that lost the examiner's choice - the client simply
// did not read what it was sent.
//
// WHY THE LABEL IS ASSERTED AND NOT THE PIXELS. `Question.designerKind` is the
// single place all four admin surfaces resolve a badge from, and the three
// predicates in `answer_layouts` (`_isDropdown`, `_isStarRating`, `isScaleAxis`)
// are pure functions of the same field. Pumping `AnswerArea` needs a live
// `Attempt`, a seeded store and a mocked client - the harness in
// `exam_navigation_test` - and would assert the same routing through three more
// layers.
//
// THE SCALE'S RENDERING IS PINNED SEPARATELY NOW, in
// `linear_scale_looks_like_a_scale_test.dart`, through that harness. This header
// used to defer the whole rendering half to a visual check in Chrome, and the
// scale came back from stage a second time - "Linear scale should look like it
// and not boxes": splitting the two kinds apart had left `linearScale` on the
// bordered-cell row it shared with `rating`, which reads as a row of choice boxes
// rather than a range. A star that fails to paint is still easier to see by eye
// than to assert, so the rating's own drawing stays with the E2E pass.
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';

Question _q({
  required List<QDimension> dims,
  QType type = QType.mcq,
  String sourceTemplateName = '',
}) => Question(
  id: 'q-1',
  genId: 'gen-1',
  type: type,
  name: 'A question',
  prompt: 'Answer it',
  dims: dims,
  sourceTemplateName: sourceTemplateName,
);

QDimension _dim(
  String inputKind, {
  String name = 'Answer',
  List<String> labels = const <String>['1', '2', '3', '4', '5'],
}) => QDimension(
  code: 'D1',
  name: name,
  inputKind: inputKind,
  options: <QOption>[
    for (final String l in labels)
      QOption(id: 'o-$l', label: l, correct: l == labels.first),
  ],
);

void main() {
  group('the badge names the control, not the engine', () {
    test('a dropdown is called "Dropdown", not "MCQ"', () {
      final Question q = _q(
        dims: <QDimension>[
          _dim('dropdown', labels: <String>['One', 'Two']),
        ],
      );

      expect(q.designerKind, FormItemKind.dropdown);
      expect(q.taskLabel, 'Dropdown');
      expect(
        q.taskLabel,
        isNot(QType.mcq.short),
        reason: 'a dropdown, a linear scale, a rating and a multiple choice are '
            'all STORED as mcq because they are all "pick one keyed option" - '
            'that is right for scoring and useless as a badge',
      );
    });

    test('a linear scale and a rating do not share a label', () {
      final Question scale = _q(dims: <QDimension>[_dim('linearScale')]);
      final Question rating = _q(dims: <QDimension>[_dim('rating')]);

      expect(scale.taskLabel, 'Linear scale');
      expect(rating.taskLabel, 'Rating');
      expect(
        scale.taskLabel,
        isNot(rating.taskLabel),
        reason: 'the two controls are different shapes and the badge has to say '
            'which one the examiner drew',
      );
    });

    test('a question with no authored control reads its engine type', () {
      // Every question written before the designer stamped `input_kind` - i.e.
      // the whole existing bank. The fallback must be unchanged for them.
      final Question q = _q(
        dims: <QDimension>[_dim('', labels: <String>['Yes', 'No'])],
      );

      expect(q.designerKind, isNull);
      expect(q.taskLabel, QType.mcq.short);
      expect(q.taskLabelLong, QType.mcq.label);
    });

    test('a TEMPLATE name still outranks the control', () {
      // A reviewer approving "Verify a single photo edit" needs the task, not
      // the widget. The designer kind only answers the case where there is no
      // task name at all.
      final Question q = _q(
        sourceTemplateName: 'Verify a single photo edit',
        dims: <QDimension>[_dim('dropdown')],
      );

      expect(q.taskLabel, 'Verify a single photo edit');
      expect(q.taskLabelLong, 'Verify a single photo edit');
    });

    test('a kind this build cannot draw falls back rather than throwing', () {
      // A form authored by a newer build. `designerKind` must be null, not an
      // exception, and the badge must still say something true.
      final Question q = _q(dims: <QDimension>[_dim('holographicSlider')]);

      expect(q.designerKind, isNull);
      expect(q.taskLabel, QType.mcq.short);
    });

    test('a grid names its kind on every row and reads as one label', () {
      final Question q = _q(
        dims: <QDimension>[
          _dim('choiceGrid', name: 'Row 1', labels: <String>['A', 'B']),
          _dim('choiceGrid', name: 'Row 2', labels: <String>['A', 'B']),
        ],
      );

      expect(q.taskLabel, 'Multiple choice grid');
    });

    test('the kind is read from the first axis that names one', () {
      // A question whose lead axis is a plain one - the grid rows carry the
      // kind. Reading only `dims.first` would report the engine type.
      final Question q = _q(
        dims: <QDimension>[
          _dim('', name: 'Lead', labels: <String>['x', 'y']),
          _dim('rating', name: 'Quality'),
        ],
      );

      expect(q.designerKind, FormItemKind.rating);
    });

    test('every designer kind that survives publish resolves to a label', () {
      // A COMPLETENESS CHECK, not a list of examples. `input_kind` is stamped
      // from the designer kind for every published axis, so any kind whose name
      // does not round-trip through `FormItemKind.values` badges as its engine
      // type instead - silently, and only on that one kind.
      for (final FormItemKind k in FormItemKind.values) {
        final Question q = _q(dims: <QDimension>[_dim(k.name)]);
        expect(
          q.designerKind,
          k,
          reason: '"${k.name}" is stamped onto input_kind at publish, so it '
              'must resolve back to a kind here',
        );
        expect(q.taskLabel, k.label);
      }
    });
  });
}
