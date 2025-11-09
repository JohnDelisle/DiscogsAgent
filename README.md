# DiscogsAgent

DiscogsAgent provides a chat-first interface (a ChatGPT custom GPT) that calls a trusted backend proxy to interact with the Discogs API. The proxy is an Azure Function App (Python) that forwards requests to Discogs while injecting the required User-Agent header and keeping Discogs credentials secret.

Project objectives
- Build a ChatGPT custom GPT with an Action that calls an HTTP endpoint described by an OpenAPI spec.
- Implement an Azure Function (Python) that acts as a proxy and injects a controlled User-Agent header and Discogs credentials from secure configuration.
- Mirror Discogs API paths in the Function App so callers use the same endpoints (for example, the function exposes GET /artists/{id} and forwards to https://api.discogs.com/artists/{id}).
- Start small: implement GET /artists/{id} (Discogs /artists/{id}) as v1, add an OpenAPI spec, and provision infra with Bicep.
- Personal-first: get it working for a single account, then make it available to others.

Why a proxy?
- Discogs requires both auth (API key / OAuth) and a per-request User-Agent header.
- The proxy ensures every request includes the controlled User-Agent and keeps Discogs tokens out of the client/custom-GPT.

Architecture (high level)
- ChatGPT custom GPT (Action) -> OpenAPI-described endpoint -> Azure Function (Python) proxy -> Discogs API
- Secrets (Discogs token, API keys) live in Function App configuration; local.settings.json is used for local development.

Repo layout
- az-function/: Python Azure Function code for the proxy (initially mirrors Discogs paths like /artists/{id}).
- openapi/: OpenAPI spec describing the Function App endpoints so the custom GPT Action can call them.
- infra/: Bicep templates to provision the Function App and required Azure resources.
- docs/: notes and future tasks.

## Infra (Azure) — deploy with Bicep

This repo includes `infra/main.bicep` to provision the runtime for the proxy:
- Storage account (for Functions runtime)
- Linux Consumption plan and Function App (Python)
- Log Analytics + Application Insights
- Key Vault (stores Discogs token and client API key) with Function MSI access

Defaults:
- location: `canadacentral`
- resource group: `jmd-discogs`
- name prefix: `jmd-discogs` (e.g., `jmd-discogs-func`, `jmd-discogs-kv`)

One-shot deploy (infra + secrets + code)

```powershell
./scripts/deploy.ps1 `
  -SubscriptionId "<subId>" `
  -ResourceGroup "jmd-discogs" `
  -NamePrefix "jmd-discogs" `
  -Location "canadacentral" `
  -DiscogsToken "<your_discogs_token>" `
  -ClientApiKey "<your_client_api_key>"
```

What it does:
- Gets your AAD object id and passes it to Bicep so the template grants you a temporary RBAC role on the Key Vault.
- Provisions/updates all Azure resources via `infra/main.bicep`.
- Sets `DISCOGS-TOKEN` and `X-API-KEY` in Key Vault (with a brief retry loop to allow RBAC propagation).
- Packages and zip-deploys the Azure Functions code with Oryx build enabled.
- Supports optional Flex Consumption plan (set `useFlexConsumption=true`) to future-proof against classic Linux Consumption EOL.

Manual deploy (subscription scope):

```powershell
# Requires Azure CLI logged in and correct subscription selected
az deployment sub create `
  --location canadacentral `
  --template-file infra/main.bicep `
  --parameters rgName=jmd-discogs location=canadacentral namePrefix=jmd-discogs

# Grant yourself RBAC to write secrets, then set them (replace values)
# Option A: Use the helper script
./scripts/set-secrets.ps1 -ResourceGroupName "jmd-discogs" -VaultName "jmd-discogs-kv" -DiscogsToken "<your_discogs_token>" -ClientApiKey "<your_client_api_key>"

# Option B: Do it manually
$user = az ad signed-in-user show --query id -o tsv
$kvId = az keyvault show -n jmd-discogs-kv -g jmd-discogs --query id -o tsv
az role assignment create --role "Key Vault Secrets Officer" --assignee-object-id $user --assignee-principal-type User --scope $kvId
az keyvault secret set --vault-name jmd-discogs-kv --name DISCOGS-TOKEN --value "<your_discogs_token>"
az keyvault secret set --vault-name jmd-discogs-kv --name X-API-KEY --value "<your_client_api_key>"

# Show outputs
az deployment sub show --name $(az deployment sub list --query "[?properties.templateHash!='']|[-1].name" -o tsv) -o jsonc
```

Notes:
- The Function App is created with system-assigned managed identity and Key Vault references for secrets.
- You’ll deploy the Python code separately (zip deploy or CI/CD). Set `WEBSITE_RUN_FROM_PACKAGE` during code deploy.
- For production hardening, consider IP restrictions, VNET integration, and rate limiting.

Key Vault and app settings
- Key Vault is configured for RBAC (no access policies). The template grants the Function's managed identity the "Key Vault Secrets User" role so it can read secrets at runtime.
- App settings use Key Vault references for `DISCOGS_TOKEN` and `X_API_KEY`. Once the secrets exist in the vault, Functions will resolve them automatically—no redeploy needed.

Flex Consumption vs classic Consumption
- Classic Linux Consumption (Y1) is scheduled to reach end of life (EOL) 30 Sep 2028. Flex Consumption (FC1) offers a newer billing/scaling model.
- Switch by passing `useFlexConsumption=true` in deployment parameters (or adding `-UseFlexConsumption` if surfaced in scripts later).
- Current differences: Flex supports more predictable cold start characteristics and longer execution limits; pricing may differ.

Quickstart (local)
1. Install Azure Functions Core Tools and Python 3.10+.
2. From az-function/:
   - pip install -r requirements.txt
   - copy local.settings.json.example -> local.settings.json and add DISC0GS_TOKEN (or API key) and X_API_KEY (client key)
   - func start
3. Example request (local) — note the function exposes the same path shape as Discogs:
   curl -X GET "http://localhost:7071/api/artists/12345" \
     -H "x-api-key: change-me"

Security model
- Client requests must include a minimal client API key (x-api-key).
- The function reads the Discogs token from environment/config and injects:
  - User-Agent: <controlled-agent-string>
  - Authorization or token param as required by Discogs
- The function forwards the response from Discogs back to the caller.

Planned milestones
1. Implement Python Azure Function that proxies GET /artists/{id} to Discogs /artists/{id}.
2. Create OpenAPI spec for that endpoint and test it with the custom GPT Action.
3. Add Bicep templates to provision the Function App and related resources; consider Key Vault / managed identity for production secrets.
4. Expand proxy endpoints (search, releases, etc.) and harden auth/quotas before broader release.

Notes
- Endpoints in this project intentionally mirror Discogs paths so client code and the custom GPT can call familiar endpoints (e.g., /artists/{id}, /database/search).

## Usage examples

All routes are exposed under the default Azure Functions prefix `/api`. Include your client key in the `x-api-key` header.

### Get artist
```powershell
curl "https://<function-host>/api/artists/108713" -H "x-api-key: <client-key>"
```

### Get release
```powershell
curl "https://<function-host>/api/releases/249504" -H "x-api-key: <client-key>"
```

### Database search (simple)
```powershell
curl "https://<function-host>/api/database/search?q=nevermind" -H "x-api-key: <client-key>"
```

### Database search (fields)
```powershell
curl "https://<function-host>/api/database/search?release_title=Disintegration&artist=The%20Cure" -H "x-api-key: <client-key>"
```

If you omit all supported search parameters you’ll receive:
```json
{"error":"invalid_request","reason":"no_supported_search_params"}
```

Supported parameters: `q, type, title, release_title, credit, artist, anv, label, genre, style, country, year, format, catno, barcode, track, submitter, contributor, page, per_page, sort, sort_order`.

### Rate limit and pagination headers
On successful (2xx) responses the proxy forwards Discogs headers:

- `Link`: RFC 5988 pagination; may include `first`, `prev`, `next`, `last`.
- `X-Discogs-Ratelimit`: Total allowed requests in the window.
- `X-Discogs-Ratelimit-Used`: How many requests used.
- `X-Discogs-Ratelimit-Remaining`: Remaining before throttle.
- `X-Discogs-Ratelimit-Reset`: Seconds until the limit window resets.

Example to inspect the `Link` header:
```powershell
curl -I "https://<function-host>/api/database/search?q=nevermind" -H "x-api-key: <client-key>" |
  Select-String -Pattern "^Link:"
```

## Observability and telemetry

Each upstream call logs a JSON payload in the trace message:

```
discogs_proxy: {"event":"discogs_proxy_call","entity":"search","status":200,"elapsed_ms":123.45,"trace_id":"<uuid>"}
```

Transient retries are logged like:

```
transient_retry attempt=1 backoff_s=0.25 error_type=TimeoutException
```

### KQL snippets (Application Insights)

Recent proxy calls:
```kql
traces
| where timestamp > ago(1h)
| where message startswith "discogs_proxy: "
| parse message with "discogs_proxy: " jsonText
| extend data = parse_json(jsonText)
| project timestamp, data.entity, data.status, data.elapsed_ms, data.trace_id
```

Average latency per entity:
```kql
traces
| where timestamp > ago(1h)
| where message startswith "discogs_proxy: "
| parse message with "discogs_proxy: " jsonText
| extend data = parse_json(jsonText)
| summarize avg_latency_ms=avg(todouble(data.elapsed_ms)), calls=count() by entity=tostring(data.entity)
| order by avg_latency_ms desc
```

Rate limit responses (429):
```kql
traces
| where timestamp > ago(24h)
| where message startswith "discogs_proxy: "
| parse message with "discogs_proxy: " jsonText
| extend data = parse_json(jsonText)
| where toint(data.status) == 429
| project timestamp, data.entity, data.status, data.trace_id
```

Retries and timeouts:
```kql
traces
| where timestamp > ago(6h)
| where message contains "transient_retry" or message contains "Timeout contacting Discogs"
| project timestamp, message
```

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| 401 unauthorized | x-api-key mismatch | Ensure client key matches Key Vault `X-API-KEY`. |
| 503 secrets_unresolved | Key Vault reference not resolved yet | Confirm secrets exist; wait 1-2 minutes; restart Function App. |
| 400 invalid_request (search) | No supported query parameters | Add at least one recognized search field (e.g., `q` or `artist`). |
| 502 upstream_error | Discogs returned 5xx | Retry later; check rate limits. |
| 504 timeout | Discogs slow / network issue | Automatic retry happens; investigate persistent latency. |

## Next steps / hardening ideas

- Add caching for common artist/release lookups.
- Enforce client-side throttling before hitting Discogs.
- Add circuit breaker for repeated upstream 5xx.
- Extend OpenAPI coverage and add more endpoints (marketplace, lists).
- Switch to a structured logger that writes JSON fields directly for richer KQL.
