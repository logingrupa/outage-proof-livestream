// Gapless SRT Pusher — Dashboard pure formatting/math helpers
// Plain browser JavaScript, DOM-free and global-free (brief #5/#6/#7, DASH-05/06/07).
// Shipped as a plain <script> (no type=module) so index.html loads it with zero
// build step, exactly like dashboard/app.js. window.DashboardFormat is the browser
// surface; the guarded CommonJS tail at the bottom lets `node --test` import the
// SAME functions for unit testing without a browser or DOM -- the guard is inert in
// the browser (no `module` global exists there), so this file behaves identically
// to a plain script in production while remaining directly testable.

(function () {
  "use strict";

  function formatMegabytes(bytes) {
    // Matches the existing formatter-guard style (dashboard/app.js formatBytes/
    // formatSeconds): null/undefined/non-number/non-finite (NaN, +/-Infinity) all
    // collapse to the "—" sentinel, never a fabricated number.
    if (bytes === null || bytes === undefined || typeof bytes !== "number" || !isFinite(bytes)) {
      return "—";
    }
    var megabytes = bytes / 1048576;
    return megabytes.toFixed(1) + " MB";
  }

  function formatHumanDuration(seconds) {
    // Matches the existing formatter-guard style (formatMegabytes/formatSeconds):
    // null/undefined/non-number/non-finite (NaN, +/-Infinity) all collapse to the
    // "—" sentinel, never a fabricated duration.
    if (seconds === null || seconds === undefined || typeof seconds !== "number" || !isFinite(seconds)) {
      return "—";
    }

    var total = Math.max(0, Math.round(seconds));
    var hours = Math.floor(total / 3600);
    var minutes = Math.floor((total % 3600) / 60);
    var secs = total % 60;

    if (total < 60) {
      return secs + "s";
    }

    if (total < 3600) {
      return minutes + "m " + secs + "s";
    }

    var paddedMinutes = minutes < 10 ? "0" + minutes : "" + minutes;
    return hours + "h " + paddedMinutes + "m";
  }

  // computeDelayTrend (260719-fmu-04): operator-friendly "did the delay get
  // better or worse in the last ~60s" summary for the hero panel. Pure/
  // DOM-free and node-testable -- app.js owns the ring buffer of {t, delay}
  // samples (wall-clock seconds + DelaySecondsBehindLive) and the
  // Streaming/session-restart reset policy; this function only reasons about
  // an already-collected sample array, never touches the DOM or a clock
  // itself (nowSeconds is passed in, matching this file's existing
  // dependency-injection style for anything time-based).
  //
  // samples: array of { t: <epoch seconds>, delay: <seconds behind live> }.
  // Only finite {t, delay} pairs are usable; anything else is skipped rather
  // than corrupting the comparison (D-13, never fabricated).
  function computeDelayTrend(samples, nowSeconds, windowSeconds, flatThresholdSeconds) {
    var win =
      typeof windowSeconds === "number" && isFinite(windowSeconds) && windowSeconds > 0 ? windowSeconds : 60;
    var flatThreshold =
      typeof flatThresholdSeconds === "number" && isFinite(flatThresholdSeconds) && flatThresholdSeconds >= 0
        ? flatThresholdSeconds
        : 2;

    if (
      !Array.isArray(samples) ||
      samples.length === 0 ||
      typeof nowSeconds !== "number" ||
      !isFinite(nowSeconds)
    ) {
      return { status: "measuring", text: "measuring…" };
    }

    var usable = [];
    for (var i = 0; i < samples.length; i += 1) {
      var sample = samples[i];
      if (
        sample &&
        typeof sample.t === "number" &&
        isFinite(sample.t) &&
        typeof sample.delay === "number" &&
        isFinite(sample.delay)
      ) {
        usable.push(sample);
      }
    }

    if (usable.length === 0) {
      return { status: "measuring", text: "measuring…" };
    }

    var newest = usable[usable.length - 1];
    var oldest = usable[0];

    if (nowSeconds - oldest.t < win) {
      // Not enough history yet -- never fabricate a trend from a shorter window.
      return { status: "measuring", text: "measuring…" };
    }

    // Pick the sample whose timestamp is closest to "windowSeconds ago" as the
    // comparison point (exact 60s-old samples rarely exist at 1s poll cadence).
    var targetT = nowSeconds - win;
    var closest = usable[0];
    var closestDiff = Math.abs(usable[0].t - targetT);
    for (var j = 1; j < usable.length; j += 1) {
      var diff = Math.abs(usable[j].t - targetT);
      if (diff < closestDiff) {
        closest = usable[j];
        closestDiff = diff;
      }
    }

    var delta = closest.delay - newest.delay; // positive => delay shrank (caught up)

    if (Math.abs(delta) < flatThreshold) {
      return { status: "steady", text: "holding steady" };
    }

    var deltaText = formatHumanDuration(Math.abs(delta));
    if (delta > 0) {
      return { status: "improving", text: "caught up " + deltaText + " in last minute" };
    }
    return { status: "worsening", text: "fell behind " + deltaText + " in last minute" };
  }

  // updateDelayTrendState (260719-fmu-06, bugfix): the pure ring-buffer
  // collection + reset policy behind the hero delay trend, extracted out of
  // app.js so it is node-testable (app.js itself cannot be `require`d under
  // node --test -- it unconditionally reads `window` at load time). This is
  // exactly where the original bug lived: a naive "any single poll where
  // ConnectionState !== 'Streaming' wipes the whole buffer" reset is too
  // aggressive on a bonded/lossy WAN where brief single-tick Reconnecting
  // blips are common (the whole reason this project's pusher has backoff/
  // reconnect machinery) -- on real hardware that wiped 60s of history
  // every time a blip landed more often than once per window, so
  // computeDelayTrend NEVER saw enough history and stayed stuck on
  // "measuring…" forever, even though the operator perceived the stream as
  // "Streaming the whole time" (a few one-second flickers are easy to miss
  // by eye but not by a per-poll reset).
  //
  // Fixed policy:
  //   - A genuine SESSION RESTART (SessionDurationSeconds drops between
  //     polls -- a real new sessionStartEpochSeconds) wipes the buffer
  //     outright; old samples truly no longer describe the current stream.
  //   - A single non-Streaming/non-finite-delay poll only PAUSES collection
  //     (no new sample pushed) -- it does NOT wipe existing history. A
  //     sustained non-Streaming stretch still empties the buffer over time
  //     via the same age-based pruning used for normal samples (nothing new
  //     is pushed, so everything eventually ages past windowSeconds+margin
  //     and is pruned away), which is the correct "actually gone" case.
  //
  // state: { samples: [{t, delay}], previousSessionDurationSeconds } or
  //   null/undefined for a fresh start. Returns a NEW state object (never
  //   mutates the input), matching this file's pure-function discipline.
  function updateDelayTrendState(state, viewModel, nowSeconds, windowSeconds) {
    var win = typeof windowSeconds === "number" && isFinite(windowSeconds) && windowSeconds > 0 ? windowSeconds : 60;

    var samples = state && Array.isArray(state.samples) ? state.samples.slice() : [];
    var previousSessionDurationSeconds =
      state &&
      typeof state.previousSessionDurationSeconds === "number" &&
      isFinite(state.previousSessionDurationSeconds)
        ? state.previousSessionDurationSeconds
        : null;

    var sessionDurationSeconds = viewModel ? viewModel.SessionDurationSeconds : null;
    var isSessionDurationSecondsNumeric =
      typeof sessionDurationSeconds === "number" && isFinite(sessionDurationSeconds);

    var sessionRestarted = isSessionRestart(sessionDurationSeconds, previousSessionDurationSeconds);

    var nextPreviousSessionDurationSeconds = isSessionDurationSecondsNumeric
      ? sessionDurationSeconds
      : previousSessionDurationSeconds;

    if (sessionRestarted) {
      samples = [];
    }

    var isValidNow = typeof nowSeconds === "number" && isFinite(nowSeconds);
    var delay = viewModel ? viewModel.DelaySecondsBehindLive : null;
    var isUsablePoll =
      isValidNow &&
      viewModel &&
      isChartableConnectionState(viewModel.ConnectionState) &&
      typeof delay === "number" &&
      isFinite(delay);

    if (isUsablePoll) {
      samples.push({ t: nowSeconds, delay: delay });
    }

    // Prune unconditionally (not only when a sample was just pushed) so a
    // sustained non-Streaming stretch drains the buffer back to empty on its
    // own, purely by every remaining sample aging past the window+margin --
    // no separate "was this Streaming" wipe condition needed for that case.
    if (isValidNow) {
      var cutoff = nowSeconds - (win + 10);
      while (samples.length > 0 && samples[0].t < cutoff) {
        samples.shift();
      }
    }

    return { samples: samples, previousSessionDurationSeconds: nextPreviousSessionDurationSeconds };
  }

  // isSessionRestart (260719-fmu-07): shared "did the pusher's own session
  // genuinely restart" predicate, factored out of updateDelayTrendState so
  // the new chart ring buffer (updateChartBufferState, below) can apply the
  // IDENTICAL restart-detection rule without duplicating it. Pure extraction
  // only -- updateDelayTrendState's own behavior/signature/tests are
  // unchanged. A tolerance of 1s absorbs publish-cadence/clock jitter
  // without masking a genuine restart.
  function isSessionRestart(sessionDurationSeconds, previousSessionDurationSeconds) {
    return (
      typeof sessionDurationSeconds === "number" &&
      isFinite(sessionDurationSeconds) &&
      typeof previousSessionDurationSeconds === "number" &&
      isFinite(previousSessionDurationSeconds) &&
      sessionDurationSeconds < previousSessionDurationSeconds - 1
    );
  }

  // isChartableConnectionState (15-03 Task 1, CHUR-03): shared "should the
  // hero chart/trend keep collecting a sample this poll" predicate. Widened
  // beyond the original "Streaming"-only gate so the exact window an
  // operator most wants to watch -- the end-of-service drain -- is charted
  // instead of going dark the instant ConnectionState flips to "Draining"
  // (the old isStreamingPoll/isUsablePoll gates below). Factored out ONCE
  // (this repo's DRY rule, matching isSessionRestart's own extraction above)
  // so updateDelayTrendState and updateChartBufferState can never drift
  // apart on which states are chartable.
  function isChartableConnectionState(connectionState) {
    return connectionState === "Streaming" || connectionState === "Draining";
  }

  // ---------- Hero mini-chart (260719-fmu-07) ----------
  // Hand-rolled inline SVG (no charting library, no build step -- house
  // rule). All scaling/path/windowing math lives here, DOM-free and
  // node-testable; app.js only builds/updates SVG DOM nodes from these
  // already-computed pixel-space results (thin wiring).

  function roundToPrecision(value, precision) {
    var factor = Math.pow(10, typeof precision === "number" && precision >= 0 ? precision : 1);
    return Math.round(value * factor) / factor;
  }

  // computeLinearScale: maps a domain value to a pixel position. rangeMin
  // may be numerically GREATER than rangeMax on purpose -- SVG y grows
  // downward, so a y-axis scale passes rangeMin=<bottom pixel> (large) and
  // rangeMax=<top pixel> (small) to map domain 0 to the bottom of the panel.
  function computeLinearScale(value, domainMin, domainMax, rangeMin, rangeMax) {
    if (
      typeof value !== "number" || !isFinite(value) ||
      typeof domainMin !== "number" || !isFinite(domainMin) ||
      typeof domainMax !== "number" || !isFinite(domainMax) ||
      typeof rangeMin !== "number" || !isFinite(rangeMin) ||
      typeof rangeMax !== "number" || !isFinite(rangeMax)
    ) {
      return rangeMin;
    }
    if (domainMax === domainMin) {
      return rangeMin;
    }
    return rangeMin + ((value - domainMin) / (domainMax - domainMin)) * (rangeMax - rangeMin);
  }

  // invertLinearScale: the inverse of computeLinearScale -- pixel position
  // (e.g. a mouse cursor's x offset) back to a domain value (e.g. the
  // hovered wall-clock second), used by the chart's hover/crosshair.
  function invertLinearScale(pixelValue, domainMin, domainMax, rangeMin, rangeMax) {
    if (
      typeof pixelValue !== "number" || !isFinite(pixelValue) ||
      typeof domainMin !== "number" || !isFinite(domainMin) ||
      typeof domainMax !== "number" || !isFinite(domainMax) ||
      typeof rangeMin !== "number" || !isFinite(rangeMin) ||
      typeof rangeMax !== "number" || !isFinite(rangeMax)
    ) {
      return domainMin;
    }
    if (rangeMax === rangeMin) {
      return domainMin;
    }
    return domainMin + ((pixelValue - rangeMin) / (rangeMax - rangeMin)) * (domainMax - domainMin);
  }

  // computeNiceAxisMax: rounds a raw maximum data value up to a "nice"
  // round number (1/2/5 x a power of ten) for the panel's single y-max
  // gridline/label -- e.g. a raw peak of 27.4 Mbit/s becomes a 30 Mbit
  // axis top, not an ugly "27.4 Mbit" label. minimumCeiling keeps an
  // idle/near-zero series from collapsing the axis to 0 (a flat line at
  // the very bottom is still readable against a sane minimum scale).
  function computeNiceAxisMax(maxValue, minimumCeiling) {
    var floor = typeof minimumCeiling === "number" && isFinite(minimumCeiling) && minimumCeiling > 0 ? minimumCeiling : 1;
    var effectiveMax = typeof maxValue === "number" && isFinite(maxValue) && maxValue > floor ? maxValue : floor;
    var magnitude = Math.pow(10, Math.floor(Math.log10(effectiveMax)));
    var normalized = effectiveMax / magnitude;
    var niceNormalized;
    if (normalized <= 1) {
      niceNormalized = 1;
    } else if (normalized <= 2) {
      niceNormalized = 2;
    } else if (normalized <= 5) {
      niceNormalized = 5;
    } else {
      niceNormalized = 10;
    }
    return niceNormalized * magnitude;
  }

  // selectSamplesInWindow: filters a flat samples array down to the finite,
  // in-window {t, value} pairs the chart needs, sorted ascending by time.
  // valueKey lets ONE combined ring-buffer sample shape (e.g.
  // {t, sendMbit, recordMbit, delaySeconds} from updateChartBufferState)
  // serve as the source for three independent per-series windows, without
  // three separate buffers that could drift out of time-alignment.
  function selectSamplesInWindow(samples, nowSeconds, windowSeconds, valueKey) {
    var key = typeof valueKey === "string" && valueKey ? valueKey : "value";
    var win = typeof windowSeconds === "number" && isFinite(windowSeconds) && windowSeconds > 0 ? windowSeconds : 300;
    if (!Array.isArray(samples) || typeof nowSeconds !== "number" || !isFinite(nowSeconds)) {
      return [];
    }
    var minT = nowSeconds - win;
    var result = [];
    for (var i = 0; i < samples.length; i += 1) {
      var sample = samples[i];
      if (!sample || typeof sample.t !== "number" || !isFinite(sample.t) || sample.t < minT || sample.t > nowSeconds) {
        continue;
      }
      var value = sample[key];
      if (typeof value !== "number" || !isFinite(value)) {
        continue;
      }
      result.push({ t: sample.t, value: value });
    }
    result.sort(function (a, b) {
      return a.t - b.t;
    });
    return result;
  }

  // findNearestSampleIndex: nearest-by-time lookup for the chart's hover
  // crosshair/tooltip (given a cursor x already inverted to a wall-clock
  // second, find which sample to show). Works on any array of objects with
  // a numeric `.t` -- callers pass either a windowed per-series array or the
  // raw combined buffer.
  function findNearestSampleIndex(samples, targetT) {
    if (!Array.isArray(samples) || samples.length === 0 || typeof targetT !== "number" || !isFinite(targetT)) {
      return -1;
    }
    var bestIndex = 0;
    var bestDiff = Math.abs(samples[0].t - targetT);
    for (var i = 1; i < samples.length; i += 1) {
      var diff = Math.abs(samples[i].t - targetT);
      if (diff < bestDiff) {
        bestDiff = diff;
        bestIndex = i;
      }
    }
    return bestIndex;
  }

  // buildMonotonePathD: SVG path 'd' string through already-scaled pixel
  // points [[x,y], ...] (sorted ascending by x) using monotone cubic
  // interpolation (the same Fritsch-Carlson-derived algorithm as d3-shape's
  // curveMonotoneX) -- smooth between samples without the overshoot
  // "ringing" a naive Catmull-Rom spline produces on noisy bitrate/delay
  // data (a spline that overshoots could visually imply a value the stream
  // never actually hit, which this project's D-13 "never fabricate" ethos
  // rules out for a metric this literally). Degenerates gracefully: 0
  // points -> null, 1 point -> a single "M" (a dot, no visible stroke), 2
  // points -> a plain straight line (monotone interpolation needs >=3
  // points to have an interior tangent to compute).
  function buildMonotonePathD(pixelPoints, precision) {
    if (!Array.isArray(pixelPoints) || pixelPoints.length === 0) {
      return null;
    }
    var p = typeof precision === "number" && precision >= 0 ? precision : 1;
    var fmt = function (n) {
      return roundToPrecision(n, p);
    };

    if (pixelPoints.length === 1) {
      return "M" + fmt(pixelPoints[0][0]) + "," + fmt(pixelPoints[0][1]);
    }

    if (pixelPoints.length === 2) {
      return (
        "M" + fmt(pixelPoints[0][0]) + "," + fmt(pixelPoints[0][1]) +
        "L" + fmt(pixelPoints[1][0]) + "," + fmt(pixelPoints[1][1])
      );
    }

    var xs = [];
    var ys = [];
    for (var i = 0; i < pixelPoints.length; i += 1) {
      xs.push(pixelPoints[i][0]);
      ys.push(pixelPoints[i][1]);
    }
    var n = xs.length;

    // Per-segment slopes.
    var d = [];
    for (var s = 0; s < n - 1; s += 1) {
      var dx = xs[s + 1] - xs[s];
      d.push(dx === 0 ? 0 : (ys[s + 1] - ys[s]) / dx);
    }

    function sign(x) {
      return x < 0 ? -1 : 1;
    }

    // Tangents at each point (Fritsch-Carlson / d3 curveMonotoneX): the
    // endpoints take the single adjacent slope; interior points take a
    // sign(d[i-1])+sign(d[i])-weighted harmonic-style blend of their two
    // neighboring slopes, clamped so the curve never overshoots past
    // either neighboring segment (the monotonicity-preserving property).
    var t = new Array(n);
    t[0] = d[0];
    t[n - 1] = d[n - 2];
    for (var i2 = 1; i2 < n - 1; i2 += 1) {
      var h0 = xs[i2] - xs[i2 - 1];
      var h1 = xs[i2 + 1] - xs[i2];
      var s0 = d[i2 - 1];
      var s1 = d[i2];
      var pTangent = (s0 * h1 + s1 * h0) / (h0 + h1);
      t[i2] = (sign(s0) + sign(s1)) * Math.min(Math.abs(s0), Math.abs(s1), 0.5 * Math.abs(pTangent)) || 0;
    }

    var pathParts = ["M" + fmt(xs[0]) + "," + fmt(ys[0])];
    for (var k = 0; k < n - 1; k += 1) {
      var dxThird = (xs[k + 1] - xs[k]) / 3;
      var c1x = xs[k] + dxThird;
      var c1y = ys[k] + dxThird * t[k];
      var c2x = xs[k + 1] - dxThird;
      var c2y = ys[k + 1] - dxThird * t[k + 1];
      pathParts.push(
        "C" + fmt(c1x) + "," + fmt(c1y) + " " + fmt(c2x) + "," + fmt(c2y) + " " + fmt(xs[k + 1]) + "," + fmt(ys[k + 1])
      );
    }
    return pathParts.join("");
  }

  function maxSeriesValue(series) {
    var max = 0;
    for (var i = 0; i < series.length; i += 1) {
      if (series[i].value > max) {
        max = series[i].value;
      }
    }
    return max;
  }

  function toPixelPoints(series, xScale, yScale) {
    var points = [];
    for (var i = 0; i < series.length; i += 1) {
      points.push([
        computeLinearScale(series[i].t, xScale.domainMin, xScale.domainMax, xScale.rangeMin, xScale.rangeMax),
        computeLinearScale(series[i].value, yScale.domainMin, yScale.domainMax, yScale.rangeMin, yScale.rangeMax),
      ]);
    }
    return points;
  }

  function buildGridLines(yScale, yMax, fractions, labelFn) {
    var lines = [];
    for (var i = 0; i < fractions.length; i += 1) {
      var value = yMax * fractions[i];
      var y = computeLinearScale(value, yScale.domainMin, yScale.domainMax, yScale.rangeMin, yScale.rangeMax);
      lines.push({
        y: roundToPrecision(y, 1),
        value: value,
        // Only the top (max) gridline carries a label -- "tiny y-max label
        // only", every other gridline is a bare recessive reference line.
        label: fractions[i] === 1 ? labelFn(value) : null,
      });
    }
    return lines;
  }

  // updateChartBufferState (260719-fmu-07): the mini-chart's ring buffer.
  // Reuses the EXACT restart-detection rule updateDelayTrendState uses
  // (isSessionRestart) so both buffers treat "the pusher's session
  // genuinely restarted" identically, but keeps its own buffer/window
  // (5 minutes vs the hero trend's 60 seconds) and its own richer per-tick
  // payload -- ONE combined sample per poll tick carrying all three series
  // ({t, sendMbit, recordMbit, delaySeconds}), so the shared time axis is
  // exact by construction (every tick contributes at most one point, never
  // three independently-timestamped buffers that could drift apart).
  //
  // A tick is skipped (paused, not wiped -- same policy as
  // updateDelayTrendState) unless the pusher is Streaming AND at least one
  // of the three metrics is a real finite reading; any metric that's
  // non-finite that tick is stored as null and simply produces a gap in
  // that one series (selectSamplesInWindow drops it), never a fabricated
  // zero (D-13).
  function updateChartBufferState(state, viewModel, nowSeconds, windowSeconds) {
    var win = typeof windowSeconds === "number" && isFinite(windowSeconds) && windowSeconds > 0 ? windowSeconds : 300;

    var samples = state && Array.isArray(state.samples) ? state.samples.slice() : [];
    var previousSessionDurationSeconds =
      state &&
      typeof state.previousSessionDurationSeconds === "number" &&
      isFinite(state.previousSessionDurationSeconds)
        ? state.previousSessionDurationSeconds
        : null;

    var sessionDurationSeconds = viewModel ? viewModel.SessionDurationSeconds : null;
    var isSessionDurationSecondsNumeric =
      typeof sessionDurationSeconds === "number" && isFinite(sessionDurationSeconds);
    var restarted = isSessionRestart(sessionDurationSeconds, previousSessionDurationSeconds);
    var nextPreviousSessionDurationSeconds = isSessionDurationSecondsNumeric
      ? sessionDurationSeconds
      : previousSessionDurationSeconds;

    if (restarted) {
      samples = [];
    }

    var isValidNow = typeof nowSeconds === "number" && isFinite(nowSeconds);
    var isStreamingPoll = isValidNow && viewModel && isChartableConnectionState(viewModel.ConnectionState);

    if (isStreamingPoll) {
      var sendBytesPerSecond = viewModel.SendBytesPerSecond;
      var recordBytesPerSecond = viewModel.RecordBytesPerSecond;
      var delaySeconds = viewModel.DelaySecondsBehindLive;
      var nicUploadBps = viewModel.NicUploadBps;
      var sendMbit =
        typeof sendBytesPerSecond === "number" && isFinite(sendBytesPerSecond) ? (sendBytesPerSecond * 8) / 1e6 : null;
      var recordMbit =
        typeof recordBytesPerSecond === "number" && isFinite(recordBytesPerSecond)
          ? (recordBytesPerSecond * 8) / 1e6
          : null;
      var delayValue = typeof delaySeconds === "number" && isFinite(delaySeconds) ? delaySeconds : null;
      // NIC upload speed (260722-xbr/NIC-TELEMETRY-01): the third hero-chart
      // series, shares the top panel's Mbit axis with send/record. Same
      // never-fabricate guard as the other two -- non-finite/absent collapses
      // to null (a gap in this one series), never a fabricated zero.
      var nicMbit = typeof nicUploadBps === "number" && isFinite(nicUploadBps) ? (nicUploadBps * 8) / 1e6 : null;

      if (sendMbit !== null || recordMbit !== null || delayValue !== null || nicMbit !== null) {
        samples.push({
          t: nowSeconds,
          sendMbit: sendMbit,
          recordMbit: recordMbit,
          delaySeconds: delayValue,
          nicMbit: nicMbit,
        });
      }
    }

    if (isValidNow) {
      var cutoff = nowSeconds - (win + 10);
      while (samples.length > 0 && samples[0].t < cutoff) {
        samples.shift();
      }
    }

    return { samples: samples, previousSessionDurationSeconds: nextPreviousSessionDurationSeconds };
  }

  // buildHeroChart (260719-fmu-07): the composite entry point app.js
  // actually calls -- ties windowing + scaling + path/gridline/label
  // generation together for BOTH stacked panels off ONE shared time axis,
  // so app.js's own job is thin DOM rendering only. NEVER draws a line from
  // fabricated data: a series with fewer than 2 usable points in the
  // window renders no path at all (hasData reflects this per panel; when
  // hasAnyData is false across the whole chart, app.js shows a
  // "collecting…" placeholder instead of an empty/misleading chart shell).
  function buildHeroChart(config) {
    var cfg = config || {};
    var chartSamples = Array.isArray(cfg.samples) ? cfg.samples : [];
    var nowSeconds = cfg.nowSeconds;
    var windowSeconds =
      typeof cfg.windowSeconds === "number" && isFinite(cfg.windowSeconds) && cfg.windowSeconds > 0
        ? cfg.windowSeconds
        : 300;
    var topWidth = typeof cfg.topWidth === "number" && cfg.topWidth > 0 ? cfg.topWidth : 600;
    var topHeight = typeof cfg.topHeight === "number" && cfg.topHeight > 0 ? cfg.topHeight : 90;
    var bottomWidth = typeof cfg.bottomWidth === "number" && cfg.bottomWidth > 0 ? cfg.bottomWidth : topWidth;
    var bottomHeight = typeof cfg.bottomHeight === "number" && cfg.bottomHeight > 0 ? cfg.bottomHeight : 30;
    var precision = typeof cfg.precision === "number" && cfg.precision >= 0 ? cfg.precision : 1;
    var topPadding = typeof cfg.topPadding === "number" && cfg.topPadding >= 0 ? cfg.topPadding : 4;

    var sendSeries = selectSamplesInWindow(chartSamples, nowSeconds, windowSeconds, "sendMbit");
    var recordSeries = selectSamplesInWindow(chartSamples, nowSeconds, windowSeconds, "recordMbit");
    var delaySeries = selectSamplesInWindow(chartSamples, nowSeconds, windowSeconds, "delaySeconds");
    var nicSeries = selectSamplesInWindow(chartSamples, nowSeconds, windowSeconds, "nicMbit");

    var domainMin = typeof nowSeconds === "number" && isFinite(nowSeconds) ? nowSeconds - windowSeconds : 0;
    var domainMax = typeof nowSeconds === "number" && isFinite(nowSeconds) ? nowSeconds : 0;
    var xScale = { domainMin: domainMin, domainMax: domainMax, rangeMin: 0, rangeMax: topWidth };

    var topRawMax = Math.max(maxSeriesValue(sendSeries), maxSeriesValue(recordSeries), maxSeriesValue(nicSeries));
    var topYMax = computeNiceAxisMax(topRawMax, 1);
    var topYScale = { domainMin: 0, domainMax: topYMax, rangeMin: topHeight, rangeMax: topPadding };
    var topGridLines = buildGridLines(topYScale, topYMax, [0.5, 1], function (value) {
      return roundToPrecision(value, 0) + " Mbit";
    });

    var sendPixelPoints = toPixelPoints(sendSeries, xScale, topYScale);
    var recordPixelPoints = toPixelPoints(recordSeries, xScale, topYScale);
    var nicPixelPoints = toPixelPoints(nicSeries, xScale, topYScale);

    var sendPathD = sendPixelPoints.length >= 2 ? buildMonotonePathD(sendPixelPoints, precision) : null;
    var recordPathD = recordPixelPoints.length >= 2 ? buildMonotonePathD(recordPixelPoints, precision) : null;
    var nicPathD = nicPixelPoints.length >= 2 ? buildMonotonePathD(nicPixelPoints, precision) : null;

    var sendEndLabel =
      sendPixelPoints.length >= 2
        ? {
            x: sendPixelPoints[sendPixelPoints.length - 1][0],
            y: sendPixelPoints[sendPixelPoints.length - 1][1],
            text: "send",
          }
        : null;
    var recordEndLabel =
      recordPixelPoints.length >= 2
        ? {
            x: recordPixelPoints[recordPixelPoints.length - 1][0],
            y: recordPixelPoints[recordPixelPoints.length - 1][1],
            text: "record",
          }
        : null;
    var nicEndLabel =
      nicPixelPoints.length >= 2
        ? {
            x: nicPixelPoints[nicPixelPoints.length - 1][0],
            y: nicPixelPoints[nicPixelPoints.length - 1][1],
            text: "nic",
          }
        : null;

    var bottomRawMax = maxSeriesValue(delaySeries);
    var bottomYMax = computeNiceAxisMax(bottomRawMax, 5);
    var bottomPadding = topPadding / 2;
    var bottomYScale = { domainMin: 0, domainMax: bottomYMax, rangeMin: bottomHeight, rangeMax: bottomPadding };
    var bottomGridLines = buildGridLines(bottomYScale, bottomYMax, [1], function (value) {
      return formatHumanDuration(value);
    });

    var delayPixelPoints = toPixelPoints(delaySeries, xScale, bottomYScale);
    var delayPathD = delayPixelPoints.length >= 2 ? buildMonotonePathD(delayPixelPoints, precision) : null;

    var topHasData = sendPixelPoints.length >= 2 || recordPixelPoints.length >= 2 || nicPixelPoints.length >= 2;
    var bottomHasData = delayPixelPoints.length >= 2;

    return {
      // Reflects what's actually RENDERABLE (>=2 points somewhere), not merely
      // "the buffer has one sample" -- a single point can't draw a line, so
      // app.js should still show the "collecting…" placeholder until then
      // (no fake/misleading partial chart shell, D-13).
      hasAnyData: topHasData || bottomHasData,
      xScale: xScale,
      xAxisLabel: formatHumanDuration(windowSeconds),
      top: {
        hasData: topHasData,
        yMax: topYMax,
        yMaxLabel: roundToPrecision(topYMax, 0) + " Mbit",
        gridLines: topGridLines,
        // Lines only (260719-fmu-08, operator design feedback) -- no area
        // fill under send, no delay band; clean 2px lines carry the data.
        sendPathD: sendPathD,
        recordPathD: recordPathD,
        nicPathD: nicPathD,
        sendEndLabel: sendEndLabel,
        recordEndLabel: recordEndLabel,
        nicEndLabel: nicEndLabel,
        yScale: topYScale,
      },
      bottom: {
        hasData: bottomHasData,
        yMax: bottomYMax,
        yMaxLabel: formatHumanDuration(bottomYMax),
        gridLines: bottomGridLines,
        delayPathD: delayPathD,
        yScale: bottomYScale,
      },
    };
  }

  // ---------- Dashboard history persistence (260719-fmu-08) ----------
  // Pure serialize/deserialize/validate/prune/restore-decision logic behind
  // mirroring the delay-trend + hero-chart ring buffers into localStorage so
  // a browser refresh mid-service doesn't lose the last few minutes of
  // history. app.js owns the actual localStorage.getItem/setItem calls
  // (feature-detection + try/catch for quota/privacy denial) -- this file
  // stays DOM/storage-free, as always; every function here operates on
  // plain strings/objects a caller already read from (or is about to write
  // to) storage.

  var DASHBOARD_HISTORY_SCHEMA_VERSION = 1;

  // deriveSessionKey: a stable-across-refreshes, different-across-sessions
  // identifier.
  //
  // CHOICE: derived from SessionDurationSeconds (nowSeconds -
  // SessionDurationSeconds ~= the session's own sessionStartEpochSeconds),
  // rounded to a 5-second bucket to absorb poll-to-poll/clock jitter --
  // deliberately NOT RecordingFilePath, even though it's a tempting
  // candidate at first glance: this project's file-rotation feature
  // (Phase 3) deliberately keeps ONE continuous session running across a
  // mid-service file rotation (a new recording file, same session, same
  // sessionStartEpochSeconds) -- keying on RecordingFilePath would misfire
  // a "new session" on every rotation and wipe/reject history that should
  // legitimately survive it. SessionDurationSeconds is exactly the same
  // signal isSessionRestart already uses to detect a GENUINE new session,
  // so this reuses proven, already-tested plumbing instead of inventing a
  // second, differently-scoped notion of "session boundary".
  function deriveSessionKey(viewModel, nowSeconds) {
    if (!viewModel || typeof nowSeconds !== "number" || !isFinite(nowSeconds)) {
      return null;
    }
    var sessionDurationSeconds = viewModel.SessionDurationSeconds;
    if (typeof sessionDurationSeconds !== "number" || !isFinite(sessionDurationSeconds)) {
      return null;
    }
    var approximateStartEpoch = nowSeconds - sessionDurationSeconds;
    var bucketed = Math.round(approximateStartEpoch / 5) * 5;
    return "s" + bucketed;
  }

  function isPlainBufferState(state) {
    return !!state && typeof state === "object" && Array.isArray(state.samples);
  }

  // buildDashboardHistoryPayload: the plain, JSON-safe object persisted to
  // localStorage. Stores the FULL {samples, previousSessionDurationSeconds}
  // shape for both buffers unchanged -- a restored buffer is then a
  // drop-in replacement for the live one (the exact shape
  // updateDelayTrendState/updateChartBufferState already produce and
  // consume, "respect existing buffer shapes").
  function buildDashboardHistoryPayload(sessionKey, trendState, chartState, nowSeconds) {
    return {
      v: DASHBOARD_HISTORY_SCHEMA_VERSION,
      sessionKey: sessionKey,
      savedAtEpochSeconds: nowSeconds,
      trendState: isPlainBufferState(trendState)
        ? { samples: trendState.samples, previousSessionDurationSeconds: trendState.previousSessionDurationSeconds }
        : { samples: [], previousSessionDurationSeconds: null },
      chartState: isPlainBufferState(chartState)
        ? { samples: chartState.samples, previousSessionDurationSeconds: chartState.previousSessionDurationSeconds }
        : { samples: [], previousSessionDurationSeconds: null },
    };
  }

  // serializeDashboardHistory: JSON.stringify guarded against a pathological
  // throw (never expected for this plain-data shape, but a persistence
  // detail must never crash the dashboard). Returns null on failure.
  function serializeDashboardHistory(payload) {
    try {
      return JSON.stringify(payload);
    } catch (e) {
      return null;
    }
  }

  // parseDashboardHistory: JSON.parse + structural validation. Returns null
  // for anything that isn't a genuine, schema-matching payload this file
  // itself wrote -- a corrupt entry, a foreign value some other script
  // wrote under the same key, or a future/older schema version all discard
  // safely rather than partially trusting unknown data (never a crash from
  // a malformed localStorage value).
  function parseDashboardHistory(jsonString) {
    if (typeof jsonString !== "string" || jsonString.length === 0) {
      return null;
    }
    var parsed;
    try {
      parsed = JSON.parse(jsonString);
    } catch (e) {
      return null;
    }
    if (
      !parsed ||
      typeof parsed !== "object" ||
      parsed.v !== DASHBOARD_HISTORY_SCHEMA_VERSION ||
      typeof parsed.sessionKey !== "string" ||
      typeof parsed.savedAtEpochSeconds !== "number" ||
      !isFinite(parsed.savedAtEpochSeconds) ||
      !isPlainBufferState(parsed.trendState) ||
      !isPlainBufferState(parsed.chartState)
    ) {
      return null;
    }
    return parsed;
  }

  // pruneStaleSamples: a SHAPE-PRESERVING window filter -- unlike
  // selectSamplesInWindow (which reshapes into {t,value} pairs purely for
  // chart scaling), a restored buffer must keep each sample's ORIGINAL
  // shape ({t,delay} for the trend buffer / {t,sendMbit,recordMbit,
  // delaySeconds} for the chart buffer) so the result is valid drop-in
  // state for updateDelayTrendState/updateChartBufferState to keep
  // extending on the next poll.
  function pruneStaleSamples(samples, nowSeconds, windowSeconds) {
    if (!Array.isArray(samples) || typeof nowSeconds !== "number" || !isFinite(nowSeconds)) {
      return [];
    }
    var win = typeof windowSeconds === "number" && isFinite(windowSeconds) && windowSeconds > 0 ? windowSeconds : 0;
    var minT = nowSeconds - win;
    var result = [];
    for (var i = 0; i < samples.length; i += 1) {
      var sample = samples[i];
      if (sample && typeof sample.t === "number" && isFinite(sample.t) && sample.t >= minT && sample.t <= nowSeconds) {
        result.push(sample);
      }
    }
    return result;
  }

  function sanitizePreviousSessionDurationSeconds(value) {
    return typeof value === "number" && isFinite(value) ? value : null;
  }

  // restoreDashboardHistory: the one restore-decision entry point app.js
  // calls on load. Returns { trendState, chartState } (each pruned to its
  // own window and shape-sanitized, ready to replace the live buffers
  // outright) when the stored payload is genuinely usable, or null when it
  // must be discarded -- which IS the desired "keep one session's data,
  // overwrite per stream/day" behavior: a new session naturally fails the
  // sessionKey match and starts fresh, with no separate "clear old data"
  // step required.
  //
  // Discard conditions (any one is enough):
  //   - payload/currentSessionKey/nowSeconds missing or malformed.
  //   - payload.sessionKey !== currentSessionKey (a different/new session).
  //   - the payload itself is older than maxAgeSeconds (default 1 hour) --
  //     an explicit staleness guard independent of the per-sample window
  //     pruning below, for an orphaned entry from a much earlier, unrelated
  //     stretch of time that happens to collide on sessionKey.
  function restoreDashboardHistory(payload, currentSessionKey, nowSeconds, trendWindowSeconds, chartWindowSeconds, maxAgeSeconds) {
    if (
      !payload ||
      typeof payload !== "object" ||
      typeof currentSessionKey !== "string" ||
      typeof nowSeconds !== "number" ||
      !isFinite(nowSeconds)
    ) {
      return null;
    }
    if (payload.sessionKey !== currentSessionKey) {
      return null;
    }

    var ceiling =
      typeof maxAgeSeconds === "number" && isFinite(maxAgeSeconds) && maxAgeSeconds > 0 ? maxAgeSeconds : 3600;
    if (
      typeof payload.savedAtEpochSeconds !== "number" ||
      !isFinite(payload.savedAtEpochSeconds) ||
      nowSeconds - payload.savedAtEpochSeconds > ceiling
    ) {
      return null;
    }

    var trendSamples = pruneStaleSamples(
      isPlainBufferState(payload.trendState) ? payload.trendState.samples : [],
      nowSeconds,
      trendWindowSeconds
    );
    var chartSamples = pruneStaleSamples(
      isPlainBufferState(payload.chartState) ? payload.chartState.samples : [],
      nowSeconds,
      chartWindowSeconds
    );

    return {
      trendState: {
        samples: trendSamples,
        previousSessionDurationSeconds: sanitizePreviousSessionDurationSeconds(
          payload.trendState && payload.trendState.previousSessionDurationSeconds
        ),
      },
      chartState: {
        samples: chartSamples,
        previousSessionDurationSeconds: sanitizePreviousSessionDurationSeconds(
          payload.chartState && payload.chartState.previousSessionDurationSeconds
        ),
      },
    };
  }

  // Probe status (D-02 enum: ok|degraded|down|unknown) -> status-pill class
  // (06-UI-SPEC Color section) -- the single canonical mapping, consumed by
  // resolveProbeDisplayState below. "down" deliberately maps to the neutral
  // gray state-idle, not a destructive/red class -- a down probe is a status
  // observation, not an operator action to warn against.
  var PROBE_BASE_STATUS_CLASS = {
    ok: "state-streaming",
    degraded: "state-reconnecting",
    down: "state-idle",
    unknown: "state-unknown",
  };

  // resolveProbeDisplayState (260719-fmu-05): a probe reporting 'down' while
  // the pusher's own main stats show a genuinely healthy stream (Streaming +
  // fresh) is very likely a probe-path problem, not a real outage -- render
  // that specific combination calmly/neutrally ("unverified") instead of
  // alarming, and swap the probe's own raw detail text for plain operator
  // language. Every other combination (probe down while the stream itself is
  // NOT confirmed healthy, or any non-'down' probe status) keeps the
  // existing mapping and lets the caller show the probe's own detail text
  // unchanged -- that's exactly when the probe genuinely matters.
  //
  // probeStatus: the probe's own reported status ('ok'|'degraded'|'down'|'unknown'
  //   or any other string -- treated as 'unknown').
  // connectionState: the pusher's own ConnectionState (view model field).
  // mainStatsIsStale: the pusher's own IsStale flag (view model field) --
  //   this is the MAIN /api/stats freshness signal, NOT a probe's own
  //   per-probe staleness (lastUpdateAgeSeconds); the caller applies
  //   per-probe staleness on top, at the same precedence it already used.
  function resolveProbeDisplayState(probeStatus, connectionState, mainStatsIsStale) {
    var streamConfirmedHealthy = connectionState === "Streaming" && mainStatsIsStale !== true;
    var probeReportsDown = probeStatus === "down";

    if (streamConfirmedHealthy && probeReportsDown) {
      return {
        pillClass: "state-unknown",
        pillText: "unverified",
        message:
          "Probe can't reach the relay to verify it — the stream itself is flowing normally, so this is likely a probe-path issue, not an outage.",
      };
    }

    var statusText = probeStatus || "unknown";
    return {
      pillClass: PROBE_BASE_STATUS_CLASS[statusText] || "state-unknown",
      pillText: statusText,
      message: null,
    };
  }

  function formatSessionOutcome(durationSeconds, undeliveredBytes) {
    // Calm, honest finished-screen summary (260718-epo). durationSeconds is accepted
    // for signature symmetry with the view-model call site (app.js renders it
    // separately via formatDuration/session-finished-duration) -- this function's own
    // copy is driven entirely by undeliveredBytes, never fabricated:
    //   - 0, null, undefined, or any non-positive/non-finite value -> the plain
    //     "everything sent" line (matches formatMegabytes/formatBytes's own
    //     null/NaN/non-finite guard style).
    //   - a real positive number -> an honest "<N MB> not delivered" line.
    var hasUndeliveredBytes =
      typeof undeliveredBytes === "number" && isFinite(undeliveredBytes) && undeliveredBytes > 0;

    if (!hasUndeliveredBytes) {
      return "Service finished — recording ended, everything sent, ready for next service.";
    }

    return (
      "Service finished — " +
      formatMegabytes(undeliveredBytes) +
      " not delivered (relay dropped at end). Everything else was sent."
    );
  }

  function computeEffectiveCatchUp(sendBytesPerSecond, recordBytesPerSecond) {
    // send/record -- never divide-by-zero, never Infinity/NaN out the other side
    // (DASH-05/DASH-07): a non-positive or non-finite record rate, or a non-finite
    // send rate, means "no honest ratio to report" -- null, not a fabricated number.
    if (
      sendBytesPerSecond === null || sendBytesPerSecond === undefined ||
      typeof sendBytesPerSecond !== "number" || !isFinite(sendBytesPerSecond) ||
      recordBytesPerSecond === null || recordBytesPerSecond === undefined ||
      typeof recordBytesPerSecond !== "number" || !isFinite(recordBytesPerSecond) ||
      recordBytesPerSecond <= 0
    ) {
      return null;
    }
    return sendBytesPerSecond / recordBytesPerSecond;
  }

  var DashboardFormat = {
    formatMegabytes: formatMegabytes,
    computeEffectiveCatchUp: computeEffectiveCatchUp,
    formatSessionOutcome: formatSessionOutcome,
    formatHumanDuration: formatHumanDuration,
    computeDelayTrend: computeDelayTrend,
    updateDelayTrendState: updateDelayTrendState,
    isSessionRestart: isSessionRestart,
    resolveProbeDisplayState: resolveProbeDisplayState,
    computeLinearScale: computeLinearScale,
    invertLinearScale: invertLinearScale,
    computeNiceAxisMax: computeNiceAxisMax,
    selectSamplesInWindow: selectSamplesInWindow,
    findNearestSampleIndex: findNearestSampleIndex,
    buildMonotonePathD: buildMonotonePathD,
    updateChartBufferState: updateChartBufferState,
    buildHeroChart: buildHeroChart,
    deriveSessionKey: deriveSessionKey,
    buildDashboardHistoryPayload: buildDashboardHistoryPayload,
    serializeDashboardHistory: serializeDashboardHistory,
    parseDashboardHistory: parseDashboardHistory,
    pruneStaleSamples: pruneStaleSamples,
    restoreDashboardHistory: restoreDashboardHistory,
  };

  if (typeof window !== "undefined") {
    window.DashboardFormat = DashboardFormat;
  }

  if (typeof module !== "undefined" && module.exports) {
    module.exports = DashboardFormat;
  }
})();
