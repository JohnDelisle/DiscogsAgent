import os
import azure.functions as func
from ..shared.common_proxy import proxy_request

async def main(req: func.HttpRequest) -> func.HttpResponse:
    """Proxy price suggestions for a release.
    Discogs requires an authenticated request (user token) for this endpoint.
    We perform a lightweight pre-check to surface clearer messaging when the PAT is missing.
    """
    release_id = req.route_params.get("release_id")
    if not release_id or not release_id.isdigit():
        return func.HttpResponse(status_code=400, mimetype="application/json", body='{"error":"release_id must be an integer"}')

    # If the upstream would 401 due to missing auth token, give a local 401 with descriptive reason.
    discogs_token = os.getenv("DISCOGS_TOKEN")
    if not discogs_token:
        return func.HttpResponse(status_code=401, mimetype="application/json", body='{"error":"unauthorized","reason":"discogs_token_missing"}')
    if discogs_token.startswith("@Microsoft.KeyVault("):
        return func.HttpResponse(status_code=503, mimetype="application/json", body='{"error":"secrets_unresolved","which":"DISCOGS_TOKEN"}')

    upstream_path = f"/marketplace/price_suggestions/{release_id}"
    return await proxy_request(req, "GET", upstream_path)
