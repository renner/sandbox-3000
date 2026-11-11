#!/usr/bin/env bash
# Install (or update, or remove) the Sandbox 3000 shell integration.
#
# Safe to run repeatedly: the function file is overwritten and the hook in the
# shell startup file is added only once.

set -euo pipefail

IMAGE="ghcr.io/renner/opencode-sandbox:latest"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/opencode-sandbox.sh"
DEST_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/shell"
DEST="$DEST_DIR/opencode-sandbox.sh"
RC_FILE="$HOME/.bashrc"
BEGIN_MARK="# >>> sandbox-3000 >>>"
END_MARK="# <<< sandbox-3000 <<<"

do_pull=1
do_uninstall=0

usage() {
  cat <<EOF
Usage: $0 [--no-pull] [--rc-file FILE] [--uninstall]

  --no-pull        do not pre-pull the container image
  --rc-file FILE   shell startup file to hook into (default: ~/.bashrc)
  --uninstall      remove the function file and the startup file hook
EOF
}

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

check_prerequisites() {
  local cmd
  for cmd in podman ssh-agent ssh-add; do
    command -v "$cmd" >/dev/null 2>&1 || warn "'$cmd' not found in PATH"
  done
  [ -n "${XDG_RUNTIME_DIR:-}" ] || \
    warn "XDG_RUNTIME_DIR is not set; oc() needs it for the ssh-agent socket"
}

install_function_file() {
  [ -f "$SRC" ] || die "cannot find $SRC"
  install -D -m 0644 "$SRC" "$DEST"
  say "installed $DEST"
}

hook_present() {
  [ -f "$RC_FILE" ] && grep -qF "$BEGIN_MARK" "$RC_FILE"
}

add_hook() {
  if hook_present; then
    say "hook already present in $RC_FILE"
    return
  fi
  {
    # Keep a blank line between existing content and our block.
    [ -s "$RC_FILE" ] && printf '\n'
    printf '%s\n' "$BEGIN_MARK"
    printf '%s\n' '[ -f "$HOME/.config/shell/opencode-sandbox.sh" ] && \'
    printf '%s\n' '  . "$HOME/.config/shell/opencode-sandbox.sh"'
    printf '%s\n' "$END_MARK"
  } >> "$RC_FILE"
  say "added hook to $RC_FILE"
}

remove_hook() {
  if ! hook_present; then
    say "no hook found in $RC_FILE"
    return
  fi
  local tmp
  tmp="$(mktemp)"
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { skip = 1; next }
    skip && $0 == e { skip = 0; next }
    !skip
  ' "$RC_FILE" > "$tmp"
  cat "$tmp" > "$RC_FILE"
  rm -f "$tmp"
  say "removed hook from $RC_FILE"
}

check_ssh_key() {
  if [ ! -f "$HOME/.ssh/agent_sandbox" ]; then
    say "note: ~/.ssh/agent_sandbox does not exist yet; create it with:"
    say "  ssh-keygen -t ed25519 -f ~/.ssh/agent_sandbox"
  fi
}

pull_image() {
  command -v podman >/dev/null 2>&1 || return 0
  say "pulling $IMAGE"
  podman pull -q "$IMAGE" >/dev/null || \
    warn "could not pull $IMAGE; oc() will retry on its next launch"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-pull) do_pull=0 ;;
    --uninstall) do_uninstall=1 ;;
    --rc-file)
      [ $# -ge 2 ] || die "--rc-file needs an argument"
      RC_FILE="$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

if [ "$do_uninstall" -eq 1 ]; then
  remove_hook
  rm -f "$DEST"
  say "removed $DEST"
  say "left the opencode-home volume and ~/.ssh/agent_sandbox untouched"
  exit 0
fi

check_prerequisites
install_function_file
add_hook
check_ssh_key
[ "$do_pull" -eq 1 ] && pull_image
say "done; open a new shell (or: . \"$DEST\") and run: oc"
