#!/bin/sh
cd "$(dirname "$0")/.." || exit 1
LUA=$(command -v lua5.4 || echo /usr/local/opt/lua@5.4/bin/lua5.4)
exec "$LUA" tests/run.lua "$@"
