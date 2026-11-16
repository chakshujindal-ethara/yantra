import 'dart:js_interop';

import 'package:web/web.dart' as web;

bool initialOnline() => web.window.navigator.onLine;

void watch(void Function(bool online) onChange) {
  web.window.addEventListener('online', ((web.Event _) => onChange(true)).toJS);
  web.window.addEventListener('offline', ((web.Event _) => onChange(false)).toJS);
}
