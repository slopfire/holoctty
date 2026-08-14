#!/usr/bin/env bash

set -euxo pipefail

old_pot=$(mktemp)
cp po/com.sfire.holoctty.pot "$old_pot"
zig build update-translations

# Compare previous POT to current POT
msgcmp "$old_pot" po/com.sfire.holoctty.pot --use-untranslated

# Compare all other POs to current POT
for f in po/*.po; do
  # Ignore untranslated entries
  msgcmp --use-untranslated "$f" po/com.sfire.holoctty.pot;
done
