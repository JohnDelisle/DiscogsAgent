import azure.functions as func
from ..shared.common_proxy import proxy_request

async def main(req: func.HttpRequest) -> func.HttpResponse:
    label_id = req.route_params.get("label_id")
    if not label_id or not label_id.isdigit():
        return func.HttpResponse(status_code=400, mimetype="application/json", body='{"error":"label_id must be an integer"}')

    sub = req.route_params.get("sub")
    if sub:
        if sub.lower() == "releases":
            upstream_path = f"/labels/{label_id}/releases"
        elif sub.lower() == "sublabels":
            # Discogs has /labels/{id}/releases and /labels/{id}/sublabels
            upstream_path = f"/labels/{label_id}/sublabels"
        else:
            return func.HttpResponse(status_code=404, mimetype="application/json", body='{"error":"not_found"}')
    else:
        upstream_path = f"/labels/{label_id}"

    return await proxy_request(req, "GET", upstream_path)
