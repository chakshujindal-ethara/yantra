/// −3 s / +3 s / Speed for a clip the candidate transcribes.
///
/// The Transcription question needs to replay a few seconds and slow a clip
/// down, as the Strix workbench does. The browser's own `<audio controls>` has
/// neither a jump button nor (outside Chrome) a speed menu, so the plate draws
/// them in Flutter and drives the element through [ClipControls]. The web plate
/// binds the controller to its element; in a VM test nothing is bound and every
/// call is a no-op, so the same widgets render and can be tapped.
library;

import 'package:flutter/material.dart';

import '../../theme.dart';

/// The keys a Transcription question answers while the candidate types.
const String clipKeysHint =
    'Alt+K play or pause · Alt+J / Alt+L back or forward 3 s · '
    'Alt+, / Alt+. slower or faster';

class ClipControls extends ChangeNotifier {
  /// The Strix workbench's speeds.
  static const List<double> speeds = <double>[0.5, 0.75, 1, 1.25, 1.5];

  /// How far one press of −3 s / +3 s moves the clip.
  static const double jumpSeconds = 3;

  double _rate = 1;
  double get rate => _rate;

  void Function(double seconds)? _seek;
  void Function(double rate)? _applyRate;
  void Function()? _toggle;

  /// Called by the web plate once its element exists. The speed chosen before
  /// the element arrived is applied straight away.
  void bind({
    required void Function(double seconds) seek,
    required void Function(double rate) applyRate,
    required void Function() toggle,
  }) {
    _seek = seek;
    _applyRate = applyRate;
    _toggle = toggle;
    applyRate(_rate);
  }

  void unbind() {
    _seek = null;
    _applyRate = null;
    _toggle = null;
  }

  void seekBy(double seconds) => _seek?.call(seconds);

  void togglePlay() => _toggle?.call();

  void setRate(double rate) {
    if (rate == _rate) return;
    _rate = rate;
    _applyRate?.call(rate);
    notifyListeners();
  }

  /// One step slower (-1) or faster (+1), stopping at the ends.
  void stepRate(int direction) {
    final int at = speeds.indexOf(_rate);
    final int next = ((at < 0 ? speeds.indexOf(1) : at) + direction).clamp(
      0,
      speeds.length - 1,
    );
    setRate(speeds[next]);
  }
}

/// The plate's player with −3 s before it and +3 s and Speed after it. Under
/// 520 px the buttons drop below the player so the bar keeps its width.
class ClipControlsBar extends StatelessWidget {
  const ClipControlsBar({
    super.key,
    required this.controls,
    required this.player,
  });

  final ClipControls controls;
  final Widget player;

  @override
  Widget build(BuildContext context) {
    final Widget back = _JumpButton(
      label: '−3 s',
      tooltip: 'Back 3 seconds (Alt+J)',
      onPressed: () => controls.seekBy(-ClipControls.jumpSeconds),
    );
    final Widget forward = _JumpButton(
      label: '+3 s',
      tooltip: 'Forward 3 seconds (Alt+L)',
      onPressed: () => controls.seekBy(ClipControls.jumpSeconds),
    );
    final Widget speed = _SpeedMenu(controls: controls);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        if (box.maxWidth < 520) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              player,
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[back, forward, speed],
              ),
            ],
          );
        }
        return Row(
          children: <Widget>[
            back,
            const SizedBox(width: 10),
            Expanded(child: player),
            const SizedBox(width: 10),
            forward,
            const SizedBox(width: 12),
            speed,
          ],
        );
      },
    );
  }
}

class _JumpButton extends StatelessWidget {
  const _JumpButton({
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  final String label;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: Colors.white38),
        minimumSize: const Size(64, 40),
        shape: const RoundedRectangleBorder(borderRadius: Radii.button),
      ),
      child: Text(
        label,
        style: context.type.mono.copyWith(color: Colors.white),
      ),
    ),
  );
}

class _SpeedMenu extends StatelessWidget {
  const _SpeedMenu({required this.controls});

  final ClipControls controls;

  static String _label(double rate) =>
      '${rate == rate.roundToDouble() ? rate.toInt() : rate}×';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controls,
    builder: (BuildContext context, _) => Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          'Speed',
          style: context.type.small.copyWith(color: Colors.white70),
        ),
        const SizedBox(width: 8),
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white38),
            borderRadius: Radii.button,
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<double>(
              value: controls.rate,
              dropdownColor: const Color(0xFF22262D),
              iconEnabledColor: Colors.white70,
              focusColor: Colors.transparent,
              style: context.type.body.copyWith(color: Colors.white),
              items: <DropdownMenuItem<double>>[
                for (final double r in ClipControls.speeds)
                  DropdownMenuItem<double>(value: r, child: Text(_label(r))),
              ],
              onChanged: (double? r) {
                if (r != null) controls.setRate(r);
              },
            ),
          ),
        ),
      ],
    ),
  );
}
