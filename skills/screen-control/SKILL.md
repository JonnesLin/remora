---
name: screen-control
description: Drive the operator's Mac GUI on his behalf — take a screenshot, look at it, click/type, verify. Use when the orchestrator needs to (a) trigger /clear or /compact in its own terminal, (b) spawn or feed an external AI agent (Codex / DeepSeek / Cursor / browser-based ChatGPT etc.) via its UI, or (c) operate any GUI/terminal action that has no programmatic API. Mac-only; relies on cliclick + screencapture + osascript.
---

# screen-control

Drive the operator's Mac GUI on his behalf — take a screenshot, look at it, click/type, verify.

## Role in the super-agent (narrow — GUI work goes to Codex Desktop)

The orchestrator **does not drive GUI directly**. GUI tasks dispatch to Codex Desktop (which has computer-use tooling) via `dispatch-external-agent`. The orchestrator's direct use of `cliclick` / `screencapture` / `osascript` is reserved for the irreducible chicken-and-egg cases:

1. **Self-`/clear` / `/compact` on the orchestrator's own terminal** — Codex Desktop cannot drive the Terminal session that's *running* the orchestrator (the agent and the controller would be the same process). The orchestrator types these directly via `cliclick` when the admin approves the operation.
2. **Bootstrap of Codex Desktop itself** — to dispatch to Codex Desktop, something has to launch it and paste the prompt. That something is the orchestrator (one-time per session, then handoff). The recipe lives in the Coord Cache section below.

That's it. Long-tail GUI ("click through a dialog", "drive Safari OAuth", "run /mcp on a Terminal", "navigate a setup wizard") belongs in a `tasks/<id>/prompt.md` for Codex Desktop. See `dispatch-external-agent/SKILL.md` §"Per-target adapter notes — codex-desktop". Don't expand this skill for new GUI workflows; expand the codex-desktop adapter instead.

Everything below is the operating manual for the two uses above.

## Tools

- `screencapture -x out.png` — silent screenshot, full screen.
- `screencapture -x -R x,y,w,h out.png` — region screenshot. **x,y,w,h are in points, not pixels.**
- `sips -g pixelWidth -g pixelHeight FILE` — read image dimensions.
- `cliclick` at `/opt/homebrew/bin/cliclick` (v5.1):
  - `c:X,Y` — click; `m:X,Y` — move; `dc:X,Y` — double-click; `rc:X,Y` — right-click
  - `t:"text"` — type (Unicode-safe)
  - `kp:return|esc|tab|space|...` — single key press
  - `kd:cmd t:l ku:cmd` — Cmd+L (key-down, type, key-up). Same pattern for any modifier chord.
  - `p:.` — print current cursor position (in points)
  - `w:300` — wait 300ms (chainable inside one cliclick invocation)
- `osascript -e '...'` — AppleScript fallback when cliclick can't reach a target.

Read screenshots with the `Read` tool — it accepts PNGs and shows the image.

## Coordinate system — the #1 gotcha

This Mac is a Retina display. Resolutions:
- **Screenshot (`screencapture`)**: pixels — 3024 × 1964
- **cliclick & `screencapture -R`**: points — 1512 × 982 (= pixels / 2)

When you find a target at `(px_x, px_y)` in a screenshot, click at `(px_x / 2, px_y / 2)`.

If you misread the displayed image dims (the Read tool may resize), use `sips -g pixelWidth -g pixelHeight` on the file to get the true pixel size, then scale.

## Workflow

1. `screencapture -x /tmp/s.png` (full) or `-R x,y,w,h` (region, in points).
2. Read the PNG. Identify target. Convert pixels → points (÷2).
3. Optional: `cliclick m:X,Y` then re-screenshot to verify cursor landed on target before clicking. Cheap insurance for small/dense UI.
4. `cliclick c:X,Y` (click), or `t:"..."` (type), `kp:return` (Enter).
5. Re-screenshot. Verify the click did what you expected — don't assume.

## Self-`/clear` / `/compact` (authorized)

The orchestrator may issue `/clear` or `/compact` against its own active Claude Code terminal. The procedure:

1. Make sure all in-flight state is persisted to disk: `PROGRESS.md`, `tasks/<id>/state.json` and any `pending_question.md`, and — critically — every outstanding orchestrator obligation in `~/projects/_admin/pending/` (auth deadlines, ETAs given to non-admins, "I'll get back to you" promises). Anything that lives only in conversation context is lost. See PROTOCOL.md §0 (cold start) and CLAUDE.md "Persisting before promising" for the rule.
2. Focus the orchestrator's terminal window.
3. `cliclick t:"/clear"` then `kp:return` (or `/compact`).
4. After clear, the next inbound message will reload `CLAUDE.md` → `PROTOCOL.md` and pick up state from the on-disk files.

This was previously banned in an older CLAUDE.md but is now explicitly allowed (admin authorized 2026-05-01).

## External-agent dispatch entry

When `dispatch-external-agent` calls into screen-control to feed a target AI:

1. Open / focus the target app (Codex CLI in a terminal, Cursor, a Safari tab with a chat UI, etc.).
2. Type or paste the entry pointer — typically the absolute path to `tasks/<id>/prompt.md` plus a one-line instruction telling the target agent to write its final result to `tasks/<id>/result.md`.
3. Submit. **Do not** poll the screen to read the answer — the dispatch protocol is markdown-only. screen-control's job ends once the target has accepted the prompt.

If the target is a non-agentic chat UI that cannot write files, OCR/scraping fallback is out of scope for phase 1 — escalate to the admin instead.

## Known menu-bar coordinates (this Mac, current layout)

Menu bar y ≈ 15 (points). From left:

- Apple menu: x=30
- App name (Safari/Chrome/etc — varies): around x=70
- Then app menus (File, Edit, View, …)

Right side, in order (each ~25pt wide, packed tightly — easy to miss-click by one):
- Focus moon
- Wi-Fi
- Battery: x≈1283
- **Spotlight (magnifier): x≈1310** ← verified
- Control Center: x≈1335
- Time/date: rightmost

If the layout changed (new menu-bar app installed/removed), re-probe by clicking and reading the result, then update.

## Dock

Dock auto-shows at bottom; row center y ≈ 960 (points). Icons are ~50pt wide each, starting at x≈30 for Finder. Calendar (the "30" icon) is at x≈503.

## What's flaky / use AppleScript instead

- **Web page elements** (links, tabs inside a Google result, form fields): pixel-clicking by eyeballing the screenshot is unreliable — DOM layouts shift, and the renderer scaling can mislead. Use `osascript` with Safari's `do JavaScript` to `.click()` the right element by selector.
- **Cmd+L → type Chinese characters → Enter**: typing committed but Enter sometimes lands in autocomplete dropdown instead of submitting. Easier to `open -a Safari "https://..."` for URL navigation.
- **First-launch Spotlight tutorial**: a "Continue" dialog appears once, blocks the search field. Click Continue (not visually obvious by Return) before typing.

## Asking another agent to find click coords

When delegating "look at this screenshot and tell me where to click X" to a subagent:

- **Ask for fractional coords (0–1 of image dims), not absolute pixels.** The Read tool may downscale the image before the model sees it; the model can't reliably know what coordinate system its perception is in. Externally scale: `pt_x = fx * 1512`, `pt_y = fy * 982`.
- **Don't tell the model "divide by 2"** — that assumes the model sees the original 3024×1964 pixels. It doesn't. (Round 1 of the benchmark below failed for this reason.)
- **Model choice (verified 2026-04-30, 10-target benchmark, 30 pt hit radius):**
  - **Opus** — 6/10 hits, median error 29 pt. Use when accuracy matters.
  - **Sonnet** — 4/10 hits (all menu-bar / Dock), median 80 pt. Cheapest tokens; fine for fixed-position UI.
  - **Haiku** — 2/10 hits, median 91 pt. Fast end-to-end but spends ~2× tokens for worse output. Use only for very large, unambiguous targets.
- **All three fail on in-page web elements** (search box, X button, link, tabs). For those, drive Safari via `osascript` + `do JavaScript` to query DOM and click by selector — pixel-clicking is the wrong tool.
- The figures above come from a 10-target click-accuracy benchmark on macOS. Methodology: (1) ask each model for fractional 0–1 coords on a fixed screenshot, (2) externally scale to points, (3) measure pixel distance from click-verified ground truth, (4) hit = within 30 pt. Re-run for your own runtime if click work matters; in-page web elements failed for all three models, so prefer DOM-level interaction.

## Pre-verify accessibility permissions before driving

Before any non-trivial automation session, sanity-check that the parent process actually has macOS Accessibility permission:

```bash
osascript -e 'tell application "System Events" to name of (first process whose frontmost is true)'
```

- Returns the current frontmost app name → permissions OK, proceed.
- Returns `AppleEvent timed out. (-1712)` → permissions missing or partial. **Stop and ask the admin** to grant Accessibility access in System Settings → Privacy & Security → Accessibility, then retry.

Symptoms of partial accessibility (verified 2026-05-01): `cliclick` typing/keypresses work, but precise clicks miss web elements and `osascript` Apple events to other apps time out. This makes GUI automation feel "almost working" but actually unreliable. Don't waste cycles iterating on click coords if the underlying issue is permissions.

## Coord cache for repeatable targets

For targets that don't move between sessions (app windows at default positions, fixed UI elements), record their coords here so future runs skip the screenshot+vision dance.

### Codex Desktop (window at default opened position)

| Target | How to drive | Status |
|---|---|---|
| Activate app | `osascript -e 'tell application "Codex" to activate'` | ✓ verified 2026-05-01 |
| Focus chat input | `cliclick c:850,485` | ✓ |
| Paste clipboard | `cliclick kd:cmd t:v ku:cmd` (after focusing input) | ✓ |
| Submit | `osascript -e 'tell application "System Events" to keystroke return using {command down}'` (Cmd+Enter) | ✓ verified — Enter alone adds newline, only Cmd+Enter sends |
| Send button (visual) | DON'T click — vision agents confuse it with the "5.5 ExtraHigh" model selector at (1119, 638). Use Cmd+Enter instead. | ✗ |
| Dismiss dropdown | `cliclick c:600,300` (click blank area). Esc is unreliable. | ✓ |

**When the coord cache misses**: re-screenshot, re-derive coords, update this table. Window resizing or major Codex Desktop UI updates will invalidate.

### Safari (web pages — DO NOT cache)

Web page DOM layouts shift; coord-cache for in-page elements rots fast. Use one of:
- `osascript` + Safari `do JavaScript` to query DOM and `.click()` by selector
- Delegate to a desktop-capable agent (Codex Desktop with the desktop-control plugin, etc.) that does its own visual perception per turn

Don't put OAuth Continue / Allow / "Not Now" coordinates in this cache.

## Don't

- **Don't approve security/permission prompts** that appear during automation (e.g., "Terminal wants to control X"). Stop and tell the operator — those need his consent. (This is part of the broader admin-only policy in `auth-policy.md`.)
- **Don't click blind on web elements** based on a remembered coordinate. App-window UI is mostly stable; web-page UI shifts.
- **Don't iterate on click coords if accessibility is missing.** Run the accessibility probe first; if Apple Events time out, fix permissions before retrying.
- **Don't try `cliclick kp:esc` to dismiss in-app menus** — verified unreliable on Codex Desktop (and possibly other Electron apps). Click a blank area instead.

## Verified test results (2026-04-30)

| Target | Coord (pt) | Result |
|---|---|---|
| Apple menu | 30,15 | ✓ first try |
| Dock → Calendar | 503,960 | ✓ first try |
| Spotlight icon | 1310,20 | ✓ third try (off-by-one menu-bar slot) |
| Safari Cmd+L → type → Enter | — | ✓ typing worked, Enter landed in autocomplete; recovered with `open URL` |
| Google weather "Precipitation" tab | 441,453 | ✗ click registered but tab didn't switch — web element flake |
