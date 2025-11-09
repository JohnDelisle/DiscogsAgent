import os
import logging
import azure.functions as func
import httpx
import time
import hashlib
import asyncio
import uuid

logger = logging.getLogger("database_search")
DISCOGS_BASE_URL = "https://api.discogs.com"

async def main(req: func.HttpRequest) -> func.HttpResponse:
    provided_key = req.headers.get("x-api-key")
    expected_key = os.getenv("X_API_KEY")
    disable_check = os.getenv("DISABLE_CLIENT_KEY_CHECK", "false").lower() == "true"
    provided_key = provided_key.strip() if provided_key else provided_key
    expected_key = expected_key.strip() if expected_key else expected_key
    ref_unresolved = bool(expected_key) and expected_key.startswith("@Microsoft.KeyVault(")
    hash_expected = hashlib.sha256(expected_key.encode()).hexdigest() if expected_key and not ref_unresolved else ""
    hash_provided = hashlib.sha256(provided_key.encode()).hexdigest() if provided_key else ""
    mismatch = bool(expected_key) and provided_key != expected_key and not ref_unresolved and not disable_check
    logger.warning("auth_diag", extra={
        "has_expected": bool(expected_key),
        "has_provided": bool(provided_key),
        "expected_len": len(expected_key) if expected_key else 0,
        "provided_len": len(provided_key) if provided_key else 0,
        "kv_unresolved": ref_unresolved,
        "disable_check": disable_check,
        "mismatch": mismatch,
        "hash_expected_prefix": hash_expected[:12],
        "hash_provided_prefix": hash_provided[:12]
    })
    if mismatch:
        return func.HttpResponse(status_code=401, mimetype="application/json", body='{"error":"unauthorized","reason":"api_key_mismatch"}')

    discogs_token = os.getenv("DISCOGS_TOKEN")
    user_agent = os.getenv("USER_AGENT", "DiscogsAgent/0.1")
    debug_errors = os.getenv("DEBUG_ERRORS", "false").lower() == "true"
    token_unresolved = bool(discogs_token) and discogs_token.startswith("@Microsoft.KeyVault(")
    if token_unresolved:
        logger.warning("secrets_unresolved", extra={"which": "DISCOGS_TOKEN"})
        return func.HttpResponse(status_code=503, mimetype="application/json", body='{"error":"secrets_unresolved","which":"DISCOGS_TOKEN"}')
    headers = {"User-Agent": user_agent, "Accept": "application/json"}
    if discogs_token:
        headers["Authorization"] = f"Discogs token={discogs_token}"

    # Validate at least one search parameter as per Discogs spec
    supported_params = {
        "q","type","title","release_title","credit","artist","anv","label","genre","style",
        "country","year","format","catno","barcode","track","submitter","contributor","page","per_page","sort","sort_order"
    }
    qs = req.url.split("?", 1)[1] if "?" in req.url else ""
    # Simple guard: ensure any provided key intersects supported set
    provided_keys = set()
    if qs:
        for pair in qs.split("&"):
            if not pair:
                continue
            key = pair.split("=", 1)[0]
            if key:
                provided_keys.add(key)
    if not provided_keys.intersection(supported_params):
        return func.HttpResponse(status_code=400, mimetype="application/json", body='{"error":"invalid_request","reason":"no_supported_search_params"}')
    url = f"{DISCOGS_BASE_URL}/database/search" + (f"?{qs}" if qs else "")
    trace_id = str(uuid.uuid4())
    try:
        started = time.perf_counter()
        attempt = 0
        while attempt < 2:
            attempt += 1
            try:
                def _do_sync():
                    with httpx.Client(timeout=15) as client:
                        return client.get(url, headers=headers)
                resp = await asyncio.to_thread(_do_sync)
                break
            except (httpx.TimeoutException, httpx.RequestError) as rerr:
                if attempt >= 2:
                    raise
                backoff = 0.25 * attempt
                logger.warning("transient_retry", extra={"attempt": attempt, "backoff_s": backoff, "error_type": type(rerr).__name__})
                await asyncio.sleep(backoff)
        elapsed_ms = (time.perf_counter() - started) * 1000
        status = resp.status_code
        telemetry = {"event": "discogs_proxy_call", "entity": "search", "status": status, "elapsed_ms": round(elapsed_ms, 2), "trace_id": trace_id}
        # Emit structured JSON directly in message to ease KQL queries
        logger.info("discogs_proxy: " + str(telemetry).replace("'", '"'))
        if 200 <= status < 300:
            # Forward useful headers (pagination + rate limit)
            hdrs = {}
            for h in ["Link","X-Discogs-Ratelimit","X-Discogs-Ratelimit-Used","X-Discogs-Ratelimit-Remaining","X-Discogs-Ratelimit-Reset"]:
                v = resp.headers.get(h)
                if v:
                    hdrs[h] = v
            return func.HttpResponse(status_code=status, mimetype="application/json", body=resp.text, headers=hdrs)
        if status == 404:
            return func.HttpResponse(status_code=404, mimetype="application/json", body=f'{{"error":"not_found","trace_id":"{trace_id}"}}')
        if status == 429:
            rl_reset = resp.headers.get("X-Discogs-Ratelimit-Reset")
            rl_rem = resp.headers.get("X-Discogs-Ratelimit-Remaining")
            rl = resp.headers.get("X-Discogs-Ratelimit")
            body = {"error": "rate_limited", "trace_id": trace_id, "limit": rl, "remaining": rl_rem, "reset": rl_reset}
            return func.HttpResponse(status_code=429, mimetype="application/json", body=str(body).replace("'", '"'))
        if 500 <= status < 600:
            return func.HttpResponse(status_code=502, mimetype="application/json", body=f'{{"error":"upstream_error","upstream_status":{status},"trace_id":"{trace_id}"}}')
        return func.HttpResponse(status_code=status, mimetype="application/json", body=f'{{"error":"unexpected_status","upstream_status":{status},"trace_id":"{trace_id}"}}')
    except httpx.TimeoutException as e:
        logger.warning("Timeout contacting Discogs search")
        msg = f',"detail":"{str(e)}"' if debug_errors else ""
        return func.HttpResponse(status_code=504, mimetype="application/json", body=f'{{"error":"timeout","trace_id":"{trace_id}"{msg}}}')
    except httpx.RequestError as e:
        logger.exception("RequestError contacting Discogs search")
        msg = f',"detail":"{str(e)}"' if debug_errors else ""
        return func.HttpResponse(status_code=502, mimetype="application/json", body=f'{{"error":"bad_gateway","trace_id":"{trace_id}"{msg}}}')
    except Exception as e:
        logger.exception("Unexpected error contacting Discogs search")
        msg = f',"detail":"{str(e)}"' if debug_errors else ""
        return func.HttpResponse(status_code=500, mimetype="application/json", body=f'{{"error":"internal_error","trace_id":"{trace_id}"{msg}}}')
