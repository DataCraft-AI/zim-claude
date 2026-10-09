# claude-desktop-integration

Run **Claude Desktop** (Cowork / Chat / Code sessions) on Opus 5.5, through the same
LiteLLM proxy idea as `zim-claude` — but wired up the way Claude Desktop actually
supports third-party models.

```
Claude Desktop (Cowork / Chat / Code)
     |  POST /v1/messages   Authorization: Bearer sk-claude-desktop-local
     v
LiteLLM :4002   (litellm-config.desktop.yaml)
     |  OpenAI-style
     v
Token Juice  ->  Opus 5.5
```

This is **separate from the CLI proxy** on `:4000`, so `zim-claude` keeps working
untouched. Own port, own config, own PID file.

## Why an env file is not enough

`~/claude-source/deepseek-claude` (the `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN`
profile) only steers the **Claude Code CLI**. Claude Desktop is a different app: when it
spawns its embedded agent it *blanks* those variables and injects its own credentials, so
exporting them has no effect. Claude Desktop only accepts a custom endpoint through its
**Third-Party Inference → Gateway** setting (or the equivalent managed config).

Claude Desktop also imposes two rules the proxy has to obey:

1. **Model names must look Anthropic-shaped.** Any model whose name lacks `claude` /
   `anthropic` is dropped from the picker:
   *`inferenceModels: "X" is not an Anthropic model and was removed from the list`*.
   So Opus 5.5 is exposed as `claude-opus-5-5` (an Opus-tier name).
2. **Anthropic-only fields must be tolerated.** Cowork/Code send `cache_control`,
   `tool_reference`, beta headers. The upstream is OpenAI-style, so the config sets
   `drop_params: true` to avoid HTTP 400s.
3. **`drop_params` is not enough on its own.** Reasoning fields need
   `additional_drop_params`, and the model must not be declared `openai/*` or litellm
   will route `/v1/messages` through the Responses API. Both are wired into
   `litellm-config.desktop.yaml`; see Troubleshooting for the failure it prevents.

Requirements met by this setup: LiteLLM ≥ v1.100.1 (for `GET /v1/models` discovery *and*
`POST /v1/messages` on `openai/*`-registered models — see the note below) and a gateway
that implements `POST /v1/messages`.

> **LiteLLM ≥ v1.100.1 is a hard floor.** Older litellm only served `/v1/messages` when a
> model's provider was `anthropic`. These models are registered as `openai/*`, so on older
> litellm the route the app uses returns **500** while `/v1/chat/completions` keeps
> working — a proxy that looks healthy and fails every request. zim-claude's `install.sh`
> pins `litellm[proxy]>=1.100.1` for exactly this reason; don't lower it.

## Install

```bash
cd claude-desktop-integration
./install.sh
```

That makes the scripts executable, starts the proxy on `:4002`, and prints the exact
values to paste into Claude Desktop. It does **not** touch `:4000` or your shell config.

**You do not need a global litellm.** This route shares the virtualenv that zim-claude's
top-level `install.sh` builds at `~/.local/share/zim-claude/venv`, and looks for litellm
in the same order that `start-litellm.sh` does (`$LITELLM_BIN` → `PATH` → `~/.local/bin`
→ that venv). Run the top-level `./install.sh` first if you have no litellm at all; this
one will tell you so if it finds none.

### Windows

There is no separate Windows installer here. The repo's `windows\win-install.bat`
installs **both** sides in one pass — the CLI proxy on `:4000` and this Desktop gateway
on `:4002` — and starts them:

```bat
cd windows
win-install.bat
```

Use `-SkipCli` if you want only the `:4002` gateway. The desktop config lands at
`%USERPROFILE%\.local\share\zim-claude\desktop\litellm-config.desktop.yaml`, its log at
`...\logs\desktop.log`, and `start-proxies.ps1 gateway` prints the three values below.
Verify with `windows\verify.ps1`.

**`--managed` is Linux-only.** The no-click managed-settings route writes
`/etc/claude-desktop/managed-settings.json` with sudo, which has no Windows equivalent
here. On Windows, use the in-app dialog described below.

Then, in Claude Desktop:

1. **Help → Troubleshooting → Enable Developer Mode**
2. **Claude menu → Developer → Configure Third-Party Inference…**
3. Connection section:

   | Field | Value |
   |---|---|
   | Inference provider | `Gateway` |
   | Gateway base URL | `http://127.0.0.1:4002` |
   | Gateway API key | `sk-claude-desktop-local` |
   | Gateway auth scheme | `bearer` |

4. **Apply Changes** (older builds: *Apply locally*), then **restart Claude Desktop**.

The picker now lists `claude-opus-5-5`, and every Cowork,
Chat and Code model call goes to LiteLLM → Token Juice → Opus 5.5.

### No-click alternative (managed config)

If you'd rather not click through the UI, install the managed settings file:

```bash
./install.sh --managed          # needs sudo -> /etc/claude-desktop/managed-settings.json
./install.sh --uninstall-managed
```

This is the same content as `managed-settings.json`. A managed profile may make the app
show a *managed configuration* notice — that is expected.

### macOS without a subscription

On macOS the dialog above **cannot succeed without a Claude Code entitlement**, and that
has nothing to do with this gateway. *Apply Changes* runs an OAuth scope-expansion
authorize against `api.anthropic.com` before it saves anything; for an account without the
entitlement that authorize returns `403 permission_error`, so the dialog dies with
"Couldn't load configuration" and never reaches the write. `claude_desktop_config.json`
and `deploymentMode` are not the problem — the save simply never happens.

`/etc/claude-desktop/managed-settings.json` is **Linux-only**. The macOS build instead
reads a *managed plist* from `/Library/Managed Preferences/com.anthropic.claudefordesktop.plist`
(needs root), or a user-owned **config library** under the app's `-3p` profile (does not).

Use the config library — no sudo, no dialog:

```bash
./macos-managed-config.sh              # quit Claude Desktop first
./macos-managed-config.sh --status     # show what is configured
./macos-managed-config.sh --uninstall  # restore the most recent backup
```

Then `open -a Claude`. The app's own log confirms it
(`~/Library/Logs/Claude-3p/main.log`):

```
[custom-3p] Credentials loaded from managed config { provider: 'gateway' }
[custom-3p] 3P mode active { provider: 'gateway' }
[custom-3p] inference apiHost=http://127.0.0.1:4002
[custom-3p] Model discovery: 1 found in 115ms; picker = 1 (discovery)
```

**What it writes.** Two things, both under `~/Library/Application Support/Claude-3p/`:

| File | Change |
|---|---|
| `configLibrary/<uuid>.json` | the gateway config (base URL, key, bearer, `static` credential) |
| `configLibrary/_meta.json` | `appliedId` pointing at that entry |
| `claude_desktop_config.json` | `deploymentMode` → `"3p"` |

It backs all three up under `~/.local/share/zim-claude/backups/` first. `--uninstall`
restores them.

**The key spellings are not interchangeable.** The local config library validates
*flatKeys*; the managed plist reader matches *enum names*. They agree for the inference
keys but diverge for the sign-in toggle:

| Setting | local config library | managed plist |
|---|---|---|
| disable Claude.ai sign-in | `disableDeploymentModeChooser` | `disableClaudeAiSignIn` |

Use the wrong one and the app logs
`Ignoring local configuration value "…": not a recognized configuration key` and ignores
it. (The keys are ignored, not fatal — 3p mode still activates from `deploymentMode`.)

**Why not the env escape hatch.** The asar exposes `CLAUDE_E2E_MANAGED_PLIST`, but it is
gated: the app only honours environment variables when
`globalThis.isDeveloperApprovedE2eTestHooksEnabled` is set, and the sole caller sets it to
`GZ()`, which verifies an **ed25519 signature** against a pinned public key with a 5-minute
expiry. Unforgeable by design. Debug/override argv switches are likewise refused at startup.

**Does this need a subscription?** No. Third-party mode replaces the subscription path
entirely; the gateway key is what authenticates, and the upstream credential stays in
`litellm-config.desktop.yaml`. The `403`s above are what you hit when you go *through* the
subscription dialog — this route skips it.

## Manage the proxy

```bash
./start-desktop-proxy.sh start     # bring it up
./start-desktop-proxy.sh status
./start-desktop-proxy.sh gateway   # print the 3 values for the UI
./start-desktop-proxy.sh logs      # tail /tmp/litellm-desktop.log
./start-desktop-proxy.sh restart
./start-desktop-proxy.sh stop
```

## Verify

```bash
./verify.sh
```

Checks the health endpoint, `GET /v1/models` (that a `claude*` model is discoverable),
and a real `POST /v1/messages` round-trip.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `CLAUDE_DESKTOP_PORT` | `4002` | proxy port |
| `CLAUDE_DESKTOP_LITELLM_KEY` | `sk-claude-desktop-local` | gateway key (bearer) |
| `CLAUDE_DESKTOP_CONFIG` | `./litellm-config.desktop.yaml` | proxy config |
| `CLAUDE_DESKTOP_LOG` | `/tmp/litellm-desktop.log` | log file |
| `LITELLM_ENV_FILE` | `~/claude-source/deepseek-claude` | profile with the upstream token |

Use a different upstream profile:

```bash
LITELLM_ENV_FILE=~/claude-source/some-other-model ./start-desktop-proxy.sh restart
```

## Files

| File | Purpose |
|---|---|
| `litellm-config.desktop.yaml` | LiteLLM config: claude-named aliases, `drop_params`, master key |
| `start-desktop-proxy.sh` | start/stop/status/logs for the `:4002` proxy |
| `managed-settings.json` | Third-Party Inference config (flat gateway form) |
| `macos-managed-config.sh` | macOS: write the user-owned config library (no sudo, no dialog) |
| `install.sh` | glue: checks, permissions, optional managed settings, start, instructions |
| `verify.sh` | endpoint + model-name checks |

## Caveats

- **Enabling third-party inference signs the app out of your Claude.ai subscription
  path.** Model calls go to your gateway instead. Switch the provider back to default to
  revert.
- **Desktop sends the gateway key, not an Anthropic OAuth token.** That's fine here: the
  upstream credential lives in `litellm-config.desktop.yaml` (via `ANTHROPIC_AUTH_TOKEN`
  from the profile), so LiteLLM reaches Token Juice on its own.
- **Anthropic-only capabilities won't apply** — 1M context, prompt-cache reuse and some
  beta headers depend on an Anthropic upstream; Opus 5.5 won't honor them.
- **Extended thinking is stripped, not forwarded.** Token Juice rejects both
  `reasoning_effort` and `reasoning`, so the config drops them (see Troubleshooting).
  The app still receives `thinking` content blocks, but they are not real reasoning
  tokens — budget them as if thinking were off.
- Same token as `zim-claude`; rotate at Token Juice if it leaks, then restart both
  proxies.

## Troubleshooting

- **Picker is empty / model missing.** Confirm `./verify.sh` shows a `claude*` id from
  `/v1/models`. A non-claude name is silently dropped by the app.
- **Requests fail with 400.** The upstream rejected Anthropic-only fields — ensure
  `drop_params: true` is on the model entry (it is by default here).
- **`400 ... OpenAIException - {"message":"Invalid request"}`, recurring on Code
  sessions.** Two different upstream rejections share that opaque body; check the
  traceback's URL to tell them apart.

  *Ends in `/v1/responses`* — litellm's `/v1/messages` handler has a **second** path
  besides chat/completions. Any request carrying `thinking={"type":"enabled"}` gets its
  model rewritten to `openai/responses/<model>` (adapters/handler.py,
  `_route_openai_thinking_to_responses_api_if_needed`), which **ignores `drop_params`
  entirely** and hits Token Juice's Responses API. Token Juice answers 400 to the
  `reasoning` field that path adds. This is why it looked intermittent: Cowork/Chat
  turns don't send `thinking`, Code turns do, so it lands on whichever session is
  reasoning — repeatedly, not randomly.

  *Ends in `/v1/chat/completions`* — Token Juice also 400s on `reasoning_effort`, which
  is what litellm converts Anthropic `thinking` into for chat targets. `drop_params`
  does not cover it: it drops only params absent from the target model's price-map
  entry, and `deepseek-ai/DeepSeek-V4.1-Flash` has no entry.

  **Which effort values survive** matters for reproducing this. litellm buckets
  `thinking.budget_tokens` into an effort label (512/1024 → `low`, 2048 → `medium`,
  4096 → `high`) and Token Juice accepts only `low`, `high` and `none` — it rejects
  `minimal`, `medium` and `xhigh`. So a session reasoning with a 2048-token budget
  fails every turn while a 512-token one passes, on the same config. `verify.sh`'s
  check 4 pins `budget_tokens: 2048` for exactly this reason.

  The config fixes both by (a) declaring the model `hosted_vllm/*` rather than
  `openai/*`, which keeps the call on chat/completions and out of the thinking rewrite,
  and (b) listing the reasoning fields in `additional_drop_params`. Verify a change here
  against the two shapes that used to fail — `thinking` + `tools`, and `thinking` +
  `stream` — since plain requests passed all along.
- **App can't reach the proxy.** Use `127.0.0.1` (not `localhost`) in the base URL, and
  check `./start-desktop-proxy.sh status`.
- **Nothing changed after editing config.** `./start-desktop-proxy.sh restart`, then
  restart Claude Desktop.
- **`{"error":{"message":"No connected db.","type":"no_db_connection"}}`.** The gateway
  key did not match `master_key`. Make sure the app's *Gateway API key* is exactly
  `sk-claude-desktop-local` (or whatever `CLAUDE_DESKTOP_LITELLM_KEY` you set). With no
  matching key LiteLLM tries to treat it as a DB-backed virtual key and there is no DB,
  hence the odd message.
