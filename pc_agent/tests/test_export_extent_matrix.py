"""Round-6 issue 06 — §10.4 export extent matrix + artboard survival.

NORMATIVE checks (Doc 02 §10.4):

* bounded preset ⇒ extent is EXACTLY the artboard rect, ``px = world*dpi/300``
  strip-padded to the 2048 grid, DISTINCT and proportionally correct per DPI;
* INFINITE ⇒ ``content_bounds`` padded 64 world units (content-derived, never
  artboard-shaped);
* every loader/index/sync path preserves ``artboard.preset/width/height/
  is_infinite`` end-to-end — an extent resolving to content size for a bounded
  doc is a bug;
* PDF pages stay artboard-proportional (artboard pt exactly — NO strip padding).
"""

from __future__ import annotations

import json
import math
import zipfile
from pathlib import Path
from uuid import uuid4

import pytest

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import EventBus
from pc_agent.engine.document_store import (
    Artboard,
    CanvasDocument,
    DocumentStore,
)
from pc_agent.engine.local_canvas_index import LocalCanvasIndex
from pc_agent.engine.scene_graph import CanvasNode, NodeGeometry, NodeStyle, SceneGraph
from pc_agent.export import tiled_raster_exporter as tiled
from pc_agent.export import vector_pdf_exporter as pdf

#: §3 preset table (300-DPI world units).
_PRESETS: dict[str, tuple[float, float]] = {
    "A5": (1748.0, 2480.0),
    "A4": (2480.0, 3508.0),
    "LETTER": (2550.0, 3300.0),
}
#: IDENTICAL content for every preset — overflows A5 on purpose (real docs do too).
_CONTENT: dict[str, float] = {"min_x": 100.0, "min_y": 100.0, "max_x": 3000.0, "max_y": 1200.0}
#: Expected raster dims: (preset, dpi) → (w, h) per §10.4.
#: Round-11 issue 05 — these are the EXACT ``world * dpi / 300`` sizes; the
#: 2048 strip grid is a renderer detail and no longer pads the delivered file.
_DIM_MATRIX: dict[tuple[str, int], tuple[int, int]] = {
    ("A5", 300): (1748, 2480),
    ("A5", 600): (3496, 4960),
    ("A4", 300): (2480, 3508),
    ("A4", 600): (4960, 7016),
    ("LETTER", 300): (2550, 3300),
    ("LETTER", 600): (5100, 6600),
}
#: INFINITE content extent: content ±64 ⇒ 3028×1228 world.
_INFINITE_EXTENT = (36.0, 36.0, 3064.0, 1264.0)
_INFINITE_DIMS = {300: (3028, 1228), 600: (6056, 2456)}


def _stroke_layer() -> list[CanvasNode]:
    """Identical content: one chain stroke + one polyline over the content rect."""
    chain = [[100.0, 100.0], [900.0, 400.0], [1800.0, 700.0], [3000.0, 1200.0]]
    anchors = [[100.0, 1200.0], [1500.0, 600.0], [3000.0, 100.0]]
    nodes = []
    for i, pts in enumerate((chain, anchors)):
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        nodes.append(
            CanvasNode(
                node_id=f"m{i}",
                kind="STROKE",
                layer=i,
                bbox=(min(xs), min(ys), max(xs), max(ys)),
                style=NodeStyle(color="#1E1E1E", stroke_width=6.0, opacity=1.0,
                                blend_mode="SRC_OVER"),
                geometry=NodeGeometry(pts=pts, shape_type=None, graph_config=None,
                                      asset_ref=None),
            )
        )
    return nodes


def make_doc(preset: str) -> CanvasDocument:
    """Doc for ``preset`` with IDENTICAL content on every preset."""
    if preset == "INFINITE":
        width, height, infinite = None, None, True
    else:
        width, height = _PRESETS[preset]
        infinite = False
    return CanvasDocument(
        canvas_id=f"matrix-{preset.lower()}-{uuid4().hex[:6]}",
        title=f"matrix {preset}",
        created_at=1,
        updated_at=1,
        artboard=Artboard(preset=preset, width=width, height=height,
                          is_infinite=infinite),
        content_bounds=dict(_CONTENT),
        elements=_stroke_layer(),
    )


def _png_size(path: Path) -> tuple[int, int]:
    head = path.read_bytes()[:24]
    assert head[:4] == b"\x89PNG" and head[12:16] == b"IHDR", path
    return (int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big"))


def _config(tmp_path: Path) -> AppConfig:
    return AppConfig(
        shader_dir=tmp_path / "shaders",
        assets_dir=tmp_path / "assets",
        export_dir=tmp_path / "exports",
        appdata_dir=tmp_path / "appdata",
    )


def _env(tmp_path: Path) -> tuple[DocumentStore, LocalCanvasIndex]:
    bus = EventBus()
    scene = SceneGraph(bus)
    store = DocumentStore(bus, _config(tmp_path), scene)
    index = LocalCanvasIndex(store, tmp_path / "hub")
    store.attach_index(index)
    return store, index


# ---------------------------------------------------------------------------
# §10.4 extent matrix
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("preset", list(_PRESETS))
def test_bounded_extent_is_exact_artboard(preset: str) -> None:
    doc = make_doc(preset)
    width, height = _PRESETS[preset]
    assert tiled.resolve_extent(doc) == (0.0, 0.0, width, height)


@pytest.mark.parametrize(("preset", "dpi"), sorted(_DIM_MATRIX, key=lambda k: (k[0], k[1])))
def test_extent_matrix_px_dims(preset: str, dpi: int) -> None:
    extent = tiled.resolve_extent(make_doc(preset))
    assert tiled.extent_to_px(extent, dpi) == _DIM_MATRIX[(preset, dpi)]


@pytest.mark.parametrize(("preset", "dpi"), sorted(_DIM_MATRIX, key=lambda k: (k[0], k[1])))
def test_bounded_matches_artboard_aspect_ratio(preset: str, dpi: int) -> None:
    """Round-11 issue 05 — a 1:√2 A4 page must never export as a square."""
    world_w, world_h = _PRESETS[preset]
    px_w, px_h = tiled.extent_to_px(tiled.resolve_extent(make_doc(preset)), dpi)
    assert px_w / px_h == pytest.approx(world_w / world_h, rel=5e-4)


def test_a4_export_is_not_square_at_any_dpi() -> None:
    for dpi in sorted(tiled.SUPPORTED_DPIS):
        w, h = tiled.extent_to_px((0.0, 0.0, 2480.0, 3508.0), dpi)
        assert (w, h) == (math.ceil(2480 * dpi / 300), math.ceil(3508 * dpi / 300))
        assert w != h


@pytest.mark.parametrize(("preset", "dpi"), sorted(_DIM_MATRIX, key=lambda k: (k[0], k[1])))
def test_render_grid_is_exact_target(preset: str, dpi: int) -> None:
    """The memmap is allocated at the delivered size — no 2048 padding."""
    extent = tiled.resolve_extent(make_doc(preset))
    assert tiled.extent_to_px(extent, dpi) == _DIM_MATRIX[(preset, dpi)]
    # Strip counts cover the last partial row/column (ceil, never truncate).
    w, h = _DIM_MATRIX[(preset, dpi)]
    assert math.ceil(w / tiled.STRIP_PX) * tiled.STRIP_PX >= w
    assert math.ceil(h / tiled.STRIP_PX) * tiled.STRIP_PX >= h


@pytest.mark.parametrize("dpi", [300, 600])
def test_infinite_stays_content_derived(dpi: int) -> None:
    extent = tiled.resolve_extent(make_doc("INFINITE"))
    assert extent == pytest.approx(_INFINITE_EXTENT)
    dims = tiled.extent_to_px(extent, dpi)
    assert dims == _INFINITE_DIMS[dpi]
    # Clearly different from every bounded preset at the same DPI.
    for preset in _PRESETS:
        assert dims != _DIM_MATRIX[(preset, dpi)]


def test_extents_are_distinct_per_preset() -> None:
    extents = {
        preset: tiled.resolve_extent(make_doc(preset)) for preset in (*_PRESETS, "INFINITE")
    }
    assert len(set(extents.values())) == len(extents)


@pytest.mark.parametrize(
    ("preset", "dpi"),
    [("A4", 300), ("A5", 300), ("A5", 600), ("A4", 600), ("INFINITE", 300)],
)
def test_export_dims_matrix_end_to_end(
    preset: str, dpi: int, tmp_path: Path
) -> None:
    """Real PNG artifacts carry the §10.4 dims (header-read, no decode)."""
    exporter = tiled.TiledRasterExporter(_config(tmp_path))
    out = tmp_path / "exports" / f"{preset}_{dpi}.png"
    exporter.export(make_doc(preset), dpi, out)
    expected = _DIM_MATRIX.get((preset, dpi), _INFINITE_DIMS[dpi])
    assert _png_size(out) == expected
    assert list(out.parent.glob("*.part")) == []


# ---------------------------------------------------------------------------
# §10.4 artboard survival: every loader / index / sync path
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("preset", list(_PRESETS))
def test_artboard_survives_index_round_trip(preset: str, tmp_path: Path) -> None:
    store, index = _env(tmp_path)
    doc = make_doc(preset)
    index.save_document(doc)
    loaded = index.load(doc.canvas_id)
    assert loaded is not None
    assert loaded.artboard == doc.artboard
    assert tiled.resolve_extent(loaded) == tiled.resolve_extent(doc)


@pytest.mark.parametrize("preset", list(_PRESETS))
def test_artboard_survives_payload_archive_and_parse(preset: str, tmp_path: Path) -> None:
    store, _index = _env(tmp_path)
    doc = make_doc(preset)
    body = DocumentStore.document_to_json(doc)

    parsed = DocumentStore.parse_document(json.loads(json.dumps(body)))
    assert parsed.artboard == doc.artboard

    path = tmp_path / "arc" / f"{doc.canvas_id}.slatesync"
    store.write_archive(doc, path, stamp_updated=False, sync_scene=False, focus=False)
    with zipfile.ZipFile(path) as archive:
        raw = json.loads(archive.read("document.json"))
    assert raw["artboard"] == json.loads(json.dumps(body))["artboard"]
    reopened = store.read_archive(path)
    assert reopened.artboard == doc.artboard

    opened = store.open_payload(json.loads(json.dumps(body)))
    assert opened.artboard == doc.artboard
    for survivor in (parsed, reopened, opened):
        assert tiled.resolve_extent(survivor) == tiled.resolve_extent(doc)
        assert pdf.page_size_pt(survivor) == pdf.page_size_pt(doc)


# ---------------------------------------------------------------------------
# §10.4 resilience: flags and missing dims can never content-collapse a page
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("flag", ["false", "False", "0", "no", ""])
def test_string_false_is_infinite_never_collapses_extent(flag: str) -> None:
    """Legacy senders could deliver ``is_infinite`` as a string — ``bool("false")``
    is True and (pre-fix) pushed every bounded preset onto content bounds."""
    doc = make_doc("A4")
    body = DocumentStore.document_to_json(doc)
    body["artboard"]["is_infinite"] = flag
    parsed = DocumentStore.parse_document(body)
    assert parsed.artboard.is_infinite is False
    assert tiled.resolve_extent(parsed) == (0.0, 0.0, 2480.0, 3508.0)


def test_stale_infinite_flag_keeps_bounded_artboard_extent() -> None:
    doc = make_doc("A4")
    doc.artboard.is_infinite = True  # stale/lying flag on a bounded preset
    assert tiled.resolve_extent(doc) == (0.0, 0.0, 2480.0, 3508.0)
    assert pdf.page_size_pt(doc) == pytest.approx((595.2, 841.92), abs=0.5)


def test_bounded_missing_dims_backfilled_from_preset_table() -> None:
    body = DocumentStore.document_to_json(make_doc("A4"))
    body["artboard"]["width"] = None
    body["artboard"]["height"] = None
    parsed = DocumentStore.parse_document(body)
    assert parsed.artboard.width == 2480.0
    assert parsed.artboard.height == 3508.0
    assert parsed.artboard.is_infinite is False
    assert tiled.resolve_extent(parsed) == (0.0, 0.0, 2480.0, 3508.0)


def test_infinite_payload_normalises_dims_and_flag() -> None:
    body = DocumentStore.document_to_json(make_doc("INFINITE"))
    body["artboard"]["width"] = 2480.0
    body["artboard"]["height"] = 3508.0
    body["artboard"]["is_infinite"] = "true"
    parsed = DocumentStore.parse_document(body)
    assert parsed.artboard.is_infinite is True
    assert parsed.artboard.width is None and parsed.artboard.height is None
    assert tiled.resolve_extent(parsed) == pytest.approx(_INFINITE_EXTENT)


# ---------------------------------------------------------------------------
# PDF page policy (§10.4 applies: page = artboard pt exactly, no strip pad)
# ---------------------------------------------------------------------------
@pytest.mark.parametrize(
    ("preset", "expected_pt"),
    [
        ("A4", (595.2, 841.92)),
        ("A5", (419.52, 595.2)),
        ("LETTER", (612.0, 792.0)),
    ],
)
def test_pdf_page_sizes_artboard_proportional(
    preset: str, expected_pt: tuple[float, float]
) -> None:
    w_pt, h_pt = pdf.page_size_pt(make_doc(preset))
    assert w_pt == pytest.approx(expected_pt[0], abs=0.5)
    assert h_pt == pytest.approx(expected_pt[1], abs=0.5)
    # Artboard pt exactly — PDF pages are never strip-padded like rasters.
    width, height = _PRESETS[preset]
    assert w_pt == pytest.approx(width * pdf.UNIT_TO_PT)
    assert h_pt == pytest.approx(height * pdf.UNIT_TO_PT)


def test_pdf_infinite_page_content_derived() -> None:
    extent = pdf._page_extent(make_doc("INFINITE"))
    # Doc 14 §4: content_bounds padded ±48/side (not the raster's ±64).
    assert extent == pytest.approx((52.0, 52.0, 3048.0, 1248.0))
    w_pt, h_pt = pdf.page_size_pt(make_doc("INFINITE"))
    assert w_pt == pytest.approx(2996.0 * pdf.UNIT_TO_PT)
    assert h_pt == pytest.approx(1196.0 * pdf.UNIT_TO_PT)
    # …and clearly not any bounded preset's page.
    for preset in _PRESETS:
        b_w, b_h = pdf.page_size_pt(make_doc(preset))
        assert (w_pt, h_pt) != (b_w, b_h)
