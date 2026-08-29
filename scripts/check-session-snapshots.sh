#!/bin/sh
set -eu

zig build test -Dtest-filter='session snapshot'
zig build test -Dtest-filter='CLI process copies NUL separated foreground argv'
zig build test -Dtest-filter='startup input override reaches the shell verbatim'
zig build test -Dtest-filter='gtk session presentation options parse'
zig build -Demit-macos-app=false
