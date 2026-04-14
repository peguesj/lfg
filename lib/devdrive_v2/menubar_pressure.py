"""Menubar pressure indicator and history chart for LFG DevDrive v2.

Reads the metrics ring buffer from StateManager, classifies disk pressure
into GREEN/YELLOW/RED levels, and generates a self-contained D3.js HTML
chart suitable for display inside the LFG menubar popover.

Typical usage::

    mgr = StateManager()
    snap = get_current_pressure(mgr)
    history = get_pressure_history(mgr, hours=24.0)
    html = generate_chart_html(history)
    path = write_chart_to_file(html)
"""

from __future__ import annotations

import datetime
import json as _json
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Optional

from devdrive_v2.state import StateManager

# ---------------------------------------------------------------------------
# Thresholds (GB)
# ---------------------------------------------------------------------------
_THRESHOLD_GREEN = 10.0  # > 10 GB -> GREEN
_THRESHOLD_YELLOW = 5.0  # 5-10 GB -> YELLOW
# < 5 GB -> RED

DEFAULT_CHART_PATH = Path.home() / ".config" / "lfg" / "pressure_chart.html"


# ---------------------------------------------------------------------------
# PressureLevel
# ---------------------------------------------------------------------------


class PressureLevel(str, Enum):
    """Disk pressure classification based on df_free_gb."""

    GREEN = "green"
    YELLOW = "yellow"
    RED = "red"


def _classify(free_gb: float) -> PressureLevel:
    """Return the PressureLevel for a given free-space value.

    Args:
        free_gb: Available disk space in gigabytes.

    Returns:
        PressureLevel.GREEN when free_gb > 10,
        PressureLevel.YELLOW when 5 < free_gb <= 10,
        PressureLevel.RED when free_gb <= 5.
    """
    if free_gb > _THRESHOLD_GREEN:
        return PressureLevel.GREEN
    if free_gb > _THRESHOLD_YELLOW:
        return PressureLevel.YELLOW
    return PressureLevel.RED


_LEVEL_COLOR: dict[PressureLevel, str] = {
    PressureLevel.GREEN: "#22c55e",
    PressureLevel.YELLOW: "#eab308",
    PressureLevel.RED: "#ef4444",
}


# ---------------------------------------------------------------------------
# PressureSnapshot
# ---------------------------------------------------------------------------


@dataclass
class PressureSnapshot:
    """Point-in-time pressure reading for the menubar indicator.

    Attributes:
        level: Classified pressure level (GREEN / YELLOW / RED).
        free_gb: Raw df free space in GB from the latest metric sample.
        container_free_gb: APFS container free space in GB.
        purgeable_gb: Purgeable space in GB.
        color_hex: CSS hex colour matching the pressure level.
        label: Human-readable label, e.g. ``"45.2 GB free"``.
    """

    level: PressureLevel
    free_gb: float
    container_free_gb: float
    purgeable_gb: float
    color_hex: str
    label: str


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def get_current_pressure(state_mgr: StateManager) -> PressureSnapshot:
    """Return the current pressure snapshot from the latest metric sample.

    If no metrics have been recorded yet the snapshot reflects 0 GB free
    (RED level) with zeroed container and purgeable values.

    Args:
        state_mgr: Initialised StateManager instance. ``load()`` does not need
            to have been called first -- the property accessor on StateManager
            handles lazy loading.

    Returns:
        A PressureSnapshot describing current disk pressure.
    """
    sample = state_mgr.latest_metric()
    if sample is None:
        level = PressureLevel.RED
        free_gb = 0.0
        container_free_gb = 0.0
        purgeable_gb = 0.0
    else:
        free_gb = sample.df_free_gb
        container_free_gb = sample.container_free_gb
        purgeable_gb = sample.purgeable_gb
        level = _classify(free_gb)

    return PressureSnapshot(
        level=level,
        free_gb=free_gb,
        container_free_gb=container_free_gb,
        purgeable_gb=purgeable_gb,
        color_hex=_LEVEL_COLOR[level],
        label=f"{free_gb:.1f} GB free",
    )


def get_pressure_history(
    state_mgr: StateManager,
    hours: float = 24.0,
) -> list[dict]:
    """Return ring-buffer entries within the requested time window.

    Entries are sorted oldest-first, ready to be fed directly to
    generate_chart_html().

    Args:
        state_mgr: Initialised StateManager instance.
        hours: Look-back window in hours.  Defaults to 24.0.

    Returns:
        A list of dicts, each with keys: ``ts_iso`` (ISO-8601 UTC string),
        ``df_free_gb``, ``container_free_gb``, ``purgeable_gb``.
        Empty list when the ring buffer is empty or all samples fall outside
        the window.
    """
    import time

    cutoff = time.time() - hours * 3600.0
    result: list[dict] = []
    for sample in state_mgr.state.metrics:
        if sample.ts < cutoff:
            continue
        ts_iso = datetime.datetime.fromtimestamp(
            sample.ts, tz=datetime.timezone.utc
        ).isoformat()
        result.append(
            {
                "ts_iso": ts_iso,
                "df_free_gb": sample.df_free_gb,
                "container_free_gb": sample.container_free_gb,
                "purgeable_gb": sample.purgeable_gb,
            }
        )
    return result


# ---------------------------------------------------------------------------
# Chart generation helpers
# ---------------------------------------------------------------------------

_CHART_CSS = """
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: #1a1a1a;
    color: #e5e5e5;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
    font-size: 12px;
    padding: 12px;
  }
  h1 {
    font-size: 13px;
    font-weight: 600;
    color: #f5f5f5;
    margin-bottom: 10px;
    letter-spacing: 0.02em;
  }
  #chart { width: 100%; }
  .line-df        { fill: none; stroke: #22c55e; stroke-width: 1.8px; }
  .line-container { fill: none; stroke: #60a5fa; stroke-width: 1.4px; stroke-dasharray: 4 3; }
  .line-purgeable { fill: none; stroke: #a78bfa; stroke-width: 1.4px; stroke-dasharray: 2 3; }
  .band-green  { fill: #22c55e; opacity: 0.06; }
  .band-yellow { fill: #eab308; opacity: 0.08; }
  .band-red    { fill: #ef4444; opacity: 0.10; }
  .threshold-line { stroke-dasharray: 3 3; stroke-width: 1px; opacity: 0.5; }
  .event-line { stroke: #f97316; stroke-width: 1px; stroke-dasharray: 4 2; opacity: 0.8; }
  .event-label { fill: #f97316; font-size: 10px; }
  .axis text  { fill: #999; font-size: 10px; }
  .axis line, .axis path { stroke: #444; }
  .grid line { stroke: #2a2a2a; }
  .legend { display: flex; gap: 14px; margin-top: 8px; align-items: center; }
  .legend-item { display: flex; align-items: center; gap: 5px; color: #aaa; font-size: 11px; }
  .legend-swatch { width: 22px; height: 3px; border-radius: 2px; }
  .tooltip {
    position: absolute;
    background: #2a2a2a;
    border: 1px solid #444;
    border-radius: 6px;
    padding: 6px 10px;
    font-size: 11px;
    color: #e5e5e5;
    pointer-events: none;
    opacity: 0;
    transition: opacity 0.15s;
    line-height: 1.6;
    white-space: nowrap;
  }
"""

_CHART_JS_TEMPLATE = """
(function () {{
  const RAW_HISTORY = {history_json};
  const RAW_EVENTS  = {events_json};

  const data = RAW_HISTORY.map(function(d) {{
    return {{ ts: new Date(d.ts_iso), df: +d.df_free_gb,
              container: +d.container_free_gb, purgeable: +d.purgeable_gb }};
  }});
  const events = RAW_EVENTS.map(function(e) {{
    return {{ ts: new Date(e.ts_iso), label: String(e.label) }};
  }});

  var margin = {{ top: 16, right: 20, bottom: 36, left: 44 }};
  var totalW = (document.getElementById("chart").clientWidth || 480);
  var totalH = 200;
  var W = totalW - margin.left - margin.right;
  var H = totalH - margin.top - margin.bottom;

  var svg = d3.select("#chart")
    .append("svg")
    .attr("width", totalW)
    .attr("height", totalH)
    .attr("role", "img")
    .attr("aria-label", "DevDrive pressure time-series chart");

  var g = svg.append("g")
    .attr("transform", "translate(" + margin.left + "," + margin.top + ")");

  var allTs = data.map(function(d) {{ return d.ts; }})
    .concat(events.map(function(e) {{ return e.ts; }}));
  var xDomain = allTs.length > 0
    ? [d3.min(allTs), d3.max(allTs)]
    : [new Date(Date.now() - 86400000), new Date()];

  var allVals = [];
  data.forEach(function(d) {{
    allVals.push(d.df, d.container, d.purgeable);
  }});
  var maxVal = allVals.length > 0 ? Math.max(d3.max(allVals) * 1.15, 15) : 15;

  var xScale = d3.scaleTime().domain(xDomain).range([0, W]);
  var yScale = d3.scaleLinear().domain([0, maxVal]).range([H, 0]).nice();

  // Grid
  g.append("g").attr("class", "grid")
    .call(d3.axisLeft(yScale).tickSize(-W).tickFormat(""))
    .select(".domain").remove();

  // Threshold bands
  g.append("rect").attr("class", "band-green")
    .attr("x", 0).attr("y", yScale(maxVal))
    .attr("width", W)
    .attr("height", Math.max(0, yScale(10) - yScale(maxVal)));

  g.append("rect").attr("class", "band-yellow")
    .attr("x", 0).attr("y", yScale(10))
    .attr("width", W)
    .attr("height", Math.max(0, yScale(5) - yScale(10)));

  g.append("rect").attr("class", "band-red")
    .attr("x", 0).attr("y", yScale(5))
    .attr("width", W)
    .attr("height", Math.max(0, yScale(0) - yScale(5)));

  // Threshold lines
  [{{ y: 10, c: "#22c55e" }}, {{ y: 5, c: "#eab308" }}].forEach(function(t) {{
    g.append("line").attr("class", "threshold-line")
      .attr("x1", 0).attr("x2", W)
      .attr("y1", yScale(t.y)).attr("y2", yScale(t.y))
      .attr("stroke", t.c);
  }});

  // Series lines
  var lineDf = d3.line()
    .x(function(d) {{ return xScale(d.ts); }})
    .y(function(d) {{ return yScale(d.df); }})
    .defined(function(d) {{ return !isNaN(d.df); }});
  var lineCtr = d3.line()
    .x(function(d) {{ return xScale(d.ts); }})
    .y(function(d) {{ return yScale(d.container); }})
    .defined(function(d) {{ return !isNaN(d.container); }});
  var linePrg = d3.line()
    .x(function(d) {{ return xScale(d.ts); }})
    .y(function(d) {{ return yScale(d.purgeable); }})
    .defined(function(d) {{ return !isNaN(d.purgeable); }});

  if (data.length > 0) {{
    g.append("path").datum(data).attr("class", "line-df").attr("d", lineDf);
    g.append("path").datum(data).attr("class", "line-container").attr("d", lineCtr);
    g.append("path").datum(data).attr("class", "line-purgeable").attr("d", linePrg);
  }} else {{
    g.append("text")
      .attr("x", W / 2).attr("y", H / 2)
      .attr("text-anchor", "middle")
      .attr("fill", "#555").attr("font-size", "11px")
      .text("No data recorded yet");
  }}

  // Event markers
  events.forEach(function(ev) {{
    var x = xScale(ev.ts);
    g.append("line").attr("class", "event-line")
      .attr("x1", x).attr("x2", x).attr("y1", 0).attr("y2", H);
    g.append("text").attr("class", "event-label")
      .attr("x", x + 3).attr("y", 12)
      .text(ev.label.substring(0, 20));
  }});

  // Axes
  g.append("g").attr("class", "axis")
    .attr("transform", "translate(0," + H + ")")
    .call(d3.axisBottom(xScale).ticks(5).tickFormat(d3.timeFormat("%H:%M")));
  g.append("g").attr("class", "axis")
    .call(d3.axisLeft(yScale).ticks(5).tickFormat(function(d) {{ return d + " GB"; }}));

  // Tooltip via title elements (accessible, no XSS risk)
  var bisect = d3.bisector(function(d) {{ return d.ts; }}).left;
  var tooltipEl = document.getElementById("tooltip");

  svg.append("rect")
    .attr("fill", "none").attr("pointer-events", "all")
    .attr("width", totalW).attr("height", totalH)
    .on("mousemove", function(event) {{
      if (data.length === 0) return;
      var coords = d3.pointer(event, this);
      var x0 = xScale.invert(coords[0] - margin.left);
      var i = bisect(data, x0, 1);
      var d = i < data.length ? data[i] : data[data.length - 1];
      var timeStr = d3.timeFormat("%Y-%m-%d %H:%M")(d.ts);
      // Build tooltip using safe DOM text nodes only
      while (tooltipEl.firstChild) {{ tooltipEl.removeChild(tooltipEl.firstChild); }}
      var lines = [
        timeStr,
        "df free: " + d.df.toFixed(1) + " GB",
        "container: " + d.container.toFixed(1) + " GB",
        "purgeable: " + d.purgeable.toFixed(1) + " GB"
      ];
      lines.forEach(function(line, idx) {{
        var p = document.createElement("div");
        p.textContent = line;
        if (idx === 1) p.style.color = "#22c55e";
        if (idx === 2) p.style.color = "#60a5fa";
        if (idx === 3) p.style.color = "#a78bfa";
        tooltipEl.appendChild(p);
      }});
      tooltipEl.style.opacity = "1";
      tooltipEl.style.left = (event.offsetX + 12) + "px";
      tooltipEl.style.top  = (event.offsetY - 10) + "px";
    }})
    .on("mouseleave", function() {{ tooltipEl.style.opacity = "0"; }});
}})();
"""


def generate_chart_html(
    history: list[dict],
    events: Optional[list[dict]] = None,
) -> str:
    """Generate a self-contained D3.js HTML chart for the pressure history.

    The chart renders three time-series lines (df_free_gb, container_free_gb,
    purgeable_gb) over the supplied history window with colour-coded threshold
    bands and optional vertical event markers.

    The returned string is a complete HTML document -- no external dependencies
    beyond the D3.js CDN link.

    Args:
        history: List of dicts produced by get_pressure_history().
            Each dict must have ``ts_iso``, ``df_free_gb``, ``container_free_gb``,
            ``purgeable_gb`` keys.
        events: Optional list of event dicts.  Each must have ``ts_iso`` (str)
            and ``label`` (str) keys.  A vertical dashed marker is drawn at
            each event timestamp.

    Returns:
        A self-contained HTML document string.
    """
    events = events or []
    history_json = _json.dumps(history)
    events_json = _json.dumps(events)

    js_body = _CHART_JS_TEMPLATE.format(
        history_json=history_json,
        events_json=events_json,
    )

    return (
        "<!DOCTYPE html>\n"
        '<html lang="en">\n'
        "<head>\n"
        '<meta charset="UTF-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1.0">\n'
        "<title>LFG -- DevDrive Pressure History</title>\n"
        '<script src="https://cdn.jsdelivr.net/npm/d3@7/dist/d3.min.js"></script>\n'
        "<style>\n"
        + _CHART_CSS
        + "\n</style>\n"
        "</head>\n"
        "<body>\n"
        "<h1>DevDrive Pressure -- 24h History</h1>\n"
        '<div id="chart"></div>\n'
        '<div class="legend">\n'
        '  <div class="legend-item">'
        '    <div class="legend-swatch" style="background:#22c55e;"></div>df free'
        "  </div>\n"
        '  <div class="legend-item">'
        '    <div class="legend-swatch" style="background:#60a5fa;"></div>container free'
        "  </div>\n"
        '  <div class="legend-item">'
        '    <div class="legend-swatch" style="background:#a78bfa;"></div>purgeable'
        "  </div>\n"
        "</div>\n"
        '<div class="tooltip" id="tooltip"></div>\n'
        "<script>\n"
        + js_body
        + "\n</script>\n"
        "</body>\n"
        "</html>"
    )


def write_chart_to_file(
    html: str,
    path: Optional[Path] = None,
) -> Path:
    """Write the chart HTML to a file and return the resolved path.

    When *path* is ``None`` the file is written to
    ``~/.config/lfg/pressure_chart.html``, which is the location the LFG
    menubar Swift helper reads when opening the pressure popover.

    Args:
        html: Self-contained HTML string produced by generate_chart_html().
        path: Destination file path.  When ``None`` the default location
            ``~/.config/lfg/pressure_chart.html`` is used.

    Returns:
        The resolved Path of the written file.
    """
    dest = Path(path) if path is not None else DEFAULT_CHART_PATH
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(html, encoding="utf-8")
    return dest
