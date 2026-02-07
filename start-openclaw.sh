#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox
# This script:
# 1. Restores config from R2 backup if available
# 2. Runs openclaw onboard --non-interactive to configure from env vars
# 3. Patches config for features onboard doesn't cover (channels, gateway auth)
# 4. Starts the gateway

set -e

if pgrep -f "openclaw gateway" > /dev/null 2>&1; then
    echo "OpenClaw gateway is already running, exiting."
    exit 0
fi

CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
BACKUP_DIR="/data/moltbot"

mkdir -p "$CONFIG_DIR"

# ============================================================
# RESTORE FROM R2 BACKUP
# ============================================================

should_restore_from_r2() {
    local R2_SYNC_FILE="$BACKUP_DIR/.last-sync"
    local LOCAL_SYNC_FILE="$CONFIG_DIR/.last-sync"

    if [ ! -f "$R2_SYNC_FILE" ]; then
        echo "No R2 sync timestamp found, skipping restore"
        return 1
    fi

    if [ ! -f "$LOCAL_SYNC_FILE" ]; then
        echo "No local sync timestamp, will restore from R2"
        return 0
    fi

    R2_TIME=$(cat "$R2_SYNC_FILE" 2>/dev/null)
    LOCAL_TIME=$(cat "$LOCAL_SYNC_FILE" 2>/dev/null)

    echo "R2 last sync: $R2_TIME"
    echo "Local last sync: $LOCAL_TIME"

    R2_EPOCH=$(date -d "$R2_TIME" +%s 2>/dev/null || echo "0")
    LOCAL_EPOCH=$(date -d "$LOCAL_TIME" +%s 2>/dev/null || echo "0")

    if [ "$R2_EPOCH" -gt "$LOCAL_EPOCH" ]; then
        echo "R2 backup is newer, will restore"
        return 0
    else
        echo "Local data is newer or same, skipping restore"
        return 1
    fi
}

# Check for backup data in new openclaw/ prefix first, then legacy clawdbot/ prefix
if [ -f "$BACKUP_DIR/openclaw/openclaw.json" ]; then
    if should_restore_from_r2; then
        echo "Restoring from R2 backup at $BACKUP_DIR/openclaw..."
        cp -a "$BACKUP_DIR/openclaw/." "$CONFIG_DIR/"
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored config from R2 backup"
    fi
elif [ -f "$BACKUP_DIR/clawdbot/clawdbot.json" ]; then
    # Legacy backup format — migrate .clawdbot data into .openclaw
    if should_restore_from_r2; then
        echo "Restoring from legacy R2 backup at $BACKUP_DIR/clawdbot..."
        cp -a "$BACKUP_DIR/clawdbot/." "$CONFIG_DIR/"
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        # Rename the config file if it has the old name
        if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ]; then
            mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
        fi
        echo "Restored and migrated config from legacy R2 backup"
    fi
elif [ -f "$BACKUP_DIR/clawdbot.json" ]; then
    # Very old legacy backup format (flat structure)
    if should_restore_from_r2; then
        echo "Restoring from flat legacy R2 backup at $BACKUP_DIR..."
        cp -a "$BACKUP_DIR/." "$CONFIG_DIR/"
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ]; then
            mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
        fi
        echo "Restored and migrated config from flat legacy R2 backup"
    fi
elif [ -d "$BACKUP_DIR" ]; then
    echo "R2 mounted at $BACKUP_DIR but no backup data found yet"
else
    echo "R2 not mounted, starting fresh"
fi

# Restore skills from R2 backup if available (only if R2 is newer)
SKILLS_DIR="/root/clawd/skills"
if [ -d "$BACKUP_DIR/skills" ] && [ "$(ls -A $BACKUP_DIR/skills 2>/dev/null)" ]; then
    if should_restore_from_r2; then
        echo "Restoring skills from $BACKUP_DIR/skills..."
        mkdir -p "$SKILLS_DIR"
        cp -a "$BACKUP_DIR/skills/." "$SKILLS_DIR/"
        echo "Restored skills from R2 backup"
    fi
fi

# ============================================================
# ONBOARD (only if no config exists yet)
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, running openclaw onboard..."

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

    openclaw onboard --non-interactive --accept-risk \
        --mode local \
        $AUTH_ARGS \
        --gateway-port 18789 \
        --gateway-bind lan \
        --skip-channels \
        --skip-skills \
        --skip-health
    
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
fi

# ============================================================
# PATCH CONFIG (channels, gateway auth, trusted proxies)
# ============================================================
# openclaw onboard handles provider/model config, but we need to patch in:
# - Channel config (Telegram, Discord, Slack)
# - Gateway token auth
# - Trusted proxies for sandbox networking
# - Base URL override for legacy AI Gateway path
node << 'EOFPATCH'
const fs = require('fs');

const configPath = '/root/.openclaw/openclaw.json';
let config = {};

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

config.gateway = config.gateway || {};
config.channels = config.channels || {};
config.models = config.models || {};
config.models.providers = config.models.providers || {};

// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

if (process.env.OPENCLAW_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.OPENCLAW_GATEWAY_TOKEN;
}

// Always set allowInsecureAuth explicitly to ensure it matches current env
// This is important when restoring config from R2 that may have had DEV_MODE=true previously
config.gateway.controlUi = config.gateway.controlUi || {};
config.gateway.controlUi.allowInsecureAuth = (process.env.OPENCLAW_DEV_MODE === 'true');

// Legacy AI Gateway base URL override — patch into provider config
// (only needed when using AI_GATEWAY_BASE_URL, not native cloudflare-ai-gateway)
if (process.env.ANTHROPIC_BASE_URL && process.env.ANTHROPIC_API_KEY) {
    const baseUrl = process.env.ANTHROPIC_BASE_URL.replace(/\/+$/, '');
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    config.models.providers.anthropic = config.models.providers.anthropic || {};
    config.models.providers.anthropic.baseUrl = baseUrl;
    config.models.providers.anthropic.apiKey = process.env.ANTHROPIC_API_KEY;
    // Ensure models array exists (required by OpenClaw)
    if (!config.models.providers.anthropic.models) {
        config.models.providers.anthropic.models = [];
    }
}

// If using OpenAI-compatible proxy (AI Gateway), remove incomplete Anthropic provider
// This prevents config validation errors from old/restored configs
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
    
    // Dynamically fetch models from the proxy API
    // We'll do this synchronously using child_process since we're in a startup script
    const { execSync } = require('child_process');
    let fetchedModels = [];
    try {
        const modelsUrl = baseUrl + '/models';
        const result = execSync(
            `curl -s -H "Authorization: Bearer ${proxyApiKey}" "${modelsUrl}"`,
            { encoding: 'utf8', timeout: 10000 }
        );
        const modelsResponse = JSON.parse(result);
        if (modelsResponse.data && Array.isArray(modelsResponse.data)) {
            fetchedModels = modelsResponse.data.map(m => {
                const id = m.id;
                // Determine properties based on model name patterns
                const isThinking = id.includes('thinking');
                const isImage = id.includes('image');
                const isClaude = id.includes('claude');
                const isKimi = id.includes('kimi');
                const isGemini = id.includes('gemini');
                
                // Set context window based on model type
                let contextWindow = 128000; // default
                if (isGemini) contextWindow = 1000000;
                else if (isClaude) contextWindow = 200000;
                else if (isKimi) contextWindow = 128000;
                
                // Generate friendly name from id
                const name = id.split('-').map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(' ')
                    .replace(/(\d)\.(\d)/g, '$1.$2'); // preserve version numbers
                
                return {
                    id,
                    name: m.name || name,
                    contextWindow: m.context_length || contextWindow,
                    reasoning: isThinking,
                    input: isImage ? ['text', 'image'] : ['text']
                };
            });
        }
    } catch (e) {
        // Failed to fetch models, will use fallback
    }
    
    // Use fetched models or fallback to a minimal default
    if (fetchedModels.length > 0) {
        config.models.providers.openai.models = fetchedModels;
    } else {
        // Fallback: minimal model list if API fetch fails
        config.models.providers.openai.models = [
            { id: 'claude-sonnet-4-5-thinking', name: 'Claude Sonnet 4.5 Thinking', contextWindow: 200000, reasoning: true, input: ['text'] },
            { id: 'gemini-2.5-flash', name: 'Gemini 2.5 Flash', contextWindow: 1000000, reasoning: false, input: ['text'] }
        ];
    }
    
    // Set default model - prefer claude-sonnet-4-5-thinking if available, else first model
    const defaultModelId = fetchedModels.find(m => m.id === 'claude-sonnet-4-5-thinking')?.id 
        || fetchedModels.find(m => m.id.includes('sonnet'))?.id
        || fetchedModels[0]?.id 
        || 'claude-sonnet-4-5-thinking';
    config.agents = config.agents || {};
    config.agents.defaults = config.agents.defaults || {};
    config.agents.defaults.model = { primary: 'openai/' + defaultModelId };
}

// Telegram configuration
if (process.env.TELEGRAM_BOT_TOKEN) {
    config.channels.telegram = config.channels.telegram || {};
    config.channels.telegram.botToken = process.env.TELEGRAM_BOT_TOKEN;
    config.channels.telegram.enabled = true;
    const telegramDmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    config.channels.telegram.dmPolicy = telegramDmPolicy;
    if (process.env.TELEGRAM_DM_ALLOW_FROM) {
        config.channels.telegram.allowFrom = process.env.TELEGRAM_DM_ALLOW_FROM.split(',');
    } else if (telegramDmPolicy === 'open') {
        config.channels.telegram.allowFrom = ['*'];
    }
}

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

// Discord configuration
if (process.env.DISCORD_BOT_TOKEN) {
    config.channels.discord = config.channels.discord || {};
    config.channels.discord.token = process.env.DISCORD_BOT_TOKEN;
    config.channels.discord.enabled = true;
    const discordDmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
    config.channels.discord.dm = config.channels.discord.dm || {};
    config.channels.discord.dm.policy = discordDmPolicy;
    if (discordDmPolicy === 'open') {
        config.channels.discord.dm.allowFrom = ['*'];
    }
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = config.channels.slack || {};
    config.channels.slack.botToken = process.env.SLACK_BOT_TOKEN;
    config.channels.slack.appToken = process.env.SLACK_APP_TOKEN;
    config.channels.slack.enabled = true;
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
EOFPATCH

# ============================================================
# START GATEWAY
# ============================================================
echo "Starting OpenClaw Gateway..."
echo "Gateway will be available on port 18789"

rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

echo "Dev mode: ${OPENCLAW_DEV_MODE:-false}"

if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
    exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan --token "$OPENCLAW_GATEWAY_TOKEN"
else
    echo "Starting gateway with device pairing (no token)..."
    exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan
fi
