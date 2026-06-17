# Ralph Build Prompt — LFG Formation

Formation: fmt-lfg-fleet-20260419
Mode: build
Branch: develop

---

## Mission

You are a build agent executing the LFG formation. Your objective is to implement the LFG macOS disk management suite per the specs and implementation plan, using strict TDD methodology.

Reference documents (read these first):
- `IMPLEMENTATION_PLAN.md` — wave order and backpressure gates
- `specs/daemon-xpc.md` — XPC daemon spec
- `specs/native-app-operations.md` — SwiftUI operational controls spec
- `specs/devdrive-v2-backend.md` — DevDrive v2 backend spec
- `specs/ux-refactor.md` — UX refactor spec
- `AGENTS.md` — validation commands and file conventions

---

## TDD Discipline (strict)

For every piece of Swift logic you implement:

1. **Write the test first** in `Tests/LFGKitTests/`
2. Run `swift test 2>&1` — confirm the new test FAILS (red)
3. Write the minimum implementation to make it pass
4. Run `swift test 2>&1` — confirm all tests PASS (green)
5. Refactor if needed; confirm tests still pass

Do NOT write implementation code before its corresponding test exists. Do NOT commit code with failing tests.

---

## Per-Iteration Checklist

After every implementation unit (function, type, or view):

```
[ ] swift build 2>&1           — must exit 0
[ ] swift test 2>&1            — must exit 0, all tests pass
[ ] shellcheck lib/*.sh scripts/*.sh   — if any .sh files modified
[ ] python3 -m pylint devdrive/*.py    — if any .py files modified
```

If any check fails: fix the failure before proceeding. Do not advance to the next implementation unit with a broken build or failing tests.

---

## Wave Execution Order

Follow `IMPLEMENTATION_PLAN.md` wave order exactly:

1. Wave 1 — Foundation (SPM structure, stub targets)
2. Wave 2 — Daemon (FSEvents, XPC protocol, LaunchAgent)
3. Wave 3 — App Operations (DaemonClient, Offload, SymlinkAuditor, UI)
4. Wave 4 — DevDrive v2 (FleetRegistry v2, ReconcileService, migration)
5. Wave 5 — UX Polish (design tokens, module views, WebKit removal)
6. Wave 6 — TDD Completion (coverage to 80%+, linting)
7. Wave 7 — Integration (APM bridge, Plane sync, release build)

Do not skip waves. Each wave has a backpressure gate — confirm it passes before starting the next wave.

---

## Constraints

- No `any` type without explicit justification and comment
- No `TODO` or `FIXME` in committed code
- No `WKWebView` import in Sources/ after Wave 5
- No real `diskutil` or `hdiutil` calls in test code — use mock types
- Home-dir offload symlinks must never be redirected to internal fallback (regression: CP-108)
- All XPC timeout paths must surface `DaemonError.timeout`, never silently swallow

---

## APM Notification

On completing each wave, POST to the APM bridge:

```bash
curl -s -X POST http://localhost:3032/api/notify \
  -H "Content-Type: application/json" \
  -d '{"project":"lfg","event":"wave_complete","wave":"<N>","formation":"fmt-lfg-fleet-20260419"}'
```

---

## Completion Promise

When all 7 waves are complete and all backpressure gates pass:

<promise>LFG-FORMATION-COMPLETE</promise>

Emit this token exactly once in your final message.

---

## Escape Hatch

If you reach **20 iterations** without completing the current wave:
1. Stop implementation
2. Document all blockers in a file named `BLOCKERS.md` at repo root
3. List: what was attempted, exact error output, what was tried to resolve it
4. Do NOT emit the completion promise
5. Notify: `curl -s -X POST http://localhost:3032/api/notify -H "Content-Type: application/json" -d '{"project":"lfg","event":"escape_hatch","wave":"<N>","formation":"fmt-lfg-fleet-20260419"}'`

---

## File Conventions (from AGENTS.md)

- Swift shared logic: `Sources/LFGKit/`
- Swift UI: `Sources/LFGApp/`
- XPC daemon: `Sources/LFGDaemon/`
- CLI: `Sources/lfg-cli/`
- Tests: `Tests/LFGKitTests/`
- Bash modules: `lib/*.sh`
- Python DevDrive engine: `devdrive/*.py`
