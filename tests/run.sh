#!/bin/sh
# Run every test suite from the project root: plain-Lua suites under both
# LuaJIT (what LÖVE uses) and Lua 5.1, then the headless LÖVE simulation suite.
#   sh tests/run.sh
cd "$(dirname "$0")/.." || exit 1
status=0
for suite in physics sandbox json; do
    for lua in luajit lua; do
        if command -v "$lua" >/dev/null 2>&1; then
            printf '%-8s %-7s ' "$suite" "$lua"
            "$lua" "tests/${suite}_test.lua" > /tmp/kusogaki_test_$$.log 2>&1 || status=1
            tail -n 1 /tmp/kusogaki_test_$$.log
        fi
    done
done
love=$(command -v love2d || command -v love)
if [ -n "$love" ]; then
    printf '%-16s ' "sim (love)"
    "$love" . --sim-test > /tmp/kusogaki_test_$$.log 2>&1 || status=1
    tail -n 1 /tmp/kusogaki_test_$$.log
fi
grep -h "^FAIL" /tmp/kusogaki_test_$$.log 2>/dev/null
rm -f /tmp/kusogaki_test_$$.log
exit $status
