"""SlateSync PC agent bootstrap (Doc 04).

``--smoke`` proves config + EventBus + shader directory headlessly (no GUI, no GL,
no network) and exits 0. The full branch runs the lifecycle order frozen in
Doc 04 §5 step 7 (wired in Wave 3.A).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Allow `python pc_agent/main.py` as well as `python -m pc_agent.main`.
if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def run_smoke() -> int:
    """Config + bus + shader-dir check; no Tk, no GL, no sockets (Doc 04 §4)."""
    from pc_agent.core.config_manager import ConfigManager
    from pc_agent.core.events import EventBus

    manager = ConfigManager()
    bus = EventBus()
    config = manager.config

    probe: list[object] = []
    bus.on("SMOKE", lambda **payload: probe.append(payload))
    bus.emit("SMOKE", ok=True)
    if probe != [{"ok": True}]:
        print("SMOKE FAIL: EventBus did not deliver the probe payload", file=sys.stderr)
        return 1

    # Shader sources land with Docs 07/08; create the directory when absent so the
    # existence check stays truthful before and after those waves.
    config.shader_dir.mkdir(parents=True, exist_ok=True)
    if not config.shader_dir.is_dir():
        print(f"SMOKE FAIL: shader dir missing: {config.shader_dir}", file=sys.stderr)
        return 1

    print("OK")
    return 0


def run_full() -> int:
    """Full lifecycle (Doc 04 §5 step 7, wired by Wave 3.A).

    Every runtime module stays lazy-imported so ``--smoke`` needs no GUI, GL or
    network (Doc 04 §5). Bus→Tk hops go only through StudioWindow/GLCanvasHost's
    internal marshalling — nothing here touches Tk off the Tk thread.
    """
    import logging
    import threading
    import tkinter as tk

    from pc_agent.core.config_manager import ConfigManager
    from pc_agent.core.events import (
        CANVAS_LIST_UPDATED,
        DOCUMENT_LOADED,
        PAIRING_INFO,
        RPC_MESSAGE,
        EventBus,
    )
    from pc_agent.engine.document_store import CanvasDocument, DocumentStore
    from pc_agent.engine.local_canvas_index import LocalCanvasIndex
    from pc_agent.engine.scene_graph import SceneGraph
    from pc_agent.export.export_coordinator import ExportCoordinator
    from pc_agent.export.tiled_raster_exporter import TiledRasterExporter
    from pc_agent.export.vector_pdf_exporter import VectorPdfExporter
    from pc_agent.gui.studio_window import StudioWindow
    from pc_agent.gui.tray_daemon import TrayDaemon
    from pc_agent.network.canvas_sync import CanvasSyncManager
    from pc_agent.network.discovery_pairing import DiscoveryPairing
    from pc_agent.network.ws_stream_server import WsStreamServer
    from pc_agent.viewport import GLCanvasHost

    logger = logging.getLogger(__name__)

    # --- 1. config + EventBus ------------------------------------------------
    manager = ConfigManager()
    manager.load()  # load-on-init is idempotent; explicit per Doc 04 step 7
    config = manager.config
    logging.basicConfig(level=config.log_level)
    bus = EventBus()

    # PAIRING_INFO is emitted exactly once, inside DiscoveryPairing.start()
    # (Doc 12 §5) — before the GUI exists — so cache it here and replay it
    # after StudioWindow.build() or the QR dialog would wait forever.
    pairing_info: dict = {}
    bus.on(PAIRING_INFO, lambda **info: pairing_info.update(info))

    # --- 2. discovery + ws server -------------------------------------------
    pairing = DiscoveryPairing(bus=bus, config=config)
    pairing.start()

    server = WsStreamServer(
        bus=bus, config=config, token_provider=lambda: pairing.session_token
    )
    server.start()  # daemon thread + own asyncio loop (Doc 11)

    # --- 3. scene graph + document store (both self-subscribe RPC_MESSAGE) ---
    scene_graph = SceneGraph(bus)
    document_store = DocumentStore(bus, config, scene_graph)

    # --- 3a. local canvas index (Doc 02 §9.3): %APPDATA%/SlateSync/canvases
    # (<id>.slatesync + index.json). The index takes the store for ZIP I/O and
    # is attached back so open_payload persist-on-open + autosave row refreshes
    # work. Browsing is local/read-only with 0 devices; sync actions no-op. ----
    local_index = LocalCanvasIndex(document_store, config.appdata_dir / "canvases")
    document_store.attach_index(local_index)

    # --- 3b. canvas sync v2 (Doc 02 §9): per-device state, LWW merge, pull/put,
    # hub list broadcast; pushes go through the exporters' broadcast_json. -----
    canvas_sync = CanvasSyncManager(
        bus=bus,
        config=config,
        push=server.broadcast_json,
        store=document_store,
        index=local_index,
    )

    # --- 4. exports (Doc 15); output files land in config.export_dir --------
    current_doc: dict[str, CanvasDocument | None] = {"doc": None}

    def remember_document(doc=None, **_extra) -> None:
        current_doc["doc"] = doc

    def document_for_export(_payload: dict) -> CanvasDocument:
        """Doc 15 loader: job payload → the open document (single-doc PC)."""
        doc = current_doc["doc"]
        if doc is None:
            raise ValueError("export rejected: no document is open")
        return doc

    bus.on(DOCUMENT_LOADED, remember_document)
    coordinator = ExportCoordinator(
        bus,
        config,
        TiledRasterExporter(config),
        VectorPdfExporter(config),
        push=server.broadcast_json,
    )
    coordinator.attach_document_loader(document_for_export)

    # --- 5. Tk root → StudioWindow → GL host (Doc 16 layout) ----------------
    root = tk.Tk()  # visible at launch (withdrawn=False)
    gl_host = GLCanvasHost(root, config, bus)
    window = StudioWindow(
        config,
        bus,
        gl_host,
        export_submit=coordinator.submit,
        open_request=canvas_sync.request_open,  # File → Open synced canvas…
    )
    window.build(root)  # gridded layout; build() mounts the GL host (Doc 16 §5.4)
    if pairing_info:  # replay the pre-GUI PAIRING_INFO for the window
        bus.emit(PAIRING_INFO, **pairing_info)
    # Round 5: seed the gallery/HUD with the persisted hub store (§9.2) — the
    # manager was built before the GUI, so replay its current merged state.
    bus.emit(
        CANVAS_LIST_UPDATED,
        canvases=canvas_sync.canvases,
        devices=canvas_sync.devices,
    )

    def menu_rpc(envelope: dict) -> None:
        """File→New/Open envelopes (Doc 16 §5.12), routed by payload shape."""
        payload = envelope.get("payload") or {}
        if envelope.get("action") != "OPEN_CANVAS":
            logger.warning("menu RPC ignored: %r", envelope)
        elif payload.get("path"):
            bus.emit(RPC_MESSAGE, msg=envelope)  # Doc 10 opens + emits DOCUMENT_LOADED
        elif payload.get("preset"):
            # New… {preset, title}: Doc 10's RPC path needs payload.path, so seed
            # directly and emit DOCUMENT_LOADED so the GUI + GL host pick it up.
            doc = document_store.new(
                str(payload["preset"]), str(payload.get("title", "Untitled"))
            )
            # Doc 02 §9.4 flow 4 (PC New): persist to hub storage, broadcast the
            # silent CANVAS_PUT + hub list — devices persist WITHOUT switching,
            # only this PC shows the new canvas immediately. Local-file "Open
            # local file…" above stays index-free.
            try:
                local_index.save_document(doc, source="hub")
            except Exception:
                logger.exception("persisting the new canvas to the hub index failed")
            canvas_sync.put_canvas(doc)
            bus.emit(DOCUMENT_LOADED, doc=doc)
        else:
            logger.warning("menu RPC ignored: %r", envelope)

    def zoom_to_fit() -> None:
        """View→Zoom to Fit: frame the scene's content bounds (Doc 16 §5.12)."""
        bounds = scene_graph.content_bounds()  # all zeros when empty
        width = float(bounds["max_x"]) - float(bounds["min_x"])
        height = float(bounds["max_y"]) - float(bounds["min_y"])
        if width <= 0.0 or height <= 0.0 or not gl_host._vp_w or not gl_host._vp_h:
            return  # GLCanvasHost exposes no viewport-size getter (template §4)
        scale = min(gl_host._vp_w / width, gl_host._vp_h / height)
        scale = max(0.05, min(20.0, scale))
        gl_host.set_camera(
            scale,
            (float(bounds["min_x"]) + float(bounds["max_x"])) / 2.0,
            (float(bounds["min_y"]) + float(bounds["max_y"])) / 2.0,
        )
        doc = current_doc["doc"]
        window.update_hud(scale, doc.artboard.preset if doc else "")

    window.bind_actions(
        rpc=menu_rpc, save=document_store.autosave_tick, zoom_to_fit=zoom_to_fit
    )

    # --- 6. tray daemon; 8. graceful teardown (defined first: the tray holds
    # on_quit) ---------------------------------------------------------------
    state = {"torn_down": False}
    teardown_lock = threading.Lock()

    def teardown_tk() -> None:  # Tk thread only (widgets + GL host)
        gl_host.shutdown()
        try:
            document_store.autosave_tick()  # final save of a dirty document
        except Exception:
            logger.exception("final autosave failed")
        try:
            root.destroy()
        except tk.TclError:
            pass  # raced with an earlier destroy

    def teardown() -> None:
        with teardown_lock:
            if state["torn_down"]:
                return
            state["torn_down"] = True
        tray.stop()  # skips its own thread when called from pystray (Doc 17)
        canvas_sync.shutdown()  # symmetric with its constructor subscription
        server.stop()
        pairing.stop()
        if threading.current_thread() is threading.main_thread():
            teardown_tk()  # WM_DELETE_WINDOW / mainloop exit: already on Tk
        else:
            window.after(0, teardown_tk)  # tray-thread quit: marshal (§5.8)

    tray = TrayDaemon(
        on_show=lambda: window.after(0, window.show),
        on_quit=teardown,
    )
    tray.bind_bus(bus)
    tray.start()

    # --- 7. autosave: the single Tk timer (Doc 10 §5) ------------------------
    autosave_ms = int(config.autosave_interval_s * 1000)

    def autosave_tick() -> None:
        if state["torn_down"]:
            return
        try:
            if document_store.autosave_tick():
                # The hub store changed (§9.2): advertise the new updated_at so
                # devices can PULL the fresh copy (§9.4 flow 2).
                canvas_sync.broadcast_hub_list()
        except Exception:
            logger.exception("autosave failed")
        root.after(autosave_ms, autosave_tick)

    root.after(autosave_ms, autosave_tick)
    root.protocol("WM_DELETE_WINDOW", teardown)  # 8. window close → teardown

    try:
        root.mainloop()
    finally:
        teardown()  # idempotent: covers mainloop exit without a close event
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="slatesync-agent",
        description="SlateSync PC agent bootstrap (Doc 04).",
    )
    parser.add_argument(
        "--smoke",
        action="store_true",
        help="headless self-check (config + bus + shader dir); exit 0, no GUI/GL/network",
    )
    args = parser.parse_args(argv)
    if args.smoke:
        return run_smoke()
    return run_full()


if __name__ == "__main__":
    sys.exit(main())
