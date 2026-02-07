# Custom Changes for ProxyPal Integration

This document tracks all custom changes made to the moltworker codebase since commit `8c582a2e95193296a694c43f82930d0a869ff67e`. Use this to reapply changes if the source is overwritten with the official Cloudflare moltworker.

**Last updated:** February 7, 2026 (fixed start-openclaw.sh syntax error)

## Summary

These changes add support for:
- **ProxyPal/OpenAI-compatible proxy** (`AI_GATEWAY_BASE_URL` + `AI_GATEWAY_API_KEY`)
- **Brave web search** (`BRAVE_API_KEY`)
- **Gateway token authentication** for device CLI commands
- **WebSocket close code sanitization** (fixes 1006 → 1011)
- **Config validation fixes** (prevents "expected array" errors)
- **Shell script syntax fix** (removed empty `else` block in start-openclaw.sh)

---

## File Changes

### 1. `src/types.ts`

Add `BRAVE_API_KEY` to the `MoltbotEnv` interface:

```typescript
// Add after SLACK_APP_TOKEN line (around line 32)
BRAVE_API_KEY?: string;
```

---

### 2. `src/gateway/env.ts`

Replace the AI Gateway handling logic. Find and replace the section starting with `// Legacy AI Gateway support`:

**OLD:**
```typescript
  // Legacy AI Gateway support: AI_GATEWAY_BASE_URL + AI_GATEWAY_API_KEY
  // When set, these override direct keys for backward compatibility
  if (env.AI_GATEWAY_API_KEY && env.AI_GATEWAY_BASE_URL) {
    const normalizedBaseUrl = env.AI_GATEWAY_BASE_URL.replace(/\/+$/, '');
    envVars.AI_GATEWAY_BASE_URL = normalizedBaseUrl;
    // Legacy path routes through Anthropic base URL
    envVars.ANTHROPIC_BASE_URL = normalizedBaseUrl;
    envVars.ANTHROPIC_API_KEY = env.AI_GATEWAY_API_KEY;
  } else if (env.ANTHROPIC_BASE_URL) {
    envVars.ANTHROPIC_BASE_URL = env.ANTHROPIC_BASE_URL;
  }
```

**NEW:**
```typescript
  // AI Gateway proxy support: prioritize over direct provider keys
  if (env.AI_GATEWAY_BASE_URL && env.AI_GATEWAY_API_KEY) {
    // Use AI Gateway as OpenAI-compatible proxy, ignore direct provider keys
    const normalizedBaseUrl = env.AI_GATEWAY_BASE_URL.replace(/\/+$/, '');
    envVars.AI_GATEWAY_BASE_URL = normalizedBaseUrl;
    envVars.AI_GATEWAY_API_KEY = env.AI_GATEWAY_API_KEY;
    // Also set OPENAI_* for backwards compatibility
    envVars.OPENAI_BASE_URL = normalizedBaseUrl;
    envVars.OPENAI_API_KEY = env.AI_GATEWAY_API_KEY;
  } else {
    // Direct provider base URLs (only when no gateway configured)
    if (env.ANTHROPIC_BASE_URL) envVars.ANTHROPIC_BASE_URL = env.ANTHROPIC_BASE_URL;
  }
```

Also add BRAVE_API_KEY to the env vars (around line 52, before `return envVars`):
```typescript
  if (env.BRAVE_API_KEY) envVars.BRAVE_API_KEY = env.BRAVE_API_KEY;
```

---

### 3. `src/routes/api.ts`

Add gateway token to all CLI commands. Update these 4 places:

1. **GET /devices** - Add token variable and use in command:
```typescript
adminApi.get('/devices', async (c) => {
  const sandbox = c.get('sandbox');
  const token = c.env.MOLTBOT_GATEWAY_TOKEN;  // ADD THIS LINE
  // ...
  const proc = await sandbox.startProcess(`openclaw devices list --json --url ws://localhost:18789 --token ${token}`);  // ADD --token ${token}
```

2. **POST /devices/:requestId/approve**:
```typescript
adminApi.post('/devices/:requestId/approve', async (c) => {
  const sandbox = c.get('sandbox');
  const requestId = c.req.param('requestId');
  const token = c.env.MOLTBOT_GATEWAY_TOKEN;  // ADD THIS LINE
  // ...
  const proc = await sandbox.startProcess(`openclaw devices approve ${requestId} --url ws://localhost:18789 --token ${token}`);  // ADD --token ${token}
```

3. **POST /devices/approve-all** - Two commands need token:
```typescript
adminApi.post('/devices/approve-all', async (c) => {
  const sandbox = c.get('sandbox');
  const token = c.env.MOLTBOT_GATEWAY_TOKEN;  // ADD THIS LINE
  // ...
  const listProc = await sandbox.startProcess(`openclaw devices list --json --url ws://localhost:18789 --token ${token}`);  // ADD --token ${token}
  // ...
  const approveProc = await sandbox.startProcess(`openclaw devices approve ${device.requestId} --url ws://localhost:18789 --token ${token}`);  // ADD --token ${token}
```

---

### 4. `src/index.ts`

Fix WebSocket close code handling. In the WebSocket proxy section, add sanitization for close code 1006:

**Client close handler** (around line 363):
```typescript
    client.addEventListener('close', (event) => {
      if (debugLogs) {
        console.log('[WS] Client closed:', event.code, event.reason);
      }
      // Sanitize close code: 1006 is reserved for abnormal closure and cannot be sent explicitly
      const closeCode = event.code === 1006 ? 1011 : event.code;
      containerWs.close(closeCode, event.reason);
    });
```

**Container close handler** (around line 371):
```typescript
    containerWs.addEventListener('close', (event) => {
      if (debugLogs) {
        console.log('[WS] Container closed:', event.code, event.reason);
      }
      // Sanitize close code: 1006 is reserved for abnormal closure and cannot be sent explicitly
      const closeCode = event.code === 1006 ? 1011 : event.code;
      // Transform the close reason (truncate to 123 bytes max for WebSocket spec)
      let reason = transformErrorMessage(event.reason, url.host);
      if (reason.length > 123) {
        reason = reason.slice(0, 120) + '...';
      }
      if (debugLogs) {
        console.log('[WS] Transformed close reason:', reason);
      }
      serverWs.close(closeCode, reason);  // USE closeCode instead of event.code
    });
```

---

### 5. `start-openclaw.sh`

This file has the most changes. Key changes:

#### A. Add AI Gateway proxy auth choice in onboard (priority 1):

Find the AUTH_ARGS section in the "if no config exists" block and add AI Gateway as first option:

```bash
AUTH_ARGS=""
if [ -n "$AI_GATEWAY_BASE_URL" ] && [ -n "$AI_GATEWAY_API_KEY" ]; then
    # AI Gateway proxy mode: use as OpenAI-compatible endpoint
    AUTH_ARGS="--auth-choice openai-api-key --openai-api-key $AI_GATEWAY_API_KEY --openai-base-url $AI_GATEWAY_BASE_URL"
elif [ -n "$CLOUDFLARE_AI_GATEWAY_API_KEY" ] && [ -n "$CF_AI_GATEWAY_ACCOUNT_ID" ] && [ -n "$CF_AI_GATEWAY_GATEWAY_ID" ]; then
    AUTH_ARGS="--auth-choice cloudflare-ai-gateway-api-key \
        --cloudflare-ai-gateway-account-id $CF_AI_GATEWAY_ACCOUNT_ID \
        --cloudflare-ai-gateway-gateway-id $CF_AI_GATEWAY_GATEWAY_ID \
        --cloudflare-ai-gateway-api-key $CLOUDFLARE_AI_GATEWAY_API_KEY"
elif [ -n "$ANTHROPIC_API_KEY" ]; then
    AUTH_ARGS="--auth-choice apiKey --anthropic-api-key $ANTHROPIC_API_KEY"
    if [ -n "$ANTHROPIC_BASE_URL" ]; then
        AUTH_ARGS="$AUTH_ARGS --anthropic-base-url $ANTHROPIC_BASE_URL"
    fi
elif [ -n "$OPENAI_API_KEY" ]; then
    AUTH_ARGS="--auth-choice openai-api-key --openai-api-key $OPENAI_API_KEY"
    if [ -n "$OPENAI_BASE_URL" ]; then
        AUTH_ARGS="$AUTH_ARGS --openai-base-url $OPENAI_BASE_URL"
    fi
fi

if [ -z "$AUTH_ARGS" ]; then
    echo "ERROR: No API key configuration found."
    echo "Please set one of:"
    echo "  - AI_GATEWAY_BASE_URL + AI_GATEWAY_API_KEY (for OpenAI-compatible proxy)"
    echo "  - CLOUDFLARE_AI_GATEWAY_API_KEY + CF_AI_GATEWAY_ACCOUNT_ID + CF_AI_GATEWAY_GATEWAY_ID"
    echo "  - ANTHROPIC_API_KEY"
    echo "  - OPENAI_API_KEY"
    exit 1
fi
```

#### B. Add error handling for onboard (after openclaw onboard command):
```bash
ONBOARD_EXIT=$?
if [ $ONBOARD_EXIT -ne 0 ]; then
    echo "ERROR: Onboard failed with exit code $ONBOARD_EXIT"
    exit 1
fi

# Verify onboard created a valid config
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Onboard completed but no config file was created"
    exit 1
fi
```

#### C. Remove the "echo" logs for directories (delete these lines):
```bash
# DELETE THESE LINES:
echo "Config directory: $CONFIG_DIR"
echo "Backup directory: $BACKUP_DIR"
echo "Using existing config"
echo "Onboard completed"
```

#### D. Fix missing models arrays in Node.js config section (inside try block):
```javascript
try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    
    // Check for known validation issues and fix them BEFORE anything else
    if (config.models?.providers) {
        for (const [providerName, providerConfig] of Object.entries(config.models.providers)) {
            if (providerConfig && typeof providerConfig === 'object') {
                // Fix missing models array (causes "expected array, received undefined")
                if (!Array.isArray(providerConfig.models)) {
                    providerConfig.models = [];
                }
            }
        }
        // Write the fix immediately to prevent any race condition
        fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
    }
} catch (e) {
    // Starting with empty config
}
```

#### E. Initialize models.providers:
```javascript
config.gateway = config.gateway || {};
config.channels = config.channels || {};
config.models = config.models || {};
config.models.providers = config.models.providers || {};
```

#### F. Always set allowInsecureAuth explicitly:
```javascript
// Always set allowInsecureAuth explicitly to ensure it matches current env
// This is important when restoring config from R2 that may have had DEV_MODE=true previously
config.gateway.controlUi = config.gateway.controlUi || {};
config.gateway.controlUi.allowInsecureAuth = (process.env.OPENCLAW_DEV_MODE === 'true');
```

#### G. Add ProxyPal/OpenAI proxy configuration (MAIN FEATURE):
```javascript
// If using OpenAI-compatible proxy (AI Gateway), remove incomplete Anthropic provider
// Check for AI_GATEWAY_BASE_URL first (explicit gateway), then fall back to OPENAI_BASE_URL
const proxyBaseUrl = process.env.AI_GATEWAY_BASE_URL || process.env.OPENAI_BASE_URL;
const proxyApiKey = process.env.AI_GATEWAY_API_KEY || process.env.OPENAI_API_KEY;
if (proxyBaseUrl && proxyApiKey) {
    // Clean up any incomplete Anthropic provider that might cause validation errors
    if (config.models?.providers?.anthropic && !config.models.providers.anthropic.models) {
        delete config.models.providers.anthropic;
    }
    
    const baseUrl = proxyBaseUrl.replace(/\/+$/, '');
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    config.models.providers.openai = config.models.providers.openai || {};
    config.models.providers.openai.baseUrl = baseUrl;
    config.models.providers.openai.apiKey = proxyApiKey;
    config.models.providers.openai.api = 'openai-completions';  // Required for custom OpenAI-compatible proxies
    
    // Configure available models for the proxy - ALL ProxyPal models
    // Fetched from: curl https://proxypal-api.stackdeep.dev/v1/models
    config.models.providers.openai.models = [
        { id: 'gemini-2.5-flash-lite', name: 'Gemini 2.5 Flash Lite', contextWindow: 1000000, reasoning: false, input: ['text'] },
        { id: 'gemini-2.5-flash', name: 'Gemini 2.5 Flash', contextWindow: 1000000, reasoning: false, input: ['text'] },
        { id: 'gemini-3-flash-preview', name: 'Gemini 3 Flash', contextWindow: 1000000, reasoning: false, input: ['text'] },
        { id: 'gemini-3-pro-preview', name: 'Gemini 3 Pro', contextWindow: 1000000, reasoning: false, input: ['text'] },
        { id: 'gemini-3-pro-image-preview', name: 'Gemini 3 Pro Image', contextWindow: 1000000, reasoning: false, input: ['text', 'image'] },
        { id: 'gemini-claude-opus-4-5-thinking', name: 'Claude Opus 4.5 Thinking', contextWindow: 1000000, reasoning: true, input: ['text'] },
        { id: 'gemini-claude-sonnet-4-5', name: 'Claude Sonnet 4.5', contextWindow: 1000000, reasoning: false, input: ['text'] },
        { id: 'gemini-claude-sonnet-4-5-thinking', name: 'Claude Sonnet 4.5 Thinking', contextWindow: 1000000, reasoning: true, input: ['text'] },
        { id: 'gpt-oss-120b-medium', name: 'GPT OSS 120B', contextWindow: 1000000, reasoning: false, input: ['text'] },
        { id: 'tab_flash_lite_preview', name: 'Tab Flash Lite', contextWindow: 1000000, reasoning: false, input: ['text'] }
    ];
    
    // Set default model to gemini-claude-sonnet-4-5-thinking
    config.agents = config.agents || {};
    config.agents.defaults = config.agents.defaults || {};
    config.agents.defaults.model = { primary: 'openai/gemini-claude-sonnet-4-5-thinking' };
}
```

#### H. Add Brave web search configuration:
```javascript
// web search via Brave
if (process.env.BRAVE_API_KEY) {
  config.tools = config.tools || {};
  config.tools.web = config.tools.web || {};
  config.tools.web.search = config.tools.web.search || {};
  config.tools.web.search.enabled = true;
  config.tools.web.search.provider = 'brave';
  config.tools.web.search.maxResults = 5;
  config.tools.web.search.timeoutSeconds = 20;
  config.tools.web.search.cacheTtlMinutes = 15;
  config.tools.web.search.apiKey = process.env.BRAVE_API_KEY;
}
```

---

## Environment Variables Required

Set these in Cloudflare Worker secrets:

| Variable | Description |
|----------|-------------|
| `AI_GATEWAY_BASE_URL` | ProxyPal URL: `https://proxypal-api.stackdeep.dev/v1` |
| `AI_GATEWAY_API_KEY` | ProxyPal API key |
| `MOLTBOT_GATEWAY_TOKEN` | Gateway auth token (for device management) |
| `BRAVE_API_KEY` | Optional: Brave Search API key |

---

## How to Reapply Changes

1. Apply TypeScript changes to `src/types.ts`, `src/gateway/env.ts`, `src/routes/api.ts`, `src/index.ts`
2. Apply bash/Node.js changes to `start-openclaw.sh`
3. Run `npm run build && wrangler deploy --yes`

---

## Important Notes

1. **Do NOT use `disableModelDiscovery`** - OpenClaw doesn't recognize this config key
2. **`api: 'openai-completions'`** is required for custom OpenAI-compatible proxies
3. **Models must have** `id`, `name`, `contextWindow`, and optionally `reasoning`, `input`
4. **WebSocket close code 1006** must be sanitized to 1011 (1006 is reserved)
5. **No debug logs** - All console.log and echo debug statements have been removed
6. **Empty `else` blocks are invalid** - Bash syntax error if `else` has no commands

---

## Shell Script Fixes

### `start-openclaw.sh` - Empty else block fix

The onboard section had an empty `else` block which causes a syntax error:

**OLD (broken):**
```bash
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "ERROR: Onboard completed but no config file was created"
        exit 1
    fi
    
else
fi
```

**NEW (fixed):**
```bash
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "ERROR: Onboard completed but no config file was created"
        exit 1
    fi
fi
```
