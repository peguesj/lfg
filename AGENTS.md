# LFG Agent Guide

## Validation Commands (backpressure)
- Swift build: swift build 2>&1
- Swift tests: swift test 2>&1
- Bash lint: shellcheck lib/*.sh scripts/*.sh
- Python lint: python3 -m pylint devdrive/*.py
- Type check: swift build -Xswiftc -warnings-as-errors

## Completion criteria
- All swift test pass
- shellcheck 0 errors
- No TODO/FIXME in committed code
- APM notified

## File conventions
- Swift: Sources/LFGKit/ for shared logic, Sources/LFGApp/ for UI
- Tests: Tests/LFGKitTests/
- Daemon: Sources/LFGDaemon/ (XPC service target)
- Bash modules: lib/*.sh
- Python: devdrive/*.py
