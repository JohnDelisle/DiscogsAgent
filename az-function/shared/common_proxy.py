import os
import logging
import httpx
import time
import asyncio
import uuid
from typing import Dict, Optional

import azure.functions as func

logger = logging.getLogger("discogs_proxy")

DISCOGS_BASE_URL = "https://api.discogs.com"


def _build_auth_headers() -> Dict[str, str]:
    discogs_token = os.getenv("DISCOGS_TOKEN")
    user_agent = os.getenv("USER_AGENT", "DiscogsAgent/0.1")
    headers = {"User-Agent": user_agent, "Accept": "application/json"}
    if discogs_token:
        headers["Authorization"] = f"Discogs token={discogs_token}"
    return headers


def _client_key_check(req: func.HttpRequest) -> Optional[func.HttpResponse]:
    provided_key = req.headers.get("x-api-key")
    expected_key = os.getenv("X_API_KEY")
    disable_check = os.getenv("DISABLE_CLIENT_KEY_CHECK", "false").lower() == "true"
    provided_key = provided_key.strip() if provided_key else provided_key
    expected_key = expected_key.strip() if expected_key else expected_key
    if not disable_check and not expected_key:
        # Configuration error: we intended to enforce a client key but the env var is absent.
        return func.HttpResponse(status_code=503, mimetype="application/json", body='{"error":"server_misconfigured","reason":"x_api_key_missing"}')
    ref_unresolved = bool(expected_key) and expected_key.startswith("@Microsoft.KeyVault(")
    mismatch = bool(expected_key) and provided_key != expected_key and not ref_unresolved and not disable_check
    if mismatch:
        return func.HttpResponse(status_code=401, mimetype="application/json", body='{"error":"unauthorized","reason":"api_key_mismatch"}')
    return None


async def proxy_request(
    req: func.HttpRequest,
    method: str,
    upstream_path: str,
    allow_retry: Optional[bool] = None,
) -> func.HttpResponse:
    # Optional request debugging (disabled by default).
    debug_req = os.getenv("DEBUG_REQUEST_LOG", "false").lower() == "true"
    def _sanitize_headers(h: Dict[str, str]) -> Dict[str, str]:
        masked = {}
        for k, v in h.items():
            kl = k.lower()
            if kl in ("authorization", "x-api-key", "cookie"):
                masked[k] = "***"
            else:
                masked[k] = v
        return masked

    maybe_res = _client_key_check(req)
    if maybe_res is not None:
        return maybe_res

    discogs_token = os.getenv("DISCOGS_TOKEN")
    if bool(discogs_token) and discogs_token.startswith("@Microsoft.KeyVault("):
        logger.warning("secrets_unresolved", extra={"which": "DISCOGS_TOKEN"})
        return func.HttpResponse(status_code=503, mimetype="application/json", body='{"error":"secrets_unresolved","which":"DISCOGS_TOKEN"}')

    headers = _build_auth_headers()

    # Client-provided correlation IDs and operation hash (if any from caller)
    x_client_trace = req.headers.get("X-Client-Trace-Id") or req.headers.get("x-client-trace-id")
    x_op_hash = (
        req.headers.get("X-Operation-Hash")
        or req.headers.get("x-operation-hash")
        or req.headers.get("X-Action-Operation-Hash")
        or req.headers.get("x-action-operation-hash")
    )
    # OpenAI Action-specific contextual headers (if present)
    openai_conversation_id = req.headers.get("openai-conversation-id")
    openai_ephemeral_user_id = req.headers.get("openai-ephemeral-user-id")
    traceparent = req.headers.get("traceparent")

    if_none_match = req.headers.get("If-None-Match")
    if if_none_match:
        headers["If-None-Match"] = if_none_match

    content_type = req.headers.get("Content-Type")
    if content_type:
        headers["Content-Type"] = content_type

    # Build and normalize query string
    query = dict(req.params) if req.params else {}
    # Support 'query' alias by mapping to Discogs 'q'
    if 'query' in query and 'q' not in query:
        query['q'] = query['query']
        del query['query']
    url = f"{DISCOGS_BASE_URL}{upstream_path}"

    if allow_retry is None:
        allow_retry = method.upper() in ("GET", "HEAD")

    trace_id = str(uuid.uuid4())
    started = time.perf_counter()
    attempt = 0
    try:
        if debug_req:
            try:
                debug_payload = {
                    "method": method.upper(),
                    "upstream_path": upstream_path,
                    "query": dict(query) if query else {},
                    "headers": _sanitize_headers(dict(req.headers) if req.headers else {}),
                }
                # Only include correlation fields if present
                if x_client_trace:
                    debug_payload["x_client_trace_id"] = x_client_trace
                if x_op_hash:
                    debug_payload["x_operation_hash"] = x_op_hash
                if openai_conversation_id:
                    debug_payload["openai_conversation_id"] = openai_conversation_id
                if openai_ephemeral_user_id:
                    debug_payload["openai_ephemeral_user_id"] = openai_ephemeral_user_id
                if traceparent:
                    debug_payload["traceparent"] = traceparent
                logger.info("http_request_debug: " + str(debug_payload).replace("'", '"'))
            except Exception:
                # Never fail the request due to debug logging
                pass
        while True:
            attempt += 1
            try:
                def _do_sync():
                    with httpx.Client(timeout=10) as client:
                        if method.upper() in ("POST", "PUT", "PATCH", "DELETE"):
                            body = req.get_body()
                            return client.request(method.upper(), url, headers=headers, params=query, content=body)
                        else:
                            return client.request(method.upper(), url, headers=headers, params=query)

                resp = await asyncio.to_thread(_do_sync)
                break
            except (httpx.TimeoutException, httpx.RequestError) as rerr:
                if not allow_retry or attempt >= 2:
                    raise
                backoff = 0.25 * attempt
                logger.warning("transient_retry", extra={"path": upstream_path, "attempt": attempt, "backoff_s": backoff, "error_type": type(rerr).__name__})
                await asyncio.sleep(backoff)

        elapsed_ms = (time.perf_counter() - started) * 1000
        status = resp.status_code

        telemetry = {
            "event": "discogs_proxy_call",
            "entity": upstream_path,
            "method": method.upper(),
            "status": status,
            "elapsed_ms": round(elapsed_ms, 2),
            "trace_id": trace_id,
        }
        if x_client_trace:
            telemetry["x_client_trace_id"] = x_client_trace
        if x_op_hash:
            telemetry["x_operation_hash"] = x_op_hash
        if openai_conversation_id:
            telemetry["openai_conversation_id"] = openai_conversation_id
        if openai_ephemeral_user_id:
            telemetry["openai_ephemeral_user_id"] = openai_ephemeral_user_id
        if traceparent:
            telemetry["traceparent"] = traceparent
        logger.info("discogs_proxy: " + str(telemetry).replace("'", '"'))

        hdrs: Dict[str, str] = {}
        for h in [
            "Link",
            "X-Discogs-Ratelimit",
            "X-Discogs-Ratelimit-Used",
            "X-Discogs-Ratelimit-Remaining",
            "X-Discogs-Ratelimit-Reset",
            "ETag",
        ]:
            v = resp.headers.get(h)
            if v:
                hdrs[h] = v
        # Add our correlation id to the response for easy log correlation
        hdrs["X-Trace-Id"] = trace_id
        if x_client_trace:
            hdrs["X-Client-Trace-Id"] = x_client_trace
        if x_op_hash:
            hdrs["X-Operation-Hash"] = x_op_hash

        if status == 304:
            return func.HttpResponse(status_code=304, headers=hdrs)

        if 200 <= status < 300:
            mimetype = resp.headers.get("Content-Type", "application/json").split(";")[0]
            # Optionally rewrite api.discogs.com URLs to our proxy host for better action chaining
            if mimetype == "application/json":
                try:
                    do_rewrite = os.getenv("REWRITE_UPSTREAM_URLS", "true").lower() == "true"
                    if do_rewrite:
                        import json

                        proxy_base = f"https://{req.headers.get('host')}/api"

                        def _rewrite(obj):
                            if isinstance(obj, dict):
                                return {k: _rewrite(v) for k, v in obj.items()}
                            if isinstance(obj, list):
                                return [_rewrite(v) for v in obj]
                            if isinstance(obj, str):
                                if obj.startswith("https://api.discogs.com/"):
                                    return proxy_base + obj[len("https://api.discogs.com"):]
                                if obj.startswith("http://api.discogs.com/"):
                                    return proxy_base + obj[len("http://api.discogs.com"):]
                                return obj
                            return obj

                        data = resp.json()
                        data = _rewrite(data)
                        body_bytes = json.dumps(data, ensure_ascii=False).encode("utf-8")
                        return func.HttpResponse(status_code=status, mimetype=mimetype, body=body_bytes, headers=hdrs)
                except Exception:
                    # If rewrite fails for any reason, fall back to original content
                    pass
            return func.HttpResponse(status_code=status, mimetype=mimetype, body=resp.content, headers=hdrs)
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
        logger.warning("Timeout contacting Discogs", extra={"path": upstream_path})
        debug_errors = os.getenv("DEBUG_ERRORS", "false").lower() == "true"
        msg = f',"detail":"{str(e)}"' if debug_errors else ""
        return func.HttpResponse(status_code=504, mimetype="application/json", body=f'{{"error":"timeout","trace_id":"{trace_id}"{msg}}}')
    except httpx.RequestError as e:
        logger.exception("RequestError contacting Discogs", extra={"path": upstream_path})
        debug_errors = os.getenv("DEBUG_ERRORS", "false").lower() == "true"
        msg = f',"detail":"{str(e)}"' if debug_errors else ""
        return func.HttpResponse(status_code=502, mimetype="application/json", body=f'{{"error":"bad_gateway","trace_id":"{trace_id}"{msg}}}')
    except Exception as e:
        logger.exception("Unexpected error contacting Discogs", extra={"path": upstream_path})
        debug_errors = os.getenv("DEBUG_ERRORS", "false").lower() == "true"
        msg = f',"detail":"{str(e)}"' if debug_errors else ""
        return func.HttpResponse(status_code=500, mimetype="application/json", body=f'{{"error":"internal_error","trace_id":"{trace_id}"{msg}}}')
