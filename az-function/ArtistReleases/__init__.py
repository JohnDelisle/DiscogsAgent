import azure.functions as func
from ..shared.common_proxy import proxy_request

async def main(req: func.HttpRequest) -> func.HttpResponse:
    artist_id = req.route_params.get("artist_id")
    if not artist_id or not artist_id.isdigit():
        return func.HttpResponse(status_code=400, mimetype="application/json", body='{"error":"artist_id must be an integer"}')
    upstream_path = f"/artists/{artist_id}/releases"
    return await proxy_request(req, "GET", upstream_path)
