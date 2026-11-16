import 'dart:async';

import 'package:uuid/uuid.dart';

import '../api/tracker_models.dart';
import '../api/tracker_repository.dart';
import 'drafts.dart';
import 'errors.dart';

/// The web tracking agent (docs/PRODUCT.md 5.7): while a claim is open on the work screen it records, every
/// 30 seconds, whether the worker was active (input in the last minute), idle, or away (the tab hidden),
/// and sends the samples to the tracker. Nothing else is recorded: no keystrokes, no content, no titles.
///
/// It never blocks the work: a failed start or flush is kept and retried on the next tick, and a tracker that
/// stays down only loses activity, never the unit. A worker who withdrew the data-processing consent is
/// refused (403 `consent_withdrawn`): the agent then stops for good, records nothing and says so once.
class ActivityAgent {
  ActivityAgent({
    required this.tracker,
    required this.claimId,
    required this.devices,
    DateTime Function()? now,
    String Function()? newKey,
    this.every = const Duration(seconds: 30),
    this.onWeek,
    this.onTrackingOff,
  }) : _now = now ?? DateTime.now,
       _newKey = newKey ?? const Uuid().v4;

  final TrackerRepository tracker;
  final String claimId;

  /// Where the device id lives ("kept in your browser"): one random id per browser profile.
  final DraftStore devices;
  final Duration every;

  /// Called with the week's totals after each flush the tracker accepted.
  final void Function(TrackerWeek week)? onWeek;

  /// Called once when the tracker refuses for withdrawn consent and the agent stops.
  final void Function()? onTrackingOff;

  final DateTime Function() _now;
  final String Function() _newKey;

  static const deviceKey = 'yantra.device';
  static const maxBatch = 500;
  static const activeWindow = Duration(seconds: 60);

  String? _session;
  final List<ActivitySample> _buffer = [];

  /// The batch on its way: sent with exactly this body and key until the tracker accepts it or refuses it
  /// for good, so a retry never reuses a key with a grown body.
  _Batch? _frozen;

  /// The session start in flight, shared by every caller; [end] waits for it.
  Future<bool>? _starting;

  /// The last session ended under us: samples from before the next session's start cannot be kept.
  bool _replacing = false;
  DateTime? _lastInput;
  bool _hidden = false;
  bool _ended = false;
  bool _busy = false;
  Timer? _timer;

  /// The tracker refused for withdrawn consent: nothing is recorded or sent any more.
  bool get trackingOff => _off;
  bool _off = false;

  /// The tracker's session id once started.
  String? get session => _session;

  /// Samples not yet accepted by the tracker.
  int get pending => _buffer.length + (_frozen?.samples.length ?? 0);

  /// Starts the session and the 30-second clock. The worker counts as active from the start. Ended
  /// before the start finished, no clock is left running.
  Future<void> start() async {
    _lastInput = _now();
    await _ensureSession();
    if (_ended) return;
    _timer ??= Timer.periodic(every, (_) => unawaited(tick()));
  }

  /// Pointer or keyboard input happened.
  void input() => _lastInput = _now();

  /// The tab became hidden or visible again.
  void visible(bool value) => _hidden = !value;

  /// One clock step: record a sample, then flush.
  Future<void> tick() async {
    if (_ended) return;
    final now = _now();
    final kind = _hidden ? 'focus_lost' : (_lastInput != null && now.difference(_lastInput!) <= activeWindow ? 'active' : 'idle');
    _buffer.add(ActivitySample(now, kind));
    if (_buffer.length > maxBatch * 4) _buffer.removeRange(0, _buffer.length - maxBatch * 4); // a long outage drops the oldest
    await flush();
  }

  /// Sends what is buffered, at most [maxBatch] per request, one frozen batch at a time. A failure that
  /// may succeed later keeps the batch, body and key unchanged, for the next tick.
  Future<void> flush() async {
    if (_busy || pending == 0) return;
    _busy = true;
    try {
      if (!await _ensureSession()) return;
      while (true) {
        final batch = _frozen ??= _freeze();
        if (batch == null) return;
        try {
          final week = await tracker.samples(batch.session, batch.samples, key: batch.key);
          _frozen = null;
          onWeek?.call(week);
        } on ApiException catch (e) {
          if (!_settle(batch, e)) return;
        }
      }
    } on Object {
      // offline or the tracker is down: the frozen batch and the buffer wait for the next tick
    } finally {
      _busy = false;
    }
  }

  /// The next batch off the buffer, under its first key; null when nothing waits.
  _Batch? _freeze() {
    final session = _session;
    if (session == null || _buffer.isEmpty) return null;
    final samples = _buffer.take(maxBatch).toList();
    _buffer.removeRange(0, samples.length);
    return _Batch(session, samples, TrackerRepository.sampleKey(session, samples));
  }

  /// Applies a refusal of [batch]; true when the flush may go on with the next request.
  bool _settle(_Batch batch, ApiException e) {
    if (_consentWithdrawn(e)) {
      _turnOff(); // the tracker ended the session itself
      return false;
    }
    if (e.status == 409 && e.code == 'session_ended') {
      // ended elsewhere (stale sweep): the samples go back in front and wait for the next session
      _buffer.insertAll(0, batch.samples);
      _frozen = null;
      _session = null;
      _replacing = true;
      return false;
    }
    if (e.status == 422 && e.code == 'idempotency_mismatch') {
      _frozen = batch.rekeyed(_newKey()); // never dropped: the same samples under a fresh key
      return true;
    }
    if (e.status == 422 && e.code == 'sample_out_of_range') {
      final index = e.context['index'];
      if (index is int && index >= 0 && index < batch.samples.length) {
        final rest = [...batch.samples]..removeAt(index); // that one sample cannot be kept (clock skew)
        _frozen = rest.isEmpty ? null : _Batch(batch.session, rest, '${batch.key}:${_newKey()}');
        return true;
      }
    }
    if (retryKeepsKey(e)) return false; // may land later: the same body and key on the next tick
    _frozen = null; // refused for good: those samples cannot be kept
    return true;
  }

  /// Flushes what is left and ends the session: on submit, release, leaving the screen or claim expiry.
  /// A start still in flight is awaited first, so its session is ended rather than left open.
  Future<void> end() async {
    if (_ended) return;
    _timer?.cancel();
    _timer = null;
    final starting = _starting;
    if (starting != null) await starting;
    await flush();
    _ended = true;
    _timer?.cancel();
    _timer = null;
    final id = _session;
    if (id == null) return;
    try {
      await tracker.end(id, key: 'track-end-$id');
    } on Object {
      // the stale-session sweep ends it within minutes
    }
  }

  /// Stops the clock without ending the session (the widget went away without a clean exit).
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _ended = true;
  }

  Future<bool> _ensureSession() {
    if (_session != null) return Future.value(true);
    return _starting ??= _startSession().whenComplete(() => _starting = null);
  }

  Future<bool> _startSession() async {
    try {
      final started = await tracker.start(claimId: claimId, device: await device(devices, _newKey), key: 'track-${_newKey()}');
      _session = started.id;
      final since = started.startedAt;
      if (_replacing && since != null) _buffer.removeWhere((s) => s.at.isBefore(since));
      _replacing = false;
      return true;
    } on ApiException catch (e) {
      if (_consentWithdrawn(e)) _turnOff();
      return false;
    } on Object {
      return false;
    }
  }

  static bool _consentWithdrawn(ApiException e) => e.status == 403 && e.code == 'consent_withdrawn';

  /// Stops for good: no clock, no buffer, no session to end (the tracker ends it on the withdrawal).
  void _turnOff() {
    if (_off) return;
    _off = true;
    _ended = true;
    _timer?.cancel();
    _timer = null;
    _buffer.clear();
    _frozen = null;
    _session = null;
    onTrackingOff?.call();
  }

  /// This browser's random device id, made once and kept.
  static Future<String> device(DraftStore store, String Function() newId) async {
    final kept = await store.read(deviceKey);
    final id = kept?['id'];
    if (id is String && RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(id)) return id;
    final made = newId();
    await store.write(deviceKey, {'id': made});
    return made;
  }
}

/// One flush's samples, frozen with the session and key they are sent under.
class _Batch {
  const _Batch(this.session, this.samples, this.key);
  final String session;
  final List<ActivitySample> samples;
  final String key;

  _Batch rekeyed(String fresh) => _Batch(session, samples, '${TrackerRepository.sampleKey(session, samples)}:$fresh');
}
