import azure.functions as func
from ..shared.common_proxy import proxy_request

async def main(req: func.HttpRequest) -> func.HttpResponse:
    master_id = req.route_params.get("master_id")
    if not master_id or not master_id.isdigit():
        return func.HttpResponse(status_code=400, mimetype="application/json", body='{"error":"master_id must be an integer"}')

    sub = req.route_params.get("sub")
    # Support /masters/{id} and /masters/{id}/versions
    if sub:
        # Only allow 'versions' as sub-path
        if sub.lower() != "versions":
            return func.HttpResponse(status_code=404, mimetype="application/json", body='{"error":"not_found"}')
        upstream_path = f"/masters/{master_id}/versions"
    else:
        upstream_path = f"/masters/{master_id}"

    return await proxy_request(req, "GET", upstream_path)
