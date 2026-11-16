import 'package:flutter/foundation.dart';

import 'network_status_stub.dart' if (dart.library.js_interop) 'network_status_web.dart' as impl;

/// Whether the browser has a network ([online], from `navigator.onLine` and its events) and whether the
/// gateway answered the last request ([reachable], reported by the gateway client). The shell shows a
/// banner while either is false.
class NetworkStatus extends ChangeNotifier {
  NetworkStatus({bool online = true}) : _online = online; // ignore: prefer_initializing_formals

  /// The real browser's status, kept current by its `online`/`offline` events.
  factory NetworkStatus.platform() {
    final status = NetworkStatus(online: impl.initialOnline());
    impl.watch(status.setOnline);
    return status;
  }

  bool _online;
  bool _reachable = true;

  bool get online => _online;
  bool get reachable => _reachable;

  void setOnline(bool value) {
    if (value == _online) return;
    _online = value;
    notifyListeners();
  }

  void reportReachable(bool value) {
    if (value == _reachable) return;
    _reachable = value;
    notifyListeners();
  }
}
