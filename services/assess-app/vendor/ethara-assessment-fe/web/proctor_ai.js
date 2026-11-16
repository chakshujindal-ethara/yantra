// AI proctoring: face and phone detection over the webcam preview.
//
// Loaded on demand by `lib/services/proctor_web.dart`, and only when the
// assessment has `rules.ai_proctor` on and the camera stream is live. Nothing
// here, and nothing under `mediapipe/`, is fetched for any other candidate.
// Plain ES module, no build step.
//
//   window.__proctorAi = { start(videoEl, policy, onEvent), stop(),
//                          setPolicy(policy), preload(), release() }
//
// `onEvent({ rule, reason, score, key, queued })` fires once per trip, BEFORE
// the snapshot is uploaded: the violation is reported first, and `queued` only
// says a snapshot was taken for upload. The upload result goes to the console.
// It also fires once per start() with `{ rule: 'status', reason: '', status }`,
// how the AI stands (see `status`), which is never a violation; and again
// when frames keep failing (`failAfterFrames`) or recover (`maxRecoveries`).
//
// Snapshots that are not trips (`start`, `periodic`, and a held condition's
// later photos) are only uploaded: they never reach `onEvent`, so nothing
// counts them. An admin reads them in the evidence gallery.
//
// The rule engine (`RULES`, `initialState`, `step`) is pure and touches no DOM,
// so `tool/proctor_ai_rules_test.mjs` drives it under node with synthetic
// detection streams. Everything below the engine is browser-only.

// ---------------------------------------------------------------------------
// Rule engine
// ---------------------------------------------------------------------------

/// Every threshold in one place. The reasons go to `/violation` verbatim.
export const RULES = {
  sampleMs: 500, // about 2 fps
  // A burst: `burstMs` between frames (about 3 fps with the frame time) from
  // any phone score at `phone.seeScore` or more, until `burstForMs` after the
  // last one, so a phone coming into view is judged on more frames. Never
  // after a frame slower than `slowFrameMs`, where only a phone hit not yet
  // counted gets one `burstMs` wait for its second frame. Capped: at most `burstCapMs` of
  // burst in any `burstWindowMs`, then base rate until the window frees (a
  // steady 0.4 object would otherwise burst for as long as it sits there).
  burstMs: 250,
  burstForMs: 3000,
  burstCapMs: 6000,
  burstWindowMs: 30000,
  slowSampleMs: 1000, // 1 fps once a frame takes longer than `slowFrameMs`
  slowFrameMs: 150,
  sampleWidth: 320, // detection runs on a frame this wide
  graceMs: 10000, // nothing trips in the first 10 s after start
  cooldownMs: 30000, // per rule, the floor between two counted episodes (a rule's own `cooldownMs` wins)
  // Episodes (`no_face`, `multiple_faces`, `left_frame`, `phone`): a held
  // condition counts ONCE. It ends only once off for `releaseMs`, so detector
  // flicker stays one episode. One that starts inside the rule's cooldown is
  // counted when the cooldown ends, if it still holds.
  releaseMs: 3000,
  // While an episode holds, a snapshot only (never counted) at most this
  // often per rule, and this long after the episode's last photo (its trip's
  // included); so an episode the cooldown holds back gets one at once unless
  // the rule had one this recently. Doubtful or long signals become photos
  // for a human, not counts.
  heldShotMs: 30000,
  faceMinScore: 0.5,
  // A `person` box from the object detector counts from this score. It sees a
  // body or a half-turned head that the face detector, which needs a whole
  // face, misses. Lite0's bar; Lite2 on the GPU has its own (`gpu`).
  personMinScore: 0.5,
  no_face: { holdMs: 5000, reason: 'AI: no face for 5s' },
  // More than one face OR more than one person box, held this long.
  multiple_faces: { holdMs: 1500, reason: 'AI: more than one face' },
  // A phone scored at `minScore` or more in `hits` of the last `window` frames,
  // or at `strongScore` or more in one frame (a phone in plain view is counted
  // at once instead of waiting for a second frame over the bar). Not lower:
  // ~1.3% of no-phone frames reach 0.6 on Lite2, which as a one-frame trip
  // would flag an innocent candidate about once a minute at 2-4 fps.
  // The detector reports from `seeScore`, which only starts a burst.
  // `minScore` is Lite0's bar; Lite2 on the GPU has its own (`gpu`).
  phone: {
    seeScore: 0.35,
    minScore: 0.5,
    hits: 2,
    window: 4,
    strongScore: 0.75,
    // NO FLOOR: a phone put away and shown again is a new act and counts at
    // once. With the 30 s floor a second phone was hidden, or counted up to
    // 30 s late if still held (21 Oct 2026). What keeps one showing to one
    // count is the episode instead: it stays open while anything is seen at
    // `seeScore`, not only while the trip holds, and ends after `releaseMs`
    // with nothing seen. Ended on the trip alone, a held phone the detector
    // misses half the time re-counted on any 3 s gap (1.4 counts per 20 s
    // showing in a simulation, and 25 in 5 minutes for a look-alike on the
    // desk; 1.0 and 1.4 this way, against 9 with the old 30 s floor).
    cooldownMs: 0,
    reason: 'AI: phone detected',
  },
  // The GPU runs EfficientDet-Lite2 with these bars over `phone.minScore` and
  // `personMinScore`; the CPU fallback keeps Lite0 (185 ms a frame for Lite2
  // on an M1 Pro CPU: a 3-4x slower laptop could not hold 2 fps). Measured
  // 20 Oct 2026, headless Chrome on an M1 Pro GPU, 213 webcam-like phone
  // frames and 473 without (COCO val2017 + Open Images: cups, cameras,
  // watches, cutlery held up to the lens), each also as 6 jittered frames
  // through `step`:
  //   Lite0 at 0.5: phone in 34% of phone frames, 1.7% of no-phone frames;
  //     42% of phones counted within 20 s, 12/473 no-phone scenes in 60 s.
  //   Lite2 at 0.6: 41%, 1.3%; 45%, 9/473; p90 to count 1.3 s, not 1.8 s.
  // Lite2 scores everything higher, hence its own bars. Its phone bar was 0.6
  // until 20 Oct night; at 0.5 it counts 57% of phones (45%) and 28% of
  // phones half out of the frame (16%), for 12 no-phone scenes, not 9 (a
  // crowded bar, a DJ desk, a plate of food: none a candidate at a desk). A
  // person box at 0.6 is close to Lite0's at 0.5: a second person on 1.5%
  // (Lite0 2.0%) of one-person frames, on 60% (64%) of two-person ones.
  // 50 ms a frame, not 30; 12.1 MB, not 7.3 (10.5 MB gzipped, not 6.3).
  // A GPU 3x slower than that M1 Pro's passes `slowFrameMs` on Lite2 and
  // samples at 1 fps: a phone counted in about 2 s, not 1 (same share in 5 s).
  // So a GPU that slow does not keep it: after `warmFrames` (shader compile),
  // a median frame over `maxMs` across `probeFrames` swaps in Lite0 on the
  // same GPU with Lite0's bars, for the rest of the run (`downgrade`). `maxMs`
  // is `slowFrameMs`: Lite2 stays only where it keeps the 2 fps pace (a whole
  // frame on that M1 Pro: 87 ms median, 94 ms p90, real Chrome, 20 Oct).
  // Measured once per run, never mid-exam again.
  gpu: {
    model: 'efficientdet_lite2.tflite',
    phoneMinScore: 0.5,
    personMinScore: 0.6,
    warmFrames: 2,
    probeFrames: 8,
    maxMs: 150,
    // Lite2's own input is 448x448: a 320-wide frame was scaled UP to it and
    // a phone lost detail before the model saw it. The model's work is the
    // same at either width (it always runs on 448), so only the frame copy
    // grows; a GPU too slow still swaps to Lite0 at `sampleWidth` (320).
    sampleWidth: 448,
  },
  // A closer look: a possible phone (from `phone.seeScore` up to the trip
  // score) is checked again on a square of the video around it, `k` times
  // its long side and at least `minSide` of the frame's short side, drawn at the
  // model's own width. A small or half-seen phone gets more pixels; the best
  // score of the two counts. Measured 20 Oct 2026 night on the set of `gpu`
  // plus 182 phones cut in half by the frame edge: Lite2 at 0.5 counts 62%
  // of phones (57% without it) and 34% of half-cut ones (28%), for 13
  // no-phone scenes (12); Lite0 48% (42%) and 22% (17%), for 13 (12). It
  // runs on about 2% of no-phone frames, one more detection each. Never
  // where the frame's own detection already took over `slowFrameMs`: on a
  // weak laptop it would freeze the page twice as long on every frame a
  // look-alike sits in view. A frame it makes slower than that drops to the
  // slow rate like any other.
  zoom: { k: 2.5, minSide: 0.4 },
  // One face alone, its centre outside the central `band` (70%) ACROSS the
  // frame. Up and down are not judged: a laptop camera looks up at a face
  // that sits low in its frame. Two or more is `multiple_faces`' job.
  left_frame: { holdMs: 3000, band: 0.7, reason: 'AI: left the frame' },
  // Evidence snapshots: `start` once a frame and a policy are there (polled
  // every `startPollMs`), then `periodic` every `periodicShotMs` until stop().
  startPollMs: 250,
  periodicShotMs: 120000,
  snapshotLongSide: 640,
  snapshotQualities: [0.7, 0.5, 0.3], // first one under the policy's max_bytes
  uploadTimeoutMs: 15000,
  retryMs: [1000, 4000, 16000, 60000], // then every 60 s until a 2xx or `landed`
  queueMaxAgeMs: 24 * 3600 * 1000, // unsent snapshots older than this are dropped
  tripFlashMs: 4000,
  // Frames in a row whose detection throws before the status turns `failed`:
  // the detectors loaded but cannot run (a machine with no WebGL fails every
  // frame), and the admin must not read "running" while nothing is checked.
  // As many good frames in a row turn it back to `running`, at most
  // `maxRecoveries` times a run: every change is a request to our server, so
  // a flickering machine must not send one every few seconds. Past that the
  // next `failed` stays.
  failAfterFrames: 10,
  maxRecoveries: 2,
};

/// RULES with the bars of the object `model` file: Lite2's (`RULES.gpu`), or
/// the base ones for Lite0, on whichever delegate runs it.
function rulesFor(model) {
  if (model !== RULES.gpu.model) return RULES;
  const g = RULES.gpu;
  return {
    ...RULES,
    personMinScore: g.personMinScore,
    sampleWidth: g.sampleWidth,
    phone: { ...RULES.phone, minScore: g.phoneMinScore },
  };
}

/// A fresh engine state. `startMs` begins the grace period.
export function initialState(startMs) {
  return {
    start: startMs,
    since: {},
    phoneHits: [],
    last: {},
    burstUntil: 0,
    bursts: [], // times of the frames followed by a burst-rate wait, in the window
    next: RULES.sampleMs,
    // rule -> its episode, `{ counted, shot, off? }`: whether it was counted,
    // when it was last photographed, when it went off.
    open: {},
    shot: {}, // rule -> its last snapshot-only photo, across episodes
  };
}

/// One sampled frame through the rules.
///
/// `frame` is `{ t, faces, phone, persons, took }`: `t` in ms, `faces` as
/// `[{ x, y, w, h, score }]` in 0..1 of the frame, `phone` the best
/// `cell phone` score (0 when none), `persons` the number of `person` boxes
/// at `personMinScore` or more (0 when absent), `took` the ms the frame's
/// detection took (0 when absent). Returns `{ state, trips, shots }`: each
/// trip is `{ rule, reason, score }` (a violation, with its snapshot), each
/// shot `{ rule }` (a snapshot only, never a violation), and `state.next` is
/// the ms to wait before the next frame; `prev` is not modified.
export function step(prev, frame, rules = RULES) {
  const t = frame.t;
  const faces = [...frame.faces].sort((a, b) => b.score - a.score);
  // A device that cannot keep up never bursts: a slow frame ends the burst.
  const slow = (frame.took ?? 0) > rules.slowFrameMs;
  let burstUntil = slow ? 0 : prev.burstUntil;
  if (!slow && frame.phone >= rules.phone.seeScore) burstUntil = t + rules.burstForMs;
  // Each burst-rate wait spends `burstMs` of the cap; the window slides.
  const bursts = prev.bursts.filter((b) => t - b < rules.burstWindowMs);
  let next = slow ? rules.slowSampleMs : rules.sampleMs;
  if (
    !slow &&
    t < burstUntil &&
    (bursts.length + 1) * rules.burstMs <= rules.burstCapMs
  ) {
    next = rules.burstMs;
    bursts.push(t);
  }
  const state = {
    start: prev.start,
    since: { ...prev.since },
    phoneHits: [...prev.phoneHits, frame.phone >= rules.phone.minScore].slice(
      -rules.phone.window,
    ),
    last: { ...prev.last },
    burstUntil,
    bursts,
    next,
    open: { ...prev.open },
    shot: { ...prev.shot },
  };
  // The grace period: nothing accumulates, so a window starts when it ends.
  if (t - state.start < rules.graceMs) {
    state.since = {};
    state.phoneHits = [];
    state.open = {};
    return { state, trips: [], shots: [] };
  }

  // True once `on` has held continuously for the rule's `holdMs`.
  const held = (rule, on) => {
    if (!on) {
      delete state.since[rule];
      return false;
    }
    if (state.since[rule] === undefined) state.since[rule] = t;
    return t - state.since[rule] >= rules[rule].holdMs;
  };
  const trips = [];
  const shots = [];
  const trip = (rule, score) => {
    const last = state.last[rule];
    const floor = rules[rule].cooldownMs ?? rules.cooldownMs;
    if (last !== undefined && t - last < floor) return false;
    state.last[rule] = t;
    trips.push({ rule, reason: rules[rule].reason, score });
    return true;
  };
  // An open episode survives an off spell shorter than `releaseMs`.
  const settle = (rule, on) => {
    const e = state.open[rule];
    if (!e) return;
    if (on) {
      if (e.off !== undefined) state.open[rule] = { counted: e.counted, shot: e.shot };
    } else if (e.off === undefined) state.open[rule] = { ...e, off: t };
    else if (t - e.off >= rules.releaseMs) delete state.open[rule];
  };
  // A held condition: counted once per episode, as soon as the cooldown
  // allows (the trip takes its own snapshot), else a snapshot only, spaced
  // by `heldShotMs`.
  const hold = (rule, score) => {
    const e = state.open[rule];
    if (!e?.counted && trip(rule, score)) {
      state.open[rule] = { counted: true, shot: t };
      return;
    }
    const last = state.shot[rule];
    if (e && t - e.shot < rules.heldShotMs) return;
    if (last !== undefined && t - last < rules.heldShotMs) return;
    state.open[rule] = { counted: e?.counted ?? false, shot: t };
    state.shot[rule] = t;
    shots.push({ rule });
  };

  const noFace = faces.length === 0;
  settle('no_face', noFace);
  if (held('no_face', noFace)) hold('no_face', 0);
  const crowd = Math.max(faces.length, frame.persons ?? 0) > 1;
  settle('multiple_faces', crowd);
  if (held('multiple_faces', crowd)) hold('multiple_faces', faces[1]?.score ?? 0);
  const phone =
    state.phoneHits.filter(Boolean).length >= rules.phone.hits ||
    frame.phone >= rules.phone.strongScore;
  settle('phone', phone || frame.phone >= rules.phone.seeScore);
  if (phone) hold('phone', frame.phone);
  // A phone hit not counted yet gets its second frame at burst rate, also on
  // a slow device that never bursts: at 1 fps it waited a whole second (at
  // 200 ms a frame, median 2.4 s to count; 1.7 s with this). Within the cap.
  if (
    slow &&
    frame.phone >= rules.phone.minScore &&
    !state.open.phone &&
    (bursts.length + 1) * rules.burstMs <= rules.burstCapMs
  ) {
    state.next = rules.burstMs;
    bursts.push(t);
  }
  // Not `crowd` leaves at most one face: judged across only.
  const f = faces[0];
  const off =
    !crowd && f !== undefined && Math.abs(f.x + f.w / 2 - 0.5) > rules.left_frame.band / 2;
  settle('left_frame', off);
  if (held('left_frame', off)) hold('left_frame', f.score);
  return { state, trips, shots };
}

// ---------------------------------------------------------------------------
// Browser bridge
// ---------------------------------------------------------------------------

const STORE = 'etp_evidence';
let detectors = null; // memoised until stop(), which closes them
let run = null; // the live session, or null
let policy = null; // the current S3 presigned POST policy, or null

/// MediaPipe 1.0.1 posts task-performance counters to
/// `odml.pa.googleapis.com` and offers no switch to turn that off. A candidate's
/// browser must not talk to a third party during an exam, so requests to any
/// `*.pa.googleapis.com` host are dropped here, before the bundle loads:
/// `fetch` resolves an empty 204 (MediaPipe's logger then gives up), XHR is
/// pointed at an empty `data:` URL, `sendBeacon` reports success and sends
/// nothing. Every other request passes through untouched.
function blockTelemetry() {
  if (window.__etpTelemetryBlocked) return;
  window.__etpTelemetryBlocked = true;
  let logged = false;
  const blocked = (url) => {
    try {
      const host = new URL(url, location.href).hostname;
      if (!host.endsWith('.pa.googleapis.com')) return false;
      if (!logged) {
        logged = true;
        console.info(`proctor_ai: blocked MediaPipe telemetry to ${host}`);
      }
      return true;
    } catch (e) {
      return false;
    }
  };
  const fetch0 = window.fetch;
  window.fetch = function (input, ...rest) {
    const url = input instanceof Request ? input.url : String(input);
    if (blocked(url)) return Promise.resolve(new Response(null, { status: 204 }));
    return fetch0.call(this, input, ...rest);
  };
  const open0 = XMLHttpRequest.prototype.open;
  // Rest args keep the caller's argument COUNT: open(m, u, undefined) would
  // turn an async request synchronous.
  XMLHttpRequest.prototype.open = function (method, url, ...rest) {
    return open0.call(this, method, blocked(url) ? 'data:,' : url, ...rest);
  };
  if (navigator.sendBeacon) {
    const beacon0 = navigator.sendBeacon.bind(navigator);
    navigator.sendBeacon = (url, data) => (blocked(url) ? true : beacon0(url, data));
  }
}

/// A file under `mediapipe/`, beside this module.
const at = (p) => new URL(p, new URL('mediapipe/', import.meta.url)).href;

/// The object model `delegate` starts on: Lite2 on the GPU (`RULES.gpu`),
/// Lite0 on the CPU, where Lite2 is too slow for 2 fps. Its bars are
/// `rulesFor`'s; a slow GPU drops to Lite0 later (`downgrade`).
export function objectModel(delegate) {
  return delegate === 'GPU' ? RULES.gpu.model : LITE0;
}
const LITE0 = 'efficientdet_lite0.tflite';

/// The ObjectDetector options for `model` on `delegate`.
function objectOptions(model, delegate) {
  return {
    baseOptions: { modelAssetPath: at(model), delegate },
    runningMode: 'IMAGE',
    scoreThreshold: RULES.phone.seeScore,
    categoryAllowlist: ['cell phone', 'person'],
    // Room for a phone beside a few person boxes: the cap is shared.
    maxResults: 6,
  };
}

/// What the loader resolved, kept for `loadLite0Gpu`.
let vision = null;

/// FaceDetector + ObjectDetector, GPU first, CPU if the GPU delegate refuses;
/// `delegate` says which, and so which object model (`RULES.gpu`).
function loadDetectors() {
  if (detectors) return detectors;
  blockTelemetry();
  const loading = (async () => {
    const { FilesetResolver, FaceDetector, ObjectDetector } = await import(
      at('vision_bundle.mjs')
    );
    // No trailing slash: the resolver appends `/vision_wasm_...`.
    const fileset = await FilesetResolver.forVisionTasks(at('wasm'));
    vision = { ObjectDetector, fileset };
    // Both at once, so their model downloads overlap. One that fails closes
    // the other and rethrows, so the CPU retry below starts clean.
    const make = async (delegate) => {
      const model = objectModel(delegate);
      const [face, obj] = await Promise.allSettled([
        FaceDetector.createFromOptions(fileset, {
          baseOptions: { modelAssetPath: at('blaze_face_short_range.tflite'), delegate },
          runningMode: 'IMAGE',
          minDetectionConfidence: RULES.faceMinScore,
        }),
        ObjectDetector.createFromOptions(fileset, objectOptions(model, delegate)),
      ]);
      if (face.status === 'fulfilled' && obj.status === 'fulfilled') {
        return { face: face.value, obj: obj.value, delegate, model };
      }
      for (const x of [face, obj]) if (x.status === 'fulfilled') x.value.close();
      throw face.status === 'rejected' ? face.reason : obj.reason;
    };
    try {
      return await make('GPU');
    } catch (e) {
      console.warn('proctor_ai: GPU delegate refused, using CPU', e);
      return make('CPU');
    }
  })();
  // A failed load may be retried by a later start().
  loading.catch(() => {
    if (detectors === loading) detectors = null;
  });
  detectors = loading;
  return loading;
}

/// Lite0 on the GPU, for a GPU too slow for Lite2 (`downgrade`). Only after
/// loadDetectors() has resolved.
function loadLite0Gpu() {
  return vision.ObjectDetector.createFromOptions(vision.fileset, objectOptions(LITE0, 'GPU'));
}

/// The loaders start() and preload() use. Swapped by the node test.
export const models = { detectors: loadDetectors, lite0Gpu: loadLite0Gpu };

/// Load the models ahead of start() (the instructions screen), so detection
/// is ready at Begin. True once loaded; false on a failure, which start()
/// then retries. Memoised: start() reuses what this loaded.
function preload() {
  return models.detectors().then(
    () => true,
    () => false,
  );
}

/// Let go of the models preload() loaded, unless a run uses them: the
/// instructions page was left without starting (about 35 MB). True when it
/// let them go; false while a run (or its model load) is under way.
function release() {
  if (run) return false;
  closeDetectors();
  return true;
}

/// Release every model (wasm memory, GL contexts) once it has loaded.
function closeDetectors() {
  const d = detectors;
  detectors = null;
  if (!d) return;
  d.then(
    (x) => {
      x.face.close();
      x.obj.close();
    },
    () => {},
  );
}

/// Set a canvas's backing size only when it changes: every assignment
/// reallocates the bitmap and resets the context.
function fit(c, w, h) {
  if (c.width !== w) c.width = w;
  if (c.height !== h) c.height = h;
}

function ensureStyle() {
  if (document.getElementById('etp-proctor-ai-style')) return;
  const s = document.createElement('style');
  s.id = 'etp-proctor-ai-style';
  s.textContent =
    '@keyframes etpAiPulse{0%,100%{outline-color:rgba(229,72,77,.25)}' +
    '50%{outline-color:rgba(229,72,77,1)}}' +
    '.etp-ai-trip{outline:3px solid #e5484d;outline-offset:-3px;' +
    'animation:etpAiPulse .8s ease-in-out 5}';
  document.head.appendChild(s);
}

/// The overlay canvas, laid over the preview `<video>` inside the wrapper
/// `proctor_web.dart` registered. Mirrored like the video, so a box drawn in
/// source coordinates lands on the face the candidate sees.
function attachOverlay(video) {
  const canvas = document.createElement('canvas');
  Object.assign(canvas.style, {
    position: 'absolute',
    inset: '0',
    width: '100%',
    height: '100%',
    pointerEvents: 'none',
    borderRadius: '8px',
    transform: 'scaleX(-1)',
  });
  (video.parentElement || video).appendChild(canvas);
  return canvas;
}

/// Face boxes in red, mapped through the preview's `object-fit: cover` crop.
function draw(r, faces) {
  const { canvas, video } = r;
  const dpr = window.devicePixelRatio || 1;
  const cw = video.clientWidth;
  const ch = video.clientHeight;
  fit(canvas, Math.round(cw * dpr), Math.round(ch * dpr));
  const ctx = canvas.getContext('2d');
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  const vw = video.videoWidth;
  const vh = video.videoHeight;
  if (!vw || !vh || !cw || !ch) return;
  const s = Math.max(cw / vw, ch / vh);
  const ox = (cw - vw * s) / 2;
  const oy = (ch - vh * s) / 2;
  ctx.strokeStyle = '#e5484d';
  ctx.lineWidth = 2 * dpr;
  for (const f of faces) {
    ctx.strokeRect(
      (ox + f.x * vw * s) * dpr,
      (oy + f.y * vh * s) * dpr,
      f.w * vw * s * dpr,
      f.h * vh * s * dpr,
    );
  }
}

function flash(r) {
  const c = r.canvas;
  c.classList.remove('etp-ai-trip');
  void c.offsetWidth; // restart the animation on a repeat trip
  c.classList.add('etp-ai-trip');
  clearTimeout(r.flashTimer);
  r.flashTimer = setTimeout(() => c.classList.remove('etp-ai-trip'), RULES.tripFlashMs);
}

function schedule(r, ms) {
  r.timer = setTimeout(() => tick(r), ms);
}

async function tick(r) {
  if (run !== r) return;
  let next = RULES.sampleMs;
  const v = r.video;
  if (v.readyState >= 2 && v.videoWidth > 0) {
    try {
      const t0 = performance.now();
      const w = r.rules.sampleWidth;
      const h = Math.round((w * v.videoHeight) / v.videoWidth);
      fit(r.small, w, h);
      r.small.getContext('2d').drawImage(v, 0, 0, w, h);
      const faces = r.det.face.detect(r.small).detections.map((d) => ({
        x: d.boundingBox.originX / w,
        y: d.boundingBox.originY / h,
        w: d.boundingBox.width / w,
        h: d.boundingBox.height / h,
        score: d.categories[0]?.score ?? 0,
      }));
      const objs = r.det.obj.detect(r.small).detections;
      const phones = named(objs, 'cell phone');
      let phone = best(phones);
      const persons = named(objs, 'person').filter(
        (d) => d.categories[0].score >= r.rules.personMinScore,
      ).length;
      const full = performance.now() - t0;
      if (
        phone >= r.rules.phone.seeScore &&
        phone < r.rules.phone.minScore &&
        full <= r.rules.slowFrameMs
      ) {
        const d = phones.find((x) => x.categories[0].score === phone);
        phone = Math.max(phone, lookCloser(r, d.boundingBox, v.videoWidth / w));
        r.zooms++;
      }
      const took = performance.now() - t0;
      r.frames++;
      judgeSpeed(r, full);
      r.failStreak = 0;
      if (
        r.failing &&
        ++r.okStreak >= RULES.failAfterFrames &&
        r.recoveries < RULES.maxRecoveries
      ) {
        r.failing = false;
        r.okStreak = 0;
        r.recoveries++;
        status(r, 'running');
      }
      if (faces.length > 0) r.faceFrames++;
      r.msSum += took;
      r.msMax = Math.max(r.msMax, took);
      r.last = {
        faces: faces.length,
        faceScore: Math.max(0, ...faces.map((f) => f.score)),
        phone,
        persons,
        ms: Math.round(took),
      };
      draw(r, faces);
      const out = step(r.state, { t: performance.now(), faces, phone, persons, took }, r.rules);
      r.state = out.state;
      next = out.state.next;
      if (next === RULES.burstMs) r.burstFrames++;
      for (const trip of out.trips) onTrip(r, trip);
      for (const shot of out.shots) shoot(r, shot.rule);
    } catch (e) {
      console.warn('proctor_ai: frame failed', e);
      r.okStreak = 0;
      r.failStreak++;
      if (!r.failing && r.failStreak >= RULES.failAfterFrames) {
        r.failing = true;
        status(r, 'failed');
      }
    }
  }
  if (run === r) schedule(r, next);
}

/// The detections of category `name`.
function named(dets, name) {
  return dets.filter((d) => d.categories[0]?.categoryName === name);
}

/// The best score among `dets`, 0 when none.
function best(dets) {
  return Math.max(0, ...dets.map((d) => d.categories[0].score));
}

/// The square `[x, y, side]`, in video pixels, a closer look takes around
/// the box `{ x, y, w, h }` (`RULES.zoom`), kept inside the `vw` x `vh` frame.
export function zoomRect(b, vw, vh) {
  const short = Math.min(vw, vh);
  const z = RULES.zoom;
  const side = Math.min(Math.max(z.k * Math.max(b.w, b.h), z.minSide * short), short);
  const x = Math.min(Math.max(b.x + b.w / 2 - side / 2, 0), vw - side);
  const y = Math.min(Math.max(b.y + b.h / 2 - side / 2, 0), vh - side);
  return [x, y, side];
}

/// A closer look at a possible phone: `zoomRect` around `box` (a detection's
/// `boundingBox` in `r.small` pixels, `s` video pixels each), drawn from the
/// video at `sampleWidth` square. The best `cell phone` score in it; 0 if
/// the look fails, so the frame keeps its own checks.
function lookCloser(r, box, s) {
  try {
    const v = r.video;
    const b = { x: box.originX * s, y: box.originY * s, w: box.width * s, h: box.height * s };
    const [x, y, side] = zoomRect(b, v.videoWidth, v.videoHeight);
    const n = r.rules.sampleWidth;
    fit(r.closer, n, n);
    r.closer.getContext('2d').drawImage(v, x, y, side, side, 0, 0, n, n);
    return best(named(r.det.obj.detect(r.closer).detections, 'cell phone'));
  } catch (e) {
    console.warn('proctor_ai: closer look failed', e);
    return 0;
  }
}

/// Lite2 only: past `warmFrames`, gather `probeFrames` frame times (without
/// a closer look, which is not the model's pace), then downgrade once if
/// their median is over `maxMs`. Judged once per run.
function judgeSpeed(r, took) {
  const g = RULES.gpu;
  if (r.probed || r.det.model !== g.model || r.frames <= g.warmFrames) return;
  r.probe.push(took);
  if (r.probe.length < g.probeFrames) return;
  r.probed = true;
  const sorted = [...r.probe].sort((a, b) => a - b);
  if (sorted[sorted.length >> 1] > g.maxMs) void downgrade(r);
}

/// Swap Lite2 for Lite0 on the same GPU, and Lite0's bars, for the rest of
/// this run (stop() lets every model go, so a new run starts on Lite2 and is
/// judged again). A Lite0 that will not load keeps Lite2: slow beats off.
async function downgrade(r) {
  let obj;
  try {
    obj = await models.lite0Gpu();
  } catch (e) {
    console.warn('proctor_ai: Lite0 on the GPU failed to load, keeping Lite2', e);
    return;
  }
  if (run !== r) {
    // Stopped while Lite0 loaded: stop() already let the set go.
    try {
      obj.close();
    } catch (e) {
      console.warn('proctor_ai: closing Lite0 failed', e);
    }
    return;
  }
  const det = r.det;
  const old = det.obj;
  det.obj = obj;
  det.model = LITE0;
  r.rules = rulesFor(LITE0);
  console.warn('proctor_ai: GPU too slow for Lite2, now on Lite0');
  try {
    old.close();
  } catch (e) {
    console.warn('proctor_ai: closing Lite2 failed', e);
  }
}

/// One trip: flash the plate, grab the frame, REPORT, then upload.
///
/// The violation goes out first, synchronously: a slow or broken bucket must
/// never delay `/violation`. The frame is copied before reporting, so the
/// snapshot is the moment of the trip whatever the upload does later.
function onTrip(r, trip) {
  r.trips++;
  try {
    flash(r);
  } catch (e) {
    console.warn('proctor_ai: flash failed', e);
  }
  const c = capture(r, trip.rule);
  try {
    r.onEvent({ ...trip, key: c ? c.key : '', queued: c !== null });
  } catch (e) {
    console.warn('proctor_ai: onEvent threw', e);
  }
  if (c) void upload(c.key, c.frame, c.maxBytes);
}

/// A snapshot that is not a trip (`start`, `periodic`, a held condition):
/// queued for upload and never reported. True when one was taken.
function shoot(r, label) {
  const c = capture(r, label);
  if (c) void upload(c.key, c.frame, c.maxBytes);
  return c !== null;
}

/// The current frame and its S3 key, `<prefix><epoch_ms>_<label>.jpg` (the
/// admin gallery labels a snapshot by `label`). Null without a policy to
/// name it or a live frame. Never throws.
function capture(r, label) {
  const p = policy;
  try {
    const frame = p ? grab(r.video) : null;
    if (!frame) return null;
    return { key: `${p.prefix}${Date.now()}_${label}.jpg`, frame, maxBytes: p.max_bytes };
  } catch (e) {
    console.warn('proctor_ai: snapshot failed', e);
    return null;
  }
}

/// The current frame on a canvas, long side `snapshotLongSide`; null until
/// the video has one.
function grab(video) {
  const vw = video.videoWidth;
  const vh = video.videoHeight;
  if (video.readyState < 2 || !vw || !vh) return null;
  const k = Math.min(1, RULES.snapshotLongSide / Math.max(vw, vh));
  const c = document.createElement('canvas');
  c.width = Math.round(vw * k);
  c.height = Math.round(vh * k);
  c.getContext('2d').drawImage(video, 0, 0, c.width, c.height);
  return c;
}

/// Encode, queue and send one snapshot. The outcome is only logged.
async function upload(key, frame, maxBytes) {
  try {
    let blob = null;
    for (const q of RULES.snapshotQualities) {
      const b = await new Promise((res) => frame.toBlob(res, 'image/jpeg', q));
      if (b && (!maxBytes || b.size <= maxBytes)) {
        blob = b;
        break;
      }
    }
    if (!blob) {
      console.warn(`proctor_ai: snapshot ${key} over max_bytes, dropped`);
      return;
    }
    queue.set(key, blob);
    // Awaited so the row's delete on success cannot overtake its put.
    await idb('readwrite', (s) => s.put({ key, blob }, key));
    const out = await send(key);
    if (out === 'retry') retryLater();
    console.info(`proctor_ai: snapshot ${key}: ${out === 'ok' ? 'stored' : `held (${out})`}`);
  } catch (e) {
    console.warn('proctor_ai: snapshot upload failed', e);
  }
}

// --- Evidence queue: memory first, IndexedDB so a reload does not lose it ---

const queue = new Map(); // S3 key -> JPEG blob
let fails = 0;
let retryTimer = null;
let restored = false;

/// One IndexedDB transaction, or undefined when storage is unavailable
/// (private windows, blocked site data). Never throws: the memory queue is
/// the fallback and the exam must not notice.
async function idb(mode, fn) {
  try {
    const db = await new Promise((res, rej) => {
      const req = indexedDB.open(STORE, 1);
      req.onupgradeneeded = () => req.result.createObjectStore(STORE);
      req.onsuccess = () => res(req.result);
      req.onerror = () => rej(req.error);
    });
    return await new Promise((res, rej) => {
      const tx = db.transaction(STORE, mode);
      const req = fn(tx.objectStore(STORE));
      tx.oncomplete = () => {
        db.close();
        res(req.result);
      };
      tx.onerror = tx.onabort = () => {
        db.close();
        rej(tx.error);
      };
    });
  } catch (e) {
    return undefined;
  }
}

/// A policy that can still sign an upload: present, not past `expires_at`,
/// and not refused by S3 (a 403 marks it `dead`).
function usable(p) {
  if (!p || p.dead) return false;
  const until = Date.parse(p.expires_at || '');
  return Number.isNaN(until) || Date.now() < until;
}

/// Drop one row from both queues.
function forget(key) {
  queue.delete(key);
  void idb('readwrite', (s) => s.delete(key));
}

/// POST one queued blob. 'ok' on a 2xx, or when no reply could be read and our
/// server finds the object (the row is dropped); 'hold' when the
/// policy cannot sign it (absent, expired, refused with a 403, or another
/// attempt's prefix), which waits for setPolicy() rather than retrying;
/// 'retry' for anything else.
async function send(key) {
  const blob = queue.get(key);
  if (!blob) return 'ok'; // already sent by a concurrent drain
  const p = policy;
  if (!usable(p) || !key.startsWith(p.prefix)) return 'hold';
  const fd = new FormData();
  // `key` is skipped: boto3 returns one templated as `${filename}`, and the
  // object is named here instead. S3 wants `file` last.
  for (const [k, v] of Object.entries(p.fields || {})) {
    if (k !== 'key') fd.append(k, v);
  }
  fd.append('key', key);
  fd.append('file', blob, key.slice(key.lastIndexOf('/') + 1));
  try {
    const res = await fetch(p.url, {
      method: 'POST',
      body: fd,
      signal: AbortSignal.timeout(RULES.uploadTimeoutMs),
    });
    if (res.status === 403) {
      // Expired or refused signature: retrying cannot help. Hold every row
      // until the next /state brings a fresh policy.
      p.dead = true;
      return 'hold';
    }
    if (!res.ok) return 'retry';
  } catch (e) {
    // No reply to read: a network failure, a timeout, OR a bucket with no
    // CORS rule for POST, which still STORES the file (a multipart POST is a
    // "simple" request) and only withholds S3's answer. Our server reads S3
    // itself, so ask it before sending the same snapshot again.
    if (!(await landed(p, key))) return 'retry';
  }
  forget(key);
  return 'ok';
}

/// Whether our server finds `key` in S3 (`p.landed`, which the Dart bridge
/// adds to the policy: `/exam/<token>/evidence/landed`). False when it cannot
/// tell, so the snapshot is kept and sent again.
async function landed(p, key) {
  try {
    return typeof p.landed === 'function' && (await p.landed(key)) === true;
  } catch (e) {
    return false;
  }
}

/// The epoch ms in a key (`<prefix><epoch_ms>_<label>.jpg`); NaN if absent.
function takenAt(key) {
  return Number((/(\d+)_[a-z_]+\.jpg$/.exec(key) || [])[1]);
}

/// Send every queued row of this attempt; back off 1 s, 4 s, 16 s, then 60 s.
/// Rows older than `queueMaxAgeMs`, of ANY attempt, are dropped first, so a
/// shared machine does not keep a candidate's snapshots indefinitely.
async function drain() {
  clearTimeout(retryTimer);
  retryTimer = null;
  for (const key of [...queue.keys()]) {
    if (!(Date.now() - takenAt(key) < RULES.queueMaxAgeMs)) forget(key);
  }
  const p = policy;
  if (!usable(p)) return; // held until setPolicy()
  for (const key of [...queue.keys()]) {
    if (!key.startsWith(p.prefix)) continue; // setPolicy() already dropped these
    const out = await send(key);
    if (out === 'retry') retryLater();
    if (out !== 'ok') return;
  }
  fails = 0;
}

function retryLater() {
  if (retryTimer) return;
  const ms = RULES.retryMs[Math.min(fails, RULES.retryMs.length - 1)];
  fails++;
  retryTimer = setTimeout(drain, ms);
}

/// Rows a previous page load left behind (a reload mid-exam).
async function restore() {
  if (restored) return;
  restored = true;
  const rows = await idb('readonly', (s) => s.getAll());
  for (const row of rows || []) {
    if (!row || !row.key || !row.blob) continue;
    if (policy && !row.key.startsWith(policy.prefix)) forget(row.key);
    else if (!queue.has(row.key)) queue.set(row.key, row.blob);
  }
}

/// A policy pins uploads to its own attempt's prefix, so every queued row
/// under another prefix can never be sent: drop it from both queues now,
/// rather than leave a candidate's snapshots on a shared PC for 24 h.
function setPolicy(p) {
  policy = p && p.url && p.prefix ? p : null;
  if (policy) {
    for (const key of [...queue.keys()]) {
      if (!key.startsWith(policy.prefix)) forget(key);
    }
  }
  if (run) startShot(run);
  void drain();
}

/// Start watching `video` (the preview `<video>`, inside its wrapper).
/// A second call with a new element moves the overlay and keeps the rule
/// state, so a remounted preview does not restart the grace period, nor take
/// a second start photo.
async function start(video, opts, onEvent) {
  if (typeof onEvent !== 'function') {
    // Detection without a callback looks healthy and reports nothing.
    console.error('proctor_ai: start() got no onEvent callback; trips cannot be reported');
  }
  if (opts) setPolicy(opts);
  ensureStyle();
  if (run) {
    run.onEvent = onEvent;
    if (run.video !== video) {
      run.canvas.remove();
      run.video = video;
      run.canvas = attachOverlay(video);
    }
    return;
  }
  const r = {
    video,
    onEvent,
    canvas: attachOverlay(video),
    small: document.createElement('canvas'),
    closer: document.createElement('canvas'), // `lookCloser`
    state: null,
    det: null,
    rules: RULES, // rulesFor() the loaded object model
    timer: null,
    flashTimer: null,
    frames: 0,
    faceFrames: 0,
    burstFrames: 0,
    zooms: 0, // frames that took a closer look (`RULES.zoom`)
    msSum: 0,
    msMax: 0,
    trips: 0,
    failStreak: 0, // frames in a row that threw (`failAfterFrames`)
    okStreak: 0, // good frames in a row while `failing`
    failing: false, // `failed` is the last status reported
    recoveries: 0, // `running` reported again after a `failed` (`maxRecoveries`)
    probe: [], // Lite2 frame times until judged (`RULES.gpu.maxMs`)
    probed: false,
    last: null,
    startTimer: null,
    startTaken: false,
    periodic: setInterval(() => shoot(r, 'periodic'), RULES.periodicShotMs),
  };
  run = r;
  void restore().then(drain);
  startShot(r);
  // The grace runs from the stream, not from the end of a slow model load.
  const t0 = performance.now();
  try {
    r.det = await models.detectors();
  } catch (e) {
    // The checks are off; the start and routine photos need no model and
    // go on until stop().
    console.warn('proctor_ai: detectors failed to load, AI proctoring is off', e);
    if (run === r) status(r, 'failed');
    return;
  }
  if (run !== r) return; // stopped while loading
  r.rules = rulesFor(r.det.model);
  r.state = initialState(t0);
  status(r, 'running');
  schedule(r, RULES.sampleMs);
}

/// The `start` snapshot, as soon as the preview has a frame and a policy can
/// name it: not after the grace or the model load. Once per run. Polled for
/// the frame only while there is a policy; setPolicy() calls it again.
function startShot(r) {
  clearTimeout(r.startTimer);
  if (run !== r || r.startTaken) return;
  r.startTaken = shoot(r, 'start');
  if (!r.startTaken && policy) {
    r.startTimer = setTimeout(() => startShot(r), RULES.startPollMs);
  }
}

/// How the AI stands, on the same `onEvent` as a trip but `rule: 'status'`:
/// `running` or `failed`. Never a violation: the Dart bridge routes it
/// before anything counts it.
///
/// The value rides in `status` and `reason` stays EMPTY: this file is served
/// no-cache, so an app opened before a deploy runs its OLD bridge against it,
/// and that bridge counts every non-empty `reason` as a violation but drops
/// an empty one (deploy-skew guard in `tool/proctor_ai_rules_test.mjs`).
function status(r, value) {
  try {
    r.onEvent({ rule: 'status', reason: '', status: value });
  } catch (e) {
    console.warn('proctor_ai: onEvent threw', e);
  }
}

function stop() {
  const r = run;
  run = null;
  // Also mid-load: the detectors close as soon as they resolve. A later
  // start() loads fresh ones (the files come from the HTTP cache).
  closeDetectors();
  if (!r) return;
  clearTimeout(r.timer);
  clearTimeout(r.flashTimer);
  clearTimeout(r.startTimer);
  clearInterval(r.periodic);
  r.canvas.remove();
}

/// What the bridge is doing right now, for a console or a test rig:
/// `window.__proctorAi.debug()`. Counts only, never pixels.
function debug() {
  const r = run;
  return {
    running: r !== null,
    detecting: !!(r && r.state),
    delegate: r && r.det ? r.det.delegate : null, // GPU starts on Lite2, CPU on Lite0
    model: r && r.det ? r.det.model : null, // Lite0 on a GPU too slow for Lite2
    hasOnEvent: !!(r && typeof r.onEvent === 'function'),
    frames: r ? r.frames : 0,
    faceFrames: r ? r.faceFrames : 0,
    burstFrames: r ? r.burstFrames : 0, // frames followed by a burst-rate wait
    zooms: r ? r.zooms : 0, // frames that took a closer look at a possible phone
    avgMs: r && r.frames ? Math.round(r.msSum / r.frames) : 0, // detection time per frame
    maxMs: r ? Math.round(r.msMax) : 0,
    next: r && r.state ? r.state.next : null,
    trips: r ? r.trips : 0,
    last: r ? r.last : null,
    holding: r && r.state ? Object.keys(r.state.since) : [],
    policy: policy !== null,
    queued: queue.size,
  };
}

// The queue and setPolicy are exported only so the node test can check which
// rows a new policy drops (IndexedDB is absent there, so only memory is read);
// start and stop so it can read the status event; release to check it never
// takes the models from a run.
export { queue, release, setPolicy, start, stop };

if (typeof window !== 'undefined') {
  window.__proctorAi = { start, stop, setPolicy, debug, preload, release };
}
