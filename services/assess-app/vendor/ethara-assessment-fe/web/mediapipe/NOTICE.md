# Third-party vision assets (AI proctoring)

Self-hosted, unmodified, so a candidate's browser never fetches them from a
third-party CDN. Loaded by `web/proctor_ai.js` only when an assessment has
`rules.ai_proctor` on. Pinned 6 Oct 2026; EfficientDet-Lite2 added 20 Oct 2026.

NOT COMMITTED (about 42 MB, see `.gitignore`): `tool/fetch_mediapipe.sh` downloads each
file below from its URL and refuses any whose SHA-256 differs from this table. `make build`,
`make build-portable` and the Dockerfile run it before `flutter build web`. This table is
the script's only input, so keep its layout.

| File | Source | Version | SHA-256 |
| --- | --- | --- | --- |
| `vision_bundle.mjs` | https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@1.0.1/vision_bundle.mjs | `@mediapipe/tasks-vision` 1.0.1 | `d885630c297c0b20b1fe86096cb06291c4c8080876f27852e724f24ac603713f` |
| `wasm/vision_wasm_internal.js` | https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@1.0.1/wasm/vision_wasm_internal.js | 1.0.1 | `e170ee67dd4e16c1a6fcd8840a206687e5a59b22c20e4a902bc445b095454d73` |
| `wasm/vision_wasm_internal.wasm` | https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@1.0.1/wasm/vision_wasm_internal.wasm | 1.0.1 | `8da277a733926eacd0474b8704b36742d6ec3231c57a860c5b889dff8f1df886` |
| `wasm/vision_wasm_nosimd_internal.js` | https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@1.0.1/wasm/vision_wasm_nosimd_internal.js | 1.0.1 | `e81d715a3d42cc3373602eb2f7aff795d164934db680e32496b65dab537f9658` |
| `wasm/vision_wasm_nosimd_internal.wasm` | https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@1.0.1/wasm/vision_wasm_nosimd_internal.wasm | 1.0.1 | `a28483cd42e74e855bf5ebdb6b40d9b66a5b49e35e95020bc97669e6822a3192` |
| `blaze_face_short_range.tflite` | https://storage.googleapis.com/mediapipe-models/face_detector/blaze_face_short_range/float16/1/blaze_face_short_range.tflite | float16, model version 1 | `b4578f35940bf5a1a655214a1cce5cab13eba73c1297cd78e1a04c2380b0152f` |
| `efficientdet_lite0.tflite` | https://storage.googleapis.com/mediapipe-models/object_detector/efficientdet_lite0/float16/1/efficientdet_lite0.tflite | float16, model version 1 | `4b59100025bea1235a84c1038879a6cccc9f6c49f5e41144e91e74d99e780993` |
| `efficientdet_lite2.tflite` | https://storage.googleapis.com/mediapipe-models/object_detector/efficientdet_lite2/float16/1/efficientdet_lite2.tflite | float16, model version 1 | `5d4ebec1029bc9907aeadb9e7b4ac9cb1da6a19d01ad375210a9ae18ba173302` |

`efficientdet_lite2.tflite` is the object model on the GPU delegate and
`efficientdet_lite0.tflite` the CPU fallback's (`RULES.gpu` in `proctor_ai.js` says why);
a candidate's browser fetches one of them, or both after a GPU refusal.

The eye-movement model (`face_landmarker.task`) is no longer vendored: eye movement was
removed on 19 Oct 2026.

The five package files match the npm tarball
(`https://registry.npmjs.org/@mediapipe/tasks-vision/-/tasks-vision-1.0.1.tgz`,
integrity `sha512-rvRE2FmAZ6ZxKSw7wq+e+jQDpN3t1B/tD2mJz9SmAzb1msoDkd4dMoE4wAh8Z30Um0PQwLiHr9QtomhmXk3aUQ==`)
byte for byte. The package's `wasm/vision_wasm_module_internal.*` pair is not vendored:
`FilesetResolver.forVisionTasks(path)` only loads it when called with `useModule = true`,
which `proctor_ai.js` never does.

To upgrade: change the URLs and SHA-256 values in this table, run
`bash tool/fetch_mediapipe.sh`, then `node tool/proctor_ai_rules_test.mjs`.

## Licence

MediaPipe (`@mediapipe/tasks-vision`) and the BlazeFace, EfficientDet-Lite0 and EfficientDet-Lite2 models are
Copyright Google LLC, licensed under the Apache License, Version 2.0
(https://www.apache.org/licenses/LICENSE-2.0).

The package's own description points to its privacy notice, https://goo.gle/mediapipe-privacy:
`vision_bundle.mjs` posts aggregate task-performance counters (task type, latency, no
images) to `https://odml.pa.googleapis.com/v1/log` about once a minute while a detector runs.
`proctor_ai.js` blocks every request to `*.pa.googleapis.com` before the bundle loads, so
nothing leaves a candidate's browser for that host.
