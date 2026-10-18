"""PC network layer (Docs 11/12).

``DiscoveryPairing`` (Doc 12) lives in ``pc_agent.network.discovery_pairing``
and is intentionally not re-exported here: Doc 11's module and package
``__init__`` never import Doc 12 — coupling happens only through the injected
``token_provider`` callable (template §6 write-conflict guard).
"""

from pc_agent.network.ws_stream_server import WsStreamServer

__all__ = ["WsStreamServer"]
