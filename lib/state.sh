#!/usr/bin/env bash
# state.sh - tiny key=value state store so a partial `create` is still
# fully destroyable. File lives at state/<cluster>.state (git-ignored, 0600).

state_init() {
  mkdir -p "$STATE_DIR" "$CLUSTER_DIR"
  chmod 700 "$STATE_DIR"
  [[ -f "$STATE_FILE" ]] || { : > "$STATE_FILE"; chmod 600 "$STATE_FILE"; }
}

# state_set <key> <value>
state_set() {
  state_init
  local key="$1"; shift
  local val="$*"
  # Remove any existing line for this key, then append.
  if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
    grep -v "^${key}=" "$STATE_FILE" > "${STATE_FILE}.tmp" || true
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
  fi
  printf '%s=%s\n' "$key" "$val" >> "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

# state_get <key> -> prints value (empty if unset)
state_get() {
  [[ -f "$STATE_FILE" ]] || return 0
  local line
  line="$(grep -m1 "^${1}=" "$STATE_FILE" 2>/dev/null)" || return 0
  echo "${line#*=}"
}

state_has() { [[ -n "$(state_get "$1")" ]]; }

state_wipe() { rm -f "$STATE_FILE"; }
