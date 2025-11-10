import logging
from typing import Set

import azure.functions as func

from ..shared.common_proxy import proxy_request

logger = logging.getLogger("database_search")

SUPPORTED_PARAMS: Set[str] = {
    "q","type","title","release_title","credit","artist","anv","label","genre","style",
    "country","year","format","catno","barcode","track","submitter","contributor","page","per_page","sort","sort_order"
}

async def main(req: func.HttpRequest) -> func.HttpResponse:
    # Extract raw query string keys for validation (avoid false negatives due to route params)
    qs = req.url.split("?", 1)[1] if "?" in req.url else ""
    provided_keys = set()
    if qs:
        for pair in qs.split("&"):
            if not pair:
                continue
            key = pair.split("=", 1)[0]
            if key:
                provided_keys.add(key)
    if not provided_keys.intersection(SUPPORTED_PARAMS):
        return func.HttpResponse(status_code=400, mimetype="application/json", body='{"error":"invalid_request","reason":"no_supported_search_params"}')

    # Proxy the validated request using shared logic (includes auth, retries, ETag, headers)
    return await proxy_request(req, "GET", "/database/search")
