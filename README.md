# DiscogsAgent

DiscogsAgent provides a chat-first interface (a ChatGPT custom GPT) for common record-collection operations, with an Azure Function App (Python) that acts as a secure proxy to the Discogs API.

Overview
- Custom GPT: chat UI that triggers an action to call the backend proxy for Discogs queries.
- Azure Function (Python): trusted proxy that injects required headers (notably a controlled User-Agent) and keeps Discogs tokens secret.
- Discogs API: https://api.discogs.com

Quickstart (local)
1. Install Azure Functions Core Tools and Python 3.10+.
2. From az-function/:
   - pip install -r requirements.txt
   - copy local.settings.json.example -> local.settings.json and add values
   - func start
3. Example request:
   curl -X POST http://localhost:7071/api/proxy \
     -H "Content-Type: application/json" \
     -H "x-api-key: change-me" \
     -d '{"path":"/database/search","params":{"q":"Nina Simone","per_page":5}}'