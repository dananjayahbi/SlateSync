"""SlateSync PC engine package — SceneGraph (Doc 09) + DocumentStore (Doc 10).

Re-exports the frozen interface from :mod:`pc_agent.engine.scene_graph` and
:mod:`pc_agent.engine.document_store` (template §4); the runtime import graph
stays one-way (Doc 10 → Doc 09).
"""

from pc_agent.engine.document_store import Artboard, CanvasDocument, DocumentStore
from pc_agent.engine.scene_graph import CanvasNode, NodeGeometry, NodeStyle, SceneGraph

__all__ = [
    "Artboard",
    "CanvasDocument",
    "CanvasNode",
    "DocumentStore",
    "NodeGeometry",
    "NodeStyle",
    "SceneGraph",
]
