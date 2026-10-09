#!/usr/bin/env bash
# verify.sh — prove the Claude Desktop gateway is reachable and behaving.
#
# Exercises the same two endpoints Claude Desktop uses:
#   GET  /v1/models    (model discovery / picker)
#   POST /v1/messages  (Anthropic Messages API, streaming + tool use)
#
# Usage: ./verify.sh [model-name]

set -euo pipefail

PORT="${CLAUDE_DESKTOP_PORT:-4002}"
KEY="${CLAUDE_DESKTOP_LITELLM_KEY:-sk-claude-desktop-local}"
MODEL="${1:-claude-opus-5-5}"
BASE="http://127.0.0.1:$PORT"

pass() { printf '\033[32m  ok\033[0m  %s\n' "$*"; }
fail() { printf '\033[31m fail\033[0m  %s\n' "$*"; FAILED=$((FAILED + 1)); }
hdr()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
FAILED=0

hdr "1. proxy health ($BASE/health/liveliness)"
code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/health/liveliness" --max-time 5 || true)"
[[ "$code" == "200" ]] && pass "healthy (HTTP $code)" || { fail "HTTP $code — is the proxy running? try ./start-desktop-proxy.sh start"; exit 1; }

hdr "2. model discovery ($BASE/v1/models)"
body="$(curl -s "$BASE/v1/models" -H "Authorization: Bearer $KEY" --max-time 8 || true)"
echo "    $body"
echo "$body" | grep -q 'claude' \
  && pass "picker will show claude-* model(s)" \
  || fail "no claude/anthropic-named model — Claude Desktop would reject the deployment"

hdr "3. Anthropic Messages API (POST $BASE/v1/messages, model=$MODEL)"
code="$(curl -s -o /tmp/_verify_msg.json -w '%{http_code}' -X POST "$BASE/v1/messages" \
  -H "content-type: application/json" \
  -H "x-api-key: $KEY" \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: ready\"}]}" \
  --max-time 45 || true)"
if [[ "$code" == "200" ]]; then
  pass "HTTP 200"
  head -c 400 /tmp/_verify_msg.json; echo
else
  fail "HTTP $code"
  head -c 600 /tmp/_verify_msg.json; echo
fi

# 4. the shape that used to 400. A plain request passes even when the reasoning
#    routing is broken, so it proves nothing on its own: litellm only diverts to
#    the Responses API (or leaks reasoning_effort) when the request carries
#    thinking={"type":"enabled"}. Cowork/Chat turns omit it; Code turns send it.
#
#    budget_tokens=2048 is load-bearing. litellm buckets the budget into an
#    OpenAI effort label (512/1024 -> "low", 2048 -> "medium", 4096 -> "high")
#    and Token Juice accepts only low/high/none — "medium" is one of the three
#    it 400s on. A smaller budget passes even against a broken config, so this
#    check would silently stop testing anything.
hdr "4. thinking + tools + stream (the shape that used to 400)"
tool='{"name":"Read","description":"Read a file","input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}'
code="$(curl -s -o /tmp/_verify_think.json -w '%{http_code}' -X POST "$BASE/v1/messages?beta=true" \
  -H "content-type: application/json" \
  -H "x-api-key: $KEY" \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":512,\"stream\":true,\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":2048},\"tools\":[$tool],\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
  --max-time 60 || true)"
if [[ "$code" == "200" ]]; then
  pass "HTTP 200"
else
  fail "HTTP $code — reasoning fields are reaching Token Juice"
  head -c 600 /tmp/_verify_think.json; echo
  echo "    Check the traceback URL in /tmp/litellm-desktop.log:"
  echo "      .../v1/responses        -> model must not be declared openai/*"
  echo "      .../v1/chat/completions -> add the reasoning fields to additional_drop_params"
fi

cat <<EOF

$(hdr "Next: point Claude Desktop at this gateway")
  Developer menu -> Configure Third-Party Inference…
    Inference provider : Gateway
    Gateway base URL   : $BASE
    Gateway API key    : $KEY
    Gateway auth scheme: bearer
  Apply, then restart Claude Desktop.
EOF

if (( FAILED )); then
  printf '\033[31m%d check(s) failed.\033[0m\n' "$FAILED" >&2
  exit 1
fi
