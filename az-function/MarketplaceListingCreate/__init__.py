import azure.functions as func
import json
from ..shared.common_proxy import proxy_request

REQUIRED_FIELDS = ["release_id", "condition", "price"]

async def main(req: func.HttpRequest) -> func.HttpResponse:
    try:
        data = json.loads(req.get_body() or b"{}")
    except json.JSONDecodeError:
        return func.HttpResponse(status_code=400, mimetype="application/json", body='{"error":"invalid_json"}')
    missing = [f for f in REQUIRED_FIELDS if f not in data]
    if missing:
        return func.HttpResponse(status_code=400, mimetype="application/json", body=f'{{"error":"missing_fields","fields":"{','.join(missing)}"}}')
    # Discogs expects POST to /marketplace/listings
    upstream_path = "/marketplace/listings"
    return await proxy_request(req, "POST", upstream_path)
