// D1 - typing the internal remark on ONE sitting.
//
// A SHEET RATHER THAN AN INLINE FIELD, because this write is a claim that
// outlives the screen: it is read months later by somebody arguing about a
// mark, so it is worth a beat and a sentence saying what it is for before the
// button that saves it. `showSheet` is the house object for exactly that.
//
// THE REASON FIELD IS GONE, and with it `askToFlag`. The flag is a toggle now -
// one click beside the candidate's name, no form - so a sheet demanding a
// reason before it would raise one was standing in front of the only control
// this feature has. What is left is prose, which genuinely needs a box.
//
// THE REMARK IS INDEPENDENT OF THE FLAG. This file does not accept, return or
// imply a flag state: the caller passes `remark:` alone to
// `AppStore.flagAttempt`, so saving a remark can never raise or clear a flag as
// a side effect. That coupling is the bug this shape prevents.
import 'package:flutter/material.dart';

import '../domain/enums.dart';
import '../theme.dart';
import 'buttons.dart';
import 'controls.dart';
import 'feedback.dart';

/// Ask for the internal remark on one attempt.
///
/// Returns the text when the operator commits and null when they back out. AN
/// EMPTY STRING IS A COMMITTED ANSWER: it means "clear the remark", which is
/// why the two cases are a `String?` and not a non-empty string - collapsing
/// them would make the remark impossible to delete, and folding '' into null
/// would make backing out silently erase it.
///
/// The caller does the write, so this file knows nothing about the store.
Future<String?> askForRemark(
  BuildContext context, {
  required String candidateName,
  String existing = '',
}) {
  String remark = existing;

  return showSheet<String>(
    context,
    title: existing.trim().isEmpty
        ? 'Add a remark on $candidateName'
        : 'Edit the remark on $candidateName',
    sub: 'Internal only. This never reaches the candidate.',
    body: StatefulBuilder(
      builder: (BuildContext ctx, StateSetter setLocal) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Notice(
            tone: Tone.info,
            strong: 'This sitting only.',
            text:
                'The remark belongs to this attempt, not to the person: the '
                'same candidate on another assessment carries their own, and '
                'this one does not follow them there. It is independent of the '
                'flag - saving here neither raises nor clears one - and it is '
                'never included in anything the candidate can read.',
          ),
          const SizedBox(height: 14),
          Text('Internal remark', style: ctx.type.fieldLabel),
          const SizedBox(height: 5),
          FormTextInput(
            id: 'flag-remark',
            value: remark,
            maxLines: 6,
            hint:
                'What happened on this sitting, and what a reviewer should '
                'know about it.',
            onChanged: (String v) => setLocal(() => remark = v),
          ),
          const SizedBox(height: 10),
          // STATED, not left to be discovered by pressing Save on an empty
          // box. Deleting the text IS how a remark is removed, and an operator
          // who does not know that will leave a stale one in place rather than
          // risk it.
          Text(
            existing.trim().isEmpty
                ? 'Saving an empty box records nothing.'
                : remark.trim().isEmpty
                ? 'Saving now REMOVES the remark from this attempt.'
                : 'Saving replaces the current remark. Cancel leaves it '
                      'exactly as it is.',
            style: ctx.type.bodyMuted,
          ),
        ],
      ),
    ),
    actions: <Widget>[
      // Cancel FIRST and the affirmative LAST, per the sheet contract.
      Builder(
        builder: (BuildContext ctx) => Btn(
          'Cancel',
          size: BtnSize.sm,
          onPressed: () => Navigator.of(ctx).pop(),
        ),
      ),
      // ONE LABEL, WHICH DOES NOT REACT TO TYPING - because it cannot. The
      // actions row is built outside the `StatefulBuilder` above, so
      // `setLocal` never rebuilds it: the old sheet's Save button was disabled
      // until a reason was typed and then stayed dead, because the rebuild that
      // was supposed to re-enable it only ever reached the body. Anything
      // conditional on the text lives in the body for that reason, and this
      // button reads the current value out of the closure at click time.
      Builder(
        builder: (BuildContext ctx) => Btn.primary(
          'Save Remark',
          size: BtnSize.sm,
          tooltip:
              'Store this text on this sitting. Admins see it on the attempt; '
              'the candidate never does. It does not raise or clear the flag, '
              'and it does not change the mark or the verdict. Clearing the '
              'box and saving removes it.',
          onPressed: () => Navigator.of(ctx).pop(remark.trim()),
        ),
      ),
    ],
  );
}
