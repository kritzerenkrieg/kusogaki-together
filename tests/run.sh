#!/bin/sh
# Run every test suite from the project root: plain-Lua suites under both
# LuaJIT (what LÖVE uses) and Lua 5.1, the rendezvous server's Go tests, then
# the headless LÖVE simulation suite (with that server running for the
# internet play checks, when Go is installed).
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
server=""
if command -v go >/dev/null 2>&1; then
    printf '%-16s ' "server (go)"
    if (cd server && go vet ./... && go test -count=1 ./...) > /tmp/kusogaki_go_$$.log 2>&1; then
        echo "all server checks passed"
        if (cd server && go build -o /tmp/kusogaki_server_$$ ./cmd/kusogaki-server) >> /tmp/kusogaki_go_$$.log 2>&1; then
            /tmp/kusogaki_server_$$ -addr 127.0.0.1:26988 -relay-ports 27100-27199 > /dev/null 2>&1 &
            server=$!
            export KUSOGAKI_SERVER=127.0.0.1:26988
        fi
    else
        status=1
        echo "FAIL"
        cat /tmp/kusogaki_go_$$.log
    fi
    rm -f /tmp/kusogaki_go_$$.log
fi
love=$(command -v love2d || command -v love)
if [ -n "$love" ]; then
    printf '%-16s ' "sim (love)"
    "$love" . --sim-test > /tmp/kusogaki_test_$$.log 2>&1 || status=1
    tail -n 1 /tmp/kusogaki_test_$$.log
    grep -h "^skip" /tmp/kusogaki_test_$$.log
fi
if [ -n "$server" ]; then
    kill "$server" 2>/dev/null
    rm -f /tmp/kusogaki_server_$$
fi
grep -h "^FAIL" /tmp/kusogaki_test_$$.log 2>/dev/null
rm -f /tmp/kusogaki_test_$$.log
exit $status
