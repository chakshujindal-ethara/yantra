import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/people.dart';

/// Waits for the batch timer and the requests it starts. They run on real time, so poll for the outcome instead of
/// guessing a delay (a fixed 30 ms wait lost the second batch when the machine was busy). Gives up after 2 s and
/// lets the expectation that follows report what arrived.
Future<void> settled(bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('misses in the same frame go out as one request; answers are cached', () async {
    {
      final asked = <List<String>>[];
      final cache = PeopleCache((ids) async {
        asked.add(ids);
        return {'a': const Person(name: 'Asha', kind: 'worker')};
      });
      var notified = 0;
      cache.addListener(() => notified++);
      expect(cache.lookup('a'), isNull);
      expect(cache.lookup('b'), isNull);
      expect(cache.lookup('a'), isNull, reason: 'already queued: asked once');
      await settled(() => notified == 1);
      expect(asked, [
        ['a', 'b'],
      ]);
      expect(notified, 1);
      expect(cache.lookup('a')?.name, 'Asha');
      expect(cache.lookup('b'), isNull, reason: 'unknown ids are remembered as unknown');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(asked, hasLength(1), reason: 'a known unknown is not asked again');
    }
  });

  test('a failed request leaves the ids unknown until the negative window ends, then asks again', () async {
    {
      var now = DateTime(2026, 11, 4, 12);
      var calls = 0;
      final cache = PeopleCache((ids) async {
        calls++;
        throw StateError('down');
      }, clock: () => now);
      var notified = 0;
      cache.addListener(() => notified++);
      cache.lookup('x');
      await settled(() => notified == 1);
      expect(calls, 1);
      cache.lookup('x');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(calls, 1);
      now = now.add(const Duration(seconds: 61));
      cache.lookup('x');
      await settled(() => notified == 2);
      expect(calls, 2);
    }
  });

  test('a primed name needs no request; empty ids and names are ignored; batches are capped', () async {
    {
      final asked = <List<String>>[];
      final cache = PeopleCache((ids) async {
        asked.add(ids);
        return const {};
      }, batchSize: 2);
      cache.prime('p', 'Priya');
      cache.prime('', 'nobody');
      cache.prime('q', '');
      expect(cache.lookup('p')?.name, 'Priya');
      expect(cache.lookup(''), isNull);
      for (final id in ['1', '2', '3']) {
        cache.lookup(id);
      }
      await settled(() => asked.length == 2);
      expect(asked, [
        ['1', '2'],
        ['3'],
      ]);
    }
  });

  test('announceSelf runs once per subject and again after a failure', () async {
    var calls = 0;
    var fail = true;
    final cache = PeopleCache(
      (_) async => const {},
      announce: () async {
        calls++;
        if (fail) throw StateError('down');
      },
    );
    await cache.announceSelf('');
    expect(calls, 0);
    await cache.announceSelf('s1');
    expect(calls, 1);
    fail = false;
    await cache.announceSelf('s1');
    expect(calls, 2, reason: 'the failed announce is retried');
    await cache.announceSelf('s1');
    expect(calls, 2);
    await cache.announceSelf('s2');
    expect(calls, 3);
    await PeopleCache((_) async => const {}).announceSelf('s1');
  });

  test('shortId keeps the last eight characters, where hand-made ids differ', () {
    expect(shortId('0123456789abcdef'), '89abcdef');
    expect(shortId('00000000-0000-4000-8000-0000000000c1'), '000000c1');
    expect(shortId('abc'), 'abc');
  });
}
