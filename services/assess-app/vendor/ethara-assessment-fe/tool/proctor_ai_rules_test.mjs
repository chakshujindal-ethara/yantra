// The AI proctoring rule engine (web/proctor_ai.js) under synthetic detection
// streams. No DOM, no camera, no models: frames are made up here.
//
//   node tool/proctor_ai_rules_test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import * as engine from '../web/proctor_ai.js';
import {
  RULES,
  initialState,
  models,
  queue,
  release,
  setPolicy,
  start,
  step,
  stop,
} from '../web/proctor_ai.js';

const FACE = { x: 0.35, y: 0.3, w: 0.3, h: 0.4, score: 0.9 }; // centred
const EDGE = { x: 0.8, y: 0.3, w: 0.2, h: 0.4, score: 0.9 }; // centre at x 0.9
const SECOND = { x: 0.05, y: 0.3, w: 0.2, h: 0.3, score: 0.7 };

/// Frames from 0 to `untilMs`, each one `state.next` ms after the last, as the
/// browser schedules them; `at(t)` gives faces, phone, persons and took.
/// Returns every trip as `{ t, rule, reason, score }`; each frame's
/// `[t, wait after it]` is pushed onto `waits`, each snapshot-only event as
/// `{ t, rule }` onto `shots`.
function play(untilMs, at, waits = [], shots = []) {
  let state = initialState(0);
  const trips = [];
  for (let t = 0; t <= untilMs; t += state.next) {
    const out = step(state, { t, ...at(t) });
    state = out.state;
    waits.push([t, state.next]);
    for (const trip of out.trips) trips.push({ t, ...trip });
    for (const shot of out.shots) shots.push({ t, ...shot });
  }
  return trips;
}

/// The ms after the grace of each shot of `rule`.
const shotTimes = (shots, rule) =>
  shots.filter((x) => x.rule === rule).map((x) => x.t - grace);

/// `at(t)` for a face in view and phone scores `scores`, one per frame from
/// `t0` (a base-rate frame), then none.
function phoneFrom(t0, scores, extra = {}) {
  let k = 0;
  return (t) => ({ faces: [FACE], phone: t >= t0 ? (scores[k++] ?? 0) : 0, ...extra });
}

const grace = RULES.graceMs;
const face = { faces: [FACE], phone: 0 };
const empty = { faces: [], phone: 0 };

test('a 4 s face gap does not fire', () => {
  const trips = play(grace + 20000, (t) =>
    t >= grace + 2000 && t < grace + 6000 ? empty : face,
  );
  assert.deepEqual(trips, []);
});

test('a 6 s face gap fires no_face once, 5 s into the gap', () => {
  const trips = play(grace + 20000, (t) =>
    t >= grace + 2000 && t < grace + 8000 ? empty : face,
  );
  assert.equal(trips.length, 1);
  assert.equal(trips[0].rule, 'no_face');
  assert.equal(trips[0].reason, 'AI: no face for 5s');
  assert.equal(trips[0].t, grace + 7000);
});

test('a phone fires within 1 s: one 0.4 frame, then 0.55 and 0.52 at burst rate', () => {
  const t0 = grace + 2000;
  const waits = [];
  const trips = play(grace + 10000, phoneFrom(t0, [0.4, 0.55, 0.52]), waits);
  assert.deepEqual(
    trips.map((x) => [x.t, x.reason, x.score]),
    [[t0 + 500, 'AI: phone detected', 0.52]],
  );
  assert.ok(trips[0].t - t0 <= 1000);
  // The 0.4 frame switched to the burst rate.
  assert.deepEqual(
    waits.filter(([t]) => t >= t0 && t <= t0 + 500).map(([, w]) => w),
    [250, 250, 250],
  );
});

test('a single frame at strongScore (0.75) or more fires at once', () => {
  const t0 = grace + 2000;
  for (const score of [0.75, 0.9]) {
    const trips = play(grace + 20000, phoneFrom(t0, [score]));
    assert.deepEqual(trips.map((x) => [x.t, x.rule, x.score]), [[t0, 'phone', score]], `${score}`);
  }
});

test('a single frame just under strongScore does not fire: a fluke needs a second frame', () => {
  assert.deepEqual(play(grace + 20000, phoneFrom(grace + 2000, [0.74])), []);
});

test('a strong frame inside the grace period does not fire', () => {
  assert.deepEqual(play(grace + 20000, phoneFrom(grace - 1000, [0.95])), []);
});

test('a phone held at 0.9 counts once, not once per strong frame', () => {
  const trips = play(grace + 25000, phoneFrom(grace + 2000, Array(200).fill(0.9)));
  assert.deepEqual(trips.map((x) => x.rule), ['phone']);
});

// A PHONE SHOWN AGAIN COUNTS AGAIN. The 30 s floor between counts is for the
// other rules; for a phone it hid a second phone shown 8 s after the first,
// or counted it 20 s late if still held (21 Oct 2026).
test('a phone shown, put away for 4 s and shown again counts twice, at once', () => {
  const t0 = grace + 2000;
  const trips = play(grace + 30000, (t) => ({
    faces: [FACE],
    phone: (t >= t0 && t < t0 + 3000) || (t >= t0 + 7000 && t < t0 + 10000) ? 0.9 : 0,
  }));
  assert.deepEqual(trips.map((x) => x.rule), ['phone', 'phone']);
  assert.equal(trips[0].t, t0);
  // The first frame after it comes back, at most one base-rate wait later.
  assert.ok(trips[1].t >= t0 + 7000 && trips[1].t <= t0 + 7000 + RULES.sampleMs, `${trips[1].t - t0}`);
});

test('a phone out of view for less than releaseMs is the same episode, counted once', () => {
  const t0 = grace + 2000;
  const trips = play(grace + 30000, (t) => ({
    faces: [FACE],
    phone: (t >= t0 && t < t0 + 3000) || (t >= t0 + 4500 && t < t0 + 8000) ? 0.9 : 0,
  }));
  assert.equal(RULES.releaseMs, 3000);
  assert.deepEqual(trips.map((x) => x.rule), ['phone']);
});

// ONE SHOWING, ONE COUNT, however the detector flickers. A held phone that
// clears the trip bar only now and then, but is still SEEN in between, keeps
// its episode open: ended on the trip alone, any 3 s without a trip re-counted.
test('a held phone that trips only now and then is still one count', () => {
  const t0 = grace + 2000;
  const trips = play(grace + 60000, (t) => ({
    faces: [FACE],
    // Trip-strength for 0.6 s in every 6 s, seen at 0.4 in between: gaps
    // without a trip far longer than `releaseMs`.
    phone: t >= t0 && t < t0 + 40000 ? ((t - t0) % 6000 < 600 ? 0.55 : 0.4) : 0,
  }));
  assert.deepEqual(trips.map((x) => x.rule), ['phone']);
});

test('two 0.45 frames do not fire: below the 0.5 trip score', () => {
  assert.deepEqual(play(grace + 20000, phoneFrom(grace + 2000, [0.45, 0.45])), []);
});

test('a steady 0.4 or 0.49 (a wallet, a remote) never fires', () => {
  for (const phone of [0.4, 0.49]) {
    assert.deepEqual(play(grace + 60000, () => ({ faces: [FACE], phone })), []);
  }
});

test('the burst ends burstForMs after the last sighting and sampling returns to base', () => {
  const t0 = grace + 2000;
  const waits = [];
  play(grace + 10000, phoneFrom(t0, [0.4]), waits);
  const at = (from, to) => [...new Set(waits.filter(([t]) => t >= from && t < to).map(([, w]) => w))];
  assert.deepEqual(at(0, t0), [RULES.sampleMs]);
  assert.deepEqual(at(t0, t0 + RULES.burstForMs), [RULES.burstMs]);
  assert.deepEqual(at(t0 + RULES.burstForMs, Infinity), [RULES.sampleMs]);
  assert.equal(RULES.burstMs, 250);
  assert.equal(RULES.sampleMs, 500);
});

test('a steady 0.4 object bursts for 6 s, then base for the rest of the 30 s window, then may burst again', () => {
  const t0 = grace + 2000;
  const waits = [];
  const trips = play(
    t0 + 40000,
    (t) => ({ faces: [FACE], phone: t >= t0 ? 0.4 : 0 }),
    waits,
  );
  assert.deepEqual(trips, []);
  const at = (from, to) => [...new Set(waits.filter(([t]) => t >= from && t < to).map(([, w]) => w))];
  assert.equal(RULES.burstCapMs, 6000);
  assert.equal(RULES.burstWindowMs, 30000);
  assert.deepEqual(at(t0, t0 + 6000), [RULES.burstMs]);
  assert.deepEqual(at(t0 + 6000, t0 + 30000), [RULES.sampleMs]);
  assert.ok(at(t0 + 30000, Infinity).includes(RULES.burstMs));
  // Never more than the cap in any 30 s window.
  const bursts = waits.filter(([, w]) => w === RULES.burstMs).map(([t]) => t);
  for (const b of bursts) {
    const inWindow = bursts.filter((x) => x >= b && x < b + RULES.burstWindowMs).length;
    assert.ok(inWindow * RULES.burstMs <= RULES.burstCapMs);
  }
});

test('a 0.55 phone after the burst cap is spent still fires at base rate within 2 frames', () => {
  const t0 = grace + 2000;
  const waits = [];
  const trips = play(
    t0 + 12000,
    (t) => ({ faces: [FACE], phone: t < t0 + 7000 ? (t >= t0 ? 0.4 : 0) : 0.55 }),
    waits,
  );
  assert.deepEqual(
    trips.map((x) => [x.t, x.reason]),
    [[t0 + 7500, 'AI: phone detected']],
  );
  assert.deepEqual(
    waits.filter(([t]) => t >= t0 + 7000 && t <= t0 + 7500).map(([, w]) => w),
    [RULES.sampleMs, RULES.sampleMs],
  );
});

test('a slow device never bursts, and still fires on a clear phone', () => {
  const waits = [];
  const trips = play(grace + 20000, () => ({ faces: [FACE], phone: 0.9, took: 200 }), waits);
  assert.deepEqual([...new Set(waits.map(([, w]) => w))], [RULES.slowSampleMs]);
  // A 0.9 phone is over `strongScore`: the first 1 fps frame after the grace.
  assert.deepEqual(trips.map((x) => [x.t, x.rule]), [[grace, 'phone']]);
});

test('a slow device checks a phone at the trip score again after burstMs, not 1 s, and counts it', () => {
  const waits = [];
  const phone = RULES.phone.minScore;
  const trips = play(grace + 20000, () => ({ faces: [FACE], phone, took: 200 }), waits);
  assert.deepEqual(trips.map((x) => [x.t, x.rule]), [[grace + RULES.burstMs, 'phone']]);
  // One quick wait for the second frame; once counted, back to 1 fps.
  assert.deepEqual(
    waits.filter(([t]) => t >= grace).slice(0, 4).map(([, w]) => w),
    [RULES.burstMs, RULES.slowSampleMs, RULES.slowSampleMs, RULES.slowSampleMs],
  );
});

test('a slow device does not hurry on a sighting under the trip score', () => {
  const waits = [];
  play(grace + 20000, () => ({ faces: [FACE], phone: 0.45, took: 200 }), waits);
  assert.deepEqual([...new Set(waits.map(([, w]) => w))], [RULES.slowSampleMs]);
});

/// Waits after a hit every 4th frame (never 2 of 4, so never counted) for
/// 120 s, each frame taking `took` ms; returns the trips and the most
/// `burstMs` waits in any `burstWindowMs`.
function everyFourthHit(took) {
  let k = 0;
  const waits = [];
  const trips = play(grace + 120000, (t) => ({
    faces: [FACE],
    phone: t >= grace && k++ % 4 === 0 ? 0.6 : 0,
    took,
  }), waits);
  const quick = waits.filter(([, w]) => w === RULES.burstMs).map(([t]) => t);
  const most = Math.max(...quick.map((b) => quick.filter((x) => x >= b && x < b + RULES.burstWindowMs).length));
  return { trips, most };
}

test("a slow device's quick checks stay within the burst cap", async () => {
  await withRules({ burstCapMs: 4 * RULES.burstMs }, async () => {
    const { trips, most } = everyFourthHit(200);
    assert.deepEqual(trips, []);
    assert.equal(most, 4);
  });
});

test('a fast device spends exactly the burst cap: a hit frame is not counted twice', () => {
  const { trips, most } = everyFourthHit(0);
  assert.deepEqual(trips, []);
  assert.equal(most, RULES.burstCapMs / RULES.burstMs);
});

test('a burst whose frames turn slow falls back to the slow rate and ends', () => {
  const t0 = grace + 2000;
  const took = [50, 200, 200, 50];
  let k = 0;
  const waits = [];
  play(
    grace + 10000,
    (t) => {
      const i = t >= t0 ? k++ : -1;
      return { faces: [FACE], phone: i >= 0 && i < 3 ? 0.4 : 0, took: took[i] ?? 0 };
    },
    waits,
  );
  const i0 = waits.findIndex(([t]) => t === t0);
  // Burst, slow, slow, then base: the burst is not resumed by a fast frame.
  assert.deepEqual(
    waits.slice(i0, i0 + 4).map(([, w]) => w),
    [RULES.burstMs, RULES.slowSampleMs, RULES.slowSampleMs, RULES.sampleMs],
  );
});

// --- Episodes: a held condition counts once, and is photographed while held --

test('no face for 4 min counts once, at +5 s, with a photo every 30 s after', () => {
  const shots = [];
  const trips = play(grace + 240000, () => empty, [], shots);
  assert.deepEqual(
    trips.map((x) => [x.t - grace, x.rule]),
    [[5000, 'no_face']],
  );
  assert.deepEqual(shotTimes(shots, 'no_face'), [35000, 65000, 95000, 125000, 155000, 185000, 215000]);
  assert.equal(RULES.heldShotMs, 30000);
  assert.equal(RULES.repeatMs, undefined, 'no repeat count');
});

test('a second person who stays in view counts once, then a photo every 30 s, not every 3 min', () => {
  const shots = [];
  const trips = play(
    grace + 100000,
    (t) => ({ faces: t >= grace ? [FACE, SECOND] : [FACE], phone: 0 }),
    [],
    shots,
  );
  assert.deepEqual(
    trips.map((x) => [x.t - grace, x.rule]),
    [[1500, 'multiple_faces']],
  );
  assert.deepEqual(shotTimes(shots, 'multiple_faces'), [31500, 61500, 91500]);
});

test('a phone held for 65 s on a slow device counts once, then a photo every 30 s', () => {
  const shots = [];
  const trips = play(grace + 65000, () => ({ faces: [FACE], phone: 0.9, took: 200 }), [], shots);
  assert.deepEqual(trips.map((x) => [x.t - grace, x.rule]), [[0, 'phone']]);
  assert.deepEqual(shotTimes(shots, 'phone'), [30000, 60000]);
});

test('a second face flickering 1.6 s on, 0.5 s off for 120 s trips once', () => {
  const trips = play(grace + 120000, (t) => ({
    faces: t >= grace && (t - grace) % 2100 < 1600 ? [FACE, SECOND] : [FACE],
    phone: 0,
  }));
  assert.deepEqual(trips.map((x) => x.rule), ['multiple_faces']);
  assert.equal(RULES.releaseMs, 3000);
});

test('gone, back for 4 s, then gone again: photographed at once, counted when the 30 s floor ends', () => {
  const shots = [];
  const trips = play(
    grace + 120000,
    (t) => (t >= grace + 10000 && t < grace + 14000 ? face : empty),
    [],
    shots,
  );
  // The second absence holds at +19 s; the floor holds its count back to +35 s.
  assert.deepEqual(
    trips.map((x) => [x.t - grace, x.rule]),
    [[5000, 'no_face'], [35000, 'no_face']],
  );
  assert.equal(RULES.cooldownMs, 30000);
  assert.deepEqual(shotTimes(shots, 'no_face'), [19000, 65000, 95000]);
});

// Detector flicker: a second face 2 s on, 3.5 s off is a new episode every
// 5.5 s. Each held-back one may not bring its own photo.
test('a flickering condition is photographed at most every 30 s', () => {
  const shots = [];
  play(
    grace + 300000,
    (t) => ({ faces: t >= grace && (t - grace) % 5500 < 2000 ? [FACE, SECOND] : [FACE], phone: 0 }),
    [],
    shots,
  );
  const times = shotTimes(shots, 'multiple_faces');
  assert.ok(times.length >= 2, `${times.length} photos`);
  for (let i = 1; i < times.length; i++) {
    assert.ok(times[i] - times[i - 1] >= RULES.heldShotMs, `${times[i - 1]} then ${times[i]}`);
  }
});

// By design: a held-back episode that ends inside the cooldown is a photo
// for a human, never a count.
test('an episode that ends inside the cooldown is photographed, not counted', () => {
  const shots = [];
  const trips = play(
    grace + 60000,
    (t) => (t < grace + 8000 || (t >= grace + 14000 && t < grace + 21000) ? empty : face),
    [],
    shots,
  );
  assert.deepEqual(trips.map((x) => [x.t - grace, x.rule]), [[5000, 'no_face']]);
  assert.deepEqual(shotTimes(shots, 'no_face'), [19000]);
});

test('a condition that ends sends no more photos', () => {
  const shots = [];
  play(grace + 120000, (t) => (t < grace + 8000 ? empty : face), [], shots);
  assert.deepEqual(shots, []);
});

test('nothing fires in the grace period, and windows start when it ends', () => {
  const trips = play(grace + 6000, () => empty);
  assert.deepEqual(
    trips.map((x) => [x.t, x.rule]),
    [[grace + 5000, 'no_face']],
  );
});

test('a second face held 1.5 s fires multiple_faces', () => {
  const trips = play(grace + 10000, (t) => ({
    faces: t >= grace ? [FACE, SECOND] : [FACE],
    phone: 0,
  }));
  assert.deepEqual(
    trips.map((x) => [x.t, x.reason]),
    [[grace + 1500, 'AI: more than one face']],
  );
});

test('a half-seen second person (one face, two person boxes) fires after 1.5 s, not 1 s', () => {
  const t0 = grace + 2000;
  const seen = (ms) => (t) => ({
    faces: [FACE],
    phone: 0,
    persons: t >= t0 && t <= t0 + ms ? 2 : 1,
  });
  assert.deepEqual(play(grace + 20000, seen(1000)), []);
  assert.deepEqual(
    play(grace + 20000, seen(1500)).map((x) => [x.t, x.rule, x.reason]),
    [[t0 + 1500, 'multiple_faces', 'AI: more than one face']],
  );
  // One person box alone (the candidate) is never a second person.
  assert.deepEqual(play(grace + 20000, () => ({ faces: [FACE], phone: 0, persons: 1 })), []);
});

test('a face centred outside the middle 70% for 3 s fires left_frame', () => {
  const brief = play(grace + 10000, (t) => ({
    faces: [t >= grace && t < grace + 2500 ? EDGE : FACE],
    phone: 0,
  }));
  assert.deepEqual(brief, [], 'a 2.5 s lean is not leaving');
  const trips = play(grace + 10000, (t) => ({
    faces: [t >= grace ? EDGE : FACE],
    phone: 0,
  }));
  assert.deepEqual(
    trips.map((x) => [x.t, x.reason]),
    [[grace + 3000, 'AI: left the frame']],
  );
  const LEFT = { x: 0, y: 0.3, w: 0.2, h: 0.4, score: 0.9 }; // centre at x 0.1
  assert.deepEqual(
    play(grace + 10000, () => ({ faces: [LEFT], phone: 0 })).map((x) => x.rule),
    ['left_frame'],
    'the left edge too',
  );
});

// Stage, attempt 2676: a laptop camera looks up at the candidate, so a face
// centred across sits LOW in the frame. Only across is judged.
test('a face centred across but low or high in the frame is not leaving', () => {
  for (const y of [0.78, 0.0]) {
    const low = { x: 0.35, y, w: 0.3, h: 0.2, score: 0.9 }; // centre y 0.88 / 0.1
    assert.deepEqual(play(grace + 20000, () => ({ faces: [low], phone: 0 })), [], `y ${y}`);
  }
});

// Stage, attempt 2676: two people, one at the edge, read as "Left the frame".
// Two or more is multiple_faces' job, however the second one is seen.
test('a second person at the edge is more than one face, never left_frame', () => {
  const twoFaces = play(grace + 20000, () => ({ faces: [EDGE, FACE], phone: 0 }));
  assert.deepEqual([...new Set(twoFaces.map((x) => x.rule))], ['multiple_faces']);
  const faceAndBody = play(grace + 20000, () => ({ faces: [EDGE], phone: 0, persons: 2 }));
  assert.deepEqual([...new Set(faceAndBody.map((x) => x.rule))], ['multiple_faces']);
});

test('step does not modify the state it is given', () => {
  const s0 = initialState(0);
  const frozen = JSON.stringify(s0);
  step(s0, { t: grace + 500, faces: [], phone: 0.9 });
  assert.equal(JSON.stringify(s0), frozen);
});

test('a new policy drops the queued snapshots of every other attempt', () => {
  const mine = 'etp/proctoring/db/7/';
  const other = 'etp/proctoring/db/8/';
  const name = (prefix) => `${prefix}${Date.now()}_phone.jpg`;
  queue.clear();
  queue.set(name(mine), new Blob(['x']));
  queue.set(name(other), new Blob(['x']));
  // No policy says nothing about which attempt is live: both rows stay.
  setPolicy(null);
  assert.equal(queue.size, 2);
  // Expired on purpose, so nothing is sent: only the queue is judged.
  setPolicy({ url: 'https://s3.test/', prefix: mine, expires_at: '2000-01-01T00:00:00Z' });
  assert.deepEqual([...queue.keys()].map((k) => k.slice(0, mine.length)), [mine]);
  queue.clear();
});

// A bucket with no CORS rule for POST stores the snapshot but withholds S3's
// reply: `fetch` rejects with a bare TypeError. Our server is asked instead
// (`policy.landed`, `/evidence/landed`), so a stored snapshot is not sent
// again every 60 s; one it cannot find is kept and retried.
async function unreadableUpload(found) {
  const prefix = 'etp/proctoring/db/9/';
  const key = `${prefix}${Date.now()}_phone.jpg`;
  const fetch0 = globalThis.fetch;
  const posts = [];
  const asked = [];
  globalThis.fetch = async (url) => {
    posts.push(url);
    throw new TypeError('Failed to fetch');
  };
  try {
    queue.clear();
    queue.set(key, new Blob(['x']));
    setPolicy({
      url: 'https://s3.test/',
      prefix,
      fields: {},
      expires_at: new Date(Date.now() + 3600e3).toISOString(),
      landed: async (k) => {
        asked.push(k);
        return found;
      },
    });
    await new Promise((r) => setTimeout(r, 50));
    return { key, posts, asked, kept: queue.has(key) };
  } finally {
    setPolicy(null); // cancels the pending retry, so node can exit
    queue.clear();
    globalThis.fetch = fetch0;
  }
}

test('an unreadable upload our server finds is not sent again', async () => {
  const out = await unreadableUpload(true);
  assert.equal(out.posts.length, 1);
  assert.deepEqual(out.asked, [out.key]);
  assert.equal(out.kept, false);
});

test('an unreadable upload our server cannot find is kept for a retry', async () => {
  const out = await unreadableUpload(false);
  assert.equal(out.posts.length, 1);
  assert.deepEqual(out.asked, [out.key]);
  assert.equal(out.kept, true);
});

// --- No eye movement --------------------------------------------------------

test('no eye-movement code is left in the engine', () => {
  const src = readFileSync(new URL('../web/proctor_ai.js', import.meta.url), 'utf8');
  assert.doesNotMatch(src, /gaze|landmark|iris/i);
  assert.equal(RULES.gaze_away, undefined);
  assert.equal(engine.gazeOf, undefined);
  assert.deepEqual(Object.keys(models), ['detectors', 'lite0Gpu']);
});

test('on the GPU the object model is EfficientDet-Lite2; every model is a pinned asset', () => {
  assert.equal(engine.objectModel('GPU'), 'efficientdet_lite2.tflite');
  assert.equal(engine.objectModel('CPU'), 'efficientdet_lite0.tflite', 'Lite2 is too slow on the CPU');
  const notice = readFileSync(new URL('../web/mediapipe/NOTICE.md', import.meta.url), 'utf8');
  const pinned = [...notice.matchAll(/^\| `([^`]+)` \|/gm)].map((m) => m[1]);
  const src = readFileSync(new URL('../web/proctor_ai.js', import.meta.url), 'utf8');
  const named = new Set(src.match(/[\w-]+\.tflite/g));
  assert.ok(named.has('efficientdet_lite0.tflite'), 'the CPU fallback keeps Lite0');
  for (const f of [...named, RULES.gpu.model]) {
    assert.ok(pinned.includes(f), `${f} is not in NOTICE.md, so fetch_mediapipe.sh never fetches it`);
  }
});

// --- The browser driver, on a fake page --------------------------------------

const POLICY = {
  url: 'https://s3.test/',
  prefix: 'etp/proctoring/db/7/',
  fields: {},
  max_bytes: 400000,
  expires_at: new Date(Date.now() + 3600e3).toISOString(),
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
/// The label of each uploaded key, `<prefix><epoch_ms>_<label>.jpg`.
const labels = (keys) => keys.map((k) => /_([a-z_]+)\.jpg$/.exec(k)[1]);
/// Face and phone detectors that never see anything.
const blind = async () => ({
  face: { detect: () => ({ detections: [] }), close() {} },
  obj: { detect: () => ({ detections: [] }), close() {} },
});

/// Just enough DOM for start() to run in node: every element is a canvas
/// that draws nothing and encodes to a 1-byte JPEG, the video has a live
/// frame, and fetch records each uploaded key in `posted`. `restore()` stops
/// the run and puts node back.
function fakeBrowser() {
  const el = () => ({
    style: {},
    classList: { add() {}, remove() {} },
    remove() {},
    getContext: () => ({ drawImage() {}, clearRect() {}, strokeRect() {} }),
    toBlob: (done) => done(new Blob(['x'])),
  });
  const posted = [];
  const fetch0 = globalThis.fetch;
  const saved = { ...models };
  globalThis.document = { getElementById: () => null, createElement: el, head: { appendChild() {} } };
  globalThis.window = { devicePixelRatio: 1 };
  globalThis.fetch = async (url, init) => {
    posted.push(init.body.get('key'));
    return new Response(null, { status: 204 });
  };
  const video = {
    parentElement: { appendChild() {} },
    readyState: 4,
    videoWidth: 640,
    videoHeight: 480,
    clientWidth: 320,
    clientHeight: 240,
  };
  return {
    video,
    posted,
    restore() {
      stop(); // its timers would keep node alive
      setPolicy(null);
      queue.clear();
      for (const k of Object.keys(models)) delete models[k];
      Object.assign(models, saved);
      globalThis.fetch = fetch0;
      delete globalThis.document;
      delete globalThis.window;
    },
  };
}

/// Run `fn` with some RULES knobs changed, then put them back.
async function withRules(over, fn) {
  const saved = {};
  for (const k of Object.keys(over)) saved[k] = RULES[k];
  Object.assign(RULES, over);
  try {
    return await fn();
  } finally {
    Object.assign(RULES, saved);
  }
}

test('a paper that still asks for eye movement loads only the detectors and reports running', async () => {
  const b = fakeBrowser();
  const calls = [];
  try {
    models.detectors = async () => (calls.push('detectors'), { face: {}, obj: {} });
    models.gaze = async () => (calls.push('gaze'), {});
    const seen = [];
    await start(b.video, null, (e) => seen.push(e), { gaze: true });
    stop();
    assert.deepEqual(calls, ['detectors']);
    assert.deepEqual(seen, [{ rule: 'status', reason: '', status: 'running' }]);
  } finally {
    b.restore();
  }
});

// Stage, attempt 2676: the first snapshot came 2 min in, at the first trip.
test('the start photo is taken before the models load, once per start()', async () => {
  const b = fakeBrowser();
  try {
    models.detectors = () => new Promise(() => {}); // still loading
    void start(b.video, POLICY, () => {});
    await sleep(30);
    assert.deepEqual(labels(b.posted), ['start']);
    void start(b.video, POLICY, () => {}); // a remounted preview: the same run
    await sleep(30);
    assert.deepEqual(labels(b.posted), ['start']);
  } finally {
    b.restore();
  }
});

test('the start photo waits for a live frame', async () => {
  const b = fakeBrowser();
  try {
    models.detectors = blind;
    b.video.readyState = 0;
    await withRules({ startPollMs: 5 }, async () => {
      void start(b.video, POLICY, () => {});
      await sleep(30);
      assert.deepEqual(b.posted, [], 'no frame yet');
      b.video.readyState = 4;
      await sleep(30);
      assert.deepEqual(labels(b.posted), ['start']);
    });
  } finally {
    b.restore();
  }
});

// Without a policy there is nowhere to keep it: nothing polls, and the
// policy, when it comes, takes the photo.
test('the start photo waits for a policy without polling', async () => {
  const b = fakeBrowser();
  const timeouts = [];
  const setTimeout0 = globalThis.setTimeout;
  try {
    models.detectors = () => new Promise(() => {}); // no detection timers
    await withRules({ startPollMs: 5 }, async () => {
      globalThis.setTimeout = (fn, ms) => (timeouts.push(ms), setTimeout0(fn, ms));
      void start(b.video, null, () => {});
      globalThis.setTimeout = setTimeout0;
      await sleep(30);
      assert.deepEqual(b.posted, []);
      assert.deepEqual(timeouts, [], 'no start-photo poll without a policy');
      setPolicy(POLICY);
      await sleep(30);
      assert.deepEqual(labels(b.posted), ['start']);
    });
  } finally {
    globalThis.setTimeout = setTimeout0;
    b.restore();
  }
});

test('a routine photo every periodicShotMs from start() until stop()', async () => {
  assert.equal(RULES.periodicShotMs, 120000);
  const b = fakeBrowser();
  try {
    models.detectors = blind;
    await withRules({ periodicShotMs: 20 }, async () => {
      await start(b.video, POLICY, () => {});
      await sleep(110);
      stop();
      await sleep(5);
      const n = labels(b.posted).filter((x) => x === 'periodic').length;
      assert.ok(n >= 2, `${n} routine photos in 110 ms`);
      await sleep(60);
      assert.equal(labels(b.posted).filter((x) => x === 'periodic').length, n, 'none after stop()');
    });
  } finally {
    b.restore();
  }
});

// A device that cannot run the models still sits a watched exam: the photos
// need no model, and they are then the only evidence.
test('models that fail to load report failed, and the routine photos go on', async () => {
  const b = fakeBrowser();
  try {
    models.detectors = async () => {
      throw new Error('no WebAssembly');
    };
    const events = [];
    await withRules({ periodicShotMs: 20 }, async () => {
      await start(b.video, POLICY, (e) => events.push(e));
      await sleep(70);
      stop();
    });
    assert.deepEqual(events, [{ rule: 'status', reason: '', status: 'failed' }]);
    const got = labels(b.posted);
    assert.equal(got[0], 'start');
    assert.ok(got.includes('periodic'), got.join());
  } finally {
    b.restore();
  }
});

test('a held condition is reported once; its later photos are only uploaded', async () => {
  const b = fakeBrowser();
  try {
    models.detectors = blind;
    const events = [];
    await withRules(
      { graceMs: 0, sampleMs: 5, heldShotMs: 15, no_face: { ...RULES.no_face, holdMs: 0 } },
      async () => {
        await start(b.video, POLICY, (e) => events.push(e));
        await sleep(100);
        stop();
        await sleep(5);
      },
    );
    assert.deepEqual(events.map((e) => e.rule), ['status', 'no_face']);
    assert.ok(b.posted.includes(events[1].key), 'the trip uploads its own photo');
    const photos = labels(b.posted).filter((x) => x === 'no_face').length;
    assert.ok(photos >= 2, `${photos} no_face photos: the trip and the held ones`);
  } finally {
    b.restore();
  }
});

/// Detectors loaded on `delegate` that see one centred face, and a phone and
/// two people all at `score` (a closer look sees the same).
const seeing = (delegate, score) => async () => ({
  delegate,
  model: engine.objectModel(delegate),
  face: {
    detect: (c) => ({
      detections: [
        {
          boundingBox: {
            originX: 0.35 * c.width,
            originY: 0.3 * c.height,
            width: 0.3 * c.width,
            height: 0.4 * c.height,
          },
          categories: [{ score: 0.9 }],
        },
      ],
    }),
    close() {},
  },
  obj: {
    detect: (c) => ({
      detections: ['cell phone', 'person', 'person'].map((categoryName) => ({
        boundingBox: { originX: 0.6 * c.width, originY: 0.5 * c.height, width: 20, height: 30 },
        categories: [{ categoryName, score }],
      })),
    }),
    close() {},
  },
});

// Lite2 (GPU) scores look-alikes and people higher than Lite0 (CPU), so it
// has its own bars (RULES.gpu): a phone from 0.5, a second person from 0.6.
test('on the GPU (Lite2) a phone counts from 0.5 and a person from 0.6; on the CPU (Lite0) both from 0.5', async () => {
  const fast = { graceMs: 0, sampleMs: 5, burstMs: 5, multiple_faces: { ...RULES.multiple_faces, holdMs: 0 } };
  const trips = async (delegate, score) => {
    const b = fakeBrowser();
    try {
      models.detectors = seeing(delegate, score);
      const events = [];
      await withRules(fast, async () => {
        await start(b.video, null, (e) => events.push(e));
        await sleep(60);
        stop();
      });
      return events.filter((e) => e.rule !== 'status').map((e) => e.rule).sort();
    } finally {
      b.restore();
    }
  };
  assert.deepEqual(await trips('GPU', 0.45), [], 'a 0.45 look-alike, seen as 0.45 closer too');
  assert.deepEqual(await trips('GPU', 0.5), ['phone'], 'a 0.5 phone counts; two 0.5 person boxes do not');
  assert.deepEqual(await trips('GPU', 0.6), ['multiple_faces', 'phone'], 'exactly the person bar counts');
  assert.deepEqual(await trips('CPU', 0.45), [], 'under Lite0 bar');
  assert.deepEqual(await trips('CPU', 0.5), ['multiple_faces', 'phone'], 'Lite0 counts both from 0.5');
});

// --- A closer look at a possible phone (RULES.zoom) --------------------------

test('a closer look takes a square k times the box, at least minSide of the frame, inside it', () => {
  assert.deepEqual(RULES.zoom, { k: 2.5, minSide: 0.4 });
  // A 40x100 phone mid-frame: a 250 square around it.
  assert.deepEqual(engine.zoomRect({ x: 290, y: 190, w: 40, h: 100 }, 640, 480), [185, 115, 250]);
  // A small one: never under 0.4 of the height (192).
  assert.deepEqual(engine.zoomRect({ x: 310, y: 230, w: 20, h: 20 }, 640, 480), [224, 144, 192]);
  // Half out at the bottom-right corner: moved inside the frame.
  assert.deepEqual(engine.zoomRect({ x: 600, y: 440, w: 40, h: 40 }, 640, 480), [448, 288, 192]);
  // A huge one: never past the frame's short side.
  assert.deepEqual(engine.zoomRect({ x: 0, y: 0, w: 300, h: 400 }, 640, 480), [0, 0, 480]);
  // A phone on its side: its long side is its width.
  assert.deepEqual(engine.zoomRect({ x: 270, y: 220, w: 100, h: 40 }, 640, 480), [195, 115, 250]);
  // A portrait camera: the short side is its width.
  assert.deepEqual(engine.zoomRect({ x: 200, y: 300, w: 40, h: 40 }, 480, 640), [124, 224, 192]);
});

/// A run on the GPU (448-wide frames) whose object detector sees a phone at
/// `full` on the frame and at `closer` on a closer look (a square canvas; a
/// function is called instead, and may throw). `fullMs` and `closerMs` are
/// how long each detect takes, `rules` more RULES knobs, `decoy` a weaker
/// phone listed first, elsewhere, `runMs` how long it runs. Returns the
/// trips, the statuses, each closer look drawn from the video as
/// `[x, y, w, h, 0, 0, outW, outH]`, the frames run, the object model at the
/// end and how many times Lite0 was loaded.
async function closerLook(
  full,
  closer,
  { fullMs = 0, closerMs = 0, rules = {}, decoy = false, runMs = 40 } = {},
) {
  const b = fakeBrowser();
  const warn = console.warn;
  console.warn = () => {};
  try {
    const looks = [];
    const make = document.createElement;
    document.createElement = () => {
      const c = make();
      c.getContext = () => ({
        // A closer look is drawn from the video itself, not the small frame.
        drawImage: (...a) => a.length === 9 && a[0] === b.video && looks.push(a.slice(1)),
        clearRect() {},
        strokeRect() {},
      });
      return c;
    };
    const spin = (ms) => {
      const end = performance.now() + ms;
      while (performance.now() < end);
    };
    const phoneAt = (originX, originY, width, height, score) => ({
      boundingBox: { originX, originY, width, height },
      categories: [{ categoryName: 'cell phone', score }],
    });
    const det = await seeing('GPU', 0)();
    let frames = 0;
    // 196,140 28x42 on the 448x336 frame is 280,200 40x60 on the 640x480 video.
    det.obj.detect = (c) => {
      const square = c.width === c.height;
      if (!square) frames++;
      spin(square ? closerMs : fullMs);
      if (square && typeof closer === 'function') return closer();
      return {
        detections: [
          ...(decoy ? [phoneAt(10, 10, 20, 20, full - 0.01)] : []),
          phoneAt(196, 140, 28, 42, square ? closer : full),
        ],
      };
    };
    let loads = 0;
    models.detectors = async () => det;
    models.lite0Gpu = async () => (loads++, det.obj);
    const events = [];
    await withRules({ graceMs: 0, sampleMs: 5, burstMs: 5, ...rules }, async () => {
      await start(b.video, null, (e) => events.push(e));
      await sleep(runMs);
      stop();
    });
    const trips = events.filter((e) => e.rule !== 'status').map((e) => e.rule);
    const statuses = events.filter((e) => e.rule === 'status').map((e) => e.status);
    return { trips, statuses, looks, frames, model: det.model, loads };
  } finally {
    console.warn = warn;
    b.restore();
  }
}

test('a possible phone under the bar gets a closer look at the video, and counts if that sees one', async () => {
  const { trips, looks } = await closerLook(0.4, 0.8);
  assert.deepEqual(trips, ['phone']);
  assert.ok(looks.length > 0);
  // The video around the box (centre 300,230), 192 square, not the 448
  // frame, drawn at Lite2's own 448.
  assert.deepEqual(looks[0], [204, 134, 192, 192, 0, 0, 448, 448]);
  // From the bottom of the band.
  assert.deepEqual((await closerLook(RULES.phone.seeScore, 0.8)).trips, ['phone']);
});

test('the closer look is taken around the best possible phone', async () => {
  const { looks } = await closerLook(0.4, 0, { decoy: true });
  assert.ok(looks.length > 0);
  assert.deepEqual([...new Set(looks.map((l) => String(l.slice(0, 4))))], ['204,134,192,192']);
});

test('a closer look that sees no more keeps the frame score, so the burst goes on', async () => {
  const { trips, looks, frames } = await closerLook(0.4, 0, {
    rules: { sampleMs: 30, burstMs: 1 },
    runMs: 150,
  });
  assert.deepEqual(trips, []);
  assert.ok(looks.length > 0);
  // At 30 ms a frame 150 ms holds about 5; the burst (1 ms) many more.
  assert.ok(frames > 12, `${frames} frames`);
});

test('a person or anything else in the closer look is not a phone', async () => {
  const other = (categoryName) => ({
    boundingBox: { originX: 0, originY: 0, width: 50, height: 50 },
    categories: [{ categoryName, score: 0.9 }],
  });
  const out = await closerLook(0.4, () => ({ detections: [other('person'), other('remote')] }));
  assert.ok(out.looks.length > 0);
  assert.deepEqual(out.trips, []);
});

test('a frame its closer look makes slower than slowFrameMs drops to the slow rate', async () => {
  const { looks, frames } = await closerLook(0.4, 0, {
    closerMs: 12,
    rules: { slowFrameMs: 8, slowSampleMs: 100 },
    runMs: 150,
  });
  assert.ok(looks.length > 0);
  assert.ok(frames <= 3, `${frames} frames`);
});

test('no closer look at a phone already over the bar, nor at nothing', async () => {
  for (const full of [RULES.gpu.phoneMinScore, 0.6, 0.34, 0]) {
    assert.deepEqual((await closerLook(full, 0.9)).looks, [], `${full}`);
  }
});

test('no closer look where the frame alone took over slowFrameMs', async () => {
  const out = await closerLook(0.4, 0.9, { fullMs: 8, rules: { slowFrameMs: 5 } });
  assert.deepEqual(out.looks, []);
  assert.deepEqual(out.trips, []);
});

test('a closer look that throws leaves the frame working', async () => {
  const out = await closerLook(
    0.4,
    () => {
      throw new Error('detector closed');
    },
    { rules: { failAfterFrames: 2 } },
  );
  assert.ok(out.looks.length > 1);
  assert.deepEqual(out.statuses, ['running']);
});

test('the Lite2 speed check times the frame, not its closer look', async () => {
  const gpu = { ...RULES.gpu, warmFrames: 1, probeFrames: 3, maxMs: 5 };
  const out = await closerLook(0.4, 0, { closerMs: 12, rules: { gpu }, runMs: 150 });
  assert.ok(out.looks.length >= 4);
  assert.equal(out.loads, 0);
  assert.equal(out.model, 'efficientdet_lite2.tflite');
});

// Lite2's own input is 448x448, so it is fed 448-wide frames; Lite0 (and a
// GPU that fell back to it) keeps 320. The frame keeps the camera's shape.
test('Lite2 on the GPU sees 448-wide frames, Lite0 on the CPU 320', async () => {
  const widths = async (delegate) => {
    const b = fakeBrowser();
    try {
      const seen = [];
      const det = await seeing(delegate, 0)();
      const detect = det.obj.detect;
      det.obj.detect = (c) => {
        seen.push([c.width, c.height]);
        return detect(c);
      };
      models.detectors = async () => det;
      await withRules({ sampleMs: 5 }, async () => {
        await start(b.video, null, () => {});
        await sleep(40);
        stop();
      });
      assert.ok(seen.length > 0, `${delegate} ran no frame`);
      return [...new Set(seen.map(([w, h]) => `${w}x${h}`))];
    } finally {
      b.restore();
    }
  };
  assert.deepEqual(await widths('GPU'), ['448x336']);
  assert.deepEqual(await widths('CPU'), ['320x240']);
});

/// Every onEvent call start() makes for each way the models can load, as
/// `[expected status, events]`.
async function statusEvents() {
  const b = fakeBrowser();
  const det = async () => ({ face: {}, obj: {} });
  const fail = async () => {
    throw new Error('404');
  };
  const out = [];
  try {
    for (const [detectors, want] of [
      [det, 'running'],
      [fail, 'failed'],
    ]) {
      models.detectors = detectors;
      const seen = [];
      await start(b.video, null, (e) => seen.push(e));
      stop();
      out.push([want, seen]);
    }
  } finally {
    b.restore();
  }
  return out;
}

// start() reports how the AI stands as `{ rule: 'status', reason: '', status }`
// through the same onEvent as a trip.
test('start() reports the AI status once the models load, or failed', async () => {
  for (const [want, seen] of await statusEvents()) {
    assert.deepEqual(seen, [{ rule: 'status', reason: '', status: want }], want);
  }
});

// DEPLOY-SKEW GUARD. proctor_ai.js is loaded lazily and served no-cache, so a
// candidate who opened the app before a frontend deploy runs the OLD Dart
// bundle against THIS file. The old bridge (`git show
// d5bbff7:lib/services/proctor_web.dart`, startAiBridge) knows no status
// event: it counts every non-empty `reason` that is not `gaze_away` as a
// violation, so a status in `reason` ended cap-0/1 auto-submit papers on
// question 1. The status must ride where that bridge looks away.
test('deploy-skew guard: the old Dart bridge counts no status event as a violation', async () => {
  // The old callback, line for line.
  const oldBridge = (e, onReason, onReviewFlag) => {
    const reason = e.reason;
    if (typeof reason !== 'string' || reason === '') return;
    if (e.rule === 'gaze_away') onReviewFlag(reason);
    else onReason(reason);
  };
  for (const [want, seen] of await statusEvents()) {
    const violations = [];
    const flags = [];
    for (const e of seen) oldBridge(e, (r) => violations.push(r), (r) => flags.push(r));
    assert.deepEqual(violations, [], `${want} would be a violation`);
    assert.deepEqual(flags, [], want);
  }
});

// The instructions page warms the models; leaving it without starting lets
// them go (about 35 MB), but release() must never take them from a run.
test('release() lets preloaded models go, and never during a run', async () => {
  assert.equal(release(), true, 'nothing running: released');
  const b = fakeBrowser();
  try {
    models.detectors = blind;
    await start(b.video, null, () => {});
    assert.equal(release(), false, 'a run holds them');
  } finally {
    b.restore();
  }
  assert.equal(release(), true, 'stopped: released');
});

// A browser without WebGL loads the models, then throws on every frame. Left
// at `running`, the admin reads the checks as on while none ran; enough frames
// in a row that fail say `failed` instead, and as many good ones take it back.
test('frames that keep failing report failed once, and good frames running again', async () => {
  const b = fakeBrowser();
  let broken = true;
  const detect = () => {
    if (broken) throw new Error('no WebGL');
    return { detections: [] };
  };
  const warn = console.warn;
  console.warn = () => {};
  try {
    models.detectors = async () => ({ face: { detect }, obj: { detect }, delegate: 'CPU' });
    const seen = [];
    await withRules({ sampleMs: 2, failAfterFrames: 3 }, async () => {
      await start(b.video, null, (e) => seen.push(e));
      await new Promise((ok) => setTimeout(ok, 80));
      broken = false;
      await new Promise((ok) => setTimeout(ok, 80));
    });
    assert.deepEqual(seen.map((e) => e.status), ['running', 'failed', 'running']);
    assert.ok(seen.every((e) => e.rule === 'status' && e.reason === ''), 'never a violation');
  } finally {
    console.warn = warn;
    b.restore();
  }
});

/// The statuses one run reports while `face.detect` throws on the calls
/// `bad(n)` names (n counts from 1), over about 40 frames.
async function statusesWhen(bad, rules = {}) {
  const b = fakeBrowser();
  let n = 0;
  const face = { detect: () => {
    if (bad(++n)) throw new Error('frame failed');
    return { detections: [] };
  } };
  const obj = { detect: () => ({ detections: [] }) };
  const warn = console.warn;
  console.warn = () => {};
  try {
    models.detectors = async () => ({ face, obj, delegate: 'CPU' });
    const seen = [];
    await withRules({ sampleMs: 2, ...rules }, async () => {
      await start(b.video, null, (e) => seen.push(e));
      await new Promise((ok) => setTimeout(ok, 120));
    });
    return seen.map((e) => e.status);
  } finally {
    console.warn = warn;
    b.restore();
  }
}

test('fewer failed frames in a row than failAfterFrames stay running', async () => {
  assert.deepEqual(await statusesWhen((n) => n < RULES.failAfterFrames), ['running']);
});

test('frames that keep failing after one worked still report failed', async () => {
  assert.deepEqual(await statusesWhen((n) => n > 1, { failAfterFrames: 3 }), ['running', 'failed']);
});

// Every status change is a request to our server: a flickering machine gets
// `maxRecoveries` returns to running, and then the next `failed` stays.
test('a flickering machine recovers at most maxRecoveries times', async () => {
  const flicker = (n) => n <= 24 && Math.floor((n - 1) / 3) % 2 === 0;
  assert.deepEqual(
    await statusesWhen(flicker, { failAfterFrames: 2, maxRecoveries: 1 }),
    ['running', 'failed', 'running', 'failed'],
  );
});

/// Lite2 on the GPU seeing a 0.55 phone and two 0.55 people (the people
/// count on Lite0's 0.5 bar, not Lite2's 0.6), each frame taking `ms` (or `ms(n)`
/// for frame n, from 1), past the first `warmFrames: 1`; `lite0Gpu`
/// is the fallback loader. Returns the trips and what happened to the models.
async function onASlowGpu(ms, lite0Gpu, delegate = 'GPU') {
  const b = fakeBrowser();
  let frame = 0;
  const spin = () => {
    const end = performance.now() + (typeof ms === 'function' ? ms(++frame) : ms);
    while (performance.now() < end);
  };
  const warn = console.warn;
  console.warn = () => {};
  const det = await seeing(delegate, 0.55)();
  const lite2 = det.obj;
  let lite2Closed = false;
  det.obj = {
    ...lite2,
    // A closed MediaPipe detector throws, so a run left on it sees nothing.
    detect: (c) => {
      if (lite2Closed) throw new Error('closed');
      spin();
      return lite2.detect(c);
    },
    close: () => (lite2Closed = true),
  };
  try {
    models.detectors = async () => det;
    models.lite0Gpu = lite0Gpu;
    const events = [];
    const gpu = { ...RULES.gpu, warmFrames: 1, probeFrames: 3, maxMs: 5 };
    const fast = { graceMs: 0, sampleMs: 5, burstMs: 5, multiple_faces: { ...RULES.multiple_faces, holdMs: 0 }, gpu };
    await withRules(fast, async () => {
      await start(b.video, null, (e) => events.push(e));
      await sleep(150);
      stop();
    });
    const trips = events.filter((e) => e.rule !== 'status').map((e) => e.rule).sort();
    return { trips, model: det.model, lite2Closed };
  } finally {
    console.warn = warn;
    b.restore();
  }
}

// A GPU too slow for Lite2 would sample at 1 fps all exam: it swaps in Lite0
// on the same GPU, with Lite0's bars, once, and lets Lite2 go.
test('a GPU too slow for Lite2 swaps to Lite0 and its bars, once', async () => {
  let loads = 0;
  const lite0 = (await seeing('GPU', 0.55)()).obj;
  const out = await onASlowGpu(12, async () => (loads++, await sleep(30), lite0));
  assert.equal(loads, 1);
  assert.equal(out.model, 'efficientdet_lite0.tflite');
  assert.ok(out.lite2Closed, 'Lite2 released');
  assert.deepEqual(out.trips, ['multiple_faces', 'phone'], 'counted on 0.5 once on Lite0');
});

test('a GPU fast enough for Lite2 keeps it', async () => {
  let loads = 0;
  const out = await onASlowGpu(0, async () => (loads++, {}));
  assert.equal(loads, 0);
  assert.equal(out.model, 'efficientdet_lite2.tflite');
  assert.deepEqual(out.trips, ['phone'], 'two 0.55 person boxes are still under Lite2 bar of 0.6');
});

test('a Lite0 that will not load keeps Lite2 running', async () => {
  const out = await onASlowGpu(12, async () => {
    throw new Error('404');
  });
  assert.equal(out.model, 'efficientdet_lite2.tflite');
  assert.equal(out.lite2Closed, false);
  assert.deepEqual(out.trips, ['phone'], 'on Lite2 bars');
});

test('slow first frames (the GPU warming up) do not count against Lite2', async () => {
  let loads = 0;
  const out = await onASlowGpu((n) => (n <= 2 ? 25 : 0), async () => (loads++, {}));
  assert.equal(loads, 0, 'the warm-up frame is not judged');
  assert.equal(out.model, 'efficientdet_lite2.tflite');
});

test('the median judges: two slow frames of three swap to Lite0', async () => {
  let loads = 0;
  const lite0 = (await seeing('GPU', 0.55)()).obj;
  // Frame 1 is the warm-up; frames 2-4 are judged: slow, slow, fast.
  const out = await onASlowGpu((n) => (n <= 3 ? 12 : 0), async () => (loads++, lite0));
  assert.equal(loads, 1);
  assert.equal(out.model, 'efficientdet_lite0.tflite');
});

test('the CPU path is never judged or swapped, however slow', async () => {
  let loads = 0;
  const out = await onASlowGpu(12, async () => (loads++, {}), 'CPU');
  assert.equal(loads, 0);
  assert.equal(out.model, 'efficientdet_lite0.tflite');
});
