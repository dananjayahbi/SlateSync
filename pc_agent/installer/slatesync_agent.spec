# -*- mode: python ; coding: utf-8 -*-
"""SlateSync PC agent onedir bundle (Doc 18, field-by-field).

Run from the repo root: ``pyinstaller pc_agent/installer/slatesync_agent.spec``.
Produces ``dist/SlateSyncAgent/`` — windowless (``console=False``) with shaders,
CustomTkinter assets and native libraries under ``_internal/`` (Doc 18 §4/§6).
"""

import glob
import sys
from os.path import exists
from pathlib import Path

from PyInstaller.utils.hooks import collect_all, collect_data_files

# Doc 18 §5.1: repo root from SPECPATH (= pc_agent/installer) up two levels.
ROOT = Path(SPECPATH).resolve().parents[1]

# --- datas: GLSL shaders (Docs 07/08) ---------------------------------------
# Package-relative dest keeps AppConfig.shader_dir's shape inside the bundle.
shader_dir = ROOT / "pc_agent" / "viewport" / "shaders"
datas = [
    (path, "pc_agent/viewport/shaders")
    for pattern in ("*.vert", "*.geom", "*.frag", "*.glsl")
    for path in sorted(glob.glob(str(shader_dir / pattern)))
]

# --- datas: CustomTkinter themes/assets + runtime icon (only if present) -----
datas += collect_data_files("customtkinter")
icon_path = ROOT / "pc_agent" / "assets" / "slatesync.ico"
if exists(str(icon_path)):
    datas.append((str(icon_path), "pc_agent/assets"))
icon = str(icon_path) if exists(str(icon_path)) else None  # EXE icon= guard

# Issue 05: version resource (FileDescription/ProductName "SlateSync").
version_file = ROOT / "pc_agent" / "installer" / "slatesync_version.txt"
version = str(version_file) if exists(str(version_file)) else None

# --- hiddenimports (Doc 18 §5.5, grouped by consuming doc) ------------------
hiddenimports = [
    "zeroconf",  # Doc 12 — mDNS discovery
    "pystray",  # Doc 17 — system tray
    "qrcode",  # Doc 12 — fallback pairing QR file
    "qrcode.image.pil",
    "PIL.Image",  # Docs 12/16 — QR file + CTkImage
    "PIL.ImageDraw",
    "PIL.ImageTk",
    "websockets.asyncio.client",  # Doc 11 — async WebSocket client stack
    "websockets.legacy.client",
    "websockets.extensions.permessage_deflate",
]

# --- excludes (Doc 18 §5.6) -------------------------------------------------
excludes = ["pytest", "tests", "matplotlib"]

# --- Cairo via pycairo (Doc 18 §5.7): collect_all, then DLL fallback ---------
binaries = []
cairo_datas, cairo_binaries, cairo_hidden = collect_all("pycairo")
datas += cairo_datas
binaries += cairo_binaries
hiddenimports += cairo_hidden
if not cairo_binaries:
    # Fallback: explicit libcairo-2.dll / libgif-7.dll discovery under the
    # venv's Lib/site-packages (finds nothing when pycairo statically links).
    site_packages = Path(sys.prefix) / "Lib" / "site-packages"
    binaries += [
        (str(dll), ".")
        for dll in sorted(site_packages.glob("**/*.dll"))
        if dll.name.startswith(("libcairo", "libgif"))
    ]

# --- Analysis -> PYZ -> EXE -> COLLECT (Doc 18 §4 pipeline) ------------------
a = Analysis(
    # Doc 04 bootstrap (Wave 3.A-finalized). Absolute: PyInstaller joins
    # relative script paths to the spec's directory, not the CWD (build_main).
    scripts=[str(ROOT / "pc_agent" / "main.py")],
    pathex=[str(ROOT)],
    datas=datas,
    hiddenimports=hiddenimports,
    excludes=excludes,
    binaries=binaries,
)
# Doc 18 §5.8-5.10 written for PyInstaller 6.x: PYZ accepts only PYMODULE TOCs
# (api.py asserts), and onedir needs a.scripts + exclude_binaries=True.
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="SlateSyncAgent",
    console=False,  # windowless: no console flash (Doc 18 §5.9)
    icon=icon,  # Issue 05: pc_agent/assets/slatesync.ico (guarded above)
    version=version,  # Issue 05: SlateSync FileDescription/ProductName resource
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    name="SlateSyncAgent",
)
