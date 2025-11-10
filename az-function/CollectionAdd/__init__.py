import azure.functions as func
from ..shared.common_proxy import proxy_request

async def main(req: func.HttpRequest) -> func.HttpResponse:
    username = req.route_params.get("username")
    folder_id = req.route_params.get("folder_id")
    release_id = req.route_params.get("release_id")
    if not username:
        return func.HttpResponse(status_code=400, mimetype="application/json", body='{"error":"username is required"}')
    if not folder_id or not folder_id.isdigit():
        return func.HttpResponse(status_code=400, mimetype="application/json", body='{"error":"folder_id must be an integer"}')
    if not release_id or not release_id.isdigit():
        return func.HttpResponse(status_code=400, mimetype="application/json", body='{"error":"release_id must be an integer"}')
    upstream_path = f"/users/{username}/collection/folders/{folder_id}/releases/{release_id}"
    return await proxy_request(req, "POST", upstream_path)
