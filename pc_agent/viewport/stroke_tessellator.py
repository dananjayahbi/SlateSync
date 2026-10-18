"""Stroke tessellation & GPU meshes — Doc 07 (Wave 1.B).

Catmull-Rom (tension 0.5) → cubic Bézier → adaptive ~8 px sampling → variable-width
triangle strip ``[x, y, signed_half_width]`` float32 (12-byte stride) with 8-segment
round-cap fans appended on the CPU pass. Consumed by Doc 06's ``GLCanvasHost`` with a
``moderngl`` context handed in — this module never imports Doc 06 (acyclic, Doc 07 §2).
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import TYPE_CHECKING, Sequence

import numpy as np

if TYPE_CHECKING:
    import moderngl

#: Adaptive sampling step in screen pixels (Doc 07 §4: ~8 px per Bézier segment).
STEP_PX = 8.0
#: Catmull-Rom tension τ = 0.5 → cubic control offset τ/3 = 1/6 (Doc 07 §4).
TENSION = 0.5
#: Round end-cap fan segments: 9 rim angles from −90° to +90° + 1 center per cap.
CAP_SEGS = 8
CAP_RIM_VERTS = CAP_SEGS + 1
CAP_CENTER_VERTS = 1
CAP_VERTS_PER_CAP = CAP_RIM_VERTS + CAP_CENTER_VERTS  # 10
CAP_VERTS = 2 * CAP_VERTS_PER_CAP  # both fans: 20 — vertex count = 2·S + 20
#: Smallest half-width (world units) — clamped to keep AA edges non-degenerate.
MIN_HALF_WIDTH = 1e-4
#: Base stroke width mirroring NodeStyle.stroke_width (template §4 data model).
DEFAULT_STROKE_WIDTH = 2.5
#: Interleaved VBO layout: [x, y, half_width] float32, stride 12 bytes (Doc 07 §1).
VERTEX_DTYPE = np.float32
VERTEX_FIELDS = 3

_Point = tuple[float, float]
_Cubic = tuple[_Point, _Point, _Point, _Point]


@dataclass
class TessellatedMesh:
    """Immutable one-shot mesh handle (template §4 freeze — never mutated)."""

    vao: object
    vertex_count: int
    bbox: tuple[float, float, float, float]


def _lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def _dist(a: _Point, b: _Point) -> float:
    return math.hypot(b[0] - a[0], b[1] - a[1])


def catmull_rom_to_bezier(
    p0: _Point, p1: _Point, p2: _Point, p3: _Point
) -> tuple[_Point, _Point]:
    """Control pair for the ``p1 → p2`` segment (tension 0.5, Doc 07 §4).

    ``c1 = p1 + (p2 − p0)·τ/3``; ``c2 = p2 − (p3 − p1)·τ/3`` — together with the
    endpoints they form the cubic ``(p1, c1, c2, p2)``.
    """
    k = TENSION / 3.0
    c1 = (p1[0] + (p2[0] - p0[0]) * k, p1[1] + (p2[1] - p0[1]) * k)
    c2 = (p2[0] - (p3[0] - p1[0]) * k, p2[1] - (p3[1] - p1[1]) * k)
    return c1, c2


def spline_control_points(points: Sequence[_Point]) -> list[_Cubic]:
    """Cubic control tuples for an open polyline; endpoints clamped (Doc 07 §4).

    First/last segments duplicate the terminal points (``p_{-1} = p_0``,
    ``p_n = p_{n-1}``); fewer than two points yields no segments.
    """
    pts = [(float(x), float(y)) for x, y in points]
    n = len(pts)
    if n < 2:
        return []
    segs: list[_Cubic] = []
    for i in range(n - 1):
        p0 = pts[max(i - 1, 0)]
        p1 = pts[i]
        p2 = pts[i + 1]
        p3 = pts[min(i + 2, n - 1)]
        c1, c2 = catmull_rom_to_bezier(p0, p1, p2, p3)
        segs.append((p1, c1, c2, p2))
    return segs


def _de_casteljau(c0: _Point, c1: _Point, c2: _Point, c3: _Point, t: float) -> _Point:
    """Evaluate a cubic Bézier at ``t`` via de Casteljau subdivision."""
    u = 1.0 - t
    a0 = (u * c0[0] + t * c1[0], u * c0[1] + t * c1[1])
    a1 = (u * c1[0] + t * c2[0], u * c1[1] + t * c2[1])
    a2 = (u * c2[0] + t * c3[0], u * c2[1] + t * c3[1])
    b0 = (u * a0[0] + t * a1[0], u * a0[1] + t * a1[1])
    b1 = (u * a1[0] + t * a2[0], u * a1[1] + t * a2[1])
    return (u * b0[0] + t * b1[0], u * b0[1] + t * b1[1])


def sample_segment(
    c0: _Point, c1: _Point, c2: _Point, c3: _Point, step_px: float = 8.0, scale: float = 1.0
) -> list[_Point]:
    """Uniform-t samples of one cubic (Doc 07 §4).

    ``n = max(2, ceil(L · scale / step_px))`` where ``L`` is the control-polygon
    length; returns ``n + 1`` points for ``t = i/n`` including both endpoints.
    """
    length = _dist(c0, c1) + _dist(c1, c2) + _dist(c2, c3)
    n = max(2, math.ceil(length * float(scale) / float(step_px)))
    return [_de_casteljau(c0, c1, c2, c3, i / n) for i in range(n + 1)]


def sample_path(
    points: Sequence[_Point], step_px: float = STEP_PX, scale: float = 1.0
) -> list[_Point]:
    """Sample the whole spline path, deduplicating the shared segment joints."""
    segs = spline_control_points(points)
    if not segs:
        return [(float(x), float(y)) for x, y in points]
    samples: list[_Point] = []
    for seg_index, seg in enumerate(segs):
        chunk = sample_segment(*seg, step_px=step_px, scale=scale)
        start = 1 if seg_index > 0 else 0  # joint already emitted by previous segment
        samples.extend(chunk[start:])
    return samples


def compute_half_widths(
    pressure: Sequence[float], width: float, width_pressure_factor: float
) -> np.ndarray:
    """``hw_i = 0.5 · width · lerp(1, p_i, wpf)`` clamped to ≥ ``MIN_HALF_WIDTH``.

    ``wpf = 0`` ⇒ constant ``0.5·width``; ``wpf = 1`` ⇒ pressure maps linearly
    onto ``0 … width/2`` (Doc 07 §4).
    """
    half = 0.5 * float(width)
    wpf = float(width_pressure_factor)
    values = [max(MIN_HALF_WIDTH, half * _lerp(1.0, float(p), wpf)) for p in pressure]
    return np.asarray(values, dtype=np.float64)


def _tangents(samples: np.ndarray) -> np.ndarray:
    """Central-difference tangents (forward/backward at the ends), unit length."""
    count = len(samples)
    if count == 1:
        return np.array([[1.0, 0.0]], dtype=np.float64)
    raw = np.zeros_like(samples)
    raw[1:-1] = samples[2:] - samples[:-2]
    raw[0] = samples[1] - samples[0]
    raw[-1] = samples[-1] - samples[-2]
    norms = np.linalg.norm(raw, axis=1, keepdims=True)
    fallback = norms < 1e-12
    safe = np.where(fallback, 1.0, norms)
    unit = np.where(fallback, np.array([[1.0, 0.0]]), raw / safe)
    return unit


def build_strip(
    samples: Sequence[_Point], half_widths: Sequence[float]
) -> tuple[np.ndarray, tuple[float, float, float, float]]:
    """Variable-width strip + both round-cap fans in one interleaved array.

    Layout (Doc 07 §4): ``2·S`` strip verts (``p ± n·hw`` with signed ``±hw`` z),
    then start/end caps as ``CAP_VERTS_PER_CAP`` triangle-fan verts each
    (center ``z = 0``, rim ``z = hw·sin θ``) ⇒ ``2·S + 20`` verts total.
    Returns ``(verts, bbox)`` where bbox is the sample bbox expanded by the max
    half-width on every axis.
    """
    if len(samples) == 0:
        raise ValueError("build_strip needs at least one sample")
    hw = np.asarray(half_widths, dtype=np.float64)
    if len(hw) != len(samples):
        raise ValueError("half_widths must match samples 1:1")
    pts = np.asarray(samples, dtype=np.float64)
    count = len(pts)
    verts = np.zeros((2 * count + CAP_VERTS, VERTEX_FIELDS), dtype=VERTEX_DTYPE)

    tangents = _tangents(pts)
    normals = np.stack([-tangents[:, 1], tangents[:, 0]], axis=1)
    offsets = normals * hw[:, None]
    # Strip: even index = +n side (z = +hw), odd index = −n side (z = −hw).
    verts[0 : 2 * count : 2, 0] = pts[:, 0] + offsets[:, 0]
    verts[0 : 2 * count : 2, 1] = pts[:, 1] + offsets[:, 1]
    verts[0 : 2 * count : 2, 2] = hw
    verts[1 : 2 * count : 2, 0] = pts[:, 0] - offsets[:, 0]
    verts[1 : 2 * count : 2, 1] = pts[:, 1] - offsets[:, 1]
    verts[1 : 2 * count : 2, 2] = -hw

    rim_angles = np.linspace(-0.5 * math.pi, 0.5 * math.pi, CAP_RIM_VERTS)
    sin_a = np.sin(rim_angles)
    cos_a = np.cos(rim_angles)

    # Start cap bulges backward (−tangent) around samples[0].
    center = pts[0]
    tangent = tangents[0]
    normal = normals[0]
    hw0 = float(hw[0])
    dirs = -np.outer(cos_a, tangent) + np.outer(sin_a, normal)
    verts[2 * count] = (center[0], center[1], 0.0)
    verts[2 * count + 1 : 2 * count + 1 + CAP_RIM_VERTS, 0] = center[0] + hw0 * dirs[:, 0]
    verts[2 * count + 1 : 2 * count + 1 + CAP_RIM_VERTS, 1] = center[1] + hw0 * dirs[:, 1]
    verts[2 * count + 1 : 2 * count + 1 + CAP_RIM_VERTS, 2] = hw0 * sin_a

    # End cap bulges forward (+tangent) around samples[-1].
    center = pts[-1]
    tangent = tangents[-1]
    normal = normals[-1]
    hwn = float(hw[-1])
    dirs = np.outer(cos_a, tangent) + np.outer(sin_a, normal)
    end = 2 * count + CAP_VERTS_PER_CAP
    verts[end] = (center[0], center[1], 0.0)
    verts[end + 1 : end + 1 + CAP_RIM_VERTS, 0] = center[0] + hwn * dirs[:, 0]
    verts[end + 1 : end + 1 + CAP_RIM_VERTS, 1] = center[1] + hwn * dirs[:, 1]
    verts[end + 1 : end + 1 + CAP_RIM_VERTS, 2] = hwn * sin_a

    max_hw = float(hw.max())
    bbox = (
        float(pts[:, 0].min()) - max_hw,
        float(pts[:, 1].min()) - max_hw,
        float(pts[:, 0].max()) + max_hw,
        float(pts[:, 1].max()) + max_hw,
    )
    return verts, bbox


def tessellate_stroke(
    points: Sequence[_Point],
    pressure: Sequence[float],
    width: float,
    *,
    wpf: float = 0.0,
    scale: float = 1.0,
    step_px: float = STEP_PX,
) -> tuple[np.ndarray, tuple[float, float, float, float]]:
    """Full CPU pipeline: spline → sampling → per-sample pressure → strip + caps.

    Pressure is linearly interpolated per sample from its source segment; a short
    or empty ``pressure`` list is padded with ``1.0`` (full width). A single point
    samples to ``S = 1`` (22 verts). Raises ``ValueError`` for an empty polyline.
    """
    pts = [(float(x), float(y)) for x, y in points]
    if not pts:
        raise ValueError("tessellate_stroke needs at least one point")
    count = len(pts)
    base = [float(p) for p in pressure] if pressure else []
    if len(base) < count:
        base = base + [1.0] * (count - len(base))
    base = base[:count]

    segs = spline_control_points(pts)
    if not segs:
        samples: list[_Point] = [pts[0]]
        sample_pressure = [base[0]]
    else:
        samples = []
        sample_pressure = []
        for seg_index, seg in enumerate(segs):
            chunk = sample_segment(*seg, step_px=step_px, scale=scale)
            denom = len(chunk) - 1
            for local, point in enumerate(chunk):
                if seg_index > 0 and local == 0:
                    continue  # dedup shared joint (sample_path convention)
                t = local / denom
                samples.append(point)
                sample_pressure.append(_lerp(base[seg_index], base[seg_index + 1], t))

    half_widths = compute_half_widths(sample_pressure, width, wpf)
    return build_strip(samples, half_widths)


def _require_program(tessellator: "StrokeTessellator") -> "moderngl.Program":
    program = tessellator.program
    if program is None:
        raise RuntimeError(
            "StrokeTessellator.program is not set — assign "
            "ProgramRegistry.get('stroke') before building meshes (Docs 06/07)"
        )
    return program


class StrokeTessellator:
    """Builds stroke meshes on a handed-in ``moderngl`` context (Doc 07 §4).

    Host-owned knobs (set by Doc 06 on the Tk main thread before building):
    ``scale`` drives the adaptive ~8 px sampling; ``width_pressure_factor`` is the
    ``LiveFrame.f3`` lerp factor. ``program`` must be injected as
    ``ProgramRegistry.get("stroke")`` — VAOs bind the program they will render with.
    """

    def __init__(self, ctx) -> None:
        self._ctx = ctx
        self.program: "moderngl.Program | None" = None
        self.scale: float = 1.0
        self.width_pressure_factor: float = 0.0
        self._live_vbo: "moderngl.Buffer | None" = None
        self._live_vao: "moderngl.VertexArray | None" = None
        self._live_active = False
        self._live_mesh: TessellatedMesh | None = None

    # ------------------------------------------------------------------
    # Frozen public API (template §4)
    # ------------------------------------------------------------------
    def build_stroke(
        self, points: list[tuple[float, float]], pressure: list[float], width: float
    ) -> TessellatedMesh:
        """Immutable committed-stroke upload: one static VBO/VAO (Doc 07 §4)."""
        verts, bbox = tessellate_stroke(
            points, pressure, width, wpf=self.width_pressure_factor, scale=self.scale
        )
        buffer = self._ctx.buffer(verts.tobytes(), dynamic=False)
        vao = self._vertex_array(buffer)
        return TessellatedMesh(vao, int(verts.shape[0]), bbox)

    # ------------------------------------------------------------------
    # Doc-specific dynamic path (Doc 07 §5.7)
    # ------------------------------------------------------------------
    def begin_live(self) -> None:
        """Start a fresh in-flight stroke (dynamic VBO created on first append)."""
        self._live_active = True
        self._live_mesh = None

    def append_live(
        self, points: list[tuple[float, float]], pressure: list[float], width: float
    ) -> TessellatedMesh | None:
        """Rewrite the dynamic VBO with the stroke's full current state.

        ``buffer.orphan()`` + full rewrite each ``LIVE_POINT`` (GL_DYNAMIC_DRAW).
        Auto-begins when no stroke is active; ``None`` for an empty point list.
        """
        if not points:
            return None
        if not self._live_active:
            self.begin_live()
        verts, bbox = tessellate_stroke(
            points, pressure, width, wpf=self.width_pressure_factor, scale=self.scale
        )
        needed = int(verts.nbytes)
        if self._live_vbo is None or needed > self._live_vbo.size:
            self._release_live()
            stride = VERTEX_FIELDS * np.dtype(VERTEX_DTYPE).itemsize
            reserve = max(needed, 2048 * stride)
            self._live_vbo = self._ctx.buffer(reserve=reserve, dynamic=True)
            self._live_vao = self._vertex_array(self._live_vbo)
        else:
            self._live_vbo.orphan()  # GL_DYNAMIC_DRAW storage reuse (Doc 07 §4)
        self._live_vbo.write(verts.tobytes())
        self._live_mesh = TessellatedMesh(self._live_vao, int(verts.shape[0]), bbox)
        return self._live_mesh

    def end_live(self) -> None:
        """Finish the in-flight stroke; its mesh stops rendering (commit replaces it)."""
        self._live_active = False
        self._live_mesh = None

    @property
    def live_mesh(self) -> TessellatedMesh | None:
        """Current in-flight mesh, or ``None`` between strokes."""
        return self._live_mesh if self._live_active else None

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------
    def _vertex_array(self, buffer: "moderngl.Buffer") -> "moderngl.VertexArray":
        return self._ctx.vertex_array(_require_program(self), [(buffer, "3f", "in_vec3")])

    def _release_live(self) -> None:
        for obj in (self._live_vao, self._live_vbo):
            if obj is not None:
                obj.release()
        self._live_vao = None
        self._live_vbo = None
        self._live_mesh = None

    def release(self) -> None:
        """Free GL objects owned by this tessellator (shutdown path, Doc 06 §5.9)."""
        self._release_live()
        self._live_active = False
        self.program = None
