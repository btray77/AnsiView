# Brief for agents implementing an AnsiView 2.0 plan

Repo: /Users/bt/Source/bbs/tw2k2/AnsiView (git, `main`, remote github.com/btray77/AnsiView). macOS 26, Xcode 26.6, XcodeGen.

## Read first
- `docs/ROADMAP-2.0.md` (the spec; owner decisions at the top)
- `docs/superpowers/plans/2026-10-30-ansiview-2.0-plan-1-rendering-core.md` (format to follow; what exists)
- `README.md`, `project.yml`, `Packages/AnsiCore/Sources/AnsiCore/*`, `Shared/AnsiPlayer.swift`, `App/*`, `Preview/*`, `Tool/main.swift`

## Process (required)
1. `git switch -c ansiview-2.0-plan-<N>` from `main`.
2. Use the superpowers:writing-plans skill to write `docs/superpowers/plans/2026-10-30-ansiview-2.0-plan-<N>-<name>.md` for your roadmap items. Commit it.
3. Use superpowers:executing-plans (inline) with superpowers:test-driven-development: every task's tests are written and seen failing before code. Keep the ledger it asks for.
4. Final whole-branch review by a fresh reviewer subagent on the opus model (superpowers:requesting-code-review code-reviewer.md). Fix Critical and Important findings test-first in one pass; defer Minors.
5. Leave the branch committed and unmerged. Do not push, merge, tag, publish, create GitHub repos or releases, or change signing identities. The coordinator merges and pushes.

## Build and test
- Core tests: `cd Packages/AnsiCore && swift test` (Swift Testing). New pure logic belongs in AnsiCore with tests.
- App: `./install.sh` builds Release, installs to ~/Applications, registers Quick Look. Must print `** BUILD SUCCEEDED **` at the end of every task.
- CLI: `xcodebuild -project AnsiView.xcodeproj -scheme ansirender -configuration Release -derivedDataPath build build` then `build/Build/Products/Release/ansirender`.
- Regression corpus (never commit it, it is copyrighted): `../extracted/TWSUPP/*.ANS`. `ansirender --stats ../extracted/TWSUPP/*.ANS | sed -E 's/ format=.*//'` must keep the same `animated`/`blink` values (15 animated, 8 blink of 61).
- UI verification: screenshots of live windows are blocked (no Screen Recording permission). Verify AppKit UI by linking the real code into a harness: `swiftc -O -I build/Build/Products/Release -o harness main.swift Shared/*.swift build/Build/Products/Release/AnsiCore.o`, copy `build/Build/Products/Release/AnsiCore_AnsiCore.bundle` next to the binary, host the view controller in an offscreen NSWindow (add the view as a subview; do not use contentViewController), `layoutSubtreeIfNeeded`, `cacheDisplay` to PNG, then look at the PNG. Keep harnesses in `.superpowers/` or the scratchpad, never in the repo.
- System log: zsh has a `log` builtin; use `/usr/bin/log show ...`.
- SourceKit "cannot find type" diagnostics on single files are noise; trust `swift test` and xcodebuild.

## Rules (from the owner, mandatory)
- Never use the em-dash character in any file, UI string, doc or commit message. Use commas, colons, parentheses.
- Bump `CURRENT_PROJECT_VERSION` in project.yml with every task commit (MARKETING_VERSION stays 2.0.0).
- Show evidence: every claim in your final report cites a command and its real output. Label anything measured vs inferred vs assumed. Do not report UI as working unless you observed it (harness PNG or app behaviour).
- Commit messages end with: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
- App and extensions stay sandboxed; add only the entitlements a feature needs and say why.
- No Trade Wars or third party art in the repo. Bundled samples must be original (generate them).
- Known traps: never set `preferredContentSize` on the shared player view controller (AppKit adds priority 501 constraints that pin window size; only the Quick Look PreviewViewController sets it). `.bin` and `.adf` are system types; AnsiView is only an alternate viewer for them.
- If something truly needs the owner (credentials, publishing, licensing, paid accounts), do everything else, document the remaining step in the plan and README, and list it in your report under "Needs owner".

## Final report (your last message)
Branch name and commit range; per roadmap item: done/partial/not done with evidence; test count before and after; rulings (each with cost if wrong); deferred minors; "Needs owner" list. No em-dashes.
