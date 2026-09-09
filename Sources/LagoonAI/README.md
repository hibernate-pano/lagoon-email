# LagoonAI — LLM Provider Registry (spec §6.5)

The AI Gateway is the **only** module that talks to an LLM provider. Everything
else asks for a *capability* (`summary`, `classify`, `action_item`,
`bundle_reason`, `draft`) and the gateway routes it.

## Files

| Path | Role |
|------|------|
| `LLMProvider.swift` | `LLMProvider` protocol, `LLMCapability`, `LLMCompletion`, `LLMError` |
| `ProviderRegistry.swift` | loads `config/providers.json`, applies env overrides |
| `ProviderHTTP.swift` | outbound session: proxy from `LAGOON_HTTP_PROXY`, https-only, host allowlist, never follows redirects |
| `Providers/OpenAICompatibleProvider.swift` | OpenAI-compatible `POST {baseURL}{chatPath}` |
| `AIGateway.swift` | capability routing, strict-JSON task prompts, circuit breaker, per-call logging |

## `config/providers.json`

```jsonc
{
  "version": 1,
  "providers": [
    {
      "name": "minimax",
      "baseURL": "https://api.minimax.chat/v1",  // non-secret default
      "apiKeyEnv": "LLM_PROVIDER_PRIMARY_API_KEY", // env var that holds the key
      "model": "MiniMax-M3",
      "priority": 1,
      "capabilities": ["summary", "classify", "action_item", "bundle_reason", "draft"],
      "chatPath": "/chat/completions",             // override for non-OpenAI paths
      "costPer1kPromptUsd": null,
      "costPer1kCompletionUsd": null
    }
  ],
  "routing": { "summary": "minimax", "classify": "minimax", "...": "minimax" }
}
```

**Env overrides** (highest precedence, applied to the provider that `routing.summary`
points at):

- `LLM_PROVIDER_PRIMARY_BASE_URL` → `baseURL`
- `LLM_PROVIDER_PRIMARY_MODEL` → `model`
- `LLM_PROVIDER_PRIMARY_API_KEY` → the key itself
- `LAGOON_PROVIDER_CONFIG` → path to a different config file

A provider with no resolvable API key is skipped. If **no** provider resolves,
`AIGateway.fromEnvironment()` returns `nil`: the server stays heuristic-only for
the Briefing Feed and `GET /api/messages/{id}/summary` returns
`503 {"error":"ai-not-configured"}`.

## Adding a provider

1. Implement `LLMProvider` in `Sources/LagoonAI/Providers/<Vendor>Provider.swift`.
2. Add an entry to `config/providers.json` with `apiKeyEnv` pointing at a new
   env var, and (optionally) route specific capabilities to it.
3. No call-site changes anywhere else.

## Guardrails

- Circuit breaker: 5 consecutive 5xx within 60 s opens the provider for 5 min,
  then a half-open probe.
- One structured log line per call: capability, provider, model, prompt tokens,
  completion tokens, latency, outcome. **Bodies are never logged.**
- `classify` prompts carry headers/snippet/age only — never a message body
  (spec §6.6 rule 5). `summarize` carries the body because that is the task.
- Per-account monthly budget cap is **not implemented** (`ponytail:` ceiling in
  `AIGateway.swift`) — there is no cost-accounting source yet.
