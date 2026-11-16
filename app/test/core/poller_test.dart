import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/poller.dart';

void main() {
  testWidgets('ticks at start and every interval, never overlapping', (tester) async {
    var ticks = 0;
    final p = Poller(every: const Duration(seconds: 60), tick: () async => ticks++)..start();
    await tester.pump();
    expect(ticks, 1);
    expect(p.running, isTrue);
    p.start(); // a second start changes nothing
    await tester.pump(const Duration(seconds: 59));
    expect(ticks, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(ticks, 2);
    p.stop();
    p.stop();
    await tester.pump(const Duration(seconds: 120));
    expect(ticks, 2);
  });

  testWidgets('a hidden tab stops ticking; coming back ticks at once when the last tick is old', (tester) async {
    var now = DateTime(2026, 11, 4, 12);
    var ticks = 0;
    final p = Poller(every: const Duration(seconds: 60), tick: () async => ticks++, clock: () => now)..start();
    await tester.pump();
    expect(ticks, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump(const Duration(seconds: 180));
    expect(ticks, 1, reason: 'no ticks while hidden');
    now = now.add(const Duration(seconds: 180));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(ticks, 2, reason: 'back after a long gap: tick now');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 60));
    expect(ticks, 3);
    p.dispose();
  });

  testWidgets('a quick hide and show does not tick early, and a slow tick is not run twice', (tester) async {
    var now = DateTime(2026, 11, 4, 12);
    var ticks = 0;
    final p = Poller(every: const Duration(seconds: 60), tick: () async => ticks++, clock: () => now)..start();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    now = now.add(const Duration(seconds: 5));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(ticks, 1);
    p.dispose();
  });

  testWidgets('a tick that throws is caught and logged once; the poller keeps ticking', (tester) async {
    var ticks = 0;
    final logged = <String>[];
    final p = Poller(
      every: const Duration(seconds: 15),
      tick: () async {
        ticks++;
        if (ticks < 4) throw StateError('down');
      },
      log: logged.add,
    )..start();
    await tester.pump();
    await tester.pump(const Duration(seconds: 15));
    await tester.pump(const Duration(seconds: 15));
    expect(ticks, 3);
    expect(logged, hasLength(1), reason: 'one line per failing streak, not one per tick');
    await tester.pump(const Duration(seconds: 15));
    expect(ticks, 4, reason: 'still ticking after the failures');
    expect(tester.takeException(), isNull);
    p.dispose();
  });
}
