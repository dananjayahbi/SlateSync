"""Tests for the Export Stream Coordinator (Doc 15 §6).

All exporters are FAKE duck-typed doubles injected through the constructor —
``pc_agent.export.tiled_raster_exporter`` / ``vector_pdf_exporter`` (Docs 13/14,
parallel wave) are never imported here.
"""

import base64
import json
import threading
import time
from pathlib import Path
from types import SimpleNamespace
from uuid import UUID, uuid4

import pytest

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import (
    EXPORT_FINISHED,
    EXPORT_PROGRESS,
    EXPORT_STARTED,
    RPC_MESSAGE,
    EventBus,
)
from pc_agent.export.export_coordinator import (
    CHUNK_RAW,
    STAGES,
    ExportCancelled,
    ExportCoordinator,
)

CANVAS = str(uuid4())

# template §3 "RPC envelope" row — exactly 14 actions, incl. EXPORT_FINISHED
ACTIONS_14 = [
    "OPEN_CANVAS", "ADD_STROKE", "ADD_GRAPH", "ADD_SHAPE", "ADD_IMAGE",
    "DELETE_NODE", "UPGRADE_SIZE", "START_EXPORT", "CANCEL_EXPORT",
    "EXPORT_PROGRESS", "EXPORT_FINISHED", "ASSET_START", "ASSET_CHUNK",
    "ASSET_DONE",
]
ENVELOPE_KEYS = {"id", "type", "action", "canvas_id", "payload", "timestamp"}


# --------------------------------------------------------------------------- fakes

class PushSpy:
    """Thread-safe recorder for the injected ``push`` callable."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._entries: list[tuple[float, dict]] = []

    def __call__(self, envelope: dict) -> None:
        with self._lock:
            self._entries.append((time.monotonic(), envelope))

    def entries(self) -> list[tuple[float, dict]]:
        with self._lock:
            return list(self._entries)

    def envelopes(self, type_: str | None = None, action: str | None = None) -> list[dict]:
        return [
            env for _, env in self.entries()
            if (type_ is None or env.get("type") == type_)
            and (action is None or env.get("action") == action)
        ]

    def wait_for(self, type_: str, action: str, job_id: str | None = None,
                 timeout: float = 8.0) -> dict:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for env in self.envelopes(type_, action):
                if job_id is None or env["payload"].get("job_id") == job_id:
                    return env
            time.sleep(0.01)
        raise AssertionError(f"no {type_}/{action} envelope (job_id={job_id}) within {timeout}s")


class Gate:
    """Blocks worker threads until released — exercises the executor bound."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._started = threading.Event()
        self._release = threading.Event()
        self.arrived = 0
        self.max_arrived = 0

    def arrive(self) -> None:
        with self._lock:
            self.arrived += 1
            self.max_arrived = max(self.max_arrived, self.arrived)
            if self.arrived >= 2:
                self._started.set()
        if not self._release.wait(8.0):
            raise RuntimeError("test gate never released")
        with self._lock:
            self.arrived -= 1

    def release(self) -> None:
        self._release.set()

    def wait_started(self, timeout: float = 8.0) -> None:
        assert self._started.wait(timeout), "expected two workers to arrive at the gate"


class FakeRaster:
    """Duck-typed stand-in for Doc 13: ``export(doc, dpi, out_path, progress=None)``."""

    def __init__(self, *, steps: int = 8, delay: float = 0.03, error: Exception | None = None,
                 content: bytes = b"png-bytes", gate: Gate | None = None) -> None:
        self.steps = steps
        self.delay = delay
        self.error = error
        self.content = content
        self.gate = gate
        self.calls: list[dict] = []

    def export(self, doc, dpi, out_path, progress=None):
        self.calls.append({"doc": doc, "dpi": dpi, "out_path": Path(out_path)})
        if self.gate is not None:
            self.gate.arrive()
        if self.error is not None:
            raise self.error
        for i in range(self.steps):
            if progress is not None:
                progress((i + 1) / self.steps)  # may raise ExportCancelled
            time.sleep(self.delay)
        Path(out_path).write_bytes(self.content)
        return Path(out_path)


class FakeVector:
    """Duck-typed stand-in for Doc 14: ``export(doc, out_path, progress=None)``."""

    def __init__(self, *, steps: int = 3, delay: float = 0.02, error: Exception | None = None,
                 content: bytes = b"%PDF-fake") -> None:
        self.steps = steps
        self.delay = delay
        self.error = error
        self.content = content
        self.calls: list[dict] = []

    def export(self, doc, out_path, progress=None):
        self.calls.append({"doc": doc, "out_path": Path(out_path)})
        if self.error is not None:
            raise self.error
        for i in range(self.steps):
            if progress is not None:
                progress((i + 1) / self.steps)
            time.sleep(self.delay)
        Path(out_path).write_bytes(self.content)
        return Path(out_path)


@pytest.fixture
def build(tmp_path: Path):
    """Build coordinators on isolated export dirs; always shut their executors down."""
    created: list[ExportCoordinator] = []

    def _build(raster=None, vector=None):
        bus = EventBus()
        push = PushSpy()
        config = AppConfig(export_dir=tmp_path / "exports")
        coord = ExportCoordinator(bus, config, raster or FakeRaster(),
                                  vector or FakeVector(), push)
        created.append(coord)
        return SimpleNamespace(coord=coord, bus=bus, push=push, raster=raster, vector=vector)

    yield _build
    for coord in created:
        coord._executor.shutdown(wait=True)


def _job(**overrides) -> dict:
    job = {"canvas_id": CANVAS, "format": "PNG", "dpi": 300, "target": "PC"}
    job.update(overrides)
    return job


def _progress_pushes(push: PushSpy, job_id: str) -> list[dict]:
    return [
        env for env in push.envelopes("EXPORT_JOB", "EXPORT_PROGRESS")
        if env["payload"]["job_id"] == job_id
    ]


# --------------------------------------------------------------------------- tests

def test_progress_monotonic_0_to_100(build) -> None:
    h = build(raster=FakeRaster(steps=12, delay=0.06))
    bus_events: dict[str, list[dict]] = {"started": [], "progress": [], "finished": []}
    h.bus.on(EXPORT_STARTED, lambda **kw: bus_events["started"].append(kw))
    h.bus.on(EXPORT_PROGRESS, lambda **kw: bus_events["progress"].append(kw))
    h.bus.on(EXPORT_FINISHED, lambda **kw: bus_events["finished"].append(kw))

    job_id = h.coord.submit(_job())
    finish = h.push.wait_for("EXPORT_JOB", "EXPORT_FINISHED", job_id)

    jobs = [e for e in h.push.envelopes("EXPORT_JOB")
            if e["payload"]["job_id"] == job_id]
    assert jobs[0]["action"] == "START_EXPORT"
    assert jobs[0]["payload"]["percent"] == 0.0
    assert jobs[-1]["action"] == "EXPORT_FINISHED"
    percents = [e["payload"]["percent"] for e in jobs]
    assert all(b >= a for a, b in zip(percents, percents[1:], strict=False))
    assert all(0.0 <= p <= 100.0 for p in percents)
    progress = [e for e in jobs if e["action"] == "EXPORT_PROGRESS"]
    assert progress, "expected streamed progress envelopes"
    assert any(e["payload"]["percent"] == 100.0 for e in progress), "terminal flush missing"
    assert percents[-1] == 100.0

    payload = finish["payload"]
    assert payload["ok"] is True
    assert payload["percent"] == 100.0
    assert payload["stage"] == "DONE"
    assert payload["path"] and Path(payload["path"]).is_file()

    # bus mirrors agree on job_id/percent, in order, with the pushed envelopes
    assert bus_events["started"] == [{"job_id": job_id}]
    assert bus_events["progress"] == [
        {"job_id": e["payload"]["job_id"], "percent": e["payload"]["percent"]}
        for e in progress
    ]
    assert bus_events["finished"] == [{
        "job_id": job_id, "percent": payload["percent"],
        "path": payload["path"], "ok": True,
    }]
    assert job_id not in h.coord._jobs, "registry entry must clear after the terminal emit"


def test_cancel_mid_run_stops_progress_emission(build) -> None:
    assert issubclass(ExportCancelled, Exception)
    h = build(raster=FakeRaster(steps=60, delay=0.02))
    finished_bus: list[dict] = []
    h.bus.on(EXPORT_FINISHED, lambda **kw: finished_bus.append(kw))

    job_id = h.coord.submit(_job())
    h.push.wait_for("EXPORT_JOB", "EXPORT_PROGRESS", job_id)
    h.coord.cancel(job_id)
    count_at_cancel = len(_progress_pushes(h.push, job_id))

    finish = h.push.wait_for("EXPORT_JOB", "EXPORT_FINISHED", job_id)
    assert len(_progress_pushes(h.push, job_id)) == count_at_cancel, \
        "no EXPORT_PROGRESS may be pushed after cancel() returns"
    assert finish["payload"]["ok"] is False
    assert finish["payload"]["reason"] == "cancelled"
    assert finish["payload"]["stage"] == "ERROR"
    assert finished_bus and finished_bus[-1]["ok"] is False
    assert job_id not in h.coord._jobs


@pytest.mark.parametrize(
    ("size", "expected_sizes"),
    [
        (CHUNK_RAW, [CHUNK_RAW]),
        (CHUNK_RAW + 1, [CHUNK_RAW, 1]),
        (0, []),
    ],
    ids=["262144", "262145", "0-byte"],
)
def test_chunk_boundaries(build, tmp_path: Path, size, expected_sizes) -> None:
    h = build()
    path = tmp_path / "artifact.bin"
    path.write_bytes(b"\xab" * size)
    h.coord._push_asset(CANVAS, path, "job-not-in-registry")

    envs = h.push.envelopes("ASSET_UPLOAD")
    expected_actions = ["ASSET_START"] + ["ASSET_CHUNK"] * len(expected_sizes) + ["ASSET_DONE"]
    assert [e["action"] for e in envs] == expected_actions
    assert all(e["canvas_id"] == CANVAS for e in envs)
    for e in envs:
        assert set(e) == ENVELOPE_KEYS

    start = envs[0]["payload"]
    assert set(start) == {"transfer_id", "filename", "total_chunks", "size_bytes"}
    UUID(start["transfer_id"])
    assert start["filename"] == "artifact.bin"
    assert start["size_bytes"] == size
    assert start["total_chunks"] == len(expected_sizes)

    decoded: list[int] = []
    for index, chunk_env in enumerate(envs[1:-1]):
        payload = chunk_env["payload"]
        assert set(payload) == {"transfer_id", "index", "data_b64"}
        assert payload["transfer_id"] == start["transfer_id"]
        assert payload["index"] == index
        raw = base64.b64decode(payload["data_b64"])
        assert len(raw) <= CHUNK_RAW
        decoded.append(len(raw))
    assert decoded == expected_sizes

    done = envs[-1]["payload"]
    assert done == {"transfer_id": start["transfer_id"]}


def test_envelope_schema_matches_doc02(build) -> None:
    spec_path = Path(__file__).resolve().parents[2] / "shared_specs" / "ws_rpc_schema.json"
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    assert spec["envelope"]["action"]["enum"] == ACTIONS_14
    assert len(ACTIONS_14) == 14 and "EXPORT_FINISHED" in ACTIONS_14
    assert spec["envelope"]["required"] == ["id", "type", "action", "canvas_id", "payload",
                                            "timestamp"]

    h = build(raster=FakeRaster(steps=4, delay=0.02))
    job_id = h.coord.submit(_job())
    h.push.wait_for("EXPORT_JOB", "EXPORT_FINISHED", job_id)
    now = int(time.time())

    seen_actions = set()
    for env in h.push.envelopes("EXPORT_JOB"):
        assert set(env) == ENVELOPE_KEYS
        assert env["action"] in ACTIONS_14
        assert env["action"] in {"START_EXPORT", "EXPORT_PROGRESS", "EXPORT_FINISHED"}
        assert env["type"] == "EXPORT_JOB"
        assert UUID(env["id"]).version == 4
        assert UUID(env["canvas_id"]).version == 4
        assert isinstance(env["timestamp"], int) and not isinstance(env["timestamp"], bool)
        assert abs(env["timestamp"] - now) <= 60
        payload = env["payload"]
        assert {"job_id", "percent", "stage"} <= set(payload)
        assert payload["stage"] in STAGES
        assert isinstance(payload["percent"], (int, float))
        assert 0.0 <= payload["percent"] <= 100.0
        if env["action"] == "EXPORT_FINISHED":
            assert isinstance(payload["ok"], bool)
            assert ("reason" in payload) is (payload["ok"] is False)
        seen_actions.add(env["action"])
    assert seen_actions == {"START_EXPORT", "EXPORT_PROGRESS", "EXPORT_FINISHED"}


def test_progress_throttle_respects_10hz(build) -> None:
    h = build(raster=FakeRaster(steps=100, delay=0.005))  # ~0.5 s of rapid callbacks
    job_id = h.coord.submit(_job())
    h.push.wait_for("EXPORT_JOB", "EXPORT_FINISHED", job_id)

    progress = [(t, e) for t, e in h.push.entries()
                if e.get("type") == "EXPORT_JOB" and e["action"] == "EXPORT_PROGRESS"
                and e["payload"]["job_id"] == job_id]
    assert len(progress) >= 2
    # throttle must have dropped callbacks: far fewer pushes than 100 exporter calls
    assert len(progress) < 100
    span = progress[-1][0] - progress[0][0]
    assert len(progress) <= int(span / 0.1) + 3
    for index in range(len(progress) - 1):
        cur_t, cur_env = progress[index + 1]
        prev_t, _ = progress[index]
        if cur_env["payload"]["percent"] < 100.0:  # terminal push may flush early
            assert cur_t - prev_t >= 0.095, "EXPORT_PROGRESS exceeded 10 Hz"


def test_job_registry_transitions(build) -> None:
    h = build(raster=FakeRaster(steps=20, delay=0.05))
    seen_status: dict[str, str | None] = {}
    h.bus.on(EXPORT_FINISHED, lambda **kw: seen_status.setdefault(
        kw["job_id"], h.coord._jobs.get(kw["job_id"], {}).get("status")))

    job_id = h.coord.submit(_job())
    with h.coord._lock:
        entry = dict(h.coord._jobs[job_id])
    assert {"status", "percent", "stage", "out_path", "cancel_flag"} <= set(entry)
    assert entry["status"] in {"queued", "running"}

    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        with h.coord._lock:
            current = h.coord._jobs.get(job_id, {}).get("status")
        if current == "running":
            break
        time.sleep(0.01)
    else:
        pytest.fail("job never reached running status")
    with h.coord._lock:
        running = dict(h.coord._jobs[job_id])
    assert running["stage"] == "EXPORTING"
    assert running["out_path"] is not None
    assert running["cancel_flag"] is False
    assert 0.0 <= running["percent"] <= 100.0

    finish = h.push.wait_for("EXPORT_JOB", "EXPORT_FINISHED", job_id)
    assert finish["payload"]["ok"] is True
    assert seen_status.get(job_id) == "done", "status must be 'done' at the terminal emit"
    assert job_id not in h.coord._jobs


def test_queued_cancel_never_runs(build) -> None:
    gate = Gate()
    raster = FakeRaster(steps=3, delay=0.01, gate=gate)
    h = build(raster=raster)
    try:
        first = h.coord.submit(_job())
        second = h.coord.submit(_job())
        gate.wait_started()  # both executor workers are busy
        third = h.coord.submit(_job())
        with h.coord._lock:
            assert h.coord._jobs[third]["status"] == "queued"
        h.coord.cancel(third)
        with h.coord._lock:
            assert h.coord._jobs[third]["status"] == "cancelled"
            assert h.coord._jobs[third]["cancel_flag"] is True
    finally:
        gate.release()

    for job_id in (first, second, third):
        h.push.wait_for("EXPORT_JOB", "EXPORT_FINISHED", job_id)
    finished = {e["payload"]["job_id"]: e["payload"]
                for e in h.push.envelopes("EXPORT_JOB", "EXPORT_FINISHED")}
    assert finished[first]["ok"] is True
    assert finished[second]["ok"] is True
    assert finished[third]["ok"] is False
    assert finished[third]["reason"] == "cancelled"
    assert len(raster.calls) == 2, "cancelled queued job must never reach the exporter"
    assert not h.coord._jobs


def test_error_surfaces_as_finished_ok_false(build) -> None:
    h = build(raster=FakeRaster(error=ValueError("empty canvas")))
    bus_finished: list[dict] = []
    seen_status: dict[str, str | None] = {}
    h.bus.on(EXPORT_FINISHED, lambda **kw: bus_finished.append(kw))
    h.bus.on(EXPORT_FINISHED, lambda **kw: seen_status.setdefault(
        kw["job_id"], h.coord._jobs.get(kw["job_id"], {}).get("status")))

    job_id = h.coord.submit(_job())
    finish = h.push.wait_for("EXPORT_JOB", "EXPORT_FINISHED", job_id)
    payload = finish["payload"]
    assert payload["ok"] is False
    assert "empty canvas" in payload["reason"]
    assert payload["stage"] == "ERROR"
    assert bus_finished[-1]["ok"] is False
    assert seen_status.get(job_id) == "failed"
    assert job_id not in h.coord._jobs


def test_rpc_start_pdf_uses_loader_and_pushes_to_tablet(build) -> None:
    vector = FakeVector(steps=3, delay=0.02, content=b"%PDF-1.4 fake")
    raster = FakeRaster(error=AssertionError("raster must not be called for PDF"))
    h = build(raster=raster, vector=vector)
    loaded: list[dict] = []

    def loader(payload: dict):
        loaded.append(payload)
        return {"canvas_id": payload.get("canvas_id")}

    h.coord.attach_document_loader(loader)
    h.bus.emit(RPC_MESSAGE, msg={
        "type": "EXPORT_JOB", "action": "START_EXPORT", "canvas_id": CANVAS,
        "payload": {"format": "PDF", "dpi": None, "target": "TABLET"},
    })
    start = h.push.wait_for("EXPORT_JOB", "START_EXPORT")
    job_id = start["payload"]["job_id"]
    assert start["canvas_id"] == CANVAS
    finish = h.push.wait_for("EXPORT_JOB", "EXPORT_FINISHED", job_id)
    assert finish["payload"]["ok"] is True
    assert finish["payload"]["stage"] == "DONE"
    assert finish["payload"]["percent"] == 100.0

    assert raster.calls == []
    assert len(vector.calls) == 1
    assert vector.calls[0]["doc"] == {"canvas_id": CANVAS}
    assert loaded and loaded[0]["format"] == "PDF" and loaded[0]["canvas_id"] == CANVAS
    assert any(e["payload"].get("stage") == "TRANSFERRING"
               for e in _progress_pushes(h.push, job_id))

    assets = h.push.envelopes("ASSET_UPLOAD")
    assert [e["action"] for e in assets] == ["ASSET_START", "ASSET_CHUNK", "ASSET_DONE"]
    transfer_id = assets[0]["payload"]["transfer_id"]
    assert assets[0]["payload"]["filename"] == f"{job_id}.pdf"
    assert assets[0]["payload"]["total_chunks"] == 1
    assert assets[0]["payload"]["size_bytes"] == len(b"%PDF-1.4 fake")
    assert all(e["payload"]["transfer_id"] == transfer_id for e in assets)
    assert base64.b64decode(assets[1]["payload"]["data_b64"]) == b"%PDF-1.4 fake"
    assert finish["payload"]["path"] and Path(finish["payload"]["path"]).is_file()


def test_rpc_cancel_running_job(build) -> None:
    h = build(raster=FakeRaster(steps=50, delay=0.02))
    h.bus.emit(RPC_MESSAGE, msg={
        "type": "EXPORT_JOB", "action": "START_EXPORT", "canvas_id": CANVAS,
        "payload": {"format": "PNG", "dpi": 600, "target": "PC"},
    })
    start = h.push.wait_for("EXPORT_JOB", "START_EXPORT")
    job_id = start["payload"]["job_id"]
    h.push.wait_for("EXPORT_JOB", "EXPORT_PROGRESS", job_id)

    h.bus.emit(RPC_MESSAGE, msg={
        "type": "EXPORT_JOB", "action": "CANCEL_EXPORT", "canvas_id": CANVAS,
        "payload": {"job_id": job_id},
    })
    count_at_cancel = len(_progress_pushes(h.push, job_id))
    finish = h.push.wait_for("EXPORT_JOB", "EXPORT_FINISHED", job_id)
    assert len(_progress_pushes(h.push, job_id)) == count_at_cancel
    assert finish["payload"]["ok"] is False
    assert finish["payload"]["reason"] == "cancelled"


def test_executor_runs_at_most_two_jobs(build) -> None:
    gate = Gate()
    raster = FakeRaster(steps=2, delay=0.01, gate=gate)
    h = build(raster=raster)
    job_ids = [h.coord.submit(_job()) for _ in range(3)]
    try:
        gate.wait_started()
        time.sleep(0.3)
        with gate._lock:
            assert gate.arrived == 2, "third job must stay queued behind ThreadPoolExecutor(2)"
    finally:
        gate.release()
    for job_id in job_ids:
        finish = h.push.wait_for("EXPORT_JOB", "EXPORT_FINISHED", job_id)
        assert finish["payload"]["ok"] is True
    assert gate.max_arrived == 2
