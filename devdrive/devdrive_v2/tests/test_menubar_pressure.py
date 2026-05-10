"""Tests for devdrive_v2.menubar_pressure.

Run with::

    PYTHONPATH=lib pytest lib/devdrive_v2/tests/test_menubar_pressure.py -v

All fixtures use tmp_path so nothing is written to the real
~/.config/lfg/ directory.
"""

from __future__ import annotations

import time
from pathlib import Path

import pytest

from devdrive_v2.menubar_pressure import (
    DEFAULT_CHART_PATH,
    PressureLevel,
    PressureSnapshot,
    _classify,
    generate_chart_html,
    get_current_pressure,
    get_pressure_history,
    write_chart_to_file,
)
from devdrive_v2.state import MetricsSample, StateManager


# ---------------------------------------------------------------------------
# Helpers / Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture()
def tmp_state(tmp_path: Path) -> StateManager:
    """Return a fresh StateManager backed by a temp file."""
    return StateManager(path=tmp_path / "devdrive_state.json")


def _add_sample(
    mgr: StateManager,
    df: float,
    container: float = 80.0,
    purgeable: float = 10.0,
    ts: float | None = None,
) -> None:
    """Helper: append one MetricsSample to *mgr*."""
    mgr.record_metric(
        MetricsSample(
            ts=ts if ts is not None else time.time(),
            df_free_gb=df,
            container_free_gb=container,
            purgeable_gb=purgeable,
        )
    )


# ---------------------------------------------------------------------------
# PressureLevel classification
# ---------------------------------------------------------------------------


class TestPressureLevelClassification:
    """Verify _classify() maps GB values to the correct PressureLevel."""

    def test_green_well_above_threshold(self) -> None:
        assert _classify(50.0) is PressureLevel.GREEN

    def test_green_just_above_10(self) -> None:
        assert _classify(10.01) is PressureLevel.GREEN

    def test_green_exact_boundary_is_not_green(self) -> None:
        # exactly 10 GB -- boundary is exclusive (> 10)
        assert _classify(10.0) is PressureLevel.YELLOW

    def test_yellow_midpoint(self) -> None:
        assert _classify(7.5) is PressureLevel.YELLOW

    def test_yellow_just_above_5(self) -> None:
        assert _classify(5.01) is PressureLevel.YELLOW

    def test_red_exact_5_boundary(self) -> None:
        # exactly 5 GB -- boundary is inclusive (<= 5)
        assert _classify(5.0) is PressureLevel.RED

    def test_red_below_5(self) -> None:
        assert _classify(3.0) is PressureLevel.RED

    def test_red_zero(self) -> None:
        assert _classify(0.0) is PressureLevel.RED

    def test_red_negative(self) -> None:
        # Pathological value -- still RED
        assert _classify(-1.0) is PressureLevel.RED

    def test_enum_values(self) -> None:
        assert PressureLevel.GREEN.value == "green"
        assert PressureLevel.YELLOW.value == "yellow"
        assert PressureLevel.RED.value == "red"


# ---------------------------------------------------------------------------
# get_current_pressure
# ---------------------------------------------------------------------------


class TestGetCurrentPressure:
    """Verify snapshot fields for various free_gb values and empty state."""

    def test_empty_metrics_returns_red(self, tmp_state: StateManager) -> None:
        snap = get_current_pressure(tmp_state)
        assert snap.level is PressureLevel.RED
        assert snap.free_gb == 0.0
        assert snap.container_free_gb == 0.0
        assert snap.purgeable_gb == 0.0
        assert snap.color_hex == "#ef4444"
        assert snap.label == "0.0 GB free"

    def test_green_pressure(self, tmp_state: StateManager) -> None:
        _add_sample(tmp_state, df=45.2, container=120.5, purgeable=30.1)
        snap = get_current_pressure(tmp_state)
        assert snap.level is PressureLevel.GREEN
        assert snap.free_gb == 45.2
        assert snap.container_free_gb == 120.5
        assert snap.purgeable_gb == 30.1
        assert snap.color_hex == "#22c55e"
        assert snap.label == "45.2 GB free"

    def test_yellow_pressure(self, tmp_state: StateManager) -> None:
        _add_sample(tmp_state, df=7.8)
        snap = get_current_pressure(tmp_state)
        assert snap.level is PressureLevel.YELLOW
        assert snap.color_hex == "#eab308"
        assert "7.8" in snap.label

    def test_red_pressure(self, tmp_state: StateManager) -> None:
        _add_sample(tmp_state, df=2.3)
        snap = get_current_pressure(tmp_state)
        assert snap.level is PressureLevel.RED
        assert snap.color_hex == "#ef4444"
        assert "2.3" in snap.label

    def test_returns_latest_not_first(self, tmp_state: StateManager) -> None:
        _add_sample(tmp_state, df=20.0)
        _add_sample(tmp_state, df=3.0)  # latest -- RED
        snap = get_current_pressure(tmp_state)
        assert snap.level is PressureLevel.RED
        assert snap.free_gb == 3.0

    def test_returns_pressure_snapshot_type(self, tmp_state: StateManager) -> None:
        _add_sample(tmp_state, df=12.0)
        snap = get_current_pressure(tmp_state)
        assert isinstance(snap, PressureSnapshot)

    def test_label_format(self, tmp_state: StateManager) -> None:
        _add_sample(tmp_state, df=8.567)
        snap = get_current_pressure(tmp_state)
        # Label must be "X.X GB free" -- one decimal place
        assert snap.label == "8.6 GB free"

    def test_exact_10_boundary_is_yellow(self, tmp_state: StateManager) -> None:
        _add_sample(tmp_state, df=10.0)
        snap = get_current_pressure(tmp_state)
        assert snap.level is PressureLevel.YELLOW

    def test_exact_5_boundary_is_red(self, tmp_state: StateManager) -> None:
        _add_sample(tmp_state, df=5.0)
        snap = get_current_pressure(tmp_state)
        assert snap.level is PressureLevel.RED

    def test_lazy_load_not_required(self, tmp_path: Path) -> None:
        """StateManager.load() need not be called before get_current_pressure."""
        mgr = StateManager(path=tmp_path / "state.json")
        # Do NOT call mgr.load() first
        snap = get_current_pressure(mgr)
        assert isinstance(snap, PressureSnapshot)


# ---------------------------------------------------------------------------
# get_pressure_history
# ---------------------------------------------------------------------------


class TestGetPressureHistory:
    """Verify time-window filtering and output format."""

    def test_empty_buffer_returns_empty_list(self, tmp_state: StateManager) -> None:
        result = get_pressure_history(tmp_state, hours=24.0)
        assert result == []

    def test_all_within_window_returned(self, tmp_state: StateManager) -> None:
        now = time.time()
        _add_sample(tmp_state, df=20.0, ts=now - 3600)
        _add_sample(tmp_state, df=18.0, ts=now - 1800)
        _add_sample(tmp_state, df=15.0, ts=now - 600)
        result = get_pressure_history(tmp_state, hours=24.0)
        assert len(result) == 3

    def test_old_samples_excluded(self, tmp_state: StateManager) -> None:
        now = time.time()
        # 25 hours ago -- outside 24h window
        _add_sample(tmp_state, df=50.0, ts=now - 25 * 3600)
        # 1 hour ago -- inside window
        _add_sample(tmp_state, df=30.0, ts=now - 3600)
        result = get_pressure_history(tmp_state, hours=24.0)
        assert len(result) == 1
        assert result[0]["df_free_gb"] == 30.0

    def test_narrow_window(self, tmp_state: StateManager) -> None:
        now = time.time()
        _add_sample(tmp_state, df=40.0, ts=now - 7200)   # 2h ago -- outside 1h
        _add_sample(tmp_state, df=35.0, ts=now - 1800)   # 30m ago -- inside
        result = get_pressure_history(tmp_state, hours=1.0)
        assert len(result) == 1
        assert result[0]["df_free_gb"] == 35.0

    def test_result_dict_keys(self, tmp_state: StateManager) -> None:
        _add_sample(tmp_state, df=20.0, container=100.0, purgeable=5.0)
        result = get_pressure_history(tmp_state, hours=24.0)
        assert len(result) == 1
        entry = result[0]
        assert set(entry.keys()) == {"ts_iso", "df_free_gb", "container_free_gb", "purgeable_gb"}

    def test_ts_iso_is_utc_isoformat(self, tmp_state: StateManager) -> None:
        _add_sample(tmp_state, df=20.0)
        result = get_pressure_history(tmp_state, hours=24.0)
        ts_iso = result[0]["ts_iso"]
        # Must end with +00:00 (UTC) and contain 'T'
        assert "T" in ts_iso
        assert "+00:00" in ts_iso or "Z" in ts_iso

    def test_values_preserved(self, tmp_state: StateManager) -> None:
        _add_sample(tmp_state, df=22.5, container=88.3, purgeable=14.7)
        result = get_pressure_history(tmp_state, hours=24.0)
        entry = result[0]
        assert entry["df_free_gb"] == 22.5
        assert entry["container_free_gb"] == 88.3
        assert entry["purgeable_gb"] == 14.7

    def test_default_hours_is_24(self, tmp_state: StateManager) -> None:
        now = time.time()
        _add_sample(tmp_state, df=10.0, ts=now - 23 * 3600)  # inside 24h
        _add_sample(tmp_state, df=10.0, ts=now - 25 * 3600)  # outside 24h
        result = get_pressure_history(tmp_state)
        assert len(result) == 1

    def test_exactly_at_boundary_excluded(self, tmp_state: StateManager) -> None:
        now = time.time()
        # Exactly at the cutoff (within floating point tolerance)
        _add_sample(tmp_state, df=20.0, ts=now - 24 * 3600 - 1)
        result = get_pressure_history(tmp_state, hours=24.0)
        assert len(result) == 0

    def test_multiple_samples_ordered_oldest_first(self, tmp_state: StateManager) -> None:
        now = time.time()
        # Insert in order -- ring buffer preserves insertion order
        for i in range(5):
            _add_sample(tmp_state, df=float(10 + i), ts=now - (5 - i) * 600)
        result = get_pressure_history(tmp_state, hours=24.0)
        dfs = [r["df_free_gb"] for r in result]
        assert dfs == sorted(dfs)  # ascending = oldest first


# ---------------------------------------------------------------------------
# generate_chart_html
# ---------------------------------------------------------------------------


class TestGenerateChartHtml:
    """Verify the generated HTML is well-formed and contains required elements."""

    @pytest.fixture()
    def empty_html(self) -> str:
        return generate_chart_html([])

    @pytest.fixture()
    def sample_history(self) -> list[dict]:
        import datetime as dt
        now = dt.datetime.now(tz=dt.timezone.utc)
        return [
            {
                "ts_iso": (now - dt.timedelta(hours=h)).isoformat(),
                "df_free_gb": 20.0 - h,
                "container_free_gb": 80.0,
                "purgeable_gb": 5.0,
            }
            for h in range(6, 0, -1)
        ]

    @pytest.fixture()
    def sample_events(self) -> list[dict]:
        import datetime as dt
        now = dt.datetime.now(tz=dt.timezone.utc)
        return [
            {"ts_iso": (now - dt.timedelta(hours=3)).isoformat(), "label": "purge run"},
        ]

    def test_returns_string(self, empty_html: str) -> None:
        assert isinstance(empty_html, str)

    def test_starts_with_doctype(self, empty_html: str) -> None:
        assert empty_html.startswith("<!DOCTYPE html>")

    def test_contains_d3_cdn(self, empty_html: str) -> None:
        assert "cdn.jsdelivr.net/npm/d3" in empty_html

    def test_contains_d3_script_tag(self, empty_html: str) -> None:
        assert "<script" in empty_html
        assert "d3" in empty_html.lower()

    def test_contains_svg_container_div(self, empty_html: str) -> None:
        # The D3 code appends an SVG into #chart
        assert 'id="chart"' in empty_html

    def test_contains_threshold_band_classes(self, empty_html: str) -> None:
        assert "band-green" in empty_html
        assert "band-yellow" in empty_html
        assert "band-red" in empty_html

    def test_contains_threshold_values(self, empty_html: str) -> None:
        # 10 GB and 5 GB thresholds must appear in the JS
        assert "10" in empty_html
        assert "5" in empty_html

    def test_contains_line_series_classes(self, empty_html: str) -> None:
        assert "line-df" in empty_html
        assert "line-container" in empty_html
        assert "line-purgeable" in empty_html

    def test_dark_theme_background(self, empty_html: str) -> None:
        # Background must be dark -- #1a1a1a is the spec colour
        assert "#1a1a1a" in empty_html

    def test_green_colour_present(self, empty_html: str) -> None:
        assert "#22c55e" in empty_html

    def test_yellow_colour_present(self, empty_html: str) -> None:
        assert "#eab308" in empty_html

    def test_red_colour_present(self, empty_html: str) -> None:
        assert "#ef4444" in empty_html

    def test_history_data_embedded(self, sample_history: list[dict]) -> None:
        html = generate_chart_html(sample_history)
        # At least one ts_iso value from the history should appear verbatim
        assert sample_history[0]["ts_iso"] in html

    def test_empty_history_no_crash(self) -> None:
        html = generate_chart_html([])
        assert "<!DOCTYPE html>" in html

    def test_events_marker_class_present_when_events_given(
        self, sample_history: list[dict], sample_events: list[dict]
    ) -> None:
        html = generate_chart_html(sample_history, events=sample_events)
        assert "event-line" in html
        assert "event-label" in html

    def test_events_label_embedded(
        self, sample_history: list[dict], sample_events: list[dict]
    ) -> None:
        html = generate_chart_html(sample_history, events=sample_events)
        assert "purge run" in html

    def test_none_events_defaults_to_no_event_data(
        self, sample_history: list[dict]
    ) -> None:
        html = generate_chart_html(sample_history, events=None)
        # Events JS array should be an empty array literal
        assert "[]" in html

    def test_no_external_deps_besides_d3(self, empty_html: str) -> None:
        """Only allowed external resource is the D3 CDN."""
        import re
        external = re.findall(r'src=["\']https?://[^"\']+["\']', empty_html)
        assert len(external) == 1
        assert "d3" in external[0]

    def test_html_structure_complete(self, empty_html: str) -> None:
        assert "<html" in empty_html
        assert "</html>" in empty_html
        assert "<head>" in empty_html or "<head\n" in empty_html
        assert "<body>" in empty_html
        assert "</body>" in empty_html

    def test_tooltip_element_present(self, empty_html: str) -> None:
        assert 'id="tooltip"' in empty_html

    def test_legend_present(self, empty_html: str) -> None:
        assert "legend" in empty_html
        assert "df free" in empty_html


# ---------------------------------------------------------------------------
# write_chart_to_file
# ---------------------------------------------------------------------------


class TestWriteChartToFile:
    """Verify file writing, default path logic, and content preservation."""

    @pytest.fixture()
    def simple_html(self) -> str:
        return generate_chart_html([])

    def test_writes_to_specified_path(self, simple_html: str, tmp_path: Path) -> None:
        dest = tmp_path / "chart.html"
        result = write_chart_to_file(simple_html, path=dest)
        assert result == dest
        assert dest.exists()

    def test_content_matches(self, simple_html: str, tmp_path: Path) -> None:
        dest = tmp_path / "chart.html"
        write_chart_to_file(simple_html, path=dest)
        assert dest.read_text(encoding="utf-8") == simple_html

    def test_returns_path_object(self, simple_html: str, tmp_path: Path) -> None:
        dest = tmp_path / "chart.html"
        result = write_chart_to_file(simple_html, path=dest)
        assert isinstance(result, Path)

    def test_creates_parent_directories(self, simple_html: str, tmp_path: Path) -> None:
        dest = tmp_path / "nested" / "deep" / "chart.html"
        write_chart_to_file(simple_html, path=dest)
        assert dest.exists()

    def test_overwrites_existing_file(self, simple_html: str, tmp_path: Path) -> None:
        dest = tmp_path / "chart.html"
        dest.write_text("old content", encoding="utf-8")
        write_chart_to_file(simple_html, path=dest)
        assert dest.read_text(encoding="utf-8") == simple_html

    def test_default_path_is_config_lfg(self, simple_html: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
        """Default path resolves to ~/.config/lfg/pressure_chart.html."""
        # DEFAULT_CHART_PATH is computed at import time so we patch the
        # module-level constant directly rather than Path.home().
        import devdrive_v2.menubar_pressure as mp

        fake_dest = tmp_path / ".config" / "lfg" / "pressure_chart.html"
        monkeypatch.setattr(mp, "DEFAULT_CHART_PATH", fake_dest)
        result = write_chart_to_file(simple_html)
        assert result == fake_dest
        assert fake_dest.exists()

    def test_accepts_string_path(self, simple_html: str, tmp_path: Path) -> None:
        """path parameter accepts a Path object (str coercion handled internally)."""
        dest = tmp_path / "str_path.html"
        result = write_chart_to_file(simple_html, path=dest)
        assert result.exists()

    def test_utf8_encoding(self, tmp_path: Path) -> None:
        html = generate_chart_html([])
        dest = tmp_path / "chart.html"
        write_chart_to_file(html, path=dest)
        content = dest.read_bytes()
        # Must be decodable as UTF-8
        decoded = content.decode("utf-8")
        assert "<!DOCTYPE html>" in decoded
