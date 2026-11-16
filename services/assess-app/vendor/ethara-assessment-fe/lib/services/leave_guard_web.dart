import 'dart:js_interop';

import 'package:web/web.dart' as web;

web.EventListener? _listener;

/// Hold the page while an answer save is pending: [onLeave] runs on
/// `beforeunload` and the browser asks "Leave site?", which gives the save
/// the time an unload would cancel. Null takes the hold off.
void setLeaveGuard(void Function()? onLeave) {
  if (_listener != null) {
    web.window.removeEventListener('beforeunload', _listener);
    _listener = null;
  }
  if (onLeave == null) return;
  _listener = ((web.BeforeUnloadEvent e) {
    onLeave();
    e.preventDefault();
    // Legacy browsers only prompt when this is set.
    e.returnValue = '';
  }).toJS;
  web.window.addEventListener('beforeunload', _listener);
}
