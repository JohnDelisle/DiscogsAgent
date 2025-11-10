"""Shared utilities for Discogs Azure Function proxy.

Currently exposes:
    proxy_request - unified HTTP forwarding with auth, retries, header propagation.

Additional helpers can be added here in the future (e.g., pagination normalization).
"""

from .common_proxy import proxy_request  # re-export for convenience

__all__ = ["proxy_request"]