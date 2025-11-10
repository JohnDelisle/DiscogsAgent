import azure.functions as func
from ..shared.common_proxy import proxy_request

async def main(req: func.HttpRequest) -> func.HttpResponse:
    username = req.route_params.get("username")
    if not username:
        return func.HttpResponse(status_code=400, mimetype="application/json", body='{"error":"username is required"}')
    upstream_path = f"/users/{username}/wants"
    return await proxy_request(req, "GET", upstream_path)
