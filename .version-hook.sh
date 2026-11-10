#!/bin/bash

# Semantic Release Hook - Update version in script.sh
# This script is called by semantic-release to update the VERSION in script.sh
# and to keep the copy bundled with the agent skill identical.

if [ -z "$1" ]; then
  echo "Error: Version number required"
  exit 1
fi

NEW_VERSION="$1"
SKILL_SCRIPT="skills/git-pilot/scripts/git-pilot.sh"

# Update VERSION in script.sh
sed -i.bak "s/^VERSION=\".*\"/VERSION=\"$NEW_VERSION\"/" script.sh && rm script.sh.bak

# Sync the bundled skill script
cp script.sh "$SKILL_SCRIPT"
chmod +x "$SKILL_SCRIPT"

echo "Updated script.sh and $SKILL_SCRIPT to version $NEW_VERSION"
