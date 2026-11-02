# CLAUDE.md — Project Entry Point for AI Coding Agents

Read and strictly follow [AGENTS.md](AGENTS.md) before exploring the repository or making any changes.

`AGENTS.md` contains:
1. **Instant Codebase Map** (`src/App`, `src/Views`, `src/Services`, `src/Models`, `Tests/BitzTests`, `Scripts`, `docs`) so you can jump directly to the right file without broad searches.
2. **Performance & Idle CPU Invariants (`< 2%` CPU, `< 70 MB` RAM)** — mandatory CoreAnimation, `NSHostingView`, window teardown, and telemetry caching rules preventing regressions of #10 and #70.
3. **Ticket-First & Post-Merge Issue Closure Rules** (`Closes #<id>`, `refs #<id>`).
4. **Mascot Window & Click-Through Invariants** (`ignoresMouseEvents = true`, `canBecomeKey = false`, `MascotOverlayLayoutTests`).
5. **Toolchain & Verification Commands** (`xcrun swift test`, `./Scripts/package_and_run.sh release`).
