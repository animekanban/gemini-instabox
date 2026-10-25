---
name: gemini-instabox
description: Ask Google Gemini through Google Antigravity CLI (agy) running on an InstaBox cloud machine, for a second opinion, long-context reading, or a coding sub-task. Use when the user says "ask Gemini", "use agy" or "use gemini cli".
---

# Gemini (Antigravity CLI) on InstaBox

Runs `agy -p` headless on an InstaBox machine through the InstaBox exec API and returns the answer.
Gemini CLI no longer serves personal / Google AI Pro / Ultra accounts (since 2026-06-18); Antigravity CLI is the official replacement and uses the same subscription.

## Setup (once)
1. On each machine: `curl -fsSL https://antigravity.google/cli/install.sh | bash` (binary at `~/.local/bin/agy`).
2. Log in once: run `agy` in the machine's terminal, choose **Google OAuth**, open the printed URL, paste the code back.
   The token is stored at `~/.gemini/antigravity-cli/antigravity-oauth-token`; it can be copied (mode 600) to other machines you own.
3. Locally set:
   - `INSTABOX_API_KEY`: an InstaBox API key (prefer a restricted key that can only call exec)
   - `GEMINI_IBX_MACHINES`: aliases, e.g. `agent01=m_xxx,agent02=m_yyy`
   - optional `GEMINI_IBX_MACHINE`: default alias
   Keep these in your shell profile or a secrets manager, never in this repo.

## Usage
```bash
scripts/gemini-remote.sh "Explain this error: ..."
cat report.md | scripts/gemini-remote.sh "Summarize the file above in 5 bullets"
scripts/gemini-remote.sh -m agent02 -M claude-opus-4-6-thinking "..."
scripts/gemini-remote.sh -a yolo -C ~/proj "Fix the failing test"   # lets the agent run commands and edit files on the machine
```
Flags: `-m` machine alias or id, `-M` model alias or slug (optional, see above), `-L` list models, `-e` effort, `-a` `safe` (default: shell commands soft-denied) or `yolo` (auto-approve everything), `-C` cwd on the machine, `-t` timeout (≤600 s), `-j` raw JSON, `-A` async/poll mode (starts agy in the background on the machine and polls with ~1 s requests; use it when your environment hangs or drops long HTTP calls).
Output: the answer on stdout; errors on stderr with a non-zero exit.

## Choosing a model (optional)
`-M` is optional. Without it the run uses `$GEMINI_IBX_MODEL` if set, else the CLI default (Gemini 3.8 Flash, high).

| Alias | Slug |
|---|---|
| `flash` | gemini-3.8-flash-high |
| `flash-medium` | gemini-3.8-flash-medium |
| `flash-low` | gemini-3.8-flash-low |
| `sonnet` | claude-sonnet-4-6 |
| `opus` | claude-opus-4-6-thinking |
| `gpt-oss` | gpt-oss-120b-medium |

Note: Claude 4.6 and GPT-OSS are scheduled for removal on 2026-11-02 (per Antigravity docs). Any full slug also works. Availability depends on the account's plan: run `-L` to see what this account can use. An unknown model fails loudly (no silent fallback).
```bash
scripts/gemini-dispatch.sh -M opus "Review this design: ..."
scripts/gemini-dispatch.sh -M flash-low "Quick: translate to English ..."
scripts/gemini-dispatch.sh -L
```

## Unified dispatcher (load balancing)
`scripts/gemini-dispatch.sh` picks the machine for you:
- **Least-recently-used first**, with a per-machine lock so parallel jobs never share a machine.
- **Failover**: a suspended/cooling machine (exit 3) is benched 10 min and the next one is tried; a machine that isn't logged in is skipped.
- **Quota**: on 429 it waits 30 s and retries once (all machines share one account's quota).
```bash
scripts/gemini-dispatch.sh "prompt"                     # auto-pick a machine
scripts/gemini-dispatch.sh -B prompts.txt -P 3          # batch, one prompt per line, 3 in parallel
scripts/gemini-dispatch.sh -S                           # machine status
scripts/gemini-dispatch.sh -m agent02 "prompt"          # force one machine
```
Other flags (`-M -e -a -C -t -j -A`) pass through to `gemini-remote.sh`. The machine used is printed to stderr as `[machine: …]`. State lives in `$GEMINI_IBX_STATE` (default `/tmp/gemini-ibx`).

## Rules for the agent
- Never print or echo `INSTABOX_API_KEY` or the OAuth token, and never put secrets or private data in prompts unless the user asked.
- One call = one fresh session; put all context in the prompt or pipe it via stdin (≤1 MiB).
- If your shell tool's stdin is a pipe that never sends EOF: when the prompt is passed as an argument the scripts wait at most 1 s for stdin, then go on; when the prompt comes only from stdin they wait for EOF. Redirecting `< /dev/null` is still the safest, and prefer `-A` async/poll mode in such environments.
- Keep `-a safe` unless the user asked for changes on the machine. Note: even in safe mode the agent may write files inside the cwd; use an empty cwd for pure Q&A. Edited files live on the machine, not locally.
- Jobs over 10 minutes fail (exec limit); split them.
- Exit 3 = machine suspended or cooling down: try another machine. Don't resume or reset machines to get around plan limits.
- `authentication required` = that machine isn't logged in: ask the user to run `agy` there once.
- `RESOURCE_EXHAUSTED (429)` = quota hit (all machines share one account's quota); wait and retry once, don't fan out.
