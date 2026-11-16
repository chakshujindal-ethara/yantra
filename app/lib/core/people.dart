import 'dart:async';

import 'package:flutter/foundation.dart';

/// A person's display name and kind (`worker`, `staff`, `client`), as the people endpoint knows them.
class Person {
  const Person({required this.name, this.kind = ''});
  final String name;
  final String kind;
}

/// Names for ids, fetched lazily: every [lookup] miss in the same frame goes out as one
/// `GET /v1/people?ids=a,b,c` (at most [batchSize] ids per request). Ids the server does not know, and
/// requests that fail, are remembered as unknown for [negativeFor] so a screen of unnamed rows does not
/// ask again on every rebuild. Inline names a row already carries are [prime]d so no request is made.
class PeopleCache extends ChangeNotifier {
  PeopleCache(
    this._fetch, {
    this.announce,
    this.batchDelay = const Duration(milliseconds: 16),
    this.negativeFor = const Duration(seconds: 60),
    this.batchSize = 200,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Future<Map<String, Person>> Function(List<String> ids) _fetch;

  /// Registers the signed-in person; see [announceSelf].
  final Future<void> Function()? announce;
  String? _announcedFor;
  final Duration batchDelay;
  final Duration negativeFor;
  final int batchSize;
  final DateTime Function() _clock;

  final Map<String, Person> _known = {};
  final Map<String, DateTime> _unknownUntil = {};
  final Set<String> _queued = {};
  final Set<String> _inFlight = {};
  Timer? _timer;

  /// The person behind [id], or null while it is being fetched or when nobody knows it.
  Person? lookup(String id) {
    if (id.isEmpty) return null;
    final hit = _known[id];
    if (hit != null) return hit;
    final until = _unknownUntil[id];
    if (until != null && _clock().isBefore(until)) return null;
    if (_inFlight.contains(id) || !_queued.add(id)) return null;
    _timer ??= Timer(batchDelay, _flush);
    return null;
  }

  /// Tells the platform who is signed in (`PUT /v1/talent/people/me`), once per signed-in subject, so
  /// operators and clients see this person's name instead of an id. A failure is retried next session.
  Future<void> announceSelf(String subject) async {
    final announce = this.announce;
    if (announce == null || subject.isEmpty || _announcedFor == subject) return;
    _announcedFor = subject;
    try {
      await announce();
    } on Object {
      _announcedFor = null;
    }
  }

  /// Records a name a row already carries (`worker_name`, `author_name`).
  void prime(String id, String name, {String kind = ''}) {
    if (id.isEmpty || name.isEmpty) return;
    _known[id] = Person(name: name, kind: kind);
    _unknownUntil.remove(id);
  }

  Future<void> _flush() async {
    _timer = null;
    final ids = _queued.toList();
    _queued.clear();
    if (ids.isEmpty) return;
    _inFlight.addAll(ids);
    for (var i = 0; i < ids.length; i += batchSize) {
      final chunk = ids.sublist(i, i + batchSize > ids.length ? ids.length : i + batchSize);
      Map<String, Person> found;
      try {
        found = await _fetch(chunk);
      } on Object {
        found = const {};
      }
      _known.addAll(found);
      final until = _clock().add(negativeFor);
      for (final id in chunk) {
        if (!found.containsKey(id)) _unknownUntil[id] = until;
      }
      _inFlight.removeAll(chunk);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// The first eight characters of an id, the way tables show one when no name is known.
/// The last eight characters: the tail of a UUID is as random as its head, and ids made by hand (the rig's
/// `00000000-0000-4000-8000-0000000000c1`) differ only at the end.
String shortId(String id) => id.length > 8 ? id.substring(id.length - 8) : id;
