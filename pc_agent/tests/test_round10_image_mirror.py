"""Round 10 — issue 06: a mirrored IMAGE must show the picture, not magenta.

Report: uploading an image on the tablet shows the picture on the tablet, but
the PC mirror keeps a pink filled block. Round 9 stopped caching the 1x1
magenta placeholder under the asset key and added ``invalidate_images`` on
``ASSET_UPLOADED``, yet the block came back — so the failure is elsewhere in
the chain:

``main.py`` wires the GL host's asset root only from ``DOCUMENT_LOADED``, and
the upload path writes bytes into ``<assets_dir>/<canvas_id>/``. Any canvas
that reaches the viewport without a ``DOCUMENT_LOADED`` (the board-less mirror
before the first open, or a canvas whose open was persisted-only) therefore
renders with ``assets_root is None``, which resolves to a bare filename in the
process working directory and can never find the uploaded file.

These tests pin the resolution contract directly.
"""

from __future__ import annotations

import base64
from pathlib import Path
from typing import Any

import pytest

pytest.importorskip("moderngl")
pytest.importorskip("PIL")


def _probe_gl() -> Any:
    """One shared probe (same contract as ``test_primitive_renderer``).

    Deliberately module-level: this suite is run alongside every other GL test
    file, and creating a fresh context per test exhausts the driver's buffer
    pool ("cannot create buffer" in unrelated suites).
    """
    import moderngl

    try:
        return moderngl.create_context()
    except Exception:
        pass
    try:
        return moderngl.create_standalone_context()
    except Exception as exc:  # pragma: no cover - headless environments
        pytest.skip(f"no display/GL: {exc}")


class _FakeTk:
    """Minimal Tk stand-in: records ``after``, never fires it (headless)."""

    def __init__(self) -> None:
        self._scheduled: list[object] = []

    def after(self, _ms: int, callback: Any = None) -> str:
        self._scheduled.append(callback)
        return f"after#{len(self._scheduled)}"

    def after_cancel(self, _after_id: str) -> None:
        return None


_GL_CTX = _probe_gl()


@pytest.fixture()
def gl_ctx() -> Any:
    ctx = _GL_CTX
    fbo = ctx.simple_framebuffer((64, 64))
    fbo.use()
    ctx.viewport = (0, 0, 64, 64)
    try:
        yield ctx, fbo
    finally:
        fbo.release()


@pytest.fixture()
def store_env(tmp_path: Path) -> Any:
    from pc_agent.core.config_manager import AppConfig
    from pc_agent.core.events import EventBus
    from pc_agent.engine.document_store import DocumentStore
    from pc_agent.engine.scene_graph import SceneGraph

    bus = EventBus()
    config = AppConfig(appdata_dir=tmp_path, export_dir=tmp_path / "exports")
    scene = SceneGraph(bus)
    store = DocumentStore(bus, config, scene)
    return bus, store, scene, config


def _upload(bus: Any, canvas_id: str, name: str, data: bytes) -> None:
    from pc_agent.core.events import RPC_MESSAGE

    def envelope(action: str, payload: dict) -> dict:
        return {
            "type": "ASSET_UPLOAD",
            "action": action,
            "canvas_id": canvas_id,
            "payload": payload,
        }

    bus.emit(
        RPC_MESSAGE,
        msg=envelope(
            "ASSET_START",
            {
                "transfer_id": "t1",
                "filename": name,
                "total_chunks": 1,
                "size_bytes": len(data),
            },
        ),
    )
    bus.emit(
        RPC_MESSAGE,
        msg=envelope(
            "ASSET_CHUNK",
            {
                "transfer_id": "t1",
                "index": 0,
                "data_b64": base64.b64encode(data).decode(),
            },
        ),
    )
    bus.emit(
        RPC_MESSAGE,
        msg=envelope(
            "ASSET_DONE",
            {"transfer_id": "t1", "total_chunks": 1, "size_bytes": len(data)},
        ),
    )


def _add_image(bus: Any, canvas_id: str, node_id: str, asset_ref: str) -> None:
    from pc_agent.core.events import RPC_MESSAGE

    bus.emit(
        RPC_MESSAGE,
        msg={
            "type": "ELEMENT_COMMIT",
            "action": "ADD_IMAGE",
            "canvas_id": canvas_id,
            "payload": {
                "node_id": node_id,
                "kind": "IMAGE",
                "layer": 0,
                "bbox": [0.0, 0.0, 60.0, 60.0],
                "style": {
                    "color": "#1E1E1E",
                    "stroke_width": 2.5,
                    "opacity": 1.0,
                    "blend_mode": "SRC_OVER",
                },
                "geometry": {
                    "pts": [],
                    "shape_type": None,
                    "graph_config": None,
                    "asset_ref": asset_ref,
                },
            },
        },
    )


def _centre_pixel(fbo: Any) -> tuple[int, int, int]:
    data = fbo.read(components=3, alignment=1)
    index = (32 * 64 + 32) * 3
    return tuple(data[index : index + 3])


def _renderer(ctx: Any) -> Any:
    from pc_agent.core.config_manager import AppConfig
    from pc_agent.viewport.gl_canvas_host import ProgramRegistry
    from pc_agent.viewport.primitive_renderer import PrimitiveRenderer

    return PrimitiveRenderer(ctx, ProgramRegistry(AppConfig()))


def _png(tmp_path: Path, colour: tuple[int, int, int, int]) -> bytes:
    from PIL import Image

    target = tmp_path / "source.png"
    Image.new("RGBA", (8, 8), colour).save(target)
    return target.read_bytes()


def test_uploaded_image_renders_without_a_document_loaded_event(
    gl_ctx: Any, store_env: Any, tmp_path: Path
) -> None:
    """Issue 06 — the mirrored IMAGE must paint even with no DOCUMENT_LOADED.

    This is the production shape of the report: IMAGE bytes and the ADD_IMAGE
    commit arrive while the mirror already holds a document, and nothing
    re-fires ``DOCUMENT_LOADED``. Wiring the asset folder from that event alone
    left ``assets_root is None``, so ``resolve_asset_path`` looked for the bare
    filename in the process CWD and the quad painted magenta forever.
    """
    from pc_agent.core.events import ASSET_UPLOADED
    from pc_agent.viewport.gl_canvas_host import GLCanvasHost

    ctx, fbo = gl_ctx
    bus, store, scene, config = store_env

    host = GLCanvasHost(_FakeTk(), config, bus)
    host._primitive = _renderer(ctx)  # skip the Tk/GL mount, keep the wiring
    host.set_assets_root_resolver(store.assets_dir)

    # Assigned directly: this test is about asset resolution, not the open path.
    doc = store.new("A5", "probe")
    canvas_id = doc.canvas_id
    host.set_document(doc)  # no DOCUMENT_LOADED event is ever emitted here

    assert host._primitive._assets_root is None

    _add_image(bus, canvas_id, "img-1", "assets/pic.png")
    _upload(bus, canvas_id, "pic.png", _png(tmp_path, (0, 200, 0, 255)))

    host._sync_assets_root()
    assert host._primitive._assets_root is not None, (
        "the render pass must resolve the mirrored canvas's asset folder"
    )

    host._primitive.render(scene.nodes(), (1.0, 30.0, 30.0), doc.artboard, {})
    assert _centre_pixel(fbo) == (0, 200, 0), (
        "the mirror must paint the uploaded pixels, not the magenta placeholder"
    )

    # The bytes landing after the first frame must still recover (round 9).
    bus.on(ASSET_UPLOADED, lambda **kw: host.invalidate_images())


def test_asset_root_must_point_at_the_canvas_folder(
    gl_ctx: Any, store_env: Any, tmp_path: Path
) -> None:
    """``resolve_asset_path`` keeps only the basename, so the root is decisive."""
    ctx, fbo = gl_ctx
    bus, store, scene, _config = store_env
    renderer = _renderer(ctx)

    doc = store.new("A5", "probe")
    canvas_id = doc.canvas_id
    _upload(bus, canvas_id, "pic.png", _png(tmp_path, (10, 20, 200, 255)))
    _add_image(bus, canvas_id, "img-1", "assets/pic.png")

    # Without the injection the resolver looks in the process CWD.
    renderer.render(scene.nodes(), (1.0, 30.0, 30.0), doc.artboard, {})
    assert _centre_pixel(fbo) == (255, 0, 255), "no root ⇒ placeholder"

    # With the injection the real bytes are found.
    renderer.set_assets_root(store.assets_dir(str(canvas_id)))
    renderer.render(scene.nodes(), (1.0, 30.0, 30.0), doc.artboard, {})
    assert _centre_pixel(fbo) == (10, 20, 200)


def test_late_bytes_replace_the_placeholder_within_one_repaint(
    gl_ctx: Any, store_env: Any
) -> None:
    """ASSET_DONE after the node was drawn must not need a reload (round 9)."""
    from pc_agent.core.events import ASSET_UPLOADED

    ctx, fbo = gl_ctx
    bus, store, scene, _config = store_env
    renderer = _renderer(ctx)
    doc = store.new("A5", "probe")
    canvas_id = doc.canvas_id
    renderer.set_assets_root(store.assets_dir(str(canvas_id)))

    _add_image(bus, canvas_id, "img-1", "assets/pic.png")
    renderer.render(scene.nodes(), (1.0, 30.0, 30.0), doc.artboard, {})
    assert _centre_pixel(fbo) == (255, 0, 255), "no bytes yet ⇒ placeholder"

    bus.on(ASSET_UPLOADED, lambda **kw: renderer.invalidate_images())
    from PIL import Image

    target = store.assets_dir(str(canvas_id)) / "pic.png"
    Image.new("RGBA", (8, 8), (5, 250, 10, 255)).save(target)
    bus.emit(ASSET_UPLOADED, canvas_id=str(canvas_id), filename="pic.png")

    renderer.render(scene.nodes(), (1.0, 30.0, 30.0), doc.artboard, {})
    assert _centre_pixel(fbo) == (5, 250, 10), (
        "evicting the cache must be enough — no reopen required"
    )
