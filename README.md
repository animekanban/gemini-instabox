```markdown title="README.md"
# gemini-instabox

Call Gemini (and the other models bundled with Google Antigravity) from any AI agent or shell, by running the **Antigravity CLI (`agy`)** headless on [InstaBox](https://instabox.sh) cloud machines. A dispatcher load-balances across several machines with automatic failover.

> Gemini CLI no longer serves personal / Google AI Pro / Ultra accounts (since 2026-06-18). Antigravity CLI is Google's official replacement and uses the same subscription.

## How it works

```
your agent ──HTTPS──> InstaBox exec API ──> machine (agy -p "...") ──HTTPS──> Google
```

- `scripts/gemini-remote.sh` runs one prompt on one machine.
- `scripts/gemini-dispatch.sh` picks the machine for you: least-recently-used first, one job per machine at a time, skips suspended or logged-out machines, waits and retries once on quota errors.

## Install

```bash
git clone https://github.com/animekanban/gemini-instabox.git ~/.skills/gemini-instabox
```

Requirements: `bash`, `curl`, `jq`, `flock` (macOS: `brew install jq flock`).

## Machine setup (once per machine)

```bash
curl -fsSL https://antigravity.google/cli/install.sh | bash   # installs ~/.local/bin/agy
agy                                                          # choose Google OAuth, open the URL, paste the code
```

The login token is saved at `~/.gemini/antigravity-cli/antigravity-oauth-token`.

## Configure

```bash
export INSTABOX_API_KEY="..."                       # prefer a dedicated key per agent
export GEMINI_IBX_MACHINES="agent01=m_xxx,agent02=m_yyy"
export GEMINI_IBX_MODEL="flash"                     # optional default model
```

Never commit these values.

## Usage

```bash
D=~/.skills/gemini-instabox/scripts/gemini-dispatch.sh

bash $D "Explain this error: ..."                    # auto-pick a machine
cat report.md | bash $D "Summarize the above"        # pipe long context via stdin
bash $D -M opus "Review this design: ..."            # choose a model
bash $D -B prompts.txt -P 3                          # batch, one prompt per line
bash $D -S                                           # machine status
bash $D -L                                           # models your account can use
```

| Flag | Meaning |
|---|---|
| `-M` | model alias or full slug (optional) |
| `-e` | effort: low, medium, high |
| `-a` | `safe` (default, shell commands denied) or `yolo` (auto-approve all) |
| `-C` | working directory on the machine |
| `-t` | timeout in seconds (max 600) |
| `-m` | force a specific machine |
| `-j` | raw JSON output |
| `-A` | async/poll mode: runs agy in the background on the machine and polls with short requests; use it when your environment hangs or drops long HTTP calls |

Model aliases: `flash`, `flash-medium`, `flash-low`, `sonnet`, `opus`, `gpt-oss`. Availability depends on your Google plan; run `-L` to check.

## Notes

- All machines share one Google account's quota; avoid large parallel fan-outs.
- Each call is a fresh session; put all context in the prompt.
- Prompts and answers are encrypted in transit but visible to InstaBox and Google. Don't send secrets.
- If your shell tool's stdin is not a TTY and never sends EOF, redirect stdin (`< /dev/null`) when passing the prompt as an argument, or the call blocks before it starts.
- See `SKILL.md` for agent-facing rules.

## License

MIT
```
