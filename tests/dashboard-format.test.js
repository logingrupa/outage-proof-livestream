// dashboard-format.test.js
// Unit tests for dashboard/format.js's pure helpers (DASH-05/06/07). node is a
// DEV/test-only tool here -- it is NOT a church runtime dependency and does not
// touch the shipped plain-HTML/JS dashboard (no build step, no bundler); the
// browser loads dashboard/format.js directly as a plain <script>. Run via:
//   node --test tests/dashboard-format.test.js

const test = require("node:test");
const assert = require("node:assert");
const {
  formatMegabytes,
  computeEffectiveCatchUp,
  formatSessionOutcome,
  formatHumanDuration,
  computeDelayTrend,
  updateDelayTrendState,
  isSessionRestart,
  resolveProbeDisplayState,
  computeLinearScale,
  invertLinearScale,
  computeNiceAxisMax,
  selectSamplesInWindow,
  findNearestSampleIndex,
  buildMonotonePathD,
  updateChartBufferState,
  buildHeroChart,
  deriveSessionKey,
  buildDashboardHistoryPayload,
  serializeDashboardHistory,
  parseDashboardHistory,
  pruneStaleSamples,
  restoreDashboardHistory,
} = require("../dashboard/format.js");

test("formatMegabytes: 4400000000 bytes -> bytes / 1048576, one decimal", () => {
  // 4400000000 / 1048576 = 4196.21... -> "4196.2 MB" (bytes/1048576 per the
  // contract's own formula; illustrative examples elsewhere use round numbers,
  // this asserts the actual division this function performs).
  assert.strictEqual(formatMegabytes(4400000000), "4196.2 MB");
});

test("formatMegabytes: 0 -> '0.0 MB'", () => {
  assert.strictEqual(formatMegabytes(0), "0.0 MB");
});

test("formatMegabytes: null -> '—'", () => {
  assert.strictEqual(formatMegabytes(null), "—");
});

test("formatMegabytes: undefined -> '—'", () => {
  assert.strictEqual(formatMegabytes(undefined), "—");
});

test("formatMegabytes: NaN -> '—'", () => {
  assert.strictEqual(formatMegabytes(NaN), "—");
});

test("formatMegabytes: Infinity -> '—'", () => {
  assert.strictEqual(formatMegabytes(Infinity), "—");
});

test("formatMegabytes: a small value keeps one decimal", () => {
  assert.strictEqual(formatMegabytes(1048576), "1.0 MB");
});

test("formatMegabytes: negative preserves sign", () => {
  assert.strictEqual(formatMegabytes(-1048576), "-1.0 MB");
});

test("computeEffectiveCatchUp: (26e6, 22e6) ~= 1.18 within tolerance", () => {
  const result = computeEffectiveCatchUp(26e6, 22e6);
  assert.ok(Math.abs(result - 1.1818181818) < 0.001);
});

test("computeEffectiveCatchUp: record=0 -> null (never divide-by-zero)", () => {
  assert.strictEqual(computeEffectiveCatchUp(26e6, 0), null);
});

test("computeEffectiveCatchUp: record negative -> null", () => {
  assert.strictEqual(computeEffectiveCatchUp(26e6, -5), null);
});

test("computeEffectiveCatchUp: record null -> null", () => {
  assert.strictEqual(computeEffectiveCatchUp(26e6, null), null);
});

test("computeEffectiveCatchUp: send null -> null", () => {
  assert.strictEqual(computeEffectiveCatchUp(null, 22e6), null);
});

test("computeEffectiveCatchUp: non-finite send -> null (never Infinity/NaN out)", () => {
  assert.strictEqual(computeEffectiveCatchUp(Infinity, 22e6), null);
});

// formatSessionOutcome (260718-epo): calm honest clean-finish copy.
test("formatSessionOutcome: undelivered=0 -> the plain everything-sent line", () => {
  assert.strictEqual(
    formatSessionOutcome(300, 0),
    "Service finished — recording ended, everything sent, ready for next service."
  );
});

test("formatSessionOutcome: undelivered=null -> the plain everything-sent line", () => {
  assert.strictEqual(
    formatSessionOutcome(300, null),
    "Service finished — recording ended, everything sent, ready for next service."
  );
});

test("formatSessionOutcome: undelivered=undefined -> the plain everything-sent line", () => {
  assert.strictEqual(
    formatSessionOutcome(300, undefined),
    "Service finished — recording ended, everything sent, ready for next service."
  );
});

test("formatSessionOutcome: undelivered > 0 -> an honest 'N not delivered' line using formatMegabytes' own formula", () => {
  // 2097152 bytes / 1048576 = 2.0 MB
  assert.strictEqual(
    formatSessionOutcome(300, 2097152),
    "Service finished — 2.0 MB not delivered (relay dropped at end). Everything else was sent."
  );
});

test("formatSessionOutcome: undelivered negative -> the plain everything-sent line (never a negative undelivered claim)", () => {
  assert.strictEqual(
    formatSessionOutcome(300, -5),
    "Service finished — recording ended, everything sent, ready for next service."
  );
});

test("formatSessionOutcome: undelivered=NaN -> the plain everything-sent line", () => {
  assert.strictEqual(
    formatSessionOutcome(300, NaN),
    "Service finished — recording ended, everything sent, ready for next service."
  );
});

test("formatSessionOutcome: undelivered=Infinity -> the plain everything-sent line (never a fabricated total)", () => {
  assert.strictEqual(
    formatSessionOutcome(300, Infinity),
    "Service finished — recording ended, everything sent, ready for next service."
  );
});

test("formatSessionOutcome: duration null/NaN/Infinity does not affect the returned copy (duration is rendered separately by the caller)", () => {
  assert.strictEqual(
    formatSessionOutcome(null, 0),
    "Service finished — recording ended, everything sent, ready for next service."
  );
  assert.strictEqual(
    formatSessionOutcome(NaN, 2097152),
    "Service finished — 2.0 MB not delivered (relay dropped at end). Everything else was sent."
  );
  assert.strictEqual(
    formatSessionOutcome(Infinity, 0),
    "Service finished — recording ended, everything sent, ready for next service."
  );
});

// formatHumanDuration (260719-fmu): human-readable delay/uptime/age readouts for
// non-technical operators watching the dashboard live during a church service.
test("formatHumanDuration: 12 -> '12s'", () => {
  assert.strictEqual(formatHumanDuration(12), "12s");
});

test("formatHumanDuration: 0 -> '0s'", () => {
  assert.strictEqual(formatHumanDuration(0), "0s");
});

test("formatHumanDuration: 59 -> '59s'", () => {
  assert.strictEqual(formatHumanDuration(59), "59s");
});

test("formatHumanDuration: 60 -> '1m 0s'", () => {
  assert.strictEqual(formatHumanDuration(60), "1m 0s");
});

test("formatHumanDuration: 171 -> '2m 51s'", () => {
  assert.strictEqual(formatHumanDuration(171), "2m 51s");
});

test("formatHumanDuration: 3599 -> '59m 59s'", () => {
  assert.strictEqual(formatHumanDuration(3599), "59m 59s");
});

test("formatHumanDuration: 3600 -> '1h 00m' (zero-padded minutes, no seconds)", () => {
  assert.strictEqual(formatHumanDuration(3600), "1h 00m");
});

test("formatHumanDuration: 3840 -> '1h 04m'", () => {
  assert.strictEqual(formatHumanDuration(3840), "1h 04m");
});

test("formatHumanDuration: 7384 -> '2h 03m'", () => {
  assert.strictEqual(formatHumanDuration(7384), "2h 03m");
});

test("formatHumanDuration: 12.4 -> '12s' (rounds down)", () => {
  assert.strictEqual(formatHumanDuration(12.4), "12s");
});

test("formatHumanDuration: 59.6 -> rounds up to 60 -> '1m 0s'", () => {
  assert.strictEqual(formatHumanDuration(59.6), "1m 0s");
});

test("formatHumanDuration: 173.3 -> rounds to 173 -> '2m 53s'", () => {
  assert.strictEqual(formatHumanDuration(173.3), "2m 53s");
});

test("formatHumanDuration: -5 -> clamps to 0 -> '0s' (never a negative duration)", () => {
  assert.strictEqual(formatHumanDuration(-5), "0s");
});

test("formatHumanDuration: null -> '—'", () => {
  assert.strictEqual(formatHumanDuration(null), "—");
});

test("formatHumanDuration: undefined -> '—'", () => {
  assert.strictEqual(formatHumanDuration(undefined), "—");
});

test("formatHumanDuration: NaN -> '—'", () => {
  assert.strictEqual(formatHumanDuration(NaN), "—");
});

test("formatHumanDuration: Infinity -> '—'", () => {
  assert.strictEqual(formatHumanDuration(Infinity), "—");
});

// computeDelayTrend (260719-fmu-04): hero "did delay get better/worse in the
// last ~60s" summary. Pure -- samples/nowSeconds/windowSeconds are all passed
// in, nothing reads a real clock.
test("computeDelayTrend: empty samples -> measuring", () => {
  assert.deepStrictEqual(computeDelayTrend([], 1000, 60), { status: "measuring", text: "measuring…" });
});

test("computeDelayTrend: not an array -> measuring", () => {
  assert.deepStrictEqual(computeDelayTrend(null, 1000, 60), { status: "measuring", text: "measuring…" });
});

test("computeDelayTrend: samples span less than the window -> measuring", () => {
  const samples = [
    { t: 970, delay: 40 },
    { t: 1000, delay: 30 },
  ];
  // oldest sample is only 30s old, window is 60s -- not enough history yet.
  assert.deepStrictEqual(computeDelayTrend(samples, 1000, 60), { status: "measuring", text: "measuring…" });
});

test("computeDelayTrend: delay shrank by 18s over the window -> 'caught up 18s in last minute', improving", () => {
  const samples = [
    { t: 940, delay: 48 },
    { t: 970, delay: 40 },
    { t: 1000, delay: 30 },
  ];
  // closest-to-60s-ago sample is t=940 (delay 48); newest is t=1000 (delay 30).
  assert.deepStrictEqual(computeDelayTrend(samples, 1000, 60), {
    status: "improving",
    text: "caught up 18s in last minute",
  });
});

test("computeDelayTrend: delay grew by 12s over the window -> 'fell behind 12s in last minute', worsening", () => {
  const samples = [
    { t: 940, delay: 20 },
    { t: 1000, delay: 32 },
  ];
  assert.deepStrictEqual(computeDelayTrend(samples, 1000, 60), {
    status: "worsening",
    text: "fell behind 12s in last minute",
  });
});

test("computeDelayTrend: delta under the flat threshold (default 2s) -> 'holding steady', steady", () => {
  const samples = [
    { t: 940, delay: 30 },
    { t: 1000, delay: 31.5 },
  ];
  assert.deepStrictEqual(computeDelayTrend(samples, 1000, 60), { status: "steady", text: "holding steady" });
});

test("computeDelayTrend: delta exactly at the flat threshold boundary counts as steady (< not <=)", () => {
  const samples = [
    { t: 940, delay: 30 },
    { t: 1000, delay: 32 },
  ];
  // delta magnitude is exactly 2, the default flatThreshold -- Math.abs(delta) < flatThreshold is false at
  // equality, so this falls through to a real (small) worsening trend, not steady.
  assert.deepStrictEqual(computeDelayTrend(samples, 1000, 60), {
    status: "worsening",
    text: "fell behind 2s in last minute",
  });
});

test("computeDelayTrend: non-finite delay samples are filtered out, not treated as zero", () => {
  const samples = [
    { t: 900, delay: NaN }, // filtered -- the remaining oldest usable sample (t=940) still covers a full 60s
    { t: 940, delay: 50 },
    { t: 1000, delay: 30 },
  ];
  assert.deepStrictEqual(computeDelayTrend(samples, 1000, 60), {
    status: "improving",
    text: "caught up 20s in last minute",
  });
});

test("computeDelayTrend: samples with non-finite t are filtered out", () => {
  const samples = [
    { t: NaN, delay: 999 },
    { t: 940, delay: 50 },
    { t: 1000, delay: 30 },
  ];
  assert.deepStrictEqual(computeDelayTrend(samples, 1000, 60), {
    status: "improving",
    text: "caught up 20s in last minute",
  });
});

test("computeDelayTrend: all samples non-finite -> measuring (never a fabricated trend)", () => {
  const samples = [
    { t: 940, delay: NaN },
    { t: 1000, delay: NaN },
  ];
  assert.deepStrictEqual(computeDelayTrend(samples, 1000, 60), { status: "measuring", text: "measuring…" });
});

test("computeDelayTrend: windowSeconds omitted defaults to 60", () => {
  const samples = [
    { t: 940, delay: 48 },
    { t: 1000, delay: 30 },
  ];
  assert.deepStrictEqual(computeDelayTrend(samples, 1000), {
    status: "improving",
    text: "caught up 18s in last minute",
  });
});

test("computeDelayTrend: picks the sample CLOSEST to windowSeconds-ago, not the very oldest", () => {
  const samples = [
    { t: 900, delay: 90 }, // 100s ago -- too far, not the closest-to-60s-ago point
    { t: 941, delay: 48 }, // 59s ago -- closest to the 60s target
    { t: 1000, delay: 30 },
  ];
  assert.deepStrictEqual(computeDelayTrend(samples, 1000, 60), {
    status: "improving",
    text: "caught up 18s in last minute",
  });
});

test("computeDelayTrend: large delta formats via formatHumanDuration (minutes shape)", () => {
  const samples = [
    { t: 940, delay: 200 },
    { t: 1000, delay: 30 },
  ];
  assert.deepStrictEqual(computeDelayTrend(samples, 1000, 60), {
    status: "improving",
    text: "caught up 2m 50s in last minute",
  });
});

// resolveProbeDisplayState (260719-fmu-05): a probe reporting 'down' while the
// stream itself is confirmed healthy (Streaming + fresh main stats) should
// read calm/neutral ("unverified"), not alarming -- every other combination
// keeps the existing status-pill mapping untouched.
test("resolveProbeDisplayState: probe down + stream Streaming + fresh -> unverified, neutral, plain-language message", () => {
  assert.deepStrictEqual(resolveProbeDisplayState("down", "Streaming", false), {
    pillClass: "state-unknown",
    pillText: "unverified",
    message:
      "Probe can't reach the relay to verify it — the stream itself is flowing normally, so this is likely a probe-path issue, not an outage.",
  });
});

test("resolveProbeDisplayState: probe down + stream Streaming + mainStatsIsStale omitted (undefined, not true) -> still unverified", () => {
  // mainStatsIsStale !== true is the guard, so an omitted/undefined value
  // (falsy but not the literal `true`) still counts as "not stale".
  const result = resolveProbeDisplayState("down", "Streaming", undefined);
  assert.strictEqual(result.pillText, "unverified");
});

test("resolveProbeDisplayState: probe down + stream NOT Streaming -> keeps the loud 'down' mapping unchanged", () => {
  assert.deepStrictEqual(resolveProbeDisplayState("down", "Reconnecting", false), {
    pillClass: "state-idle",
    pillText: "down",
    message: null,
  });
});

test("resolveProbeDisplayState: probe down + main stats stale -> keeps the loud 'down' mapping unchanged (stream not confirmed healthy)", () => {
  assert.deepStrictEqual(resolveProbeDisplayState("down", "Streaming", true), {
    pillClass: "state-idle",
    pillText: "down",
    message: null,
  });
});

test("resolveProbeDisplayState: probe ok + stream Streaming -> unchanged 'ok' mapping (override only applies to 'down')", () => {
  assert.deepStrictEqual(resolveProbeDisplayState("ok", "Streaming", false), {
    pillClass: "state-streaming",
    pillText: "ok",
    message: null,
  });
});

test("resolveProbeDisplayState: probe degraded + stream Streaming -> unchanged 'degraded' mapping (override only applies to 'down')", () => {
  assert.deepStrictEqual(resolveProbeDisplayState("degraded", "Streaming", false), {
    pillClass: "state-reconnecting",
    pillText: "degraded",
    message: null,
  });
});

test("resolveProbeDisplayState: probe unknown status -> 'unknown' mapping", () => {
  assert.deepStrictEqual(resolveProbeDisplayState("unknown", "Streaming", false), {
    pillClass: "state-unknown",
    pillText: "unknown",
    message: null,
  });
});

test("resolveProbeDisplayState: probeStatus null/empty -> falls back to 'unknown' text and class", () => {
  assert.deepStrictEqual(resolveProbeDisplayState(null, "Idle", false), {
    pillClass: "state-unknown",
    pillText: "unknown",
    message: null,
  });
});

test("resolveProbeDisplayState: an unrecognized probeStatus string -> 'state-unknown' pillClass, raw text preserved", () => {
  assert.deepStrictEqual(resolveProbeDisplayState("weird-status", "Streaming", false), {
    pillClass: "state-unknown",
    pillText: "weird-status",
    message: null,
  });
});

// updateDelayTrendState (260719-fmu-06, bugfix): the pure ring-buffer
// collection + reset policy behind the hero delay trend. Extracted from
// app.js specifically so the real-world "stuck on measuring…" bug is
// reproducible here -- app.js itself cannot be `require`d under node --test
// (it reads `window` unconditionally at load time), so this was previously
// untestable, which is exactly where the bug hid.

function simulateTicks(tickCount, buildViewModel, windowSeconds) {
  // Mirrors app.js's real 1-second poll cadence (POLL_INTERVAL_MS = 1000):
  // tick i happens at wall-clock second i. Returns the FINAL {state, trend}
  // after all ticks, using the SAME sequence of calls app.js's
  // updateDelayTrendSamples()/renderDelayTrend() would make each poll.
  let state = { samples: [], previousSessionDurationSeconds: null };
  let trend = null;
  for (let i = 0; i < tickCount; i += 1) {
    const nowSeconds = i;
    const viewModel = buildViewModel(i);
    state = updateDelayTrendState(state, viewModel, nowSeconds, windowSeconds);
    trend = computeDelayTrend(state.samples, nowSeconds, windowSeconds);
  }
  return { state, trend };
}

test("updateDelayTrendState: fresh state (null) + Streaming + finite delay -> one sample pushed", () => {
  const result = updateDelayTrendState(null, { ConnectionState: "Streaming", DelaySecondsBehindLive: 42, SessionDurationSeconds: 10 }, 1000, 60);
  assert.deepStrictEqual(result.samples, [{ t: 1000, delay: 42 }]);
  assert.strictEqual(result.previousSessionDurationSeconds, 10);
});

test("updateDelayTrendState: 65 ticks of sustained Streaming at real 1s poll cadence -> trend leaves 'measuring' (baseline, no blips)", () => {
  const { trend } = simulateTicks(
    65,
    (i) => ({ ConnectionState: "Streaming", DelaySecondsBehindLive: 60 - i * 0.5, SessionDurationSeconds: 100 + i }),
    60
  );
  assert.notStrictEqual(trend.status, "measuring");
});

test("updateDelayTrendState: THE REPORTED BUG, reproduced and fixed -- single-tick Reconnecting blips every ~20s must NOT wipe 60s of history", () => {
  // Reproduces the live operator report: ConnectionState flickers to
  // 'Reconnecting' for exactly one poll every 20 ticks (easy for a human to
  // miss glancing at the pill, but enough to nuke a naive per-poll reset).
  // Under the OLD buggy policy (any non-Streaming poll => samples = []),
  // this sequence never accumulates 60s of history because a blip lands
  // roughly every 20s, well under the 60s window -- computeDelayTrend would
  // stay stuck on "measuring…" forever. Under the fixed policy (a blip only
  // PAUSES collection, it does not wipe), history keeps accumulating across
  // the blips and the trend correctly leaves "measuring".
  const { trend, state } = simulateTicks(
    65,
    (i) => {
      const isBlip = i > 0 && i % 20 === 0;
      return {
        ConnectionState: isBlip ? "Reconnecting" : "Streaming",
        DelaySecondsBehindLive: isBlip ? null : 60 - i * 0.5,
        SessionDurationSeconds: 100 + i,
      };
    },
    60
  );
  assert.notStrictEqual(trend.status, "measuring", "trend must recover despite periodic single-tick blips");
  // 65 ticks, blips at i=20,40,60 (3 blips) -> at most 62 usable samples pushed.
  assert.ok(state.samples.length >= 60, "history must keep accumulating across blips, not reset each time");
});

test("updateDelayTrendState: a single non-Streaming poll pauses collection but does NOT wipe existing samples", () => {
  let state = updateDelayTrendState(null, { ConnectionState: "Streaming", DelaySecondsBehindLive: 50, SessionDurationSeconds: 10 }, 0, 60);
  state = updateDelayTrendState(state, { ConnectionState: "Streaming", DelaySecondsBehindLive: 49, SessionDurationSeconds: 11 }, 1, 60);
  // A one-tick Reconnecting blip -- no sample pushed, but the two prior samples survive.
  state = updateDelayTrendState(state, { ConnectionState: "Reconnecting", DelaySecondsBehindLive: null, SessionDurationSeconds: 11 }, 2, 60);
  assert.deepStrictEqual(state.samples, [
    { t: 0, delay: 50 },
    { t: 1, delay: 49 },
  ]);
});

test("updateDelayTrendState: SessionDurationSeconds drop (>1s) -- a genuine session restart -- wipes the buffer", () => {
  let state = updateDelayTrendState(null, { ConnectionState: "Streaming", DelaySecondsBehindLive: 50, SessionDurationSeconds: 100 }, 0, 60);
  state = updateDelayTrendState(state, { ConnectionState: "Streaming", DelaySecondsBehindLive: 49, SessionDurationSeconds: 101 }, 1, 60);
  assert.strictEqual(state.samples.length, 2);
  // A brand-new session starts (sessionStartEpochSeconds reset) -- SessionDurationSeconds drops hard.
  state = updateDelayTrendState(state, { ConnectionState: "Streaming", DelaySecondsBehindLive: 5, SessionDurationSeconds: 2 }, 2, 60);
  assert.deepStrictEqual(state.samples, [{ t: 2, delay: 5 }]);
  assert.strictEqual(state.previousSessionDurationSeconds, 2);
});

test("updateDelayTrendState: a <=1s SessionDurationSeconds dip is jitter tolerance, NOT a restart -- buffer survives", () => {
  let state = updateDelayTrendState(null, { ConnectionState: "Streaming", DelaySecondsBehindLive: 50, SessionDurationSeconds: 100.6 }, 0, 60);
  // 100.2 is only a 0.4s dip from 100.6 -- within the 1s jitter tolerance, not a real restart.
  state = updateDelayTrendState(state, { ConnectionState: "Streaming", DelaySecondsBehindLive: 49, SessionDurationSeconds: 100.2 }, 1, 60);
  assert.strictEqual(state.samples.length, 2);
});

test("updateDelayTrendState: a sustained non-Streaming stretch longer than window+margin drains the buffer via pruning alone", () => {
  let state = updateDelayTrendState(null, { ConnectionState: "Streaming", DelaySecondsBehindLive: 50, SessionDurationSeconds: 10 }, 0, 60);
  assert.strictEqual(state.samples.length, 1);
  // 75 ticks of Reconnecting (> windowSeconds(60) + margin(10) = 70) -- no new
  // pushes, and the one old sample eventually prunes away on its own.
  for (let t = 1; t <= 75; t += 1) {
    state = updateDelayTrendState(state, { ConnectionState: "Reconnecting", DelaySecondsBehindLive: null, SessionDurationSeconds: 10 }, t, 60);
  }
  assert.deepStrictEqual(state.samples, []);
});

test("updateDelayTrendState: null/undefined viewModel does not throw and pauses collection", () => {
  const state = updateDelayTrendState(null, null, 0, 60);
  assert.deepStrictEqual(state.samples, []);
  assert.strictEqual(state.previousSessionDurationSeconds, null);
});

test("updateDelayTrendState: non-finite nowSeconds does not throw and skips pruning/pushing", () => {
  const state = updateDelayTrendState(null, { ConnectionState: "Streaming", DelaySecondsBehindLive: 50 }, NaN, 60);
  assert.deepStrictEqual(state.samples, []);
});

// updateDelayTrendState: Draining widening (15-03 Task 1, CHUR-03) -- the hero
// delay trend must keep updating throughout the end-of-service drain instead
// of freezing the instant ConnectionState flips to 'Draining'.
test("updateDelayTrendState: Draining + finite delay -> collects a sample (trend keeps updating into drain)", () => {
  const result = updateDelayTrendState(
    null,
    { ConnectionState: "Draining", DelaySecondsBehindLive: 42, SessionDurationSeconds: 10 },
    1000,
    60
  );
  assert.deepStrictEqual(result.samples, [{ t: 1000, delay: 42 }]);
});

test("updateDelayTrendState: refuses to collect for Idle/Unknown/Finished (never charts a non-live/non-draining state)", () => {
  ["Idle", "Unknown", "Finished"].forEach((connectionState) => {
    const result = updateDelayTrendState(
      null,
      { ConnectionState: connectionState, DelaySecondsBehindLive: 42, SessionDurationSeconds: 10 },
      1000,
      60
    );
    assert.deepStrictEqual(result.samples, [], connectionState + " must not collect a sample");
  });
});

// ---------- Hero mini-chart (260719-fmu-07) ----------

// isSessionRestart (shared extraction backing both updateDelayTrendState and updateChartBufferState).
test("isSessionRestart: a >1s drop is a restart", () => {
  assert.strictEqual(isSessionRestart(2, 100), true);
});

test("isSessionRestart: a <=1s dip is jitter, not a restart", () => {
  assert.strictEqual(isSessionRestart(99.5, 100), false);
});

test("isSessionRestart: an increase is never a restart", () => {
  assert.strictEqual(isSessionRestart(101, 100), false);
});

test("isSessionRestart: non-numeric inputs never signal a restart", () => {
  assert.strictEqual(isSessionRestart(null, 100), false);
  assert.strictEqual(isSessionRestart(5, null), false);
  assert.strictEqual(isSessionRestart(NaN, 100), false);
});

// computeLinearScale
test("computeLinearScale: maps domain [0,10] to range [0,100], midpoint", () => {
  assert.strictEqual(computeLinearScale(5, 0, 10, 0, 100), 50);
});

test("computeLinearScale: INVERTED range (y-axis case, rangeMin > rangeMax) maps correctly", () => {
  // Domain 0 -> the bottom pixel (100), domain 10 -> the top pixel (0) --
  // exactly the SVG y-axis convention this chart relies on.
  assert.strictEqual(computeLinearScale(0, 0, 10, 100, 0), 100);
  assert.strictEqual(computeLinearScale(10, 0, 10, 100, 0), 0);
  assert.strictEqual(computeLinearScale(5, 0, 10, 100, 0), 50);
});

test("computeLinearScale: domainMax === domainMin returns rangeMin (never divides by zero)", () => {
  assert.strictEqual(computeLinearScale(5, 10, 10, 0, 100), 0);
});

test("computeLinearScale: non-finite inputs return rangeMin, never NaN", () => {
  assert.strictEqual(computeLinearScale(NaN, 0, 10, 0, 100), 0);
  assert.strictEqual(computeLinearScale(5, 0, 10, 0, Infinity), 0);
});

// invertLinearScale
test("invertLinearScale: inverse of computeLinearScale on a plain range", () => {
  assert.strictEqual(invertLinearScale(50, 0, 10, 0, 100), 5);
});

test("invertLinearScale: inverse on an INVERTED (y-axis) range", () => {
  assert.strictEqual(invertLinearScale(100, 0, 10, 100, 0), 0);
  assert.strictEqual(invertLinearScale(0, 0, 10, 100, 0), 10);
});

test("invertLinearScale: rangeMax === rangeMin returns domainMin (never divides by zero)", () => {
  assert.strictEqual(invertLinearScale(50, 0, 10, 5, 5), 0);
});

test("invertLinearScale: non-finite inputs return domainMin, never NaN", () => {
  assert.strictEqual(invertLinearScale(NaN, 0, 10, 0, 100), 0);
});

// computeNiceAxisMax
test("computeNiceAxisMax: 27.4 -> 50 (1/2/5/10 step scheme -- the next nice number above 27.4 is 50, not 30)", () => {
  assert.strictEqual(computeNiceAxisMax(27.4, 1), 50);
});

test("computeNiceAxisMax: 45 -> 50", () => {
  assert.strictEqual(computeNiceAxisMax(45, 1), 50);
});

test("computeNiceAxisMax: 8 -> 10", () => {
  assert.strictEqual(computeNiceAxisMax(8, 1), 10);
});

test("computeNiceAxisMax: 100 -> 100 (already nice)", () => {
  assert.strictEqual(computeNiceAxisMax(100, 1), 100);
});

test("computeNiceAxisMax: below the minimum ceiling -> the ceiling itself, never a collapsed near-zero axis", () => {
  assert.strictEqual(computeNiceAxisMax(0.3, 1), 1);
  assert.strictEqual(computeNiceAxisMax(0, 5), 5);
});

test("computeNiceAxisMax: negative/NaN maxValue -> falls back to the minimum ceiling", () => {
  assert.strictEqual(computeNiceAxisMax(-5, 1), 1);
  assert.strictEqual(computeNiceAxisMax(NaN, 1), 1);
});

test("computeNiceAxisMax: minimumCeiling omitted defaults to 1", () => {
  assert.strictEqual(computeNiceAxisMax(0, undefined), 1);
});

// selectSamplesInWindow
test("selectSamplesInWindow: filters to [now-window, now], default 'value' key", () => {
  const samples = [
    { t: 0, value: 1 },
    { t: 50, value: 2 },
    { t: 70, value: 3 },
  ];
  assert.deepStrictEqual(selectSamplesInWindow(samples, 70, 60), [
    { t: 50, value: 2 },
    { t: 70, value: 3 },
  ]);
});

test("selectSamplesInWindow: custom valueKey pulls from a composite chart-buffer sample and drops nulls", () => {
  const samples = [
    { t: 10, sendMbit: 5 },
    { t: 20, sendMbit: null },
    { t: 30, sendMbit: 8 },
  ];
  assert.deepStrictEqual(selectSamplesInWindow(samples, 30, 60, "sendMbit"), [
    { t: 10, value: 5 },
    { t: 30, value: 8 },
  ]);
});

test("selectSamplesInWindow: sorts ascending by t even if the input is out of order", () => {
  const samples = [
    { t: 30, value: 3 },
    { t: 10, value: 1 },
    { t: 20, value: 2 },
  ];
  assert.deepStrictEqual(selectSamplesInWindow(samples, 30, 60), [
    { t: 10, value: 1 },
    { t: 20, value: 2 },
    { t: 30, value: 3 },
  ]);
});

test("selectSamplesInWindow: non-array samples -> []", () => {
  assert.deepStrictEqual(selectSamplesInWindow(null, 30, 60), []);
});

test("selectSamplesInWindow: non-finite nowSeconds -> []", () => {
  assert.deepStrictEqual(selectSamplesInWindow([{ t: 0, value: 1 }], NaN, 60), []);
});

test("selectSamplesInWindow: windowSeconds omitted defaults to 300", () => {
  const samples = [
    { t: 0, value: 1 },
    { t: 250, value: 2 },
  ];
  assert.deepStrictEqual(selectSamplesInWindow(samples, 300), [
    { t: 0, value: 1 },
    { t: 250, value: 2 },
  ]);
});

// findNearestSampleIndex
test("findNearestSampleIndex: picks the closest-by-time sample", () => {
  const samples = [{ t: 0 }, { t: 10 }, { t: 20 }];
  assert.strictEqual(findNearestSampleIndex(samples, 12), 1);
});

test("findNearestSampleIndex: empty array -> -1", () => {
  assert.strictEqual(findNearestSampleIndex([], 12), -1);
});

test("findNearestSampleIndex: non-finite targetT -> -1", () => {
  assert.strictEqual(findNearestSampleIndex([{ t: 0 }], NaN), -1);
});

test("findNearestSampleIndex: an exact tie keeps the earlier index", () => {
  const samples = [{ t: 0 }, { t: 20 }];
  assert.strictEqual(findNearestSampleIndex(samples, 10), 0);
});

// buildMonotonePathD
test("buildMonotonePathD: 0 points -> null", () => {
  assert.strictEqual(buildMonotonePathD([], 1), null);
});

test("buildMonotonePathD: 1 point -> a single M (a dot, no visible stroke)", () => {
  assert.strictEqual(buildMonotonePathD([[5, 5]], 1), "M5,5");
});

test("buildMonotonePathD: 2 points -> a plain straight line", () => {
  assert.strictEqual(buildMonotonePathD([[0, 0], [10, 10]], 1), "M0,0L10,10");
});

test("buildMonotonePathD: 3 collinear points reduce EXACTLY to the straight line (control points land on the line)", () => {
  // For perfectly collinear points the Fritsch-Carlson tangent at the
  // interior point equals the shared slope (1), so the cubic's control
  // points fall exactly on y=x -- a precise, hand-verifiable property.
  const d = buildMonotonePathD([[0, 0], [10, 10], [20, 20]], 2);
  assert.strictEqual(d, "M0,0C3.33,3.33 6.67,6.67 10,10C13.33,13.33 16.67,16.67 20,20");
});

test("buildMonotonePathD: n points produce exactly n-1 cubic segments, starting at the first point and ending at the last", () => {
  const points = [[0, 10], [10, 0], [20, 15], [30, 5]];
  const d = buildMonotonePathD(points, 1);
  assert.ok(d.startsWith("M0,10"), "must start with an M at the first point");
  const segmentCount = (d.match(/C/g) || []).length;
  assert.strictEqual(segmentCount, points.length - 1);
  // The path must end exactly at the last point's coordinates.
  assert.ok(d.endsWith("30,5"), "must end exactly at the last point");
});

test("buildMonotonePathD: precision controls decimal rounding", () => {
  const d0 = buildMonotonePathD([[0, 0], [3, 7]], 0);
  assert.strictEqual(d0, "M0,0L3,7");
});

// updateChartBufferState
test("updateChartBufferState: Streaming + all-finite metrics -> pushes one composite sample", () => {
  const state = updateChartBufferState(
    null,
    { ConnectionState: "Streaming", SendBytesPerSecond: 1250000, RecordBytesPerSecond: 1000000, DelaySecondsBehindLive: 12, SessionDurationSeconds: 5 },
    1000,
    300
  );
  assert.strictEqual(state.samples.length, 1);
  assert.strictEqual(state.samples[0].t, 1000);
  assert.strictEqual(state.samples[0].sendMbit, 10); // 1,250,000 * 8 / 1e6 = 10 Mbit/s
  assert.strictEqual(state.samples[0].recordMbit, 8); // 1,000,000 * 8 / 1e6 = 8 Mbit/s
  assert.strictEqual(state.samples[0].delaySeconds, 12);
});

test("updateChartBufferState: a metric that's individually non-finite is stored as null (a gap in that one series), not zero", () => {
  const state = updateChartBufferState(
    null,
    { ConnectionState: "Streaming", SendBytesPerSecond: null, RecordBytesPerSecond: 1000000, DelaySecondsBehindLive: 12 },
    1000,
    300
  );
  assert.strictEqual(state.samples[0].sendMbit, null);
  assert.strictEqual(state.samples[0].recordMbit, 8);
});

test("updateChartBufferState: ALL metrics non-finite -> no point pushed at all (never an all-null point)", () => {
  const state = updateChartBufferState(
    null,
    { ConnectionState: "Streaming", SendBytesPerSecond: null, RecordBytesPerSecond: null, DelaySecondsBehindLive: null },
    1000,
    300
  );
  assert.deepStrictEqual(state.samples, []);
});

test("updateChartBufferState: a single non-Streaming poll pauses collection, does not wipe", () => {
  let state = updateChartBufferState(null, { ConnectionState: "Streaming", SendBytesPerSecond: 1e6, RecordBytesPerSecond: 1e6, DelaySecondsBehindLive: 5, SessionDurationSeconds: 5 }, 0, 300);
  state = updateChartBufferState(state, { ConnectionState: "Reconnecting", DelaySecondsBehindLive: null, SessionDurationSeconds: 5 }, 1, 300);
  assert.strictEqual(state.samples.length, 1);
});

test("updateChartBufferState: a genuine session restart wipes the buffer (reuses isSessionRestart)", () => {
  let state = updateChartBufferState(null, { ConnectionState: "Streaming", SendBytesPerSecond: 1e6, RecordBytesPerSecond: 1e6, DelaySecondsBehindLive: 5, SessionDurationSeconds: 100 }, 0, 300);
  state = updateChartBufferState(state, { ConnectionState: "Streaming", SendBytesPerSecond: 1e6, RecordBytesPerSecond: 1e6, DelaySecondsBehindLive: 1, SessionDurationSeconds: 3 }, 1, 300);
  assert.strictEqual(state.samples.length, 1);
  assert.strictEqual(state.samples[0].t, 1);
});

// updateChartBufferState: Draining widening (15-03 Task 1, CHUR-03) -- the
// hero chart's three series must keep receiving samples throughout the
// end-of-service drain, not just up to the moment Draining begins.
test("updateChartBufferState: Draining + all-finite metrics -> pushes one composite sample (chart keeps charting into drain)", () => {
  const state = updateChartBufferState(
    null,
    { ConnectionState: "Draining", SendBytesPerSecond: 1250000, RecordBytesPerSecond: 1000000, DelaySecondsBehindLive: 12, SessionDurationSeconds: 5 },
    1000,
    300
  );
  assert.strictEqual(state.samples.length, 1);
  assert.strictEqual(state.samples[0].sendMbit, 10);
  assert.strictEqual(state.samples[0].recordMbit, 8);
  assert.strictEqual(state.samples[0].delaySeconds, 12);
});

test("updateChartBufferState: Streaming still appends a sample (no regression from the Draining widening)", () => {
  const state = updateChartBufferState(
    null,
    { ConnectionState: "Streaming", SendBytesPerSecond: 1e6, RecordBytesPerSecond: 1e6, DelaySecondsBehindLive: 5, SessionDurationSeconds: 5 },
    1000,
    300
  );
  assert.strictEqual(state.samples.length, 1);
});

test("updateChartBufferState: still refuses to append for Idle/Unknown/Reconnecting/Finished", () => {
  ["Idle", "Unknown", "Reconnecting", "Finished"].forEach((connectionState) => {
    const state = updateChartBufferState(
      null,
      { ConnectionState: connectionState, SendBytesPerSecond: 1e6, RecordBytesPerSecond: 1e6, DelaySecondsBehindLive: 5, SessionDurationSeconds: 5 },
      1000,
      300
    );
    assert.deepStrictEqual(state.samples, [], connectionState + " must not append a sample");
  });
});

test("updateChartBufferState: prunes samples older than windowSeconds+10", () => {
  let state = updateChartBufferState(null, { ConnectionState: "Streaming", SendBytesPerSecond: 1e6, RecordBytesPerSecond: 1e6, DelaySecondsBehindLive: 5, SessionDurationSeconds: 5 }, 0, 60);
  state = updateChartBufferState(state, { ConnectionState: "Streaming", SendBytesPerSecond: 1e6, RecordBytesPerSecond: 1e6, DelaySecondsBehindLive: 5, SessionDurationSeconds: 76 }, 71, 60);
  // cutoff at t=71 is 71-(60+10)=1 -- the t=0 sample (< 1) is pruned away.
  assert.strictEqual(state.samples.length, 1);
  assert.strictEqual(state.samples[0].t, 71);
});

// updateChartBufferState: NIC upload series (260722-xbr/NIC-TELEMETRY-01)
test("updateChartBufferState: Streaming poll with NicUploadBps=3625000 -> nicMbit = 29 (bytes/sec * 8 / 1e6)", () => {
  const state = updateChartBufferState(
    null,
    { ConnectionState: "Streaming", SendBytesPerSecond: 1e6, RecordBytesPerSecond: 1e6, DelaySecondsBehindLive: 5, NicUploadBps: 3625000, SessionDurationSeconds: 5 },
    1000,
    300
  );
  assert.strictEqual(state.samples.length, 1);
  assert.strictEqual(state.samples[0].nicMbit, 29);
});

test("updateChartBufferState: NicUploadBps null/undefined/non-finite -> sample.nicMbit = null (no fabricated point)", () => {
  const nullCase = updateChartBufferState(
    null,
    { ConnectionState: "Streaming", SendBytesPerSecond: 1e6, RecordBytesPerSecond: 1e6, DelaySecondsBehindLive: 5, NicUploadBps: null },
    1000,
    300
  );
  assert.strictEqual(nullCase.samples[0].nicMbit, null);

  const undefinedCase = updateChartBufferState(
    null,
    { ConnectionState: "Streaming", SendBytesPerSecond: 1e6, RecordBytesPerSecond: 1e6, DelaySecondsBehindLive: 5 },
    1000,
    300
  );
  assert.strictEqual(undefinedCase.samples[0].nicMbit, null);

  const nonFiniteCase = updateChartBufferState(
    null,
    { ConnectionState: "Streaming", SendBytesPerSecond: 1e6, RecordBytesPerSecond: 1e6, DelaySecondsBehindLive: 5, NicUploadBps: NaN },
    1000,
    300
  );
  assert.strictEqual(nonFiniteCase.samples[0].nicMbit, null);
});

test("updateChartBufferState: a sample is still pushed when only nicMbit is present (nic joins the 'any series present' push condition)", () => {
  const state = updateChartBufferState(
    null,
    { ConnectionState: "Streaming", SendBytesPerSecond: null, RecordBytesPerSecond: null, DelaySecondsBehindLive: null, NicUploadBps: 1000000 },
    1000,
    300
  );
  assert.strictEqual(state.samples.length, 1);
  assert.strictEqual(state.samples[0].nicMbit, 8);
});

// buildHeroChart
test("buildHeroChart: empty buffer -> hasAnyData false, no paths anywhere (never fabricated/partial chart)", () => {
  const chart = buildHeroChart({ samples: [], nowSeconds: 1000, windowSeconds: 300 });
  assert.strictEqual(chart.hasAnyData, false);
  assert.strictEqual(chart.top.hasData, false);
  assert.strictEqual(chart.top.sendPathD, null);
  assert.strictEqual(chart.top.recordPathD, null);
  assert.strictEqual(chart.top.sendEndLabel, null);
  assert.strictEqual(chart.top.recordEndLabel, null);
  assert.strictEqual(chart.bottom.hasData, false);
  assert.strictEqual(chart.bottom.delayPathD, null);
});

test("buildHeroChart: a populated buffer produces real paths, end labels, and gridline shapes for both panels", () => {
  const samples = [];
  for (let i = 0; i <= 60; i += 1) {
    samples.push({ t: i, sendMbit: 20 + i * 0.1, recordMbit: 18 + i * 0.1, delaySeconds: 10 - i * 0.05 });
  }
  const chart = buildHeroChart({
    samples: samples,
    nowSeconds: 60,
    windowSeconds: 300,
    topWidth: 600,
    topHeight: 90,
    bottomWidth: 600,
    bottomHeight: 30,
  });

  assert.strictEqual(chart.hasAnyData, true);

  assert.strictEqual(chart.top.hasData, true);
  assert.ok(typeof chart.top.sendPathD === "string" && chart.top.sendPathD.startsWith("M"));
  assert.ok(typeof chart.top.recordPathD === "string" && chart.top.recordPathD.startsWith("M"));
  assert.strictEqual(chart.top.sendAreaPathD, undefined, "lines only (260719-fmu-08) -- no area-fill field on the output");
  assert.deepStrictEqual(chart.top.sendEndLabel.text, "send");
  assert.deepStrictEqual(chart.top.recordEndLabel.text, "record");
  // Direct end labels sit at the RIGHTMOST plotted point (the most recent sample).
  assert.strictEqual(chart.top.sendEndLabel.x, chart.xScale.rangeMax);
  assert.strictEqual(chart.top.gridLines.length, 2);
  assert.strictEqual(chart.top.gridLines[chart.top.gridLines.length - 1].label, chart.top.yMaxLabel);
  assert.strictEqual(chart.top.gridLines[0].label, null, "only the max gridline carries a label");

  assert.strictEqual(chart.bottom.hasData, true);
  assert.ok(typeof chart.bottom.delayPathD === "string" && chart.bottom.delayPathD.startsWith("M"));
  assert.strictEqual(chart.bottom.gridLines.length, 1);
  assert.strictEqual(chart.bottom.gridLines[0].label, chart.bottom.yMaxLabel);

  assert.strictEqual(chart.xAxisLabel, formatHumanDuration(300));
});

test("buildHeroChart: only 1 point per series (not enough to draw a line) -> still 'collecting…' (hasAnyData false)", () => {
  const chart = buildHeroChart({
    samples: [{ t: 100, sendMbit: 20, recordMbit: 18, delaySeconds: 5 }],
    nowSeconds: 100,
    windowSeconds: 300,
  });
  assert.strictEqual(chart.hasAnyData, false);
  assert.strictEqual(chart.top.sendPathD, null);
  assert.strictEqual(chart.bottom.delayPathD, null);
});

test("buildHeroChart: partial data -- only the delay series has enough points -- top stays empty, bottom renders, hasAnyData true", () => {
  const samples = [];
  for (let i = 0; i <= 5; i += 1) {
    samples.push({ t: i, sendMbit: null, recordMbit: null, delaySeconds: 10 - i });
  }
  const chart = buildHeroChart({ samples: samples, nowSeconds: 5, windowSeconds: 300 });
  assert.strictEqual(chart.top.hasData, false);
  assert.strictEqual(chart.top.sendPathD, null);
  assert.strictEqual(chart.top.recordPathD, null);
  assert.strictEqual(chart.bottom.hasData, true);
  assert.ok(chart.bottom.delayPathD);
  assert.strictEqual(chart.hasAnyData, true);
});

test("buildHeroChart: yMax never collapses below the minimum ceiling for an idle/near-zero series", () => {
  const samples = [
    { t: 0, sendMbit: 0.01, recordMbit: 0.01, delaySeconds: 0.1 },
    { t: 10, sendMbit: 0.01, recordMbit: 0.01, delaySeconds: 0.1 },
  ];
  const chart = buildHeroChart({ samples: samples, nowSeconds: 10, windowSeconds: 300 });
  assert.strictEqual(chart.top.yMax, 1);
  assert.strictEqual(chart.bottom.yMax, 5);
});

// buildHeroChart: NIC upload series (260722-xbr/NIC-TELEMETRY-01)
test("buildHeroChart: >=2 samples carrying nicMbit -> top.nicPathD is a non-null path string and top.nicEndLabel.text === 'nic'", () => {
  const samples = [];
  for (let i = 0; i <= 60; i += 1) {
    samples.push({ t: i, sendMbit: 20 + i * 0.1, recordMbit: 18 + i * 0.1, delaySeconds: 10 - i * 0.05, nicMbit: 25 + i * 0.1 });
  }
  const chart = buildHeroChart({ samples: samples, nowSeconds: 60, windowSeconds: 300, topWidth: 600, topHeight: 90 });

  assert.ok(typeof chart.top.nicPathD === "string" && chart.top.nicPathD.startsWith("M"));
  assert.strictEqual(chart.top.nicEndLabel.text, "nic");
  assert.strictEqual(chart.top.nicEndLabel.x, chart.xScale.rangeMax);
});

test("buildHeroChart: a nic series higher than send/record raises topYMax (top Y axis accounts for nic values)", () => {
  const samplesWithoutHighNic = [
    { t: 0, sendMbit: 10, recordMbit: 8, delaySeconds: 1, nicMbit: 9 },
    { t: 10, sendMbit: 10, recordMbit: 8, delaySeconds: 1, nicMbit: 9 },
  ];
  const baselineChart = buildHeroChart({ samples: samplesWithoutHighNic, nowSeconds: 10, windowSeconds: 300 });

  const samplesWithHighNic = [
    { t: 0, sendMbit: 10, recordMbit: 8, delaySeconds: 1, nicMbit: 90 },
    { t: 10, sendMbit: 10, recordMbit: 8, delaySeconds: 1, nicMbit: 90 },
  ];
  const raisedChart = buildHeroChart({ samples: samplesWithHighNic, nowSeconds: 10, windowSeconds: 300 });

  assert.ok(raisedChart.top.yMax > baselineChart.top.yMax);
});

test("buildHeroChart: 0-1 nic points -> top.nicPathD is null and top.nicEndLabel is null", () => {
  const zeroPointsChart = buildHeroChart({
    samples: [
      { t: 0, sendMbit: 10, recordMbit: 8, delaySeconds: 1, nicMbit: null },
      { t: 10, sendMbit: 10, recordMbit: 8, delaySeconds: 1, nicMbit: null },
    ],
    nowSeconds: 10,
    windowSeconds: 300,
  });
  assert.strictEqual(zeroPointsChart.top.nicPathD, null);
  assert.strictEqual(zeroPointsChart.top.nicEndLabel, null);

  const onePointChart = buildHeroChart({
    samples: [
      { t: 0, sendMbit: 10, recordMbit: 8, delaySeconds: 1, nicMbit: null },
      { t: 10, sendMbit: 10, recordMbit: 8, delaySeconds: 1, nicMbit: 5 },
    ],
    nowSeconds: 10,
    windowSeconds: 300,
  });
  assert.strictEqual(onePointChart.top.nicPathD, null);
  assert.strictEqual(onePointChart.top.nicEndLabel, null);
});

// ---------- Dashboard history persistence (260719-fmu-08) ----------

// deriveSessionKey
test("deriveSessionKey: SessionDurationSeconds=100 at now=1000 -> bucketed 'sNNN' key", () => {
  assert.strictEqual(deriveSessionKey({ SessionDurationSeconds: 100 }, 1000), "s900");
});

test("deriveSessionKey: small poll-to-poll jitter still buckets to the SAME key (refresh-stable)", () => {
  // approximateStartEpoch = 1001 - 101.3 = 899.7 -> rounds to the same 900 bucket as the test above.
  assert.strictEqual(deriveSessionKey({ SessionDurationSeconds: 101.3 }, 1001), "s900");
});

test("deriveSessionKey: a genuinely different session start produces a different key", () => {
  assert.strictEqual(deriveSessionKey({ SessionDurationSeconds: 5 }, 1005), "s1000");
});

test("deriveSessionKey: null viewModel -> null", () => {
  assert.strictEqual(deriveSessionKey(null, 1000), null);
});

test("deriveSessionKey: missing/non-finite SessionDurationSeconds -> null (no stable identity yet)", () => {
  assert.strictEqual(deriveSessionKey({ SessionDurationSeconds: null }, 1000), null);
  assert.strictEqual(deriveSessionKey({ SessionDurationSeconds: NaN }, 1000), null);
  assert.strictEqual(deriveSessionKey({}, 1000), null);
});

test("deriveSessionKey: non-finite nowSeconds -> null", () => {
  assert.strictEqual(deriveSessionKey({ SessionDurationSeconds: 100 }, NaN), null);
});

// buildDashboardHistoryPayload
test("buildDashboardHistoryPayload: builds the full schema-versioned payload, copying both buffer states as-is", () => {
  const trendState = { samples: [{ t: 1, delay: 5 }], previousSessionDurationSeconds: 10 };
  const chartState = { samples: [{ t: 1, sendMbit: 2, recordMbit: 1, delaySeconds: 5 }], previousSessionDurationSeconds: 10 };
  const payload = buildDashboardHistoryPayload("s900", trendState, chartState, 1000);
  assert.deepStrictEqual(payload, {
    v: 1,
    sessionKey: "s900",
    savedAtEpochSeconds: 1000,
    trendState: trendState,
    chartState: chartState,
  });
});

test("buildDashboardHistoryPayload: a malformed buffer state (not {samples:[...]}) defaults to an empty state, never throws", () => {
  const payload = buildDashboardHistoryPayload("s900", null, undefined, 1000);
  assert.deepStrictEqual(payload.trendState, { samples: [], previousSessionDurationSeconds: null });
  assert.deepStrictEqual(payload.chartState, { samples: [], previousSessionDurationSeconds: null });
});

// serializeDashboardHistory / parseDashboardHistory round trip
test("serializeDashboardHistory -> parseDashboardHistory: round-trips a real payload exactly", () => {
  const payload = buildDashboardHistoryPayload(
    "s900",
    { samples: [{ t: 950, delay: 12 }], previousSessionDurationSeconds: 55 },
    { samples: [{ t: 950, sendMbit: 20, recordMbit: 18, delaySeconds: 12 }], previousSessionDurationSeconds: 55 },
    1000
  );
  const serialized = serializeDashboardHistory(payload);
  assert.strictEqual(typeof serialized, "string");
  assert.deepStrictEqual(parseDashboardHistory(serialized), payload);
});

test("parseDashboardHistory: non-string / empty string -> null", () => {
  assert.strictEqual(parseDashboardHistory(null), null);
  assert.strictEqual(parseDashboardHistory(""), null);
  assert.strictEqual(parseDashboardHistory(undefined), null);
});

test("parseDashboardHistory: invalid JSON -> null (never throws on a corrupt localStorage value)", () => {
  assert.strictEqual(parseDashboardHistory("{not valid json"), null);
});

test("parseDashboardHistory: valid JSON but wrong schema version -> null", () => {
  const payload = buildDashboardHistoryPayload("s900", { samples: [], previousSessionDurationSeconds: null }, { samples: [], previousSessionDurationSeconds: null }, 1000);
  payload.v = 999;
  assert.strictEqual(parseDashboardHistory(JSON.stringify(payload)), null);
});

test("parseDashboardHistory: valid JSON missing sessionKey -> null", () => {
  assert.strictEqual(parseDashboardHistory(JSON.stringify({ v: 1, savedAtEpochSeconds: 1000, trendState: { samples: [] }, chartState: { samples: [] } })), null);
});

test("parseDashboardHistory: a foreign value some other script wrote under this key -> null, never partially trusted", () => {
  assert.strictEqual(parseDashboardHistory(JSON.stringify({ hello: "world" })), null);
  assert.strictEqual(parseDashboardHistory(JSON.stringify([1, 2, 3])), null);
  assert.strictEqual(parseDashboardHistory(JSON.stringify("just a string")), null);
});

// pruneStaleSamples (shape-preserving, unlike selectSamplesInWindow)
test("pruneStaleSamples: keeps samples within [now-window, now], preserving their ORIGINAL shape", () => {
  const samples = [
    { t: 0, delay: 1 },
    { t: 50, delay: 2 },
    { t: 70, delay: 3 },
  ];
  assert.deepStrictEqual(pruneStaleSamples(samples, 70, 60), [
    { t: 50, delay: 2 },
    { t: 70, delay: 3 },
  ]);
});

test("pruneStaleSamples: composite chart-buffer samples keep ALL their fields intact", () => {
  const samples = [{ t: 10, sendMbit: 5, recordMbit: 4, delaySeconds: 2 }];
  assert.deepStrictEqual(pruneStaleSamples(samples, 10, 60), samples);
});

test("pruneStaleSamples: filters out non-finite/malformed t entries", () => {
  const samples = [{ t: NaN, delay: 1 }, { t: 10, delay: 2 }, null];
  assert.deepStrictEqual(pruneStaleSamples(samples, 10, 60), [{ t: 10, delay: 2 }]);
});

test("pruneStaleSamples: non-array samples -> []", () => {
  assert.deepStrictEqual(pruneStaleSamples(null, 10, 60), []);
});

test("pruneStaleSamples: non-finite nowSeconds -> []", () => {
  assert.deepStrictEqual(pruneStaleSamples([{ t: 10, delay: 1 }], NaN, 60), []);
});

// restoreDashboardHistory
test("restoreDashboardHistory: sessionKey mismatch -> null (a new/different session discards the old data, 'overwrite per stream/day')", () => {
  const payload = buildDashboardHistoryPayload("s900", { samples: [{ t: 950, delay: 5 }], previousSessionDurationSeconds: 10 }, { samples: [], previousSessionDurationSeconds: 10 }, 1000);
  assert.strictEqual(restoreDashboardHistory(payload, "s1200", 1005, 60, 300), null);
});

test("restoreDashboardHistory: matching sessionKey, fresh payload -> returns pruned+sanitized states, drop-in ready", () => {
  const payload = buildDashboardHistoryPayload(
    "s900",
    { samples: [{ t: 940, delay: 12 }, { t: 999, delay: 10 }], previousSessionDurationSeconds: 55 },
    { samples: [{ t: 700, sendMbit: 5, recordMbit: 4, delaySeconds: 12 }, { t: 999, sendMbit: 6, recordMbit: 5, delaySeconds: 10 }], previousSessionDurationSeconds: 55 },
    1000
  );
  // Restoring 5s "later" (1005), trend window 60s (minT=945 -- the t=940 trend sample falls
  // just outside and is pruned), chart window 300s (minT=705 -- the t=700 chart sample is pruned too).
  const restored = restoreDashboardHistory(payload, "s900", 1005, 60, 300);
  assert.deepStrictEqual(restored, {
    trendState: { samples: [{ t: 999, delay: 10 }], previousSessionDurationSeconds: 55 },
    chartState: { samples: [{ t: 999, sendMbit: 6, recordMbit: 5, delaySeconds: 10 }], previousSessionDurationSeconds: 55 },
  });
});

test("restoreDashboardHistory: a payload older than maxAgeSeconds is discarded even when sessionKey matches", () => {
  const payload = buildDashboardHistoryPayload("s900", { samples: [{ t: 999, delay: 10 }], previousSessionDurationSeconds: 55 }, { samples: [], previousSessionDurationSeconds: 55 }, 1000);
  // 5000 seconds later, default maxAgeSeconds ceiling (3600) is exceeded.
  assert.strictEqual(restoreDashboardHistory(payload, "s900", 6000, 60, 300), null);
});

test("restoreDashboardHistory: a custom maxAgeSeconds is respected", () => {
  const payload = buildDashboardHistoryPayload("s900", { samples: [{ t: 999, delay: 10 }], previousSessionDurationSeconds: 55 }, { samples: [], previousSessionDurationSeconds: 55 }, 1000);
  assert.strictEqual(restoreDashboardHistory(payload, "s900", 1010, 60, 300, 5), null); // 10s later, ceiling 5s -> discarded
  assert.notStrictEqual(restoreDashboardHistory(payload, "s900", 1003, 60, 300, 5), null); // 3s later, ceiling 5s -> kept
});

test("restoreDashboardHistory: sanitizes a corrupted previousSessionDurationSeconds to null instead of trusting it", () => {
  const payload = buildDashboardHistoryPayload("s900", { samples: [], previousSessionDurationSeconds: "not-a-number" }, { samples: [], previousSessionDurationSeconds: undefined }, 1000);
  const restored = restoreDashboardHistory(payload, "s900", 1001, 60, 300);
  assert.strictEqual(restored.trendState.previousSessionDurationSeconds, null);
  assert.strictEqual(restored.chartState.previousSessionDurationSeconds, null);
});

test("restoreDashboardHistory: null/malformed inputs never throw", () => {
  assert.strictEqual(restoreDashboardHistory(null, "s900", 1000, 60, 300), null);
  assert.strictEqual(restoreDashboardHistory({}, "s900", 1000, 60, 300), null);
  assert.strictEqual(restoreDashboardHistory({ sessionKey: "s900" }, null, 1000, 60, 300), null);
});

// End-to-end round trip through a MOCK storage object (save -> load -> restore),
// proving the full persistence pipeline without touching a real localStorage
// (app.js owns the real localStorage.getItem/setItem calls; this test exercises
// the exact same pure functions app.js calls around them).
test("persistence pipeline: save at T1, restore at T2 within the SAME session keeps in-window samples", () => {
  const mockStorage = {
    data: {},
    getItem(key) {
      return Object.prototype.hasOwnProperty.call(this.data, key) ? this.data[key] : null;
    },
    setItem(key, value) {
      this.data[key] = value;
    },
  };
  const STORAGE_KEY = "gapless-dashboard-history-v1";

  // T1: mid-session, save the current buffers.
  const viewModelAtT1 = { SessionDurationSeconds: 300 };
  const t1 = 2000;
  const sessionKeyAtT1 = deriveSessionKey(viewModelAtT1, t1);
  const trendState = { samples: [{ t: 1970, delay: 8 }], previousSessionDurationSeconds: 300 };
  const chartState = { samples: [{ t: 1970, sendMbit: 22, recordMbit: 20, delaySeconds: 8 }], previousSessionDurationSeconds: 300 };
  const payload = buildDashboardHistoryPayload(sessionKeyAtT1, trendState, chartState, t1);
  mockStorage.setItem(STORAGE_KEY, serializeDashboardHistory(payload));

  // T2: a page refresh 10 seconds later, SAME session (SessionDurationSeconds
  // has grown by exactly the elapsed wall-clock time, same underlying session start).
  const t2 = 2010;
  const viewModelAtT2 = { SessionDurationSeconds: 310 };
  const sessionKeyAtT2 = deriveSessionKey(viewModelAtT2, t2);
  assert.strictEqual(sessionKeyAtT2, sessionKeyAtT1, "the session key must be stable across the refresh");

  const restored = restoreDashboardHistory(parseDashboardHistory(mockStorage.getItem(STORAGE_KEY)), sessionKeyAtT2, t2, 60, 300);
  assert.deepStrictEqual(restored.trendState.samples, [{ t: 1970, delay: 8 }]);
  assert.deepStrictEqual(restored.chartState.samples, [{ t: 1970, sendMbit: 22, recordMbit: 20, delaySeconds: 8 }]);
});

test("persistence pipeline: a DIFFERENT session at restore time discards the stored data (overwrite behavior)", () => {
  const mockStorage = {
    data: {},
    getItem(key) {
      return Object.prototype.hasOwnProperty.call(this.data, key) ? this.data[key] : null;
    },
    setItem(key, value) {
      this.data[key] = value;
    },
  };
  const STORAGE_KEY = "gapless-dashboard-history-v1";

  const sessionKeyAtT1 = deriveSessionKey({ SessionDurationSeconds: 300 }, 2000);
  const payload = buildDashboardHistoryPayload(sessionKeyAtT1, { samples: [{ t: 1970, delay: 8 }], previousSessionDurationSeconds: 300 }, { samples: [], previousSessionDurationSeconds: 300 }, 2000);
  mockStorage.setItem(STORAGE_KEY, serializeDashboardHistory(payload));

  // A BRAND NEW session started (e.g. pusher restarted) -- SessionDurationSeconds
  // resets low relative to the new "now", producing a wholly different key.
  const sessionKeyAtNewSession = deriveSessionKey({ SessionDurationSeconds: 4 }, 3000);
  assert.notStrictEqual(sessionKeyAtNewSession, sessionKeyAtT1);

  const restored = restoreDashboardHistory(parseDashboardHistory(mockStorage.getItem(STORAGE_KEY)), sessionKeyAtNewSession, 3000, 60, 300);
  assert.strictEqual(restored, null);
});
