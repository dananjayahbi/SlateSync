"""PC agent GUI shell (Doc 16) — CustomTkinter studio window.

``tray_daemon.py`` (Doc 17) lives beside this module and is imported
explicitly by its consumers; this package init only re-exports Doc 16.
"""

from .canvas_gallery_panel import CanvasGalleryPanel
from .studio_window import StudioWindow

__all__ = ["CanvasGalleryPanel", "StudioWindow"]
