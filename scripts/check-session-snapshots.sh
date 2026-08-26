#!/bin/sh
set -eu

zig build test -Dtest-filter='session snapshot'
zig build test -Dtest-filter='gtk session presentation options parse'
zig build -Demit-macos-app=false
