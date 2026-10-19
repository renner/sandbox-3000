oc() {
  local sock="$XDG_RUNTIME_DIR/agent-sandbox.sock"
  local rc

  # Start ssh-agent if nothing is listening on the socket
  SSH_AUTH_SOCK="$sock" ssh-add -l >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 2 ]; then
    rm -f "$sock"
    ssh-agent -a "$sock" >/dev/null
  fi

  # Make sure the signing key is loaded
  SSH_AUTH_SOCK="$sock" ssh-add -l >/dev/null 2>&1 || \
    SSH_AUTH_SOCK="$sock" ssh-add -c ~/.ssh/agent_sandbox

  podman run --rm -it \
    --userns=keep-id:uid=1000,gid=1000 \
    -v "$PWD":/work:Z \
    -v opencode-home:/home/agent \
    -v "$sock":/run/ssh-agent.sock \
    -e SSH_AUTH_SOCK=/run/ssh-agent.sock \
    --security-opt label=disable \
    --cap-drop=ALL --security-opt no-new-privileges \
    opencode-sandbox opencode "$@"
}

