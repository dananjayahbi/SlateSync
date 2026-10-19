"""Round-6 issue 07 — PC thumbnail renderer contract (Doc 02 §10.6).

Covers: frozen signature, size clamping (PNG ≤192²) + parent-dir creation,
neutral bg / white paper / light border for bounded pages, stroke pixels with
the ``max(1px, w*scale)`` floor, EXACT cubic-chain tracing (``n>=4 &&
(n-1)%3==0`` — never re-fitted as anchors) with chain paths contained in the
canvas, missing/malformed elements degrading safely, and the A4-vs-INFINITE
view fit.
"""

from __future__ import annotations

import inspect
import time
from pathlib import Path

from PIL import Image

from pc_agent.engine.document_store import Artboard, CanvasDocument, DocumentStore
from pc_agent.engine.scene_graph import CanvasNode, NodeGeometry, NodeStyle
from pc_agent.export import thumbnail_renderer as thumb
from pc_agent.export.thumbnail_renderer import render_thumbnail

_BG = (0xEC, 0xEE, 0xF2)
_BORDER = (0xC9, 0xCF, 0xDA)
_PLACEHOLDER = (0xB9, 0xC2, 0xCF)
_WHITE = (255, 255, 255)


def _png_size(path: Path) -> tuple[int, int]:
    head = path.read_bytes()[:24]
    assert head[:4] == b"\x89PNG" and head[12:16] == b"IHDR", path
    return (int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big"))


def _near(c: tuple[int, int, int], rgb: tuple[int, int, int], tol: int = 12) -> bool:
    return all(abs(c[i] - rgb[i]) <= tol for i in range(3))


def _count(img: Image.Image, rgb: tuple[int, int, int], tol: int = 12) -> int:
    data = img.tobytes()
    r0, g0, b0 = rgb
    return sum(
        1
        for i in range(0, len(data), 3)
        if abs(data[i] - r0) <= tol
        and abs(data[i + 1] - g0) <= tol
        and abs(data[i + 2] - b0) <= tol
    )


def _ink_count(img: Image.Image) -> int:
    """Pixels that are neither backdrop, paper, nor border (i.e. content)."""
    data = img.tobytes()
    total = 0
    for i in range(0, len(data), 3):
        c = (data[i], data[i + 1], data[i + 2])
        if not _near(c, _BG, 18) and not _near(c, _WHITE, 30) and not _near(c, _BORDER, 30):
            total += 1
    return total


def _node(
    kind: str = "STROKE",
    pts: list | None = None,
    bbox: tuple[float, float, float, float] | None = None,
    *,
    color: str = "#1E1E1E",
    stroke_width: float = 20.0,
    shape_type: str | None = None,
    asset_ref: str | None = None,
) -> CanvasNode:
    pts = [] if pts is None else pts
    if bbox is None:
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        bbox = (min(xs), min(ys), max(xs), max(ys)) if pts else (0.0, 0.0, 0.0, 0.0)
    return CanvasNode(
        node_id=f"t-{kind}-{len(pts)}",
        kind=kind,
        layer=0,
        bbox=bbox,
        style=NodeStyle(color=color, stroke_width=stroke_width, opacity=1.0,
                        blend_mode="SRC_OVER"),
        geometry=NodeGeometry(pts=pts, shape_type=shape_type, graph_config=None,
                              asset_ref=asset_ref),
    )


def _doc(
    preset: str = "A4",
    width: float | None = 2480.0,
    height: float | None = 3508.0,
    *,
    infinite: bool = False,
    bounds: dict[str, float] | None = None,
    elements: list[CanvasNode] | None = None,
) -> CanvasDocument:
    if infinite:
        preset, width, height = "INFINITE", None, None
    return CanvasDocument(
        canvas_id="thumb-doc",
        title="thumb",
        created_at=0,
        updated_at=0,
        artboard=Artboard(preset=preset, width=width, height=height,
                          is_infinite=infinite),
        content_bounds=dict(bounds or {"min_x": 0.0, "min_y": 0.0,
                                       "max_x": 0.0, "max_y": 0.0}),
        elements=list(elements or []),
    )


def _open(path: Path) -> Image.Image:
    return Image.open(path).convert("RGB")


# ---------------------------------------------------------------------------
# Contract: signature, size clamp, parent dirs
# ---------------------------------------------------------------------------
def test_contract_signature_frozen() -> None:
    sig = inspect.signature(render_thumbnail)
    assert list(sig.parameters) == ["doc", "out_path", "size"]
    assert sig.parameters["size"].default == 192
    assert sig.return_annotation in (Path, "Path")
    assert callable(render_thumbnail)


def test_size_clamp_and_parent_dirs(tmp_path: Path) -> None:
    nested = tmp_path / "deep" / "nested" / "t.png"
    assert render_thumbnail(_doc(), nested) == nested
    assert _png_size(nested) == (192, 192)

    small = render_thumbnail(_doc(), tmp_path / "s64.png", size=64)
    assert _png_size(small) == (64, 64)

    capped = render_thumbnail(_doc(), tmp_path / "s256.png", size=256)
    assert _png_size(capped) == (192, 192)  # PNG ≤192² (§10.6)

    tiny = render_thumbnail(_doc(), tmp_path / "s0.png", size=0)
    assert _png_size(tiny) == (1, 1)


# ---------------------------------------------------------------------------
# Paper / border / backdrop
# ---------------------------------------------------------------------------
def test_bounded_paper_border_and_neutral_backdrop(tmp_path: Path) -> None:
    stroke = _node(pts=[[300.0, 400.0], [1500.0, 2000.0], [2200.0, 3100.0]])
    out = render_thumbnail(_doc(elements=[stroke]), tmp_path / "paper.png")
    img = _open(out)

    assert _near(img.getpixel((0, 0)), _BG)  # corner = neutral backdrop
    assert _count(img, _WHITE, 6) > 10_000  # white paper dominates the frame
    assert _count(img, _BORDER, 24) >= 40  # light border around the paper

    # Center of the page is paper-white (A4 aspect ⇒ centered column).
    assert _near(img.getpixel((96, 96)), _WHITE, 6)


def test_stroke_pixels_rendered_with_width_floor(tmp_path: Path) -> None:
    # 4 world units at thumb scale ≈ 0.2 px → floored to 1 px, still visible.
    stroke = _node(pts=[[300.0, 3000.0], [1200.0, 400.0], [2200.0, 3000.0]],
                   color="#E03030", stroke_width=4.0)
    out = render_thumbnail(_doc(elements=[stroke]), tmp_path / "stroke.png")
    img = _open(out)
    data = img.tobytes()
    red = sum(
        1
        for i in range(0, len(data), 3)
        if data[i] > 150 and data[i + 1] < 120 and data[i + 2] < 120
    )
    assert red >= 40


# ---------------------------------------------------------------------------
# Chain detection: EXACT cubics, contained path, (n-1) rule
# ---------------------------------------------------------------------------
def test_chain_path_contained_in_canvas(tmp_path: Path) -> None:
    view = (0.0, 0.0, 400.0, 300.0)
    chain = [[20.0, 20.0], [20.0, 150.0], [380.0, 150.0], [380.0, 20.0]]
    for x, y in chain:
        px, py = thumb._map_point(view, 192, x, y)
        assert 0.0 <= px < 192.0 and 0.0 <= py < 192.0

    # Rendered ink stays inside the canvas: a chain entirely OUTSIDE the view
    # is clipped away instead of escaping or crashing the surface.
    outside = _node(pts=[[5000.0, 5000.0], [5400.0, 5800.0], [5800.0, 5000.0],
                         [6200.0, 5800.0]])
    out = render_thumbnail(
        _doc(width=400.0, height=300.0, elements=[outside]), tmp_path / "clip.png"
    )
    assert _png_size(out) == (192, 192)
    assert _ink_count(_open(out)) == 0


def test_chain_detection_n_minus_one_rule() -> None:
    for n in (4, 7, 10, 13):  # Doc 21: n = 3k − 2 ⇒ (n-1) % 3 == 0
        assert thumb._is_chain([(0.0, 0.0)] * n) is True
    for n in (0, 1, 2, 3, 5, 6, 8, 9, 11, 12):  # never chains
        assert thumb._is_chain([(0.0, 0.0)] * n) is False


def test_chain_renders_exact_cubics_not_anchor_refit(tmp_path: Path) -> None:
    # n=4 chain: cubic bows to y≈117.5 at x=200; a straight anchor polyline
    # (re-fit) would stay on the y=20 chord instead.
    chain = [[20.0, 20.0], [20.0, 150.0], [380.0, 150.0], [380.0, 20.0]]
    doc = _doc(width=400.0, height=300.0, elements=[_node(pts=chain)])
    out = render_thumbnail(doc, tmp_path / "cubic.png")
    img = _open(out)

    bx, by = thumb._map_point((0.0, 0.0, 400.0, 300.0), 192, 200.0, 117.5)
    cx, cy = thumb._map_point((0.0, 0.0, 400.0, 300.0), 192, 200.0, 20.0)
    bow = img.getpixel((round(bx), round(by)))
    chord = img.getpixel((round(cx), round(cy)))
    assert not _near(bow, _WHITE, 30) and not _near(bow, _BG, 30)  # ink at the bow
    assert _near(chord, _WHITE, 30)  # chord clear ⇒ anchors were NOT re-fitted


def test_non_chain_n5_renders_as_polyline(tmp_path: Path) -> None:
    # n=5 ⇒ (5-1)%3 == 1 ⇒ polyline: the y=150 segment must be straight ink.
    zigzag = [[20.0, 20.0], [20.0, 150.0], [380.0, 150.0], [380.0, 20.0], [200.0, 20.0]]
    assert thumb._is_chain(zigzag) is False
    doc = _doc(width=400.0, height=300.0, elements=[_node(pts=zigzag)])
    out = render_thumbnail(doc, tmp_path / "poly.png")
    img = _open(out)

    px, py = thumb._map_point((0.0, 0.0, 400.0, 300.0), 192, 200.0, 150.0)
    probe = img.getpixel((round(px), round(py)))
    assert not _near(probe, _WHITE, 30) and not _near(probe, _BG, 30)  # straight ink


# ---------------------------------------------------------------------------
# Missing / malformed elements degrade safely
# ---------------------------------------------------------------------------
def test_missing_and_malformed_elements_safe(tmp_path: Path) -> None:
    cases = {
        "empty.png": _doc(),
        "empty_inf.png": _doc(infinite=True, bounds={"min_x": 0.0, "min_y": 0.0,
                                                     "max_x": 0.0, "max_y": 0.0}),
        "image.png": _doc(elements=[_node(kind="IMAGE", bbox=(50.0, 50.0, 1450.0, 1450.0),
                                          asset_ref="ghost.png")]),
        "junk.png": _doc(elements=[
            _node(pts=[]),
            _node(pts=[[float("nan"), 1.0]]),
            _node(pts=[[1.0, 2.0], [float("nan"), 3.0]], color="#zzz"),
        ]),
        "shape.png": _doc(elements=[
            _node(kind="SHAPE", pts=[], bbox=(100.0, 100.0, 900.0, 700.0),
                  shape_type="CIRCLE"),
            _node(kind="SHAPE", pts=[[200.0, 2600.0], [800.0, 3100.0], [300.0, 3100.0]],
                  bbox=(200.0, 2600.0, 800.0, 3100.0), shape_type="TRIANGLE"),
            _node(kind="GRAPH_AXES", pts=[], bbox=(200.0, 900.0, 1400.0, 2000.0),
                  shape_type="CARTESIAN_2D"),
        ]),
    }
    for name, doc in cases.items():
        out = render_thumbnail(doc, tmp_path / name)
        assert _png_size(out) == (192, 192), name

    # Missing image asset ⇒ neutral placeholder fill inside its bbox.
    img = _open(tmp_path / "image.png")
    assert _count(img, _PLACEHOLDER, 10) >= 500

    # Doc 03 wire dicts are accepted too (gallery payloads).
    body = DocumentStore.document_to_json(_doc(elements=[
        _node(pts=[[300.0, 400.0], [2000.0, 3000.0]]),
    ]))
    out = render_thumbnail(body, tmp_path / "from_dict.png")
    assert _png_size(out) == (192, 192)
    assert _ink_count(_open(out)) > 40


def test_gallery_row_fallback_dict_still_renders(tmp_path: Path) -> None:
    """The gallery's no-archive fallback row (no created_at/content_bounds)
    must render — A4 shows its paper, INFINITE stays paper-less (§10.6)."""
    a4_row = {
        "id": "c-8", "title": "Row", "preset": "A4", "background": "BLANK",
        "updated_at": 1, "source_devices": [],
        "canvas_id": "c-8", "elements": [],
        "artboard": {"preset": "A4", "background": "BLANK", "is_infinite": False},
    }
    a4_out = render_thumbnail(a4_row, tmp_path / "row_a4.png")
    assert _png_size(a4_out) == (192, 192)
    assert _count(_open(a4_out), _WHITE, 6) > 10_000  # paper backfilled from A4

    inf_row = dict(a4_row, canvas_id="c-9", id="c-9")
    inf_row["artboard"] = {"preset": "INFINITE", "background": "BLANK",
                           "is_infinite": True}
    inf_out = render_thumbnail(inf_row, tmp_path / "row_inf.png")
    assert _png_size(inf_out) == (192, 192)
    assert _count(_open(inf_out), _WHITE, 6) < 200  # no paper on INFINITE


# ---------------------------------------------------------------------------
# A4 vs INFINITE fit
# ---------------------------------------------------------------------------
def test_a4_vs_infinite_rect_fit(tmp_path: Path) -> None:
    bounds = {"min_x": 200.0, "min_y": 200.0, "max_x": 2200.0, "max_y": 3200.0}
    stroke = _node(pts=[[bounds["min_x"], bounds["min_y"]],
                        [1200.0, 1700.0],
                        [bounds["max_x"], bounds["max_y"]]])

    a4_out = render_thumbnail(_doc(bounds=bounds, elements=[stroke]), tmp_path / "a4.png")
    inf_out = render_thumbnail(
        _doc(infinite=True, bounds=bounds, elements=[stroke]), tmp_path / "inf.png"
    )
    assert a4_out.read_bytes() != inf_out.read_bytes()

    a4 = _open(a4_out)
    # A4 paper bbox ≈ the fitted artboard rect (184 px tall, aspect-preserved).
    scale = (192 - 8) / 3508.0
    exp_x0, exp_y0 = (192 - 2480.0 * scale) / 2.0, (192 - 3508.0 * scale) / 2.0
    xs, ys = [], []
    for y in range(192):
        for x in range(192):
            if _near(a4.getpixel((x, y)), _WHITE, 6):
                xs.append(x)
                ys.append(y)
    assert xs and ys
    assert abs(min(xs) - exp_x0) <= 6
    assert abs(min(ys) - exp_y0) <= 6
    assert abs(max(xs) - (exp_x0 + 2480.0 * scale)) <= 6
    assert abs(max(ys) - (exp_y0 + 3508.0 * scale)) <= 6

    inf = _open(inf_out)
    assert _count(inf, _WHITE, 6) < 200  # no paper on an infinite canvas
    assert _ink_count(inf) > 100  # content fitted inside the neutral frame


def test_typical_render_under_budget(tmp_path: Path) -> None:
    elements = [
        _node(pts=[[100.0 + 30.0 * i, 200.0], [1500.0, 400.0 + 40.0 * i]])
        for i in range(60)
    ]
    doc = _doc(elements=elements)
    start = time.perf_counter()
    render_thumbnail(doc, tmp_path / "perf.png")
    elapsed = time.perf_counter() - start
    assert elapsed < 1.5  # contract: <200 ms typical; generous CI headroom
