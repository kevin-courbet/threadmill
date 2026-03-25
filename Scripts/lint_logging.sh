#!/usr/bin/env bash
# Enforce os.Logger usage — ban NSLog and print() in production Sources.
# Run via: task lint   or   bash Scripts/lint_logging.sh
# Also runs as a pre-commit hook (see .git/hooks/pre-commit).
set -euo pipefail

ERRORS=0

# Ban NSLog in Sources/
if grep -rn '\bNSLog(' Sources/ --include='*.swift' 2>/dev/null; then
    echo "ERROR: NSLog() found in Sources/. Use Logger.<category> from os.Logger instead."
    echo "       See Sources/Threadmill/Support/Log.swift for available categories."
    ERRORS=$((ERRORS + 1))
fi

# Ban print() in Sources/ (test output should use os.Logger or XCTAssert)
if grep -rn '\bprint(' Sources/ --include='*.swift' 2>/dev/null; then
    echo "ERROR: print() found in Sources/. Use Logger.<category> from os.Logger instead."
    ERRORS=$((ERRORS + 1))
fi

# Ban TraceLog / trace() — removed in favor of os.Logger
if grep -rn '\btrace(' Sources/ --include='*.swift' 2>/dev/null | grep -v 'Log.swift' 2>/dev/null; then
    echo "ERROR: trace() found in Sources/. Use Logger.<category> from os.Logger instead."
    ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo "Logging lint failed with $ERRORS violation(s)."
    echo "See docs/agents/debugging.md for the logging policy."
    exit 1
fi

echo "Logging lint passed."
