// Outage-Proof Livestream — Dashboard client
// Plain browser JavaScript. No imports, no bundler, no framework, no CDN.
// Binds against the frozen element-id contract from 05-08 and the view-model
// shape from 05-05/05-07 (Get-DashboardViewModel / GET /api/stats).

(function () {
  "use strict";

  // dashboard/format.js loads BEFORE this script (plain <script>, no defer) so
  // window.DashboardFormat already exists at this point; the empty-object
  // fallback is defensive only (e.g. a load-order regression), never expected
  // in production (DASH-05/06/07).
  var DashboardFormat = window.DashboardFormat || {};

  var POLL_INTERVAL_MS = 1000;
  var FETCH_TIMEOUT_MS = 5000;

  // POST /api/config (Write-DotEnvFile) is keyed by the SCREAMING_SNAKE_CASE
  // .env EnvKey -- matches these ids and the setting-{ENV_KEY} id contract
  // from 05-08. GET /api/config (Get-RedactedConfig) instead serializes the
  // typed Config object, whose properties are PascalCase (lib/Config.psm1's
  // ConfigSchema Property column) -- the "property" field below is that
  // read-side name, used only to populate the form at load.
  var SETTINGS_FIELDS = [
    { envKey: "RELAY_HOST", property: "RelayHost" },
    { envKey: "RELAY_PORT", property: "RelayPort" },
    { envKey: "CATCH_UP_MULTIPLIER", property: "CatchUpMultiplier" },
    { envKey: "SEND_CEILING_BYTES_PER_SECOND", property: "SendCeilingBytesPerSecond" },
    { envKey: "RELAY_PROTOCOL", property: "RelayProtocol" },
    { envKey: "DASHBOARD_PORT", property: "DashboardPort" },
    { envKey: "RECORDING_FOLDER_PATH", property: "RecordingFolderPath" },
    { envKey: "RECORDING_FILENAME_GLOB", property: "RecordingFilenameGlob" },
    { envKey: "STREAM_ID", property: "StreamId" },
    { envKey: "LATENCY_MICROSECONDS", property: "LatencyMicroseconds" },
    { envKey: "AUTO_PICKUP", property: "AutoPickupEnabled" },
  ];

  var CONNECTION_STATE_CLASS = {
    Idle: "state-idle",
    Streaming: "state-streaming",
    Reconnecting: "state-reconnecting",
    Draining: "state-draining",
    Unknown: "state-unknown",
    Finished: "state-finished",
  };

  var ALL_STATE_CLASSES = [
    "state-idle",
    "state-streaming",
    "state-reconnecting",
    "state-draining",
    "state-unknown",
    "state-finished",
  ];

  // Previous OutageActive value, tracked across polls for edge-triggered
  // notifications (D-19/D-20). null = unknown (no render observed yet), so
  // the very first render never fires a spurious notification for an outage
  // that was already in progress when the page opened.
  var previousOutageActive = null;

  // Latest polled view model, kept so the Cut confirmation dialog can be
  // built from the current truth at open time, never a page-load snapshot.
  var latestViewModel = null;

  var settingsLoaded = false;
  var settingsSaveInFlight = false;

  // WR-01: ColdStartCatchUpCeilingBytesPerSecond has no settings-form input (it is
  // not operator-live-dialed the way CATCH_UP_MULTIPLIER/SEND_CEILING_BYTES_PER_SECOND
  // are), so it is captured here from the GET /api/config response the one time
  // populateSettingsForm runs, purely so updateGoverningCapReadout can name it as the
  // real, actively-enforced cap during cold start -- never fabricated, always the
  // last value the backend itself reported.
  var latestColdStartCeilingBytesPerSecond = null;

  // ---------- Delay trend (260719-fmu-04, reset policy fixed in fmu-06) ----------
  // Client-side-only ring buffer of {t: <wall-clock seconds>, delay:
  // <DelaySecondsBehindLive>} samples, fed at poll cadence.
  // DashboardFormat.updateDelayTrendState/computeDelayTrend (dashboard/format.js)
  // own ALL of the pure collection/reset/comparison logic -- this file only
  // keeps the current state object and drives the DOM from it. Moving the
  // reset policy into format.js is what made the fmu-06 "stuck on measuring"
  // bug reproducible and fixable via node --test (app.js itself cannot be
  // required under node -- it reads `window` unconditionally at load time).
  var DELAY_TREND_WINDOW_SECONDS = 60;
  var delayTrendState = { samples: [], previousSessionDurationSeconds: null };

  var ALL_TREND_CLASSES = ["hero-trend-positive", "hero-trend-warning", "hero-trend-neutral", "hero-trend-measuring"];

  var TREND_STATUS_CLASS = {
    measuring: "hero-trend-measuring",
    steady: "hero-trend-neutral",
    improving: "hero-trend-positive",
    worsening: "hero-trend-warning",
  };

  function updateDelayTrendSamples(viewModel) {
    delayTrendState = DashboardFormat.updateDelayTrendState(
      delayTrendState,
      viewModel,
      Date.now() / 1000,
      DELAY_TREND_WINDOW_SECONDS
    );
  }

  function renderDelayTrend() {
    var trend = DashboardFormat.computeDelayTrend(delayTrendState.samples, Date.now() / 1000, DELAY_TREND_WINDOW_SECONDS);
    var el = byId("hero-delay-trend");
    if (!el) {
      return;
    }
    el.textContent = trend.text;
    for (var i = 0; i < ALL_TREND_CLASSES.length; i += 1) {
      el.classList.remove(ALL_TREND_CLASSES[i]);
    }
    el.classList.add(TREND_STATUS_CLASS[trend.status] || "hero-trend-measuring");
  }

  // ---------- Hero mini-chart (260719-fmu-07) ----------
  // Hand-rolled inline SVG, no charting library, no build step. ALL
  // scaling/path/windowing math lives in DashboardFormat (dashboard/format.js,
  // node-testable); this section is thin DOM wiring only -- build/update SVG
  // nodes from an already-computed pixel-space chart spec, plus a small
  // hover/crosshair/tooltip layer driven by the same pure invert/nearest
  // helpers.
  var SVG_NS = "http://www.w3.org/2000/svg";
  var HERO_CHART_WINDOW_SECONDS = 300; // 5-minute rolling window
  var HERO_CHART_TOP_WIDTH = 600;
  var HERO_CHART_TOP_HEIGHT = 90;
  var HERO_CHART_BOTTOM_WIDTH = 600;
  var HERO_CHART_BOTTOM_HEIGHT = 30;

  // Reuses the SAME restart/pause reset policy as the delay trend buffer
  // (DashboardFormat.updateChartBufferState shares isSessionRestart with
  // updateDelayTrendState) but keeps its own 5-minute window and its own
  // richer per-tick payload (one combined {t, sendMbit, recordMbit,
  // delaySeconds} sample per poll -- guarantees the three series share an
  // EXACT time axis, never three independently-timestamped buffers).
  var heroChartBufferState = { samples: [], previousSessionDurationSeconds: null };
  var latestHeroChart = null;

  function updateHeroChartBuffer(viewModel) {
    heroChartBufferState = DashboardFormat.updateChartBufferState(
      heroChartBufferState,
      viewModel,
      Date.now() / 1000,
      HERO_CHART_WINDOW_SECONDS
    );
  }

  function svgEl(tag, attrs) {
    var el = document.createElementNS(SVG_NS, tag);
    if (attrs) {
      for (var key in attrs) {
        if (Object.prototype.hasOwnProperty.call(attrs, key)) {
          el.setAttribute(key, attrs[key]);
        }
      }
    }
    return el;
  }

  function appendHeroChartGridLines(svg, gridLines, width) {
    for (var i = 0; i < gridLines.length; i += 1) {
      var line = gridLines[i];
      svg.appendChild(svgEl("line", { x1: 0, x2: width, y1: line.y, y2: line.y, class: "hero-chart-gridline" }));
      if (line.label) {
        var text = svgEl("text", { x: 2, y: Math.max(8, line.y - 2), class: "hero-chart-axis-label" });
        text.textContent = line.label;
        svg.appendChild(text);
      }
    }
  }

  // Direct end label (dataviz method: label the line itself, no legend) --
  // an 8px colored swatch carries the color identity; the text stays in the
  // page's normal text color (never colored text) per the same rule.
  function appendHeroChartEndLabel(svg, point, swatchClass) {
    svg.appendChild(svgEl("circle", { cx: point.x, cy: point.y, r: 4, class: "hero-chart-swatch " + swatchClass }));
    var text = svgEl("text", {
      x: point.x - 6,
      y: point.y - 6,
      class: "hero-chart-end-label",
      "text-anchor": "end",
    });
    text.textContent = point.text;
    svg.appendChild(text);
  }

  function renderHeroChartTopPanel(svg, top) {
    if (!svg) {
      return;
    }
    svg.textContent = "";
    if (!top.hasData) {
      return;
    }
    // Lines only (260719-fmu-08, operator design feedback) -- no area fill
    // under send, clean 2px lines carry the data.
    appendHeroChartGridLines(svg, top.gridLines, HERO_CHART_TOP_WIDTH);
    if (top.recordPathD) {
      svg.appendChild(svgEl("path", { d: top.recordPathD, class: "hero-chart-line hero-chart-line-record" }));
    }
    if (top.sendPathD) {
      svg.appendChild(svgEl("path", { d: top.sendPathD, class: "hero-chart-line hero-chart-line-send" }));
    }
    if (top.nicPathD) {
      svg.appendChild(svgEl("path", { d: top.nicPathD, class: "hero-chart-line hero-chart-line-nic" }));
    }
    if (top.sendEndLabel) {
      appendHeroChartEndLabel(svg, top.sendEndLabel, "hero-chart-swatch-send");
    }
    if (top.recordEndLabel) {
      appendHeroChartEndLabel(svg, top.recordEndLabel, "hero-chart-swatch-record");
    }
    if (top.nicEndLabel) {
      appendHeroChartEndLabel(svg, top.nicEndLabel, "hero-chart-swatch-nic");
    }
  }

  function renderHeroChartBottomPanel(svg, bottom) {
    if (!svg) {
      return;
    }
    svg.textContent = "";
    if (!bottom.hasData) {
      return;
    }
    // Lines only (260719-fmu-08, operator design feedback) -- no delay band
    // fill, a single clean line carries the data.
    appendHeroChartGridLines(svg, bottom.gridLines, HERO_CHART_BOTTOM_WIDTH);
    if (bottom.delayPathD) {
      svg.appendChild(svgEl("path", { d: bottom.delayPathD, class: "hero-chart-line hero-chart-line-delay" }));
    }
  }

  function renderHeroChart() {
    var placeholder = byId("hero-chart-placeholder");
    var body = byId("hero-chart-body");
    if (!placeholder || !body) {
      return;
    }

    var chart = DashboardFormat.buildHeroChart({
      samples: heroChartBufferState.samples,
      nowSeconds: Date.now() / 1000,
      windowSeconds: HERO_CHART_WINDOW_SECONDS,
      topWidth: HERO_CHART_TOP_WIDTH,
      topHeight: HERO_CHART_TOP_HEIGHT,
      bottomWidth: HERO_CHART_BOTTOM_WIDTH,
      bottomHeight: HERO_CHART_BOTTOM_HEIGHT,
    });
    latestHeroChart = chart;

    // No fake/partial data (D-13): until there's enough real history to draw
    // even one line, show an honest "collecting…" placeholder instead of an
    // empty or misleading chart shell.
    if (!chart.hasAnyData) {
      placeholder.hidden = false;
      body.hidden = true;
      hideHeroChartHover();
      return;
    }
    placeholder.hidden = true;
    body.hidden = false;

    setText("hero-chart-window-label", "last " + chart.xAxisLabel);
    renderHeroChartTopPanel(byId("hero-chart-top"), chart.top);
    renderHeroChartBottomPanel(byId("hero-chart-bottom"), chart.bottom);
  }

  // ---------- Hero mini-chart hover (crosshair + shared tooltip) ----------
  // ONE hit area (the whole chart-body block, top+bottom panels together)
  // drives a single crosshair + tooltip for the whole component (dataviz
  // method: bitrate and delay panels read as one component, shared hover).

  function buildHeroChartTooltipRow(label, value, swatchClass) {
    var row = document.createElement("div");
    row.className = "hero-chart-tooltip-row";
    if (swatchClass) {
      var swatch = document.createElement("span");
      swatch.className = "hero-chart-tooltip-swatch " + swatchClass;
      row.appendChild(swatch);
    }
    var labelEl = document.createElement("span");
    labelEl.className = "hero-chart-tooltip-label";
    labelEl.textContent = label;
    row.appendChild(labelEl);
    var valueEl = document.createElement("span");
    valueEl.className = "hero-chart-tooltip-value";
    valueEl.textContent = value;
    row.appendChild(valueEl);
    return row;
  }

  function hideHeroChartHover() {
    var crosshair = byId("hero-chart-crosshair");
    if (crosshair) {
      crosshair.hidden = true;
    }
    var tooltip = byId("hero-chart-tooltip");
    if (tooltip) {
      tooltip.hidden = true;
    }
  }

  function handleHeroChartHoverAtClientX(clientX) {
    if (!latestHeroChart || !latestHeroChart.hasAnyData) {
      return;
    }
    var body = byId("hero-chart-body");
    if (!body) {
      return;
    }
    var rect = body.getBoundingClientRect();
    if (!(rect.width > 0)) {
      return;
    }

    var fraction = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
    var xScale = latestHeroChart.xScale;
    // xScale.rangeMax is the shared viewBox width both SVGs were built with
    // (buildHeroChart's topWidth) -- deriving from it here (rather than a
    // second hardcoded constant) keeps hover math correct even if the panel
    // dimensions ever change in one place without the other.
    var hoveredT = DashboardFormat.invertLinearScale(
      fraction * xScale.rangeMax,
      xScale.domainMin,
      xScale.domainMax,
      xScale.rangeMin,
      xScale.rangeMax
    );

    var nearestIndex = DashboardFormat.findNearestSampleIndex(heroChartBufferState.samples, hoveredT);
    if (nearestIndex === -1) {
      hideHeroChartHover();
      return;
    }
    var sample = heroChartBufferState.samples[nearestIndex];

    // Snap the crosshair to the ACTUAL nearest sample's timestamp, not the
    // raw cursor position -- the tooltip's numbers must match exactly where
    // the crosshair visually points.
    var snappedX = DashboardFormat.computeLinearScale(
      sample.t,
      xScale.domainMin,
      xScale.domainMax,
      xScale.rangeMin,
      xScale.rangeMax
    );
    var snappedFraction = snappedX / xScale.rangeMax;

    var crosshair = byId("hero-chart-crosshair");
    if (crosshair) {
      crosshair.style.left = snappedFraction * 100 + "%";
      crosshair.hidden = false;
    }

    var tooltip = byId("hero-chart-tooltip");
    if (tooltip) {
      var ageSeconds = Math.max(0, Date.now() / 1000 - sample.t);
      var timeText = ageSeconds < 2 ? "now" : DashboardFormat.formatHumanDuration(ageSeconds) + " ago";
      var sendText = typeof sample.sendMbit === "number" ? sample.sendMbit.toFixed(1) + " Mbit/s" : "—";
      var recordText = typeof sample.recordMbit === "number" ? sample.recordMbit.toFixed(1) + " Mbit/s" : "—";
      var nicText = typeof sample.nicMbit === "number" ? sample.nicMbit.toFixed(1) + " Mbit/s" : "—";
      var delayText =
        typeof sample.delaySeconds === "number" ? DashboardFormat.formatHumanDuration(sample.delaySeconds) : "—";

      tooltip.textContent = "";
      tooltip.appendChild(buildHeroChartTooltipRow("time", timeText));
      tooltip.appendChild(buildHeroChartTooltipRow("send", sendText, "hero-chart-swatch-send"));
      tooltip.appendChild(buildHeroChartTooltipRow("record", recordText, "hero-chart-swatch-record"));
      tooltip.appendChild(buildHeroChartTooltipRow("nic", nicText, "hero-chart-swatch-nic"));
      tooltip.appendChild(buildHeroChartTooltipRow("delay", delayText, "hero-chart-swatch-delay"));
      tooltip.hidden = false;

      // Clamp so the tooltip never overflows past the chart's right edge.
      var tooltipLeftFraction = Math.min(0.78, Math.max(0, snappedFraction - 0.05));
      tooltip.style.left = tooltipLeftFraction * 100 + "%";
    }
  }

  function handleHeroChartMouseMove(event) {
    handleHeroChartHoverAtClientX(event.clientX);
  }

  function handleHeroChartTouchMove(event) {
    if (!event.touches || event.touches.length === 0) {
      return;
    }
    handleHeroChartHoverAtClientX(event.touches[0].clientX);
  }

  function wireHeroChartHover() {
    var body = byId("hero-chart-body");
    if (!body) {
      return;
    }
    body.addEventListener("mousemove", handleHeroChartMouseMove);
    body.addEventListener("mouseleave", hideHeroChartHover);
    // Touch: a simple tap-and-drag nicety, no separate gesture handling
    // (kept simple per spec -- this is not a full mobile chart interaction).
    body.addEventListener("touchmove", handleHeroChartTouchMove, { passive: true });
    body.addEventListener("touchend", hideHeroChartHover);
  }

  // ---------- Dashboard history persistence (260719-fmu-08) ----------
  // Mirrors delayTrendState/heroChartBufferState into localStorage so a
  // browser refresh mid-service doesn't lose the last few minutes of
  // history. ALL serialize/validate/prune/restore-decision logic lives in
  // DashboardFormat (node-tested against a mock storage object); this
  // section only owns the real localStorage.getItem/setItem calls, feature
  // detection, and try/catch -- the dashboard must never break over a
  // denied/quota-exceeded/corrupted storage entry (D-13 extends to
  // persistence: a storage failure degrades to the normal cold-start empty
  // buffers, never a fabricated or crashed dashboard).
  var DASHBOARD_HISTORY_STORAGE_KEY = "gapless-dashboard-history-v1";
  var DASHBOARD_HISTORY_PERSIST_THROTTLE_SECONDS = 5;

  // "Keep ONE session's data, overwrite per stream/day" semantics: sessionKey
  // (DashboardFormat.deriveSessionKey) is derived from the exact same
  // SessionDurationSeconds signal isSessionRestart already keys off, so a
  // sessionKey CHANGE here is a faithful proxy for "the in-memory buffers
  // just got wiped by updateDelayTrendState/updateChartBufferState's own
  // isSessionRestart check" -- this clears the localStorage mirror in
  // lockstep, without duplicating that tolerance-based restart check a
  // second time against a second field.
  var previousSessionKeyForPersistence = null;
  var lastPersistedAtEpochSeconds = null;
  var historyRestoreAttempted = false;

  function isLocalStorageAvailable() {
    try {
      if (typeof window === "undefined" || !window.localStorage) {
        return false;
      }
      var probeKey = "__gapless_dashboard_storage_probe__";
      window.localStorage.setItem(probeKey, "1");
      window.localStorage.removeItem(probeKey);
      return true;
    } catch (e) {
      // Privacy mode, disabled storage, or a quota already exhausted at
      // probe time -- treat storage as entirely unavailable for this
      // session rather than retrying on every poll.
      return false;
    }
  }

  var localStorageAvailable = isLocalStorageAvailable();

  // Runs at most ONCE per page load, on the first poll where a real
  // sessionKey can be derived (never on a renderLostContact() synthetic
  // poll, which has no SessionDurationSeconds -- retried on the NEXT real
  // poll instead of permanently giving up the one-time restore chance).
  function applyPersistedHistoryIfAny(viewModel, nowSeconds) {
    if (historyRestoreAttempted || !localStorageAvailable) {
      return;
    }
    var currentSessionKey = DashboardFormat.deriveSessionKey(viewModel, nowSeconds);
    if (currentSessionKey === null) {
      return;
    }
    historyRestoreAttempted = true; // a definitive decision follows -- never retried again

    try {
      var raw = window.localStorage.getItem(DASHBOARD_HISTORY_STORAGE_KEY);
      if (raw) {
        var payload = DashboardFormat.parseDashboardHistory(raw);
        var restored = payload
          ? DashboardFormat.restoreDashboardHistory(
              payload,
              currentSessionKey,
              nowSeconds,
              DELAY_TREND_WINDOW_SECONDS,
              HERO_CHART_WINDOW_SECONDS
            )
          : null;
        if (restored) {
          delayTrendState = restored.trendState;
          heroChartBufferState = restored.chartState;
        }
      }
    } catch (e) {
      // Corrupt/blocked storage -- proceed with the normal cold-start empty
      // buffers, never break the dashboard over a bad persisted entry.
    }

    previousSessionKeyForPersistence = currentSessionKey;
  }

  function persistDashboardHistoryThrottled(viewModel, nowSeconds) {
    if (!localStorageAvailable) {
      return;
    }
    var currentSessionKey = DashboardFormat.deriveSessionKey(viewModel, nowSeconds);

    if (
      previousSessionKeyForPersistence !== null &&
      currentSessionKey !== null &&
      currentSessionKey !== previousSessionKeyForPersistence
    ) {
      try {
        window.localStorage.removeItem(DASHBOARD_HISTORY_STORAGE_KEY);
      } catch (e) {
        // Ignore -- never break the dashboard over a storage clear failure.
      }
    }
    if (currentSessionKey !== null) {
      previousSessionKeyForPersistence = currentSessionKey;
    } else {
      // No stable session identity yet -- nothing meaningful to persist.
      return;
    }

    if (
      lastPersistedAtEpochSeconds !== null &&
      nowSeconds - lastPersistedAtEpochSeconds < DASHBOARD_HISTORY_PERSIST_THROTTLE_SECONDS
    ) {
      return;
    }
    lastPersistedAtEpochSeconds = nowSeconds;

    try {
      var payload = DashboardFormat.buildDashboardHistoryPayload(
        currentSessionKey,
        delayTrendState,
        heroChartBufferState,
        nowSeconds
      );
      var serialized = DashboardFormat.serializeDashboardHistory(payload);
      if (serialized !== null) {
        window.localStorage.setItem(DASHBOARD_HISTORY_STORAGE_KEY, serialized);
      }
    } catch (e) {
      // Quota exceeded / storage revoked mid-session -- degrade silently,
      // never break the live (in-memory) dashboard over a persistence failure.
    }
  }

  function byId(id) {
    return document.getElementById(id);
  }

  // ---------- Formatting helpers ----------

  function formatBytes(n) {
    if (n === null || n === undefined || typeof n !== "number" || !isFinite(n)) {
      return "—";
    }
    var units = ["B", "KB", "MB", "GB", "TB"];
    var value = Math.abs(n);
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value = value / 1024;
      unitIndex += 1;
    }
    var sign = n < 0 ? "-" : "";
    var decimals = unitIndex === 0 ? 0 : 1;
    return sign + value.toFixed(decimals) + " " + units[unitIndex];
  }

  function formatMbit(bytesPerSecond) {
    if (bytesPerSecond === null || bytesPerSecond === undefined || typeof bytesPerSecond !== "number" || !isFinite(bytesPerSecond)) {
      return "—";
    }
    var mbit = (bytesPerSecond * 8) / 1e6;
    return mbit.toFixed(1) + " Mbit/s";
  }

  // DIAL-02: the Mbit/s<->bytes/s conversion contract, matching
  // lib/Config.psm1's ConvertTo-MegabitsPerSecondFromBytesPerSecond /
  // ConvertTo-BytesPerSecondFromMegabitsPerSecond (1 Mbit/s = 125000 bytes/s
  // exactly; display rounds half-up to 1 decimal). The .env's
  // SEND_CEILING_BYTES_PER_SECOND stays the raw-bytes source of truth --
  // these two helpers only cross the display/edit boundary in the dashboard.
  var BYTES_PER_SECOND_PER_MEGABIT_PER_SECOND = 125000;

  function bytesPerSecondToMegabitsPerSecond(bytesPerSecond) {
    var value = typeof bytesPerSecond === "number" && isFinite(bytesPerSecond) ? bytesPerSecond : 0;
    var megabits = value / BYTES_PER_SECOND_PER_MEGABIT_PER_SECOND;
    var sign = megabits < 0 ? -1 : 1;
    return (sign * Math.round(Math.abs(megabits) * 10)) / 10;
  }

  function megabitsPerSecondToBytesPerSecond(megabitsPerSecondValue) {
    // Blank/missing/unparseable/negative all resolve to 0 (off -- multiplier
    // governs), matching Read-LiveTunableOverrides' safe-default discipline.
    var value = parseFloat(megabitsPerSecondValue);
    if (!isFinite(value) || value < 0) {
      value = 0;
    }
    return Math.round(value * BYTES_PER_SECOND_PER_MEGABIT_PER_SECOND);
  }

  // DIAL-02/WR-01: pure client-side mirror of Get-CatchUpSendCeiling
  // (lib/Pacer.psm1) -- ceiling > 0 REPLACES the multiplier entirely; ceiling == 0
  // falls back to the multiplier governing (multiplier x observed record rate,
  // when a record rate is available); and when NEITHER a positive ceiling NOR a
  // usable record rate exists (cold start, or a Draining session before any
  // growth tick), the backend's own Get-CatchUpSendCeiling falls back to
  // ColdStartCatchUpCeilingBytesPerSecond -- this third branch mirrors that exactly,
  // closing the truthfulness gap where the dashboard previously read "multiplier
  // 1.5x" with no value, implying "unknown" instead of naming the real, actively-
  // enforced cold-start cap. Display-only derivation, no new endpoint -- consumes
  // the same /api/config-polled dial values already in the settings form plus the
  // existing view model's RecordBytesPerSecond.
  function computeGoverningCap(sendCeilingBytesPerSecond, catchUpMultiplier, recordBytesPerSecond, coldStartCeilingBytesPerSecond) {
    var ceiling =
      typeof sendCeilingBytesPerSecond === "number" && isFinite(sendCeilingBytesPerSecond) && sendCeilingBytesPerSecond > 0
        ? sendCeilingBytesPerSecond
        : 0;

    if (ceiling > 0) {
      return { governor: "ceiling", capBytesPerSecond: ceiling };
    }

    var multiplier = typeof catchUpMultiplier === "number" && isFinite(catchUpMultiplier) ? catchUpMultiplier : null;
    var recordRate =
      typeof recordBytesPerSecond === "number" && isFinite(recordBytesPerSecond) && recordBytesPerSecond > 0
        ? recordBytesPerSecond
        : null;

    if (multiplier !== null && recordRate !== null) {
      return { governor: "multiplier", capBytesPerSecond: multiplier * recordRate };
    }

    var coldStartCeiling =
      typeof coldStartCeilingBytesPerSecond === "number" && isFinite(coldStartCeilingBytesPerSecond) && coldStartCeilingBytesPerSecond > 0
        ? coldStartCeilingBytesPerSecond
        : null;
    if (coldStartCeiling !== null) {
      return { governor: "cold-start-ceiling", capBytesPerSecond: coldStartCeiling };
    }

    return { governor: "multiplier", capBytesPerSecond: null };
  }

  function formatCount(n) {
    if (n === null || n === undefined || typeof n !== "number" || !isFinite(n)) {
      return "—";
    }
    return String(n);
  }

  function formatPercent(n) {
    if (n === null || n === undefined || typeof n !== "number" || !isFinite(n)) {
      return "—";
    }
    return (n * 100).toFixed(0) + "%";
  }

  // Recording filenames arrive as full paths (e.g. from RecordingFilePath /
  // recordings-list fullName) -- only the basename is ever shown (05.1
  // UI-SPEC: "filename only, not the full path, to keep the indicator
  // scannable").
  function basename(path) {
    if (!path) {
      return null;
    }
    var parts = String(path).split(/[\\/]/);
    return parts[parts.length - 1];
  }

  // Relative-age formatting for the recordings list (05.1 UI-SPEC Numeric
  // Display Rules) -- reinforces SESS-01's stale-vs-current mental model on
  // the exact screen where the operator decides what's safe to delete.
  function formatRelativeAge(isoTimestamp) {
    if (!isoTimestamp) {
      return "—";
    }
    var thenMs = new Date(isoTimestamp).getTime();
    if (!isFinite(thenMs)) {
      return "—";
    }
    var deltaSeconds = Math.max(0, Math.round((Date.now() - thenMs) / 1000));
    if (deltaSeconds < 60) {
      return "just now";
    }
    var minutes = Math.floor(deltaSeconds / 60);
    if (minutes < 60) {
      return minutes + "m ago";
    }
    var hours = Math.floor(minutes / 60);
    if (hours < 24) {
      return hours + "h ago";
    }
    var days = Math.floor(hours / 24);
    return days + "d ago";
  }

  function setText(id, text) {
    var el = byId(id);
    if (el) {
      el.textContent = text;
    }
  }

  // DASH-06: exact-bytes-on-hover, set via .title/setAttribute from a
  // number-derived string -- never markup, matching this file's existing
  // textContent-only XSS discipline. One or two byte values (offset shows a
  // sent/total pair; the timeline labels each show one value on their own).
  function setExactByteTitle(id, bytesA, bytesB) {
    var el = byId(id);
    if (!el) {
      return;
    }
    var partA = typeof bytesA === "number" && isFinite(bytesA) ? String(bytesA) + " bytes" : "—";
    if (arguments.length < 3) {
      el.title = partA;
      return;
    }
    var partB = typeof bytesB === "number" && isFinite(bytesB) ? String(bytesB) + " bytes" : "—";
    el.title = partA + " / " + partB;
  }

  // DASH-07: "1.19x (cap 1.5x)" -- send/record vs the configured
  // CATCH_UP_MULTIPLIER (read from the settings input, already populated by
  // loadSettingsOnce/populateSettingsForm). "—" when the effective ratio
  // cannot be honestly computed (DashboardFormat.computeEffectiveCatchUp's
  // own null guard -- non-positive/non-finite record rate).
  function formatCatchUpRatio(sendBytesPerSecond, recordBytesPerSecond) {
    var effective = DashboardFormat.computeEffectiveCatchUp(sendBytesPerSecond, recordBytesPerSecond);
    if (effective === null || effective === undefined || !isFinite(effective)) {
      return "—";
    }
    var capInput = byId("setting-CATCH_UP_MULTIPLIER");
    var capValue = capInput ? parseFloat(capInput.value) : NaN;
    var capText = isFinite(capValue) ? capValue.toFixed(1) : "—";
    return effective.toFixed(2) + "x (cap " + capText + "x)";
  }

  // DASH-08: "N s ago" from a real published send timestamp, or an honest
  // "no send yet" before the first successful send ever happens (D-13, never
  // fabricated).
  function formatLastSendAge(lastSuccessfulSendAgeSeconds) {
    if (
      lastSuccessfulSendAgeSeconds === null ||
      lastSuccessfulSendAgeSeconds === undefined ||
      typeof lastSuccessfulSendAgeSeconds !== "number" ||
      !isFinite(lastSuccessfulSendAgeSeconds)
    ) {
      return "no send yet";
    }
    return DashboardFormat.formatHumanDuration(lastSuccessfulSendAgeSeconds) + " ago";
  }

  // 15-03 Task 2 (CHUR-03/D-10): the sticky-header Draining swap, as ONE table
  // of four slot descriptors instead of four parallel if/else pairs -- a
  // future slot change touches one place. Streaming/Rotating labels and
  // value expressions are exactly what render() computed before this plan;
  // only the draining* fields are new. Every value goes through the existing
  // DashboardFormat formatters (or the existing local formatMbit) -- no new
  // formatter, no drain math computed here (all four numbers are published
  // by the pusher / derived server-side in Get-DashboardViewModel).
  var STICKY_HEADER_SLOTS = [
    {
      labelId: "sticky-delay-label",
      valueId: "sticky-delay",
      streamingLabel: "Delay",
      drainingLabel: "Left",
      streamingValue: function (viewModel) {
        return DashboardFormat.formatHumanDuration(viewModel.DelaySecondsBehindLive);
      },
      drainingValue: function (viewModel) {
        // Same field/units as Streaming (D-06) -- only the label tells the
        // operator the number now means "content left to send".
        return DashboardFormat.formatHumanDuration(viewModel.DelaySecondsBehindLive);
      },
    },
    {
      labelId: "sticky-send-bitrate-label",
      valueId: "sticky-send-bitrate",
      streamingLabel: "Send",
      drainingLabel: "Drain rate",
      streamingValue: function (viewModel) {
        return formatMbit(viewModel.SendBytesPerSecond);
      },
      drainingValue: function (viewModel) {
        // Drain has no separate rate concept per D-02 -- relabeled current
        // send bitrate, same underlying telemetry.
        return formatMbit(viewModel.SendBytesPerSecond);
      },
    },
    {
      labelId: "sticky-record-bitrate-label",
      valueId: "sticky-record-bitrate",
      streamingLabel: "Record",
      drainingLabel: "Remaining",
      streamingValue: function (viewModel) {
        return formatMbit(viewModel.RecordBytesPerSecond);
      },
      drainingValue: function (viewModel) {
        return DashboardFormat.formatMegabytes(viewModel.PendingBytes);
      },
    },
    {
      labelId: "sticky-percent-sent-label",
      valueId: "sticky-percent-sent",
      streamingLabel: "Sent",
      drainingLabel: "ETA",
      streamingValue: function (viewModel, sentPercent) {
        return formatPercent(sentPercent / 100);
      },
      drainingValue: function (viewModel) {
        // Never a fabricated/instant ETA (D-13): "—" until the drain rate is
        // a genuinely usable positive number -- an ETA of exactly 0 reads
        // identically to "not yet known", not "done right now".
        var eta = viewModel.DrainEtaSeconds;
        if (typeof eta !== "number" || !isFinite(eta) || eta <= 0) {
          return "—";
        }
        return DashboardFormat.formatHumanDuration(eta);
      },
    },
  ];

  function renderStickyHeaderSlots(viewModel, isDraining, sentPercent) {
    for (var i = 0; i < STICKY_HEADER_SLOTS.length; i += 1) {
      var slot = STICKY_HEADER_SLOTS[i];
      setText(slot.labelId, isDraining ? slot.drainingLabel : slot.streamingLabel);
      var valueFn = isDraining ? slot.drainingValue : slot.streamingValue;
      setText(slot.valueId, valueFn(viewModel, sentPercent));
    }
  }

  // ---------- Render ----------

  function applyStateClass(el, connectionState) {
    if (!el) {
      return;
    }
    for (var i = 0; i < ALL_STATE_CLASSES.length; i += 1) {
      el.classList.remove(ALL_STATE_CLASSES[i]);
    }
    var cls = CONNECTION_STATE_CLASS[connectionState] || "state-unknown";
    el.classList.add(cls);
  }

  function render(viewModel) {
    latestViewModel = viewModel;

    var connectionState = viewModel.ConnectionState;
    var isFinished = viewModel.SessionFinished === true;
    // 15-03 Task 1 (CHUR-03/D-10): the single predicate every Draining swap in
    // this plan reuses -- evaluated once, never re-derived per swap site.
    var isDraining = connectionState === "Draining";

    // Hero: delay behind live -- units never change (D-06), only the caption
    // below tells the operator what the number now means during a drain.
    setText("delay-value", DashboardFormat.formatHumanDuration(viewModel.DelaySecondsBehindLive));
    setText("hero-caption", isDraining ? "content left to send" : "delay behind live");

    // Header status area (260719-fmu): value only -- the "Behind live" static
    // HTML label already supplies the context (260719-fmu-03 label-style pass),
    // so this mirrors sticky-delay/timeline-delay/delay-value exactly (DRY).
    setText("header-behind-live", DashboardFormat.formatHumanDuration(viewModel.DelaySecondsBehindLive));

    // Dashboard history persistence (260719-fmu-08): attempt a ONE-TIME
    // restore from localStorage before this poll's own buffer updates run,
    // so a restored buffer becomes the base this poll extends rather than
    // being immediately overwritten.
    var nowSecondsForHistory = Date.now() / 1000;
    applyPersistedHistoryIfAny(viewModel, nowSecondsForHistory);

    // 1-minute delay trend (260719-fmu-04): collect this poll's sample, then
    // render the pure comparison (DashboardFormat.computeDelayTrend).
    updateDelayTrendSamples(viewModel);
    renderDelayTrend();

    // 5-minute hero mini-chart (260719-fmu-07): collect this poll's
    // composite sample, then redraw the SVG paths from scratch. Smoothness
    // comes from the 1s poll cadence + monotone-cubic interpolation, not
    // from a CSS transition on `d` (unreliable) or requestAnimationFrame.
    updateHeroChartBuffer(viewModel);
    renderHeroChart();

    // Mirror the (now-updated) buffers into localStorage, throttled, and
    // clear the stored copy in lockstep with a genuine session restart.
    persistDashboardHistoryThrottled(viewModel, nowSecondsForHistory);

    // Connection pill + hero color, driven off ConnectionState only (D-13:
    // never fabricate meaning from an invented numeric threshold).
    // Relay transport badge (2026-07-26): which protocol the RUNNING pusher session uses
    // ('SRT'/'TCP'); omitted entirely when the backend does not report it (D-13).
    var relayProtocolSuffix = viewModel.RelayProtocol ? " · " + String(viewModel.RelayProtocol).toUpperCase() : "";
    var connectionStateText = connectionState === null || connectionState === undefined ? "—" : connectionState + relayProtocolSuffix;
    setText("metric-connection-state", connectionStateText);
    var pill = byId("connection-pill");
    if (pill) {
      pill.textContent = connectionStateText;
      applyStateClass(pill, connectionState);
    }
    applyStateClass(byId("delay-value"), connectionState);

    // Buttons: always re-derived from the polled truth, never optimistic (D-10).
    var btnStart = byId("btn-start");
    var btnStop = byId("btn-stop");
    var btnCut = byId("btn-cut");
    if (btnStart) {
      btnStart.disabled = !viewModel.StartEnabled;
    }
    if (btnStop) {
      btnStop.disabled = !viewModel.StopEnabled;
    }
    if (btnCut) {
      btnCut.disabled = !viewModel.CutEnabled;
    }

    // Metrics.
    setText("metric-send-bitrate", formatMbit(viewModel.SendBytesPerSecond));
    setText("metric-record-bitrate", formatMbit(viewModel.RecordBytesPerSecond));
    setText("metric-backoff-streak", formatCount(viewModel.BackoffAttemptNumber));
    setText("metric-cumulative-reconnects", formatCount(viewModel.CumulativeReconnectCount));
    // Live uptime (260718-epo/FEAT-B): "—" while not alive/fresh, matching every
    // other never-fabricated metric on this page (D-13).
    setText("metric-uptime", DashboardFormat.formatHumanDuration(viewModel.LiveUptimeSeconds));
    setText("metric-catchup-utilization", formatPercent(viewModel.CatchUpCapUtilization));
    setText(
      "metric-offset",
      DashboardFormat.formatMegabytes(viewModel.SentBytes) + " / " + DashboardFormat.formatMegabytes(viewModel.TotalBytes)
    );
    setExactByteTitle("metric-offset", viewModel.SentBytes, viewModel.TotalBytes);

    // Catch-up row (DASH-07): send/record vs the configured cap (the
    // CATCH_UP_MULTIPLIER setting input, already populated by
    // loadSettingsOnce). Distinct from the existing "Catch-up utilization %".
    setText("metric-catchup-ratio", formatCatchUpRatio(viewModel.SendBytesPerSecond, viewModel.RecordBytesPerSecond));

    // NIC upload = wire rate incl. SRT retransmits + tunnel overhead; large gap
    // above send bitrate means retransmit waste.
    setText("metric-nic-upload", formatMbit(viewModel.NicUploadBps));

    // Last-send row (DASH-08): honest -- "—"/"no send yet" until the backend
    // ever reports a real successful send (D-13, never fabricated).
    setText("metric-last-send", formatLastSendAge(viewModel.LastSuccessfulSendAgeSeconds));

    // Timeline: single bar, sent vs pending vs total (D-12).
    var totalBytes = viewModel.TotalBytes;
    var sentBytes = viewModel.SentBytes;
    var sentPercent = 0;
    if (typeof totalBytes === "number" && totalBytes > 0 && typeof sentBytes === "number") {
      sentPercent = Math.max(0, Math.min(100, (sentBytes / totalBytes) * 100));
    }
    var timelineSent = byId("timeline-sent");
    if (timelineSent) {
      timelineSent.style.width = sentPercent + "%";
    }
    var timelineTrack = byId("timeline-track");
    if (timelineTrack) {
      timelineTrack.setAttribute("aria-valuenow", String(Math.round(sentPercent)));
    }
    setText("timeline-sent-label", DashboardFormat.formatMegabytes(sentBytes));
    setExactByteTitle("timeline-sent-label", sentBytes);
    setText("timeline-pending-label", DashboardFormat.formatMegabytes(viewModel.PendingBytes));
    setExactByteTitle("timeline-pending-label", viewModel.PendingBytes);
    setText("timeline-delay", DashboardFormat.formatHumanDuration(viewModel.DelaySecondsBehindLive));
    setText("timeline-eta", DashboardFormat.formatHumanDuration(viewModel.DrainEtaSeconds));

    // Sticky header metrics strip (DASH-04, Draining swap 15-03 Task 2):
    // reuses the SAME sentPercent already computed above for the timeline
    // bar (DRY -- compute once). renderStickyHeaderSlots swaps both label
    // and value for all four slots at once, driven by the single isDraining
    // predicate derived at the top of render().
    renderStickyHeaderSlots(viewModel, isDraining, sentPercent);

    updateCatchUpSliderEffectiveReadout(viewModel);
    updateGoverningCapReadout(viewModel);

    // Stale banner. Gated on `!isFinished` (260718-epo): a clean end-of-service
    // leaves stats.json stale within a few seconds (D-06), but that staleness is
    // now HONEST -- the session-finished panel below already explains it calmly --
    // so the "Lost contact" alarm must never also fire for the exact same state.
    var staleBanner = byId("stale-banner");
    if (staleBanner) {
      if (viewModel.IsStale && !isFinished) {
        var secondsSinceUpdateText = DashboardFormat.formatHumanDuration(viewModel.SecondsSinceUpdate);
        staleBanner.textContent =
          "Lost contact with the pusher — last update " +
          secondsSinceUpdateText +
          " ago. If this doesn't recover, check pusher.log or restart the service.";
        staleBanner.hidden = false;
      } else {
        staleBanner.hidden = true;
      }
    }

    // Empty state. Also explicitly excludes isFinished (belt-and-braces --
    // connectionState is never "Idle" while Finished anyway, but this keeps the
    // two states from ever visually overlapping even under a future edit).
    var emptyState = byId("empty-state");
    if (emptyState) {
      emptyState.hidden = connectionState !== "Idle" || isFinished;
    }

    // Session-finished panel (260718-epo/FEAT-A): the calm "all good" screen that
    // replaces the "Lost contact" alarm after a genuine clean end-of-service.
    var sessionFinishedPanel = byId("session-finished-panel");
    if (sessionFinishedPanel) {
      sessionFinishedPanel.hidden = !isFinished;
      if (isFinished) {
        setText(
          "session-finished-summary",
          DashboardFormat.formatSessionOutcome(viewModel.SessionDurationSeconds, viewModel.PendingBytes)
        );
        setText("session-finished-duration", DashboardFormat.formatHumanDuration(viewModel.SessionDurationSeconds));
        setText("session-finished-undelivered", DashboardFormat.formatMegabytes(viewModel.PendingBytes));
      }
    }

    // New-recording notice + one-click pickup Start (260718-epo/FEAT-C): shown
    // whenever the supervisor's auto-pickup detection found a strictly-newer
    // recording, independent of AUTO_PICKUP itself -- detection always surfaces the
    // notice; only the operator's AUTO_PICKUP setting decides whether streaming
    // starts on its own (T-epo-01, never a client-side auto-start decision).
    var newRecordingNotice = byId("new-recording-notice");
    var btnPickupStart = byId("btn-pickup-start");
    var newRecordingDetected = viewModel.NewRecordingDetected === true;
    if (newRecordingNotice) {
      newRecordingNotice.hidden = !newRecordingDetected;
    }
    if (btnPickupStart) {
      btnPickupStart.disabled = !newRecordingDetected;
    }
    if (newRecordingDetected) {
      var newRecordingFilePath = viewModel.NewRecordingFilePath;
      setText(
        "new-recording-notice-text",
        "New recording detected: " + (newRecordingFilePath ? basename(newRecordingFilePath) : "unknown file")
      );
    }

    // Settings live notice (D-17): persistent whenever a pusher is streaming,
    // not only after a save. StopEnabled is the reliable proxy for "alive".
    var settingsLiveNotice = byId("settings-live-notice");
    if (settingsLiveNotice) {
      settingsLiveNotice.hidden = !viewModel.StopEnabled;
    }

    // Recording status indicator (SESS-02, D-13: never fabricate what the
    // backend didn't compute -- RecordingFilePath/RecordingFileGrowing are
    // both already null/false-safe from Get-DashboardViewModel).
    var followingFile = byId("following-file");
    var followingBadge = byId("following-badge");
    var recordingFilePath = viewModel.RecordingFilePath;
    if (followingFile) {
      followingFile.textContent = recordingFilePath ? basename(recordingFilePath) : "Not yet resolved";
    }
    if (followingBadge) {
      if (!recordingFilePath) {
        followingBadge.hidden = true;
      } else {
        followingBadge.hidden = false;
        followingBadge.classList.remove("state-growing", "state-static");
        if (viewModel.RecordingFileGrowing) {
          followingBadge.classList.add("state-growing");
          followingBadge.textContent = "● Growing";
        } else {
          followingBadge.classList.add("state-static");
          followingBadge.textContent = "● Static";
        }
      }
    }

    // Reset Resume State button (SESS-03, D-05): disabled while the pusher is
    // alive. StartEnabled is exactly "not PusherProcessAlive" already computed
    // by Get-DashboardViewModel, so its negation is the same liveness signal
    // without needing a duplicate field on the wire.
    var pusherProcessAlive = !viewModel.StartEnabled;
    var btnResetResume = byId("btn-reset-resume");
    if (btnResetResume) {
      btnResetResume.disabled = pusherProcessAlive;
      btnResetResume.title = pusherProcessAlive
        ? "Stop the pusher before resetting resume state."
        : "";
    }

    checkOutageEdge(viewModel);

    renderProbePanels(viewModel.probes || [], connectionState, viewModel.IsStale === true);
    renderVpsHealthPill(viewModel.probes || [], connectionState, viewModel.IsStale === true);
  }

  // Generic, schema-driven probe panel renderer (D-11/MON-01): ONE function
  // renders every probe type -- VPS now, OMR in Phase 7, any future
  // church-authored plugin -- from the normalized {name,title,status,metrics,
  // detail,lastUpdateAgeSeconds} shape (06-06's ApiStats fold). No per-plugin
  // branches. probes[] is small (1-3 entries) so the container is fully
  // rebuilt each poll rather than diffed.
  //
  // XSS (T-06-03): every probe-authored string (title, name, metric label/
  // value/unit, detail) is written via textContent only, NEVER innerHTML --
  // probe modules are church-authored, untrusted input.
  //
  // Zero probes -> zero DOM insertions (MON-04): the container stays empty,
  // contributing zero visual height, and the existing panels above/below it
  // render byte-for-byte identically to Phase 5.
  function renderProbePanels(probes, connectionState, mainStatsIsStale) {
    var container = byId("probes-container");
    if (!container) {
      return;
    }
    container.textContent = "";

    for (var i = 0; i < probes.length; i += 1) {
      container.appendChild(buildProbePanel(probes[i], connectionState, mainStatsIsStale));
    }
  }

  function buildProbePanel(probe, connectionState, mainStatsIsStale) {
    var panel = document.createElement("section");
    panel.className = "panel probe-panel";

    // Staleness (D-07/06-UI-SPEC): 06-06 already normalises status to
    // 'unknown' and stamps lastUpdateAgeSeconds whenever the probe's own
    // declared staleAfterEpochSeconds deadline has passed. A numeric
    // lastUpdateAgeSeconds is the sole signal of "was fresh, isn't anymore" --
    // never re-derive staleness from status alone, since a probe can also
    // report a genuinely fresh 'unknown' status. Distinct from
    // mainStatsIsStale (the pusher's OWN /api/stats freshness) below --
    // this is the PROBE's own reading going stale.
    var probeIsStale =
      typeof probe.lastUpdateAgeSeconds === "number" && isFinite(probe.lastUpdateAgeSeconds);

    var heading = document.createElement("h2");
    heading.appendChild(document.createTextNode(probe.title || probe.name || "Probe"));

    // Honest-probe-vs-alarming (260719-fmu-05): DashboardFormat.resolveProbeDisplayState
    // is the single source of truth for pill class/text + any override copy --
    // a probe reporting 'down' while the stream itself is confirmed healthy
    // (Streaming + fresh main stats) reads as a calm "unverified", not a red
    // alarm; every other combination is untouched.
    var statusText = probe.status || "unknown";
    var displayState = DashboardFormat.resolveProbeDisplayState(statusText, connectionState, mainStatsIsStale);

    var pill = document.createElement("span");
    pill.className = "status-pill " + (probeIsStale ? "state-unknown" : displayState.pillClass);
    pill.textContent = probeIsStale ? statusText : displayState.pillText;
    heading.appendChild(pill);
    panel.appendChild(heading);

    var grid = document.createElement("div");
    grid.className = "metrics-grid";
    var metrics = probe.metrics || [];
    for (var m = 0; m < metrics.length; m += 1) {
      grid.appendChild(buildProbeMetricRow(metrics[m]));
    }
    panel.appendChild(grid);

    // Detail line precedence (06-UI-SPEC Staleness section, extended by
    // 260719-fmu-05): probe-level stale beats the honest "unverified"
    // override beats never-polled beats the probe's own last-reported
    // detail -- a frozen detail string from a stale read must never be
    // presented as current, and an alarming raw exception dump must never
    // be shown as primary copy when the stream itself is demonstrably fine.
    var detailText = null;
    if (probeIsStale) {
      var ageSeconds = Math.round(probe.lastUpdateAgeSeconds);
      detailText = "stale — last update " + ageSeconds + "s ago";
    } else if (displayState.message) {
      detailText = displayState.message;
    } else if (statusText === "unknown" && !probe.detail && metrics.length === 0) {
      // No age marker, unknown status, no metrics and no detail -- the probe
      // has never completed a poll (no file / no age), not merely stale.
      detailText = "not yet polled";
    } else if (probe.detail) {
      detailText = probe.detail;
    }

    if (detailText) {
      var detail = document.createElement("p");
      detail.className = "control-helper";
      detail.textContent = detailText;
      // Demote the probe's own raw detail (e.g. a raw exception dump) to a
      // hover title instead of dropping it entirely, only when the honest
      // "unverified" copy replaced it as the primary text (T-06-03: plain
      // string -> attribute, never innerHTML).
      if (displayState.message && probe.detail && probe.detail !== detailText) {
        detail.title = probe.detail;
      }
      panel.appendChild(detail);
    }

    return panel;
  }

  function buildProbeMetricRow(metric) {
    var row = document.createElement("div");
    row.className = "metric-row";

    var label = document.createElement("span");
    label.className = "metric-label";
    label.textContent = metric.label;

    var value = document.createElement("span");
    value.className = "metric-value";
    value.textContent = metric.value + (metric.unit ? " " + metric.unit : "");

    row.appendChild(label);
    row.appendChild(value);
    return row;
  }

  // VPS health pill (D-12, 15-06): the header's always-visible summary of the
  // vps-relay probe's fixed 5-check contract (15-02 SUMMARY: Ingest, YouTube
  // LV, YouTube RU, Tunnel, Port). Reuses DashboardFormat.resolveProbeDisplayState
  // -- the SAME status-class mapping and stream-healthy-outranks-probe-down
  // downgrade buildProbePanel already uses (T-15-06-02/D-13) -- so this is
  // not a second copy of that logic. Metrics are matched by LABEL (never
  // array position) so a future extra metric (e.g. Latency) can never shift
  // a row (T-15-06-03). No click/hover event listener is registered here:
  // the open/close interaction is entirely native <details> plus the CSS
  // added in Task 1.
  //
  // T-15-06-01: every probe-authored string (metric.value) is written via
  // textContent/title only, NEVER innerHTML -- probe modules are treated as
  // untrusted input by this dashboard's existing convention.
  var VPS_HEALTH_CHECK_LABELS = ["Ingest", "YouTube LV", "YouTube RU", "Tunnel", "Port"];

  var VPS_HEALTH_VALUE_TO_DOT_CLASS = {
    active: "state-streaming",
    running: "state-streaming",
    open: "state-streaming",
    // 260809-oc4: the Port leg's passive ss-derived states -- a LISTEN socket ('open')
    // and an ESTABLISHED session already connected ('in use') are BOTH healthy; only
    // 'closed' (neither) is not. Same dot class as the rest of the healthy family.
    "in use": "state-streaming",
    inactive: "state-idle",
    "not running": "state-idle",
    closed: "state-idle",
    unknown: "state-unknown",
    "not configured": "state-unknown",
    "not applicable": "state-unknown",
  };

  function renderVpsHealthPill(probes, connectionState, mainStatsIsStale) {
    var pill = byId("vps-health-pill");
    var detailContainer = byId("vps-health-detail");
    if (!pill || !detailContainer) {
      return;
    }

    var rows = detailContainer.querySelectorAll(".vps-health-check-row");

    var probe = null;
    for (var i = 0; i < probes.length; i += 1) {
      if (probes[i] && probes[i].name === "vps-relay") {
        probe = probes[i];
        break;
      }
    }

    // Guard clause (never polled): leave the pill and all five rows in their
    // markup-default "—" / state-unknown state.
    if (!probe) {
      pill.className = "status-pill state-unknown";
      pill.textContent = "—";
      resetVpsHealthRows(rows);
      return;
    }

    var probeIsStale =
      typeof probe.lastUpdateAgeSeconds === "number" && isFinite(probe.lastUpdateAgeSeconds);
    var statusText = probe.status || "unknown";
    var displayState = DashboardFormat.resolveProbeDisplayState(statusText, connectionState, mainStatsIsStale);

    pill.className = "status-pill " + (probeIsStale ? "state-unknown" : displayState.pillClass);
    pill.textContent = probeIsStale ? statusText : displayState.pillText;

    var metrics = probe.metrics || [];
    var metricByLabel = {};
    for (var m = 0; m < metrics.length; m += 1) {
      metricByLabel[metrics[m].label] = metrics[m];
    }

    for (var r = 0; r < VPS_HEALTH_CHECK_LABELS.length; r += 1) {
      var metric = metricByLabel[VPS_HEALTH_CHECK_LABELS[r]];
      setVpsHealthRow(rows[r], metric);
    }
  }

  function setVpsHealthRow(row, metric) {
    if (!row) {
      return;
    }
    var dotEl = row.querySelector(".vps-health-check-dot");
    var detailEl = row.querySelector(".vps-health-check-detail");
    if (!dotEl || !detailEl) {
      return;
    }

    // No matching metric for this label -- keep the "—" / state-unknown
    // initial state rather than a stale prior-poll value.
    if (!metric) {
      dotEl.className = "vps-health-check-dot state-unknown";
      detailEl.textContent = "—";
      detailEl.removeAttribute("title");
      return;
    }

    // WR-02: metric.value is probe-authored (untrusted, per this file's own T-15-06-01
    // convention) and looked up as a plain-object property key -- a hasOwnProperty
    // guard, not a truthy-value check, so an inherited Object.prototype member name
    // (e.g. "constructor", "toString") can never be mistaken for a real dot class.
    var dotClass = Object.prototype.hasOwnProperty.call(VPS_HEALTH_VALUE_TO_DOT_CLASS, metric.value)
      ? VPS_HEALTH_VALUE_TO_DOT_CLASS[metric.value]
      : "state-unknown";
    dotEl.className = "vps-health-check-dot " + dotClass;
    detailEl.textContent = metric.value;
    detailEl.title = metric.value;
  }

  function resetVpsHealthRows(rows) {
    for (var i = 0; i < rows.length; i += 1) {
      setVpsHealthRow(rows[i], null);
    }
  }

  function renderLostContact() {
    // Fetch itself failed (non-200 or network error). Render through the
    // same render() path with a synthesized lost-contact view model, rather
    // than a parallel DOM-writing function, so disabled/state assignment
    // stays in exactly one place (D-10). The network here is localhost, so
    // a failure means the supervisor process is down; keep polling.
    render({
      ConnectionState: "Unknown",
      RelayProtocol: null,
      DelaySecondsBehindLive: null,
      StartEnabled: false,
      StopEnabled: false,
      CutEnabled: false,
      SendBytesPerSecond: null,
      RecordBytesPerSecond: null,
      BackoffAttemptNumber: null,
      CumulativeReconnectCount: null,
      CatchUpCapUtilization: null,
      NicUploadBps: null,
      SentBytes: null,
      TotalBytes: null,
      PendingBytes: null,
      DrainEtaSeconds: null,
      IsStale: true,
      SecondsSinceUpdate: null,
      OutageActive: previousOutageActive,
      LastSuccessfulSendAgeSeconds: null,
      SessionFinished: false,
      LiveUptimeSeconds: null,
      SessionDurationSeconds: null,
      NewRecordingDetected: false,
      NewRecordingFilePath: null,
    });
  }

  // ---------- Outage edge notifications (D-19/D-20/D-21) ----------

  function checkOutageEdge(viewModel) {
    if (viewModel.IsStale) {
      // A stale payload's OutageActive is not a current observation. Hold
      // the previous value unchanged so the edge is still detected
      // correctly when fresh data returns.
      return;
    }

    var currentOutageActive = viewModel.OutageActive;

    if (previousOutageActive === null) {
      // First fresh render: establish the baseline, fire nothing. Otherwise
      // opening the page mid-outage would announce news the operator
      // already has.
      previousOutageActive = currentOutageActive;
      return;
    }

    if (previousOutageActive === false && currentOutageActive === true) {
      if ('Notification' in window && Notification.permission === 'granted') {
        new Notification("Stream outage detected", {
          body: "Delay behind live is growing. Reconnecting automatically.",
          tag: "outage",
        });
      }
    } else if (previousOutageActive === true && currentOutageActive === false) {
      if ('Notification' in window && Notification.permission === 'granted') {
        new Notification("Stream recovered", {
          body: "Back to normal — catching up to live.",
          tag: "recovery",
        });
      }
    }

    previousOutageActive = currentOutageActive;
  }

  function updateNotificationButtonVisibility() {
    var btn = byId("enable-notifications");
    if (!btn) {
      return;
    }
    if (!('Notification' in window)) {
      btn.hidden = true;
      return;
    }
    btn.hidden = Notification.permission !== "default";
  }

  function wireNotificationButton() {
    var btn = byId("enable-notifications");
    if (!btn || !('Notification' in window)) {
      if (btn) {
        btn.hidden = true;
      }
      return;
    }
    updateNotificationButtonVisibility();
    btn.addEventListener("click", function () {
      Notification.requestPermission().then(function () {
        updateNotificationButtonVisibility();
      });
    });
  }

  // ---------- Poll loop ----------

  function scheduleNextPoll() {
    setTimeout(poll, POLL_INTERVAL_MS);
  }

  function poll() {
    var controller = new AbortController();
    var timeoutId = setTimeout(function () {
      controller.abort();
    }, FETCH_TIMEOUT_MS);

    fetch("/api/stats", { signal: controller.signal })
      .then(function (response) {
        clearTimeout(timeoutId);
        if (!response.ok) {
          renderLostContact();
          return null;
        }
        return response.json();
      })
      .then(function (viewModel) {
        if (viewModel) {
          render(viewModel);
        }
      })
      .catch(function () {
        clearTimeout(timeoutId);
        renderLostContact();
      })
      .then(function () {
        scheduleNextPoll();
      });
  }

  // ---------- Controls: Start / Stop ----------

  function postControlAction(action) {
    fetch("/api/control", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: action }),
    })
      .catch(function () {
        // Ignore — the next poll renders whatever actually happened (D-10).
      })
      .then(function () {
        poll();
      });
  }

  function wireStartStop() {
    var btnStart = byId("btn-start");
    var btnStop = byId("btn-stop");
    if (btnStart) {
      btnStart.addEventListener("click", function () {
        postControlAction("start");
      });
    }
    if (btnStop) {
      btnStop.addEventListener("click", function () {
        postControlAction("stop");
      });
    }
  }

  // ---------- New-recording pickup Start (260718-epo/FEAT-C) ----------

  function wirePickupStart() {
    var btnPickupStart = byId("btn-pickup-start");
    if (btnPickupStart) {
      btnPickupStart.addEventListener("click", function () {
        // The same start seam as btn-start (postControlAction("start")) --
        // supervisor.ps1/pusher.ps1 resolve the newest matching file on start, so no
        // separate control action or filename param is needed here.
        postControlAction("start");
      });
    }
  }

  // ---------- Cut confirmation ----------

  function wireCutConfirm() {
    var btnCut = byId("btn-cut");
    var dialog = byId("cut-confirm");
    var btnCancel = byId("btn-cut-cancel");
    var btnConfirm = byId("btn-cut-confirm");

    if (btnCut && dialog) {
      btnCut.addEventListener("click", function () {
        var message = byId("cut-confirm-message");
        if (message && latestViewModel) {
          var pendingBytesText = formatBytes(latestViewModel.PendingBytes);
          var etaSeconds = latestViewModel.DrainEtaSeconds;
          var pendingSecondsText =
            typeof etaSeconds === "number" && isFinite(etaSeconds)
              ? Math.round(etaSeconds) + "s ("
              : "";
          var closeParen = pendingSecondsText ? ")" : "";
          message.textContent =
            "Cut now? " +
            pendingSecondsText +
            pendingBytesText +
            closeParen +
            " of recorded video has not been sent yet and will not reach YouTube. This cannot be undone.";
        }
        dialog.showModal();
      });
    }

    if (btnCancel && dialog) {
      btnCancel.addEventListener("click", function () {
        dialog.close();
      });
    }

    if (btnConfirm && dialog) {
      btnConfirm.addEventListener("click", function () {
        dialog.close();
        postControlAction("cut");
      });
    }
  }

  // ---------- Recording Management: Reset Resume State (SESS-03) ----------

  // #recordings-error is the shared feedback banner for both fetch and
  // delete failures (UI-SPEC Element ID Contract). Reset/Delete success also
  // uses it as a transient inline confirmation, since no separate success
  // element is part of the fixed id contract -- Accent green is applied
  // inline (reusing the already-declared --color-accent custom property, not
  // a new class or hex) rather than the element's default destructive-red
  // styling, so a success message never reads like an error.
  function showRecordingsError(message) {
    var el = byId("recordings-error");
    if (el) {
      el.style.color = "";
      el.textContent = message;
      el.hidden = false;
    }
  }

  function showRecordingsMessage(message) {
    var el = byId("recordings-error");
    if (el) {
      el.style.color = "var(--color-accent)";
      el.textContent = message;
      el.hidden = false;
    }
  }

  function clearRecordingsError() {
    var el = byId("recordings-error");
    if (el) {
      el.style.color = "";
      el.textContent = "";
      el.hidden = true;
    }
  }

  // A dedicated POST (not postControlAction) because the UI-SPEC's D-08
  // success/failure copy ("Resume state cleared." / the 409 refusal reason)
  // requires reading the actual response, which postControlAction
  // deliberately discards (D-10: the next poll renders reality either way,
  // but Reset's copy contract needs the immediate outcome too).
  function postResetResume() {
    fetch("/api/control", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "reset-resume" }),
    })
      .then(function (response) {
        return response
          .json()
          .catch(function () {
            return {};
          })
          .then(function (body) {
            return { status: response.status, body: body };
          });
      })
      .then(function (result) {
        if (result.status === 200) {
          showRecordingsMessage("Resume state cleared.");
        } else {
          var reason = (result.body && result.body.error) || "unknown error";
          showRecordingsError("Couldn't reset resume state — " + reason + ".");
        }
      })
      .catch(function () {
        showRecordingsError("Couldn't reset resume state — request failed.");
      })
      .then(function () {
        poll();
        fetchRecordings();
      });
  }

  function wireResetConfirm() {
    var btnReset = byId("btn-reset-resume");
    var dialog = byId("reset-confirm");
    var btnCancel = byId("btn-reset-cancel");
    var btnConfirm = byId("btn-reset-confirm");

    if (btnReset && dialog) {
      btnReset.addEventListener("click", function () {
        var message = byId("reset-confirm-message");
        if (message && latestViewModel) {
          var filename = latestViewModel.RecordingFilePath
            ? basename(latestViewModel.RecordingFilePath)
            : "an unknown file";
          var offsetBytes = latestViewModel.SentBytes;
          var offsetText =
            typeof offsetBytes === "number" && isFinite(offsetBytes) ? String(offsetBytes) : "an unknown offset";
          var humanSizeText = formatBytes(offsetBytes);
          // WR-03: this offset comes from the last polled /api/stats view model, not
          // from reading state/offset.json itself -- if the pusher's most recent
          // persisted commit happened after the last poll (persist cadence is up to
          // PersistIntervalMilliseconds/PersistIntervalBytes), the real value being
          // cleared can be slightly ahead of what is shown here. "last known" makes
          // that an honest approximation rather than a claim of exactness.
          message.textContent =
            "Reset resume state? The pusher will forget it was last known to be following " +
            filename +
            " at approximately byte " +
            offsetText +
            " (" +
            humanSizeText +
            ") and will start fresh from today's newest recording next time you press Start. This does not delete any file.";
        }
        dialog.showModal();
      });
    }

    if (btnCancel && dialog) {
      btnCancel.addEventListener("click", function () {
        dialog.close();
      });
    }

    if (btnConfirm && dialog) {
      btnConfirm.addEventListener("click", function () {
        dialog.close();
        postResetResume();
      });
    }
  }

  // ---------- Recording Management: Recordings list + delete (SESS-04) ----------

  // Pending delete target lives in a JS variable, not a DOM lookup at confirm
  // time, per the UI-SPEC Element ID Contract note -- data-filename on the
  // clicked row's Delete button is only how it gets set (05.1-UI-SPEC.md:205).
  var pendingDeleteFilename = null;
  var pendingDeleteSizeBytes = null;

  function getConfiguredRecordingFolderPath() {
    var input = byId("setting-RECORDING_FOLDER_PATH");
    return input && input.value ? input.value : null;
  }

  function renderRecordingsList(recordings) {
    var listEl = byId("recordings-list");
    var emptyEl = byId("recordings-empty");
    if (!listEl) {
      return;
    }
    listEl.textContent = "";

    if (!recordings || recordings.length === 0) {
      if (emptyEl) {
        var folderPath = getConfiguredRecordingFolderPath();
        emptyEl.textContent = folderPath ? "No recordings found in " + folderPath + "." : "No recordings found.";
        emptyEl.hidden = false;
      }
      return;
    }

    if (emptyEl) {
      emptyEl.hidden = true;
    }

    for (var i = 0; i < recordings.length; i += 1) {
      listEl.appendChild(buildRecordingRow(recordings[i], recordings));
    }
  }

  function buildRecordingRow(recording, allRecordings) {
    var row = document.createElement("div");
    row.className = "recording-row";

    var info = document.createElement("div");
    info.className = "recording-row-info";

    var nameEl = document.createElement("span");
    nameEl.className = "recording-row-name";
    nameEl.textContent = recording.name;
    info.appendChild(nameEl);

    var metaEl = document.createElement("span");
    metaEl.className = "recording-row-meta";
    metaEl.textContent = formatBytes(recording.sizeBytes) + " · " + formatRelativeAge(recording.lastWriteTimeUtc);
    info.appendChild(metaEl);

    row.appendChild(info);

    if (recording.isLive) {
      // Live file: no Delete button at all (SESS-04, D-07) -- not merely
      // disabled, absent, so there is nothing a DOM edit could re-enable.
      var liveBadge = document.createElement("span");
      liveBadge.className = "status-pill state-static";
      liveBadge.title = "Currently recording — cannot be deleted.";
      liveBadge.textContent = "Live";
      row.appendChild(liveBadge);
      return row;
    }

    var btnDelete = document.createElement("button");
    btnDelete.type = "button";
    btnDelete.className = "btn btn-cut";
    btnDelete.setAttribute("data-filename", recording.name);
    btnDelete.textContent = "Delete";
    btnDelete.addEventListener("click", function () {
      var filename = btnDelete.getAttribute("data-filename");
      var matched = null;
      for (var j = 0; j < allRecordings.length; j += 1) {
        if (allRecordings[j].name === filename) {
          matched = allRecordings[j];
          break;
        }
      }
      pendingDeleteFilename = filename;
      pendingDeleteSizeBytes = matched ? matched.sizeBytes : null;

      var message = byId("delete-confirm-message");
      if (message) {
        message.textContent = "Delete " + filename + " (" + formatBytes(pendingDeleteSizeBytes) + ")? This cannot be undone.";
      }
      var dialog = byId("delete-confirm");
      if (dialog) {
        dialog.showModal();
      }
    });
    row.appendChild(btnDelete);

    return row;
  }

  function fetchRecordings() {
    fetch("/api/recordings")
      .then(function (response) {
        if (!response.ok) {
          return response
            .json()
            .catch(function () {
              return {};
            })
            .then(function (body) {
              throw new Error((body && body.error) || "HTTP " + response.status);
            });
        }
        return response.json();
      })
      .then(function (recordings) {
        clearRecordingsError();
        renderRecordingsList(recordings);
      })
      .catch(function (err) {
        showRecordingsError("Couldn't load recordings — " + (err && err.message ? err.message : "request failed") + ".");
      });
  }

  function postRecordingDelete(filename) {
    fetch("/api/recordings/delete", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ filename: filename }),
    })
      .then(function (response) {
        return response
          .json()
          .catch(function () {
            return {};
          })
          .then(function (body) {
            return { status: response.status, body: body };
          });
      })
      .then(function (result) {
        if (result.status === 200) {
          showRecordingsMessage("Deleted " + filename + ".");
          fetchRecordings();
        } else {
          var reason = (result.body && result.body.error) || "unknown error";
          var isLockedFile = reason.indexOf("in use") !== -1;
          var message = isLockedFile
            ? "Couldn't delete " + filename + " — file is currently in use. Try again in a moment."
            : "Couldn't delete " + filename + " — " + reason + ".";
          showRecordingsError(message);
        }
      })
      .catch(function () {
        showRecordingsError("Couldn't delete " + filename + " — request failed.");
      })
      .then(function () {
        pendingDeleteFilename = null;
        pendingDeleteSizeBytes = null;
      });
  }

  function wireRecordingsList() {
    var dialog = byId("delete-confirm");
    var btnCancel = byId("btn-delete-cancel");
    var btnConfirm = byId("btn-delete-confirm");

    if (btnCancel && dialog) {
      btnCancel.addEventListener("click", function () {
        dialog.close();
      });
    }

    if (btnConfirm && dialog) {
      btnConfirm.addEventListener("click", function () {
        dialog.close();
        if (pendingDeleteFilename) {
          postRecordingDelete(pendingDeleteFilename);
        }
      });
    }

    // Administrative data, not part of the 1x/second stats poll (D-25) --
    // load once, then refresh after any mutation (UI-SPEC Refresh cadence).
    fetchRecordings();
  }

  // ---------- Settings ----------

  function populateSettingsForm(config) {
    for (var i = 0; i < SETTINGS_FIELDS.length; i += 1) {
      var field = SETTINGS_FIELDS[i];
      var input = byId("setting-" + field.envKey);
      if (!input || !Object.prototype.hasOwnProperty.call(config, field.property)) {
        continue;
      }
      var value = config[field.property];
      if (field.envKey === "SEND_CEILING_BYTES_PER_SECOND") {
        // DIAL-02: this field is presented and edited in Mbit/s (the .env's
        // raw bytes/s value stays the source of truth, converted only at this
        // display boundary and at the collectSettingsChanges() write boundary).
        var rawBytesPerSecond = value === null || value === undefined ? 0 : Number(value);
        input.value = bytesPerSecondToMegabitsPerSecond(rawBytesPerSecond).toFixed(1);
      } else {
        input.value = value === null || value === undefined ? "" : value;
      }
    }

    // Slider (DASH-05): initialise from the same CatchUpMultiplier property,
    // once, at load -- the slider and the setting-CATCH_UP_MULTIPLIER input
    // stay in sync from here on via wireCatchUpSlider()'s own 'change' write-back.
    var slider = byId("catchup-slider");
    if (slider && Object.prototype.hasOwnProperty.call(config, "CatchUpMultiplier")) {
      var catchUpValue = config.CatchUpMultiplier;
      if (catchUpValue !== null && catchUpValue !== undefined) {
        slider.value = String(catchUpValue);
        setText("catchup-slider-value", parseFloat(slider.value).toFixed(1));
        updateCatchUpSliderEffectiveReadout(latestViewModel);
      }
    }

    // DIAL-01: initialise the Upload Speed panel's ceiling slider from the
    // same SendCeilingBytesPerSecond property, once, at load -- live-sync
    // from here on via wireSendCeilingSlider()'s own 'change' write-back.
    var ceilingSlider = byId("ceiling-slider");
    if (ceilingSlider && Object.prototype.hasOwnProperty.call(config, "SendCeilingBytesPerSecond")) {
      var ceilingRawBytes = config.SendCeilingBytesPerSecond;
      ceilingSlider.value = String(bytesPerSecondToMegabitsPerSecond(ceilingRawBytes === null || ceilingRawBytes === undefined ? 0 : Number(ceilingRawBytes)));
      updateSendCeilingSliderLabel();
    }

    // WR-01: no settings-form input exists for this key (unlike CATCH_UP_MULTIPLIER/
    // SEND_CEILING_BYTES_PER_SECOND, it is not operator-live-dialed) -- captured
    // straight from the polled config object for updateGoverningCapReadout's cold-start
    // fallback branch.
    if (Object.prototype.hasOwnProperty.call(config, "ColdStartCatchUpCeilingBytesPerSecond")) {
      var coldStartCeilingValue = config.ColdStartCatchUpCeilingBytesPerSecond;
      latestColdStartCeilingBytesPerSecond =
        coldStartCeilingValue === null || coldStartCeilingValue === undefined ? null : Number(coldStartCeilingValue);
    }

    updateSendCeilingMbitReadout();
    updateGoverningCapReadout(latestViewModel);
  }

  // DIAL-02: the live-preview span next to the (now Mbit/s) ceiling field --
  // mirrors catchup-slider-value's role for the slider. Shows the CANONICAL
  // half-up-1-decimal value that will actually be stored, which can differ
  // from whatever precision the operator is mid-typing, plus an explicit
  // "off" callout at the 0 boundary (blank/negative/unparseable also read as
  // 0, matching Read-LiveTunableOverrides' safe-default discipline).
  function updateSendCeilingMbitReadout() {
    var input = byId("setting-SEND_CEILING_BYTES_PER_SECOND");
    if (!input) {
      return;
    }
    var canonicalBytesPerSecond = megabitsPerSecondToBytesPerSecond(input.value);
    var canonicalMegabits = bytesPerSecondToMegabitsPerSecond(canonicalBytesPerSecond);
    var suffix = canonicalBytesPerSecond === 0 ? " (off — multiplier governs)" : "";
    setText("send-ceiling-mbit-readout", canonicalMegabits.toFixed(1) + " Mbit/s" + suffix);
  }

  // DIAL-02/WR-01: "governing cap: ceiling 16.0 Mbit/s", "governing cap:
  // multiplier 1.5x (19.5 Mbit/s)", or "governing cap: cold-start ceiling X.X
  // Mbit/s (multiplier 1.5x pending)" -- always names WHICH knob governs (D-04),
  // derived purely client-side via computeGoverningCap from the values already
  // polled/entered in the settings form + the latest view model + the cold-start
  // ceiling captured by populateSettingsForm.
  function updateGoverningCapReadout(viewModel) {
    var ceilingInput = byId("setting-SEND_CEILING_BYTES_PER_SECOND");
    var multiplierInput = byId("setting-CATCH_UP_MULTIPLIER");
    var ceilingBytesPerSecond = ceilingInput ? megabitsPerSecondToBytesPerSecond(ceilingInput.value) : 0;
    var multiplierValue = multiplierInput ? parseFloat(multiplierInput.value) : NaN;
    var multiplier = isFinite(multiplierValue) ? multiplierValue : null;
    var recordRate = viewModel ? viewModel.RecordBytesPerSecond : null;

    var result = computeGoverningCap(ceilingBytesPerSecond, multiplier, recordRate, latestColdStartCeilingBytesPerSecond);
    var multiplierText = multiplier !== null ? multiplier.toFixed(1) + "x" : "—";
    var text;
    if (result.governor === "ceiling") {
      text = "governing cap: ceiling " + bytesPerSecondToMegabitsPerSecond(result.capBytesPerSecond).toFixed(1) + " Mbit/s";
    } else if (result.governor === "cold-start-ceiling") {
      text =
        "governing cap: cold-start ceiling " +
        bytesPerSecondToMegabitsPerSecond(result.capBytesPerSecond).toFixed(1) +
        " Mbit/s (multiplier " +
        multiplierText +
        " pending)";
    } else if (result.capBytesPerSecond !== null) {
      text = "governing cap: multiplier " + multiplierText + " (" + bytesPerSecondToMegabitsPerSecond(result.capBytesPerSecond).toFixed(1) + " Mbit/s)";
    } else {
      text = "governing cap: multiplier " + multiplierText;
    }
    setText("governing-cap-readout", text);
  }

  // DASH-05: "effective 1.19x / cap 1.5x" next to the slider -- the effective
  // side comes from the LATEST polled view model's real send/record rates
  // (never fabricated); the cap side tracks the slider's OWN current value
  // (a live preview of the multiplier being dragged, not necessarily the
  // persisted setting yet -- Write-DotEnvFile is the validating authority).
  function updateCatchUpSliderEffectiveReadout(viewModel) {
    var slider = byId("catchup-slider");
    if (!slider) {
      return;
    }
    var sliderValue = parseFloat(slider.value);
    var capText = isFinite(sliderValue) ? sliderValue.toFixed(1) : "—";
    var effective = DashboardFormat.computeEffectiveCatchUp(
      viewModel ? viewModel.SendBytesPerSecond : null,
      viewModel ? viewModel.RecordBytesPerSecond : null
    );
    var effectiveText =
      effective === null || effective === undefined || !isFinite(effective) ? "—" : effective.toFixed(2) + "x";
    setText("catchup-effective", "effective " + effectiveText + " / cap " + capText + "x");
  }

  // DIAL-01 (operator UAT feedback, 2026-07-28): the ceiling dial lives in the
  // Upload Speed panel as a slider, NOT only in the Settings form -- it applies
  // LIVE (pusher repolls .env ~1s) and must read as a live control. Same POST
  // /api/config route as the multiplier slider; .env raw bytes/s stays the
  // source of truth (slider is Mbit/s at the display boundary only). 0 = off.
  function updateSendCeilingSliderLabel() {
    var slider = byId("ceiling-slider");
    if (!slider) {
      return;
    }
    var megabits = parseFloat(slider.value);
    var labelText = !isFinite(megabits) || megabits === 0 ? "off — multiplier governs" : megabits.toFixed(1) + " Mbit/s";
    setText("ceiling-slider-value", labelText);
  }

  function wireSendCeilingSlider() {
    var slider = byId("ceiling-slider");
    if (!slider) {
      return;
    }

    slider.addEventListener("input", function () {
      updateSendCeilingSliderLabel();
      // Live-preview the governing cap from the slider's own value by syncing
      // the settings field first (updateGoverningCapReadout reads that field).
      var ceilingInput = byId("setting-SEND_CEILING_BYTES_PER_SECOND");
      if (ceilingInput) {
        ceilingInput.value = parseFloat(slider.value).toFixed(1);
      }
      updateSendCeilingMbitReadout();
      updateGoverningCapReadout(latestViewModel);
    });

    slider.addEventListener("change", function () {
      var megabits = parseFloat(slider.value);
      if (!isFinite(megabits)) {
        return;
      }
      var bytesPerSecond = megabitsPerSecondToBytesPerSecond(String(megabits));

      fetch("/api/config", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ SEND_CEILING_BYTES_PER_SECOND: String(bytesPerSecond) }),
      })
        .then(function (response) {
          return response.json().then(function (body) {
            return { status: response.status, body: body };
          });
        })
        .then(function (result) {
          var body = result.body || {};
          var success = body.Success !== undefined ? body.Success : body.success;
          var problems = body.Problems !== undefined ? body.Problems : body.problems;
          if (result.status === 200 && success) {
            clearSettingsError();
            var ceilingInput = byId("setting-SEND_CEILING_BYTES_PER_SECOND");
            if (ceilingInput) {
              ceilingInput.value = megabits.toFixed(1);
            }
            updateSendCeilingMbitReadout();
            updateGoverningCapReadout(latestViewModel);
          } else {
            problems = problems || [];
            var reason = problems.length > 0 ? problems.join("; ") : "unknown validation error";
            showSettingsError("Couldn't save max upload speed: " + reason + ". Nothing was changed.");
          }
        })
        .catch(function () {
          showSettingsError("Couldn't save max upload speed: request failed. Nothing was changed.");
        });
    });
  }

  function wireCatchUpSlider() {
    var slider = byId("catchup-slider");
    if (!slider) {
      return;
    }

    slider.addEventListener("input", function () {
      setText("catchup-slider-value", parseFloat(slider.value).toFixed(1));
      updateCatchUpSliderEffectiveReadout(latestViewModel);
      updateGoverningCapReadout(latestViewModel);
    });

    slider.addEventListener("change", function () {
      var value = parseFloat(slider.value);
      if (!isFinite(value)) {
        return;
      }

      // Reuses the existing POST /api/config route unchanged (same fetch
      // shape, same Success/Problems handling as wireSettingsForm's save
      // path) -- no second write path, no new HTTP route (DASH-05).
      fetch("/api/config", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ CATCH_UP_MULTIPLIER: String(value) }),
      })
        .then(function (response) {
          return response.json().then(function (body) {
            return { status: response.status, body: body };
          });
        })
        .then(function (result) {
          var body = result.body || {};
          var success = body.Success !== undefined ? body.Success : body.success;
          var problems = body.Problems !== undefined ? body.Problems : body.problems;
          if (result.status === 200 && success) {
            clearSettingsError();
            var capInput = byId("setting-CATCH_UP_MULTIPLIER");
            if (capInput) {
              capInput.value = String(value);
            }
          } else {
            problems = problems || [];
            var reason = problems.length > 0 ? problems.join("; ") : "unknown validation error";
            showSettingsError("Couldn't save catch-up multiplier: " + reason + ". Nothing was changed.");
          }
        })
        .catch(function () {
          showSettingsError("Couldn't save catch-up multiplier: request failed. Nothing was changed.");
        });
    });
  }

  function loadSettingsOnce() {
    if (settingsLoaded) {
      return;
    }
    settingsLoaded = true;
    fetch("/api/config")
      .then(function (response) {
        if (!response.ok) {
          return null;
        }
        return response.json();
      })
      .then(function (config) {
        if (config) {
          populateSettingsForm(config);
        }
      })
      .catch(function () {
        // Leave the form untouched; the operator can retry by reloading.
      });
  }

  function collectSettingsChanges() {
    var changes = {};
    for (var i = 0; i < SETTINGS_FIELDS.length; i += 1) {
      var envKey = SETTINGS_FIELDS[i].envKey;
      var input = byId("setting-" + envKey);
      if (!input) {
        continue;
      }
      if (envKey === "SEND_CEILING_BYTES_PER_SECOND") {
        // DIAL-02: the field holds Mbit/s (see populateSettingsForm); convert
        // back to the raw bytes/s .env contract before POST. Blank/negative/
        // unparseable all convert to 0 (off, multiplier governs).
        changes[envKey] = String(megabitsPerSecondToBytesPerSecond(input.value));
      } else {
        changes[envKey] = input.value;
      }
    }
    return changes;
  }

  function showSettingsError(message) {
    var errorEl = byId("settings-error");
    if (errorEl) {
      errorEl.textContent = message;
      errorEl.hidden = false;
    }
  }

  function clearSettingsError() {
    var errorEl = byId("settings-error");
    if (errorEl) {
      errorEl.textContent = "";
      errorEl.hidden = true;
    }
  }

  // DIAL-02: live Mbit/s readout + governing-cap readout while the operator
  // types into the (now Mbit/s) ceiling field -- mirrors wireCatchUpSlider's
  // 'input' listener. Persistence itself still goes through the existing
  // Save Settings form submit / collectSettingsChanges() conversion above;
  // no per-keystroke POST is added here (no new write path).
  function wireSendCeilingField() {
    var input = byId("setting-SEND_CEILING_BYTES_PER_SECOND");
    if (!input) {
      return;
    }
    input.addEventListener("input", function () {
      updateSendCeilingMbitReadout();
      updateGoverningCapReadout(latestViewModel);
    });
  }

  function wireSettingsForm() {
    var form = byId("settings-form");
    var btnSave = byId("btn-save-settings");
    if (!form) {
      return;
    }
    form.addEventListener("submit", function (event) {
      event.preventDefault();
      if (settingsSaveInFlight) {
        return;
      }
      settingsSaveInFlight = true;
      if (btnSave) {
        btnSave.disabled = true;
      }

      var changes = collectSettingsChanges();

      fetch("/api/config", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(changes),
      })
        .then(function (response) {
          return response.json().then(function (body) {
            return { status: response.status, body: body };
          });
        })
        .then(function (result) {
          // /api/config's success path serializes a PascalCase pscustomobject
          // (Success/Problems); its malformed-body 400 path returns a
          // hand-written lowercase literal (success/problems) -- read both so
          // an operator always sees the server's real Problems, never a
          // generic fallback caused by key-casing alone.
          var body = result.body || {};
          var success = body.Success !== undefined ? body.Success : body.success;
          var problems = body.Problems !== undefined ? body.Problems : body.problems;
          if (result.status === 200 && success) {
            clearSettingsError();
          } else {
            problems = problems || [];
            var reason = problems.length > 0 ? problems.join("; ") : "unknown validation error";
            showSettingsError("Couldn't save settings: " + reason + ". Nothing was changed.");
          }
        })
        .catch(function () {
          showSettingsError("Couldn't save settings: request failed. Nothing was changed.");
        })
        .then(function () {
          settingsSaveInFlight = false;
          if (btnSave) {
            btnSave.disabled = false;
          }
        });
    });
  }

  // ---------- Boot ----------

  function init() {
    wireStartStop();
    wirePickupStart();
    wireCutConfirm();
    wireResetConfirm();
    wireRecordingsList();
    wireSettingsForm();
    wireCatchUpSlider();
    wireSendCeilingSlider();
    wireSendCeilingField();
    wireNotificationButton();
    wireHeroChartHover();
    loadSettingsOnce();
    poll();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
