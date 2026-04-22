# Personal fork maintenance

This fork carries two patches on top of [thedotmack/claude-mem](https://github.com/thedotmack/claude-mem) and keeps itself in sync with upstream via an automated three-layer pipeline.

## Why this fork exists

| Branch | Purpose | Why it's here, not upstream |
|--------|---------|-----------------------------|
| `fix/gemini-preview-models-v1beta` | Switch `GEMINI_API_URL` from `v1` → `v1beta`; add `gemini-3.1-pro-preview` and `gemini-3.1-flash-lite-preview`. Fixes [#1148](https://github.com/thedotmack/claude-mem/issues/1148). | Upstream restricts PR creation to collaborators. |
| `feat/add-zh-tw-mode` | Add `plugin/modes/code--zh-tw.json` — Traditional Chinese (Taiwan) observer mode with TW-standard vocabulary (`檔案`, `使用者`, `程式碼`, `運作`, …). | Same restriction. |

Both branches are single-commit and rebase onto each new upstream release tag.

## Branch map

```
upstream/main (thedotmack)
     │
     ▼
origin/main ────────────────────── mirror of upstream + this .github/workflows/sync-upstream.yml + .fork/
     │
     ├── fix/gemini-preview-models-v1beta   ◄── for future upstream PRs; auto-rebased by GHA
     ├── feat/add-zh-tw-mode                ◄── same
     │
     ├── release-local                      ◄── 👉 what you install from (upstream tag + 2 fixes + rebuilt bundles)
     │
     ├── auto/needs-review-<upstream_tag>   ◄── conflict workspace; routine cleans up
     │
     └── tags: my-release/<upstream_tag>-<YYYYMMDD>  ◄── rollback points
```

**You only ever interact with `release-local`** via `cm-update`. Everything else is infrastructure.

## The three-layer sync pipeline

```
┌──────────────────────────────────────────────────────────────────────┐
│ Layer 1 — GitHub Action (.github/workflows/sync-upstream.yml)        │
│                                                                       │
│ Runs every 6h + on manual dispatch.                                   │
│                                                                       │
│ 1. git fetch upstream main --tags                                     │
│ 2. latest_tag = newest v*.*.*                                         │
│ 3. if my-release/<latest_tag>-* exists → skip (idempotent)            │
│ 4. rebase fix/gemini... and feat/add-zh-tw-mode onto latest_tag       │
│                                                                       │
│    ✅ Clean:                                                          │
│       - cherry-pick both onto release-local (based at latest_tag)     │
│       - npm install + npm run build                                   │
│       - 5 invariant greps (v1beta endpoint, 3 preview models, zh-tw)  │
│       - commit rebuilt bundles, push release-local                    │
│       - tag my-release/<latest_tag>-<YYYYMMDD>, push                  │
│       - 🟢 Telegram via curl                                          │
│                                                                       │
│    ⚠️  Conflict:                                                      │
│       - push auto/needs-review-<latest_tag> (unresolved markers)      │
│       - create issue with label `auto-resolve`, body has              │
│         RUNBOOK + INVARIANTS + ON_FAILURE                             │
│       - 🟡 Telegram: "routine will handle it"                         │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              │ (issue with label=auto-resolve)
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Layer 2 — Claude Code routine (claude.ai scheduled remote agent)     │
│                                                                       │
│ Polls every 3h via mcp__github__list_issues.                          │
│                                                                       │
│ 1. list open issues with label=auto-resolve                           │
│ 2. none → exit silently (no notification)                             │
│ 3. one or more → read oldest issue body                               │
│ 4. execute RUNBOOK: resolve conflicts, preserve INVARIANTS            │
│    from issue body (authoritative), rebuild, verify                   │
│                                                                       │
│    ✅ Resolved:                                                       │
│       - push fix branches + release-local + rollback tag              │
│       - comment on issue summarising resolution choices               │
│       - close issue                                                   │
│       - 🔵 Telegram via MCP Telegram connector                        │
│                                                                       │
│    ❌ Can't resolve:                                                  │
│       - comment on issue with failure step + stderr                   │
│       - do NOT close issue                                            │
│       - 🔴 Telegram: "need you to handle manually"                    │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              │ (you receive Telegram, decide to update)
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Layer 3 — cm-update fish function (.fork/cm-update.fish)             │
│                                                                       │
│ Manual, on-demand. Pulls release-local into your local plugin         │
│ marketplace and restarts the worker.                                  │
│                                                                       │
│ cm-update                    → pull latest, sync, restart             │
│ cm-update --check            → just check if update available         │
│ cm-update --status           → show installed/latest/recent tags      │
│ cm-update --version <tag>    → install a specific my-release/* tag    │
│ cm-update --rollback         → install the 2nd-newest my-release tag  │
└──────────────────────────────────────────────────────────────────────┘
```

## Telegram notifications

Four message types; each has its own emoji so the notification's purpose is obvious at a glance.

| Emoji | From | Triggered by | What it means | Your action |
|-------|------|--------------|---------------|-------------|
| 🟢 | Layer 1 (curl) | Clean rebase + build succeeded | New `release-local` ready, no conflicts | Run `cm-update` when convenient |
| 🟡 | Layer 1 (curl) | Rebase hit a conflict | GHA handed off to routine via issue | Wait for 🔵 or 🔴 (up to 3h) |
| 🔵 | Layer 2 (MCP) | Routine resolved the conflict | Release ready, see issue comment for resolution notes | Review the issue + diff, then `cm-update` |
| 🔴 | Layer 2 (MCP) | Routine can't auto-resolve | Needs hand-intervention | Clone fork, resolve manually |

Required secrets on `audichuang/claude-mem` (Settings → Secrets and variables → Actions):

- `TELEGRAM_BOT_TOKEN` — from [@BotFather](https://t.me/BotFather)
- `TELEGRAM_CHAT_ID` — get via:
  ```bash
  curl "https://api.telegram.org/bot<TOKEN>/getUpdates" \
    | jq '.result[0].message.chat.id'
  ```

The routine (Layer 2) uses a separate channel: a **Telegram MCP connector** configured at [claude.ai/settings/connectors](https://claude.ai/settings/connectors) — no token handling in the routine prompt.

## How to install on a new machine

1. **Install the official plugin first** (so the marketplace scaffold exists):
   ```bash
   cd ~   # don't run from this repo, npx gets confused by local package.json
   npx claude-mem@latest install
   ```
   Select Claude Code / Codex CLI / Gemini CLI — whatever you use.

2. **Clone this fork**:
   ```bash
   git clone https://github.com/audichuang/claude-mem.git ~/my-claude-mem
   cd ~/my-claude-mem
   git remote rename origin origin
   git remote add upstream https://github.com/thedotmack/claude-mem.git
   git fetch upstream main
   ```

3. **Point `CM_FORK_PATH` at the clone, wire up `cm-update`**:
   ```fish
   set -Ux CM_FORK_PATH ~/my-claude-mem
   ln -s $CM_FORK_PATH/.fork/cm-update.fish ~/.config/fish/functions/cm-update.fish
   ```
   (Symlink means future updates to the function auto-apply.)

4. **First sync**:
   ```fish
   cm-update
   ```

5. **(Optional) If the GitHub Action hasn't produced a `release-local` yet**:
   - Go to https://github.com/audichuang/claude-mem/actions/workflows/sync-upstream.yml
   - Click "Run workflow" → branch `main` → Run.
   - Wait for 🟢 Telegram.
   - Then `cm-update`.

## Daily flow

```
┌─── passive ──────────────────────────────┐     ┌─── active ─────────────┐
│                                          │     │                        │
│  upstream releases v12.4.0               │     │  you get 🟢 Telegram   │
│  └─ GHA notices within 6h                │     │  └─ cm-update          │
│     └─ tries rebase                      │ ──▶ │     └─ next session    │
│        ├─ clean → 🟢 Telegram            │     │        uses new bundle │
│        └─ conflict → 🟡 Telegram         │     │                        │
│           └─ routine picks up in ≤3h     │     └────────────────────────┘
│              ├─ resolves → 🔵 Telegram   │
│              └─ fails → 🔴 Telegram      │
└──────────────────────────────────────────┘
```

## Rollback

Everything that goes into `release-local` gets a `my-release/<upstream_tag>-<YYYYMMDD>` tag attached. Tags are permanent; force-pushes to `release-local` never remove them.

```fish
# See available rollback points
cm-update --status

# Quick: go to 2nd-newest
cm-update --rollback

# Specific: pin to a known-good tag
cm-update --version my-release/v12.3.8-20260422

# Nuclear: blow away fork version entirely, back to thedotmack's npm
cd ~
npx claude-mem@latest install   # overwrites ~/.claude/plugins/marketplaces/thedotmack/
```

## Manual GHA trigger

If you want to force an immediate sync without waiting for the 6h cron:

```bash
gh workflow run sync-upstream.yml \
  --repo audichuang/claude-mem \
  --ref main
```

Or via the Actions UI: https://github.com/audichuang/claude-mem/actions/workflows/sync-upstream.yml

## Invariants the system enforces

After every rebuild, these five commands must all exit 0. If any fails, Layer 1 won't push release-local; Layer 2 won't close the issue:

```bash
grep -q "v1beta/models"                plugin/scripts/worker-service.cjs
grep -q "gemini-3.1-flash-lite-preview" plugin/scripts/worker-service.cjs
grep -q "gemini-3.1-pro-preview"        plugin/scripts/worker-service.cjs
test -f plugin/modes/code--zh-tw.json
python3 -c "import json; json.load(open('plugin/modes/code--zh-tw.json'))"
```

When adding a new fix-intent to this fork, add a line to this list in both `.github/workflows/sync-upstream.yml` **and** the issue template it produces.

## If upstream ever opens PR contributions

`fix/gemini-preview-models-v1beta` and `feat/add-zh-tw-mode` are kept single-commit and rebase-clean specifically so they can be submitted upstream without rewriting history. Just:

```bash
gh pr create --repo thedotmack/claude-mem \
  --base main --head audichuang:fix/gemini-preview-models-v1beta \
  --title "..." --body-file ...
```

(Currently fails with "does not have correct permissions" — upstream's setting, not ours.)

## File layout

```
.fork/
  README.md        — this file
  cm-update.fish   — the fish function Layer 3
.github/workflows/
  sync-upstream.yml  — Layer 1
```

The Layer 2 routine lives on claude.ai, not in the repo. Its prompt is referenced here for recall:

- Polls `mcp__github__list_issues` with `labels=auto-resolve, state=open`
- Empty → exit silently (no Telegram)
- Non-empty → read issue body → follow RUNBOOK → push or fail → Telegram via MCP

The issue body generated by Layer 1 is the single source of truth for what the routine should do on any given run.
