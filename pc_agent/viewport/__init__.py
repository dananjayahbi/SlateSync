"""SlateSync OpenGL viewport package (Docs 06/07).

Re-exports the two frozen Wave 1.B surfaces. Importing this package has no side
effects beyond module imports — no GL context, pyglet window, or Tk widget is
created until ``GLCanvasHost.mount`` runs.
"""

from __future__ import annotations

from pc_agent.viewport.gl_canvas_host import GLCanvasHost, ProgramRegistry
from pc_agent.viewport.stroke_tessellator import StrokeTessellator, TessellatedMesh

__all__ = ["GLCanvasHost", "ProgramRegistry", "StrokeTessellator", "TessellatedMesh"]
