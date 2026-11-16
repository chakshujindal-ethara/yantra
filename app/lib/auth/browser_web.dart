import 'package:web/web.dart' as web;

import 'browser.dart';

Browser create() => _WebBrowser();

class _WebBrowser implements Browser {
  @override
  bool get canRedirect => true;

  @override
  Uri currentUri() => Uri.parse(web.window.location.href);

  @override
  Uri redirectUri() => Uri.parse('${web.window.location.origin}/auth/callback');

  @override
  void navigate(Uri url) => web.window.location.assign(url.toString());

  @override
  void replaceUrl(Uri url) => web.window.history.replaceState(null, '', url.toString());

  @override
  String? read(String key) {
    try {
      return web.window.sessionStorage.getItem(key);
    } on Object {
      return null; // storage blocked (private mode, policy): the redirect login simply cannot complete
    }
  }

  @override
  void write(String key, String? value) {
    try {
      if (value == null) {
        web.window.sessionStorage.removeItem(key);
      } else {
        web.window.sessionStorage.setItem(key, value);
      }
    } on Object {
      // same as read: tolerated, the attempt will fail with a clear message
    }
  }
}
