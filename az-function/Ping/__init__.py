import azure.functions as func

def main(req: func.HttpRequest) -> func.HttpResponse:
    return func.HttpResponse(status_code=200, mimetype="application/json", body='{"status":"ok"}')
