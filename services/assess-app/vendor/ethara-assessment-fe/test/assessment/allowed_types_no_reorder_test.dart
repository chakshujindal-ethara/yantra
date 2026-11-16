/// Choosing a question type must not move the chips already on screen.
///
/// THE DEFECT, as reported: the picker "flickers or appears to shake" when a
/// type is selected. Not a paint bug - a reorder.
///
/// `setAllowedTypes` writes optimistically so the chip appears instantly, and
/// the picker hands it the list it already holds with the new type APPENDED.
/// It then awaits `loadGenerator`, which replaces the record with the server's
/// copy - and the server returns the types in its own fixed order. So a type
/// that sorts early was painted at the right-hand end of the row and then
/// jumped to the front a moment later, sliding every other chip sideways.
///
/// Proven in a browser before it was fixed: seeding "Video prompt writing" and
/// then "Rubric" rendered as `Rubric > Video prompt writing` - the opposite of
/// the order they were added in, which is only possible if something reordered
/// the list after the optimistic write.
///
/// The fix sorts the optimistic list into the same order, so the refetch has
/// nothing left to change.
library;

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppStore store;
  late String genId;

  setUp(() {
    store = AppStore();
    genId = store.generators.first.id;
  });

  tearDown(() => store.dispose());

  /// The types as the picker would paint them, read WITHOUT awaiting - the
  /// optimistic frame is the one the user sees and the one that was wrong.
  List<QType> painted() => store.genById(genId)!.allowedTypes;

  test('a type appended by the picker lands in its settled position', () {
    // Exactly the reported case: two later types already chosen, then MCQ -
    // which belongs first - added on the end the way the picker adds it.
    store.updateGenerator(store.genById(genId)!.copyWith(
      allowedTypes: const <QType>[QType.subjectiveRubric],
    ));

    // Not awaited on purpose. This is the frame that is painted immediately.
    unawaited(store.setAllowedTypes(
      genId,
      const <QType>[QType.subjectiveRubric, QType.mcq],
    ));

    expect(
      painted(),
      const <QType>[QType.mcq, QType.subjectiveRubric],
      reason: 'MCQ must be painted first straight away, not appear last and '
          'then jump when the refetch lands',
    );
  });

  test('the order never depends on the order they were picked in', () {
    // Two runs, opposite pick orders, same settled row. Without this the row
    // reads differently depending on history, and reordering itself later is
    // exactly the shake.
    store.updateGenerator(
      store.genById(genId)!.copyWith(allowedTypes: const <QType>[]),
    );
    unawaited(store.setAllowedTypes(
      genId,
      const <QType>[QType.videoPrompt, QType.subjectiveRubric],
    ));
    final List<QType> first = List<QType>.from(painted());

    unawaited(store.setAllowedTypes(
      genId,
      const <QType>[QType.subjectiveRubric, QType.videoPrompt],
    ));

    expect(painted(), first);
    expect(
      painted().first,
      QType.subjectiveRubric,
      reason: 'Rubric sorts before Video prompt writing in QType.generatable, '
          'which is the order the server returns',
    );
  });

  test('every ticked type survives the sort', () {
    // The sort exists to stop a row jumping. Losing a type while doing it
    // would be a far worse bug than the one being fixed.
    unawaited(store.setAllowedTypes(genId, QType.generatable.reversed.toList()));

    expect(painted().toSet(), QType.generatable.toSet());
    expect(painted(), QType.generatable);
  });

  test('clearing every type still clears', () {
    unawaited(store.setAllowedTypes(genId, const <QType>[QType.mcq]));
    unawaited(store.setAllowedTypes(genId, const <QType>[]));

    expect(painted(), isEmpty);
  });
}

/// Local, so the test can state plainly that it is NOT awaiting the write.
void unawaited(Future<void> f) {}
