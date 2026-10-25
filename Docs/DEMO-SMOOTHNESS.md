# Demo camera and playback smoothness

Date: 2026-10-25. Installed capture acceptance updated 2026-10-26. This follows the recording workflow changes documented in [RECORDING-EXPERIENCE.md](RECORDING-EXPERIENCE.md).

## Diagnosis

The visible stalls had two independent causes:

- Overlapping zoom segments averaged their focus positions. Distant clicks could leave the camera stationary at the midpoint for 0.875 seconds. A short overlap also created a low-weight valley: the normalized focus changed rapidly and the final crop clamp released abruptly.
- Preview used a 30 Hz run-loop timer, built the full-resolution frame with synchronous `createCGImage` on AppKit's main thread, and assigned that image to a layer. The isolated 1920×1200 composition/readback stage took p50/p95 8.15/8.54 ms, before decoding, UI updates or display scheduling. Source recording and output were also limited to 30 fps.

## Changes

`DemoCameraPath` compiles a deterministic camera timeline and caches it until pointer or zoom data changes. Overlapping segments form a continuous group, handing off to the latest active target. Magnification and image translation use the same positive quintic blend; valid target crops remain valid during the entire transition. The 0.9-second transition kernel and 0.72-second outer envelope maintain continuous velocity and acceleration. Visible cursor positions still use the recorded trajectory.

Visible preview uses `NSView.displayLink`, targeting 60 Hz. Source pixels and effects share the predicted display time. Core Image renders directly to a `CAMetalLayer` at the preview's visible pixel dimensions. Drawable acquisition and GPU encoding run on a bounded serial queue; AppKit does not wait for a drawable. Late playback work is discarded, seeks invalidate old work, and paused edits retry until their final frame can be submitted. A new source hides the previous drawable until its own first frame arrives. Hidden previews retain a readback path for exact seek and media checks.

The rounded mask is created once. Background and shadow are retained in a GPU texture, with the same Metal device as the dynamic compositor. In the isolated 1920×1200 benchmark, CPU GPU submission p50/p95 is 0.72/1.92 ms and GPU execution is 1.15/1.23 ms. These stage timings are not playback FPS measurements.

New recordings and pointer sampling target 60 Hz; exports produce constant 60 fps. Existing 30 fps and sparse recordings use the new camera path and 60 fps effects without altering their source media. End-of-recording timestamps are compared after quantization, preventing a duplicate final PTS at an exact 60 fps boundary.

## Reproducible checks

- `scripts/check-demo-video.sh`: the same new camera assertions fail 61 times against the saved old planner and pass against the new one. Coverage includes C2 boundaries, distant target handoff, short overlapping segments, corners, mixed magnification, disabled segments, trim source time, reverse/random seek and copy-on-write cache invalidation. Existing pixel comparisons and cancellation protection remain strict. A genuine two-frame/four-second VFR movie exports 240 independently composed frames at 60 fps; exact seek, replay and trim checks pass.
- `scripts/check-demo-recorder.sh`: a bounded five-surface producer supplies 120 frames at 60 fps, all retained through real H.264 writing; pause/resume, idle duration, steps, errors and cancellation remain covered.
- `scripts/check-demo-studio.sh`: actual slider/play/trim actions in the editor retain the selected destination and source bytes.

The original 22.733-second real pointer trajectory was evaluated at identical timestamps before and after the change, using a 1920×1200 screen transform:

| 60 Hz camera motion metric | Before | After |
| --- | ---: | ---: |
| Maximum one-frame displacement | 98.62 px | 36.68 px |
| Maximum acceleration | 239,545 px/s² | 9,119 px/s² |
| Maximum jerk | 15,656,961 px/s³ | 111,477 px/s³ |

The maximum acceleration decreases 96.2%; the midpoint stall is eliminated. These quantify trajectory continuity, rather than subjective playback quality. The cached path evaluates 100,000 random timestamps in 8.46 ms in the task-local harness.

Evidence is retained locally in `artifacts/camera-smoothness/`, `artifacts/smoothness-regression/` and `artifacts/smoothness-perf/`. User recordings are never modified by the analysis.

## Display and installation acceptance

The visible Metal preview's complete four-quadrant direction fixture was compared with the CPU reference: all labels are upright, with red/green above blue/yellow. Raw texture row order alone was insufficient to infer `CAMetalLayer` presentation orientation; no extra image flip is applied.

Final visible presentation was measured from each drawable's actual `presentedTime`, after two seconds of warmup, for approximately six seconds. No screenshots or root builds ran during these final samples. Other applications were left running.

| Visible scene | Presented frames | Interval p95 | Intervals >25 ms |
| --- | ---: | ---: | ---: |
| Synthetic cursor/zoom fixture | 360 | 16.667 ms | 0 |
| Real 1920×1200 recording, standalone preview | 359 | 16.667 ms | 2 |
| Same real recording, complete Studio editor | 360 | 16.667 ms | 0 |

The standalone real-source sample had two 33.334 ms intervals and none above 40 ms. Complete Studio retained the normal play-button action and 10 Hz playback controls; its timeline action paused and sought to 3.25 seconds, with the last actually presented effect time exactly 3.25. No measured effect timestamps repeated or moved backwards during steady playback. These are short acceptance samples, not a guarantee for all system loads or long recordings.

GPU and CPU full-frame pixels match after accounting for their readback row conventions. Source movie and metadata SHA-256 values before and after real-source playback are identical. Detailed samples are in `artifacts/smoothness-perf/final-visible/`.

The smoothness build was initially installed as SHA-256 `c3946a34e8081f5ac55da478bfa51b45d9bb555ce04e0221c598b45d5b010f3e`. After the parallel screenshot improvements were combined, the final installed executable is `bb8705a7c049a553adc272e32385df545f7bf148a75a3ad9cbe7f2c8974fd479`, matching `dist/XShot.app`. The existing screen-recording grant was associated with that exact package before acceptance; no further rebuild or permission change was needed. The previous application and the screenshot open at update time are saved under `artifacts/smoothness-install/`.

### Installed recording and export, 2026-10-26

The final installed app selected a dedicated, normal-level 960×628-point window through the recording UI. Its 60 Hz display counter and continuously animated blue ruler contain no user content. Recording stopped into the editor normally, without a recording notice. The app then played the result and exported MP4 through the native save panel.

- Original MOV: 1920×1256, 35.591667 seconds, 2,051 source frames; average approximately **57.63 fps**, rather than constant 60 fps. Excluding the first/last half-second, source PTS interval p50/p95 is 16.667/20.000 ms, with a maximum of 36.666 ms. Two steady intervals exceed 25 ms, none exceed 40 ms. The full recording also contains one initial 38.334 ms interval.
- Every source frame contains an identifiable moving blue bar. There are no identical ruler-region frames or stationary updates. Excluding turnarounds, 68/1,745 updates exceed 1.5 nominal 60 Hz motion steps; this records the remaining source-cadence variation rather than hiding it behind the export frame count. Turnaround spacing has a median of 1.9983 seconds, with no endpoint stall.
- Native MP4 export: H.264, 1920×1256, **60/1 fps**, 2,136 frames, 35.591667 seconds, zero start, strictly increasing PTS and 16.666–16.667 ms intervals. All three colour tags are BT.709; full-file decoding passes. Project/media durations differ by less than 1 ms.
- This automated capture had no physical pointer inside the selected window, so pointer/click arrays are empty. It verifies capture and export cadence, not new physical-input sampling. Camera handoff remains covered by the earlier real input trajectory, actual drawable timing and deterministic regression checks.

Evidence: `artifacts/smoothness-capture/analysis-8572A4/report.json`, its per-frame CSV, `export-verification.json`, and `installed-60fps.mp4`. The dedicated test app has exited, the test editor is closed, and the original 1728×1401 screenshot is visible again. Its saved PNG retains SHA-256 `74e9f17c10ff74767bb36cd9dcd419276bbd1e11e719e053b2e056a4b21550e3`.

## Follow-up: click visibility and workspace windows, 2026-10-26

The previous C2 path was smooth but causal, adding approximately 450 ms of target lag. In the user's subsequent 13.668-second project, the fourth recorded click projected to normalized screen y=-0.259 at the event and y=-0.116 after 100 ms. The event was stored, but its action was cropped out. Separately, the recorder's 120/350 ms time/distance debounce could discard actual fast mouseDown events.

The path now anticipates targets by 380 ms while retaining its 0.9-second C2 transition. If a burst of distant targets cannot all fit a tightly zoomed, smoothly moving view, a C2 visibility envelope temporarily widens the framing. The operation and its short response remain visible. The visible cursor also receives exact event-time click anchors, sorted alongside timer samples.

Every received mouseDown is retained, including rapid target changes and same-position double/triple clicks. PNG queue and total-step limits still bound resource use, but do not remove click metadata. The fallback for a missing CGEvent uses the event's own coordinates rather than a later mouse location.

`WorkspaceWindowCoordinator` hides existing XShot workspace windows before countdown without closing them. Cancellation/failure restores the visible stack; successful completion shows only the new Studio. Dock reopen prefers a current or recently used document across image/studio types. The home window appears when explicitly requested or when there is no document to resume.

Verification:

- 60/80/100 ms event sequences now retain 9/9 events each; replay of the old debounce retained 4/9. Same-position double/triple clicks, exact cursor anchors, late delivery, missing pre-click cache, pending-PNG pressure and the 200-step limit pass real media-pipeline regression.
- The user's actual trajectory has 0/252 cropped operation samples after the fix, versus 59/252 before. A synthetic 120 ms alternating-corner sequence improves from 693/696 cropped samples to 0/696. Sampling covers the operation and up to 200 ms of response; the last user click has only 44 ms of remaining source footage.
- C2 continuity, 240 Hz crop bounds, random/reverse seek, click-array cache invalidation, exact preview/export pixels, trim, cancellation, actual editor actions and window restoration regressions pass.
- Final installed executable: `cef7397539e678636152802fb0cb62a0119e1457251ff51238d6e1ecd0c58a87`, matching dist, strict signature verification passes. Existing screen-recording permission was reassociated and became ready after restarting XShot as requested by System Settings, without a new Touch ID challenge.
- Actual recording completion returned to the new Studio unobstructed. A confirmed dedicated window capture is 1800×1176, 25.349 seconds, without a recording notice (`演示 2026-10-26 00.34.43-260510.xshotdemo`). The custom fixture received automated coordinate events, but these were not observed by the cross-app mouse monitor; this UI run is not physical rapid-click acceptance. The separate 9/9 tests exercise the real recording sink with controlled event timestamps. Earlier attempts that combined popup selection and start in one automation batch did not wait for selection to settle and captured the first source; they are excluded from dedicated-window evidence.
- A 4.26-second, 256-frame/60 fps excerpt of the user's actual source shows the revised camera around the affected operations, at `artifacts/rapid-click-qa/responsive-after.mp4`. Source video and metadata hashes are unchanged. The test fixture has exited; the user's newly opened screenshot was left untouched.

Task-local reports are under `artifacts/camera-responsiveness/`, `artifacts/workspace-window-checks/` and `artifacts/rapid-click-qa/`. Original projects written before event preservation cannot recover input events that were never stored.
