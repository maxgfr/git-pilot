#!/bin/bash

# Semantic Release Hook - Update version in script.sh
# This script is called by semantic-release to update the VERSION in script.sh
# and to keep the copy bundled with the agent skill identical.

set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Error: Version number required" >&2
  exit 1
fi

NEW_VERSION="$1"
SKILL_SCRIPT="skills/git-pilot/scripts/git-pilot.sh"

# The version is pasted into a sed replacement: accept version characters only.
case "$NEW_VERSION" in
  *[!0-9A-Za-z.+-]*)
    echo "Error: invalid version: $NEW_VERSION" >&2
    exit 1
    ;;
esac

# Update VERSION in script.sh, and make sure the line was really there
sed -i.bak "s/^VERSION=\".*\"/VERSION=\"$NEW_VERSION\"/" script.sh
rm script.sh.bak
if ! grep -qxF "VERSION=\"$NEW_VERSION\"" script.sh; then
  echo "Error: no VERSION line to update in script.sh" >&2
  exit 1
fi

# Sync the bundled skill script
cp script.sh "$SKILL_SCRIPT"
chmod +x "$SKILL_SCRIPT"

echo "Updated script.sh and $SKILL_SCRIPT to version $NEW_VERSION"
