import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/network_status.dart';

void main() {
  test('starts online and reachable; notifies only on a change', () {
    final n = NetworkStatus();
    var calls = 0;
    n.addListener(() => calls++);
    expect(n.online, isTrue);
    expect(n.reachable, isTrue);
    n.reportReachable(true);
    expect(calls, 0);
    n.reportReachable(false);
    expect(n.reachable, isFalse);
    n.setOnline(false);
    expect(n.online, isFalse);
    expect(calls, 2);
    n.setOnline(true);
    n.reportReachable(true);
    expect(calls, 4);
  });
}
