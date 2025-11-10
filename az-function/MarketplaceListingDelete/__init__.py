import azure.functions as func
from ..shared.common_proxy import proxy_request

async def main(req: func.HttpRequest) -> func.HttpResponse:
    listing_id = req.route_params.get("listing_id")
    if not listing_id or not listing_id.isdigit():
        return func.HttpResponse(status_code=400, mimetype="application/json", body='{"error":"listing_id must be an integer"}')
    upstream_path = f"/marketplace/listings/{listing_id}"
    return await proxy_request(req, "DELETE", upstream_path)
