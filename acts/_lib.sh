#!/usr/bin/env bash
# Shared setup for the Harborlight acts. Source this file; do not execute it.
#
# Every value that looks like a secret in these scripts is a dummy value.
# Do NOT replace any of them with a real secret.

set -euo pipefail

HARBORLIGHT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI_MODE="${OPAQUE_QUICKSTART_CI:-0}"

# Echo-then-execute helper so the transcript documents itself.
run() { echo "\$ $*"; "$@"; echo; }

say() { printf '\n═══ %s ═══\n\n' "$1"; }

need_opaque() {
  local bin
  for bin in opaque opaqued; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "error: $bin not found on PATH" >&2
      echo "install it with: brew install opaque-dev/tap/opaque" >&2
      exit 1
    fi
  done
}

harborlight_cleanup() {
  if [[ -n "${OPAQUED_PID:-}" ]]; then
    kill "$OPAQUED_PID" >/dev/null 2>&1 || true
    wait "$OPAQUED_PID" >/dev/null 2>&1 || true
    OPAQUED_PID=""
  fi
  # Act 5 runs its own task daemon, mock provider, and (featured path) a real
  # Vault dev server in a second throwaway directory. Tear those down too.
  local pid
  for pid in "${ACT5_DAEMON_PID:-}" "${ACT5_MOCK_PID:-}" "${ACT5_VAULT_PID:-}"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
    fi
  done
  ACT5_DAEMON_PID=""; ACT5_MOCK_PID=""; ACT5_VAULT_PID=""
  # CI keeps the daemon log for diagnosis; the throwaway HOME is still removed.
  if [[ -n "${HARBORLIGHT_LOG_COPY:-}" && -f "${HARBORLIGHT_DIR:-}/logs/opaqued.log" ]]; then
    cp "$HARBORLIGHT_DIR/logs/opaqued.log" "$HARBORLIGHT_LOG_COPY" >/dev/null 2>&1 || true
  fi
  if [[ "${HARBORLIGHT_KEEP:-0}" != "1" ]]; then
    if [[ -n "${HARBORLIGHT_DIR:-}" ]]; then rm -rf "$HARBORLIGHT_DIR" >/dev/null 2>&1 || true; fi
    if [[ -n "${ACT5_DIR:-}" ]]; then rm -rf "$ACT5_DIR" >/dev/null 2>&1 || true; fi
  fi
}

harborlight_env() {
  # Reuse an environment prepared by quickstart.sh; otherwise create one.
  if [[ -n "${HARBORLIGHT_DIR:-}" ]]; then return; fi
  HARBORLIGHT_DIR="$(mktemp -d /private/tmp/harborlight.XXXXXX 2>/dev/null || mktemp -d /tmp/harborlight.XXXXXX)"
  OPAQUED_PID=""
  trap harborlight_cleanup EXIT

  # Use a throwaway state directory so we do not touch ~/.opaque or any real secrets.
  export HOME="$HARBORLIGHT_DIR/home"
  export XDG_RUNTIME_DIR="$HARBORLIGHT_DIR/xdg"
  mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$HARBORLIGHT_DIR/logs"
  chmod 700 "$HOME" "$XDG_RUNTIME_DIR" >/dev/null 2>&1 || true
}

ci_banner() {
  cat <<'EOF'
┌────────────────────────────────────────────────────────────────────────┐
│ CI MODE: approvals are synthetic.                                      │
│                                                                        │
│ This run appends approval_backend = "insecure_auto_approve" to the     │
│ config and sets OPAQUE_INSECURE_AUTO_APPROVE=1. The daemon will        │
│ approve every request without a human. It announces this with an       │
│ error-level audit event, and every approval is attributed to the       │
│ synthetic approver "insecure-auto-approve" in the audit record.        │
│                                                                        │
│ This mode exists for learning and CI. Never use it in production.      │
└────────────────────────────────────────────────────────────────────────┘
EOF
}

ensure_initialized() {
  if [[ -f "$HOME/.opaque/config.toml" ]]; then return; fi
  run opaque init --preset github-secrets

  # Top-level daemon keys must sit above the preset's [[rules]] tables, so they
  # are prepended, not appended. data_dir pins all state to this throwaway HOME
  # and scopes seal verification to it. Without it the daemon consults the OS
  # keychain, where a real Opaque installation on this machine may hold a
  # config seal that this throwaway config cannot satisfy.
  local toplevel
  toplevel="data_dir = \"$HOME/.opaque\""
  if [[ "$CI_MODE" == "1" ]]; then
    ci_banner
    toplevel="$toplevel"$'\n''approval_backend = "insecure_auto_approve"'
    export OPAQUE_INSECURE_AUTO_APPROVE=1
  fi
  # shellcheck disable=SC2016  # banner prints literally; expansion is the bug class we avoid
  echo '$ edit "$HOME/.opaque/config.toml"   # prepend data_dir (and, in CI, the insecure backend)'
  printf '%s\n\n' "$toplevel" | cat - "$HOME/.opaque/config.toml" > "$HOME/.opaque/config.toml.new"
  mv "$HOME/.opaque/config.toml.new" "$HOME/.opaque/config.toml"
  echo

  # shellcheck disable=SC2016  # banner prints literally; expansion is the bug class we avoid
  echo '$ cat policy/harborlight-extras.toml >> "$HOME/.opaque/config.toml"'
  cat "$HARBORLIGHT_REPO/policy/harborlight-extras.toml" >> "$HOME/.opaque/config.toml"
  echo

  # Install the analyst sandbox profile with this checkout's path filled in.
  # The platform sandbox stays on: seatbelt on macOS, bubblewrap (or unshare)
  # with Landlock and seccomp on Linux. The daemon names the strategy it used
  # in the sandbox.created audit row, and Act 3 reads that row back.
  mkdir -p "$HOME/.opaque/profiles"
  sed "s|__REPO_DIR__|$HARBORLIGHT_REPO|" \
    "$HARBORLIGHT_REPO/profiles/analyst.toml" > "$HOME/.opaque/profiles/analyst.toml"

  run opaque policy check
}

# Resolve a concrete python3 for the sandbox. The /usr/bin/python3 shim on
# macOS asks xcrun to locate an interpreter, and xcrun cannot write its cache
# under the sandbox. The resolved binary runs fine.
resolve_analyst_python() {
  if [[ "$(uname)" == "Darwin" ]] && command -v xcrun >/dev/null 2>&1; then
    if xcrun --find python3 2>/dev/null; then return; fi
  fi
  python3 -c 'import sys; print(sys.executable)'
}

start_daemon() {
  if [[ -n "${OPAQUED_PID:-}" ]]; then return; fi

  # The dummy source value is given to the daemon only. Your shell and the
  # CLI do not carry it; the analyst profile maps it in by reference.
  # Do NOT replace with a real secret.
  echo "\$ opaqued   # started in the background; log: $HARBORLIGHT_DIR/logs/opaqued.log"
  OPAQUE_DEMO_VALUE_SRC="demo_value_123456" RUST_LOG=info \
    opaqued >"$HARBORLIGHT_DIR/logs/opaqued.log" 2>&1 &
  OPAQUED_PID=$!
  echo

  # With data_dir set, the daemon serves data_dir/run/opaqued.sock and writes
  # the daemon token beside it.
  local sock="$HOME/.opaque/run/opaqued.sock"
  local token="$HOME/.opaque/run/daemon.token"
  for _ in $(seq 1 200); do
    if [[ -S "$sock" && -f "$token" ]]; then break; fi
    sleep 0.05
  done
  if [[ ! -S "$sock" ]]; then
    echo "error: opaqued did not start; log follows" >&2
    cat "$HARBORLIGHT_DIR/logs/opaqued.log" >&2
    exit 1
  fi

  # Pin the CLI to this daemon's socket. Without this, a machine that also
  # runs a system daemon at /run/opaque/opaqued.sock could answer instead.
  export OPAQUE_SOCK="$sock"
}

stop_daemon() {
  if [[ -z "${OPAQUED_PID:-}" ]]; then return; fi
  # shellcheck disable=SC2016  # banner prints literally; expansion is the bug class we avoid
  echo '$ kill $OPAQUED_PID   # stop the daemon before tampering with its database'
  kill "$OPAQUED_PID" >/dev/null 2>&1 || true
  wait "$OPAQUED_PID" >/dev/null 2>&1 || true
  OPAQUED_PID=""
  echo
}
