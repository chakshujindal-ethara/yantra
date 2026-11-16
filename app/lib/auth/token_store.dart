import 'package:shared_preferences/shared_preferences.dart';

import 'tokens.dart';

/// Where the session survives an app restart.
abstract class TokenStore {
  Future<Tokens?> read();
  Future<void> write(Tokens? tokens);
}

class MemoryTokenStore implements TokenStore {
  Tokens? _tokens;

  @override
  Future<Tokens?> read() async => _tokens;

  @override
  Future<void> write(Tokens? tokens) async => _tokens = tokens;
}

class PreferencesTokenStore implements TokenStore {
  static const _key = 'yantra.session';

  @override
  Future<Tokens?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return Tokens.decode(prefs.getString(_key));
  }

  @override
  Future<void> write(Tokens? tokens) async {
    final prefs = await SharedPreferences.getInstance();
    if (tokens == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, tokens.encode());
    }
  }
}
