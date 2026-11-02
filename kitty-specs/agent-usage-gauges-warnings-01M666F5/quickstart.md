# Quickstart: Verifying Agent Gauges & Warnings Manually

Prerequisites: `./Scripts/package_and_run.sh release` running; Claude and Antigravity enabled in Settings → AI Agents; speech bubbles on.

## 1. Drop-box events (any agent)

```bash
# Usage: [AGENT=antigravity NAME=Antigravity] drop <kind> <message> [metadata-json]
drop() { dir="$HOME/Library/Application Support/Bitz/agent-events"; mkdir -p "$dir"
  id=$(uuidgen | tr '[:upper:]' '[:lower:]'); ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"id":"%s","agentID":"%s","agentName":"%s","kind":"%s","message":"%s","timestamp":"%s"%s}\n' \
    "$id" "${AGENT:-claude}" "${NAME:-Claude}" "$1" "$2" "$ts" "${3:+,\"metadata\":$3}" > "$dir/$id.json"; }

drop almostDone "✨ Claude is almost done!"                     # eager bubble, gone after ~6 s
drop usage "" '{"contextTokens":"185000"}'                      # gauge → Claude ctx 185k · 92%, context warning + amber visor
drop working "Claude is working..."                             # warning bubble stays
drop warning "⚠️ Claude reported a problem" '{"reason":"reported"}'  # replaces the context warning
```
Click **Got it** → bubble disappears, visor returns to its wellness color, clicks pass through the bubble area again.

## 2. Approval override and menu dismiss

1. `drop warning "⚠️ Claude test" '{"reason":"reported"}'`
2. `AGENT=antigravity NAME=Antigravity drop needsApproval "Antigravity needs input!"` → approval bubble shows, visor stays amber.
3. `AGENT=antigravity NAME=Antigravity drop working "Antigravity is working..."` → Claude's warning bubble returns.
4. Open the menu bar dropdown → **Dismiss Agent Warning** → warning clears, visor returns to its wellness color.
5. Settings → AI Agents → turn speech bubbles off; `drop warning "⚠️ hidden" '{"reason":"reported"}'` → no bubble, visor amber; **Dismiss Agent Warning** in the menu clears it. Turn bubbles back on.

## 3. Signal latency (NFR-003, timed)

Run each three times and record the seconds (pass: every run ≤ 5 s):
```bash
start=$(date +%s); drop warning "⏱ latency test" '{"reason":"reported"}'; echo "dropped at $start"
# press Return the moment the bubble appears:
read -r _; echo "latency: $(( $(date +%s) - start )) s"
```
For a live session: in a Claude Code session run a command that loops the same tool call 4× (e.g. ask it to run `true` four times as separate calls) and time from the 4th call appearing in the terminal to the loop warning bubble.

## 4. Live Claude Code session

1. Start a Claude Code session; send a prompt → "Claude is working..." on first output; gauge shows `Claude ctx …`.
2. Turn ends → "Claude is done!"; no stall warning afterwards.
3. Run a long `sleep 300` tool call → no stall warning while it runs.
4. If the Claude desktop app is installed: raise a warning (`drop warning …`), then quit the desktop app → the warning stays.

## 5. Settings

Settings → AI Agents → Agent Signals: toggle loop warnings off, set stall timeout to 10 min, set Claude window to 1M → gauge percent drops accordingly; relaunch keeps the values.

## 6. Resource check

Activity Monitor: Bitz stays < 2% CPU and < 70 MB RAM with an active Claude Code session over 5 minutes.
