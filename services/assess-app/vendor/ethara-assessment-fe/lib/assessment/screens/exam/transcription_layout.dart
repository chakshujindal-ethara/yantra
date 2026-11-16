/// The exam layout for a Transcription question: the clip with −3 s / +3 s /
/// Speed, the transcription box, and the "About this clip" panel.
///
/// Same arrangement as the Strix workbench: the player above, the answer and
/// the clip questions side by side from 900 px, stacked below that. The Alt
/// keys reach the clip from anywhere in the question, typing included.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../domain/transcription.dart';
import '../../state/app_store.dart';
import '../../widgets/feedback.dart';
import '../../widgets/panel.dart';
import 'answer_layouts.dart' show mediaPlates;
import 'audio_plate.dart';
import 'clip_answers_form.dart';
import 'clip_controls.dart';
import 'transcription_box.dart';

/// The clip a transcription question owns: its `single` slot, else its first.
Asset? transcriptionClip(Question q) {
  for (final Asset v in q.videos) {
    if (v.slot == 'single' && (v.url ?? '').isNotEmpty) return v;
  }
  for (final Asset v in q.videos) {
    if ((v.url ?? '').isNotEmpty) return v;
  }
  return null;
}

class TranscriptionLayout extends StatefulWidget {
  const TranscriptionLayout({
    super.key,
    required this.store,
    required this.ev,
    required this.q,
    required this.r,
    this.readOnly = false,
  });

  final AppStore store;
  final Attempt ev;
  final Question q;
  final Response r;
  final bool readOnly;

  @override
  State<TranscriptionLayout> createState() => _TranscriptionLayoutState();
}

class _TranscriptionLayoutState extends State<TranscriptionLayout> {
  final ClipControls _controls = ClipControls();
  late ClipAnswers _clip = (widget.r.clip ?? ClipAnswers()).copy();

  /// What is in the box, kept while a non-None category hides it: choosing
  /// None again brings it back, as the Strix workbench does. Only a None
  /// category SENDS it - the guide says such a clip is not transcribed.
  late String _text = widget.r.justification;

  @override
  void dispose() {
    _controls.dispose();
    super.dispose();
  }

  void _save() {
    if (widget.readOnly) return;
    final Response now = widget.store.responseFor(widget.ev, widget.q);
    widget.store.saveAnswerQuiet(
      widget.ev.id,
      widget.q.id,
      now.copyWith(
        justification: _clip.transcribed ? _text : '',
        clip: _clip.copy(),
      ),
    );
  }

  /// Alt+K / J / L / , / . drive the clip while the candidate types. Matched
  /// on the PHYSICAL key: on a Mac, Alt+K is "˚" as a logical key, and
  /// returning handled is also what keeps that "˚" out of the box.
  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent || !HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final PhysicalKeyboardKey k = e.physicalKey;
    if (k == PhysicalKeyboardKey.keyK) {
      _controls.togglePlay();
    } else if (k == PhysicalKeyboardKey.keyJ) {
      _controls.seekBy(-ClipControls.jumpSeconds);
    } else if (k == PhysicalKeyboardKey.keyL) {
      _controls.seekBy(ClipControls.jumpSeconds);
    } else if (k == PhysicalKeyboardKey.comma) {
      _controls.stepRate(-1);
    } else if (k == PhysicalKeyboardKey.period) {
      _controls.stepRate(1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final Asset? clip = transcriptionClip(widget.q);
    final String language = widget.q.transcriptionLanguage;

    final Widget answer = Panel(
      title: 'Your answer',
      child: _clip.transcribed
          ? TranscriptionBox(
              key: ValueKey<String>('tx-${widget.q.id}'),
              language: language,
              initialText: _text,
              readOnly: widget.readOnly,
              blockPaste: true,
              controls: _controls,
              onChanged: (String v) {
                _text = v;
                _save();
              },
            )
          : const Notice(
              tone: Tone.info,
              text:
                  'With this category the clip is not transcribed, so there '
                  'is nothing to type. To transcribe it, set the category to '
                  'None.',
            ),
    );
    final Widget about = Panel(
      title: 'About this clip',
      child: ClipAnswersForm(
        clip: _clip,
        language: language,
        readOnly: widget.readOnly,
        onChanged: (ClipAnswers c) {
          setState(() => _clip = c);
          _save();
        },
      ),
    );

    return Focus(
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // Media a Form Studio block placed before this question carried in
          // (an example clip, a picture): shown above the clip to transcribe.
          ...mediaPlates(widget.q.images, <Asset>[
            for (final Asset v in widget.q.videos)
              if (!identical(v, clip)) v,
          ]),
          if (clip == null)
            const Notice(
              tone: Tone.warn,
              text:
                  'The clip for this question is missing. Tell your '
                  'assessment organiser.',
            )
          else
            AudioPlate(asset: clip, controls: _controls),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) =>
                box.maxWidth >= 900
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(child: answer),
                      const SizedBox(width: 16),
                      SizedBox(width: 340, child: about),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      answer,
                      const SizedBox(height: 16),
                      about,
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
