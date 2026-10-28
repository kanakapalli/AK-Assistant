#!/bin/bash
# Makes this Mac look like Duck Keyboard was never installed, so you can install it again and
# go through onboarding: quits it, deletes the app, resets every macOS permission it was given,
# and removes its settings, history, meetings and downloaded models.
#
#   ./reset-to-fresh-install.sh                 full reset (models are downloaded again in onboarding)
#   ./reset-to-fresh-install.sh --keep-models   same, but keep the downloaded speech models
#
# Shared Hugging Face downloads (~/.cache/huggingface, also used by other tools) are left alone;
# the script prints how to remove them if you want.
set -uo pipefail

BUNDLE_ID="com.natfirst.akassistant"
KEEP_MODELS=false
[[ "${1:-}" == "--keep-models" ]] && KEEP_MODELS=true
SUPPORT="$HOME/Library/Application Support"

say() { printf '\n▸ %s\n' "$1"; }
remove() { for p in "$@"; do if [[ -e "$p" ]]; then rm -rf "$p" && echo "  removed $p"; fi; done; }

say "Quitting Duck Keyboard"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1
sleep 1
pkill -x "Duck Keyboard" 2>/dev/null; pkill -x "AKAssistant" 2>/dev/null
sleep 1

say "Turning off launch at login"
osascript -e 'tell application "System Events" to delete (every login item whose name is "Duck Keyboard" or name is "AKAssistant")' >/dev/null 2>&1 || true

say "Deleting the app"
remove "/Applications/Duck Keyboard.app" "/Applications/AKAssistant.app" \
       "$HOME/Applications/Duck Keyboard.app" "$HOME/Applications/AKAssistant.app"

say "Resetting permissions (Microphone, Accessibility, Input Monitoring, Screen & System Audio Recording, Automation)"
tccutil reset All "$BUNDLE_ID"

say "Removing settings (this also brings onboarding back)"
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 && echo "  removed preferences"
remove "$HOME/Library/Preferences/$BUNDLE_ID.plist"

say "Removing history, meetings and caches"
# History uses SwiftData's default store; meetings and the search index live in the app's folder.
remove "$SUPPORT/default.store" "$SUPPORT/default.store-shm" "$SUPPORT/default.store-wal"
remove "$SUPPORT/AK Assistant/Meetings" "$SUPPORT/AK Assistant/Meetings.store" \
       "$SUPPORT/AK Assistant/Meetings.store-shm" "$SUPPORT/AK Assistant/Meetings.store-wal" \
       "$SUPPORT/AK Assistant/Index.store" "$SUPPORT/AK Assistant/Index.store-shm" "$SUPPORT/AK Assistant/Index.store-wal"
remove "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
       "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"

if $KEEP_MODELS; then
  say "Keeping downloaded speech models (--keep-models)"
else
  say "Removing downloaded speech models"
  remove "$SUPPORT/AK Assistant" "$SUPPORT/FluidAudio"
fi

HF="$HOME/.cache/huggingface"
if [[ -d "$HF" ]]; then
  say "Left alone: Hugging Face cache ($(du -sh "$HF" 2>/dev/null | cut -f1)) with the AI / embedding models"
  echo "  It's shared with other tools. To delete it too:  rm -rf ~/.cache/huggingface"
fi

say "Done. Duck Keyboard is gone from this Mac."
echo "  Install it again from the DMG (or run it from Xcode) to see onboarding."
echo "  Tip: if an old entry still shows in System Settings › Privacy & Security, it disappears after a restart."
