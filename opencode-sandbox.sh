oc() {
  local sock="$XDG_RUNTIME_DIR/agent-sandbox.sock"
  local rc
  local -a podman_args=()

  # Pull out oc's own options; everything else is passed on to opencode.
  # Repeat --podman-arg once per podman argument, e.g.:
  #   oc --podman-arg -p --podman-arg 4321:4321
  # Use -- to stop parsing and pass the remaining arguments to opencode.
  while [ $# -gt 0 ]; do
    case "$1" in
      --podman-arg)
        if [ $# -lt 2 ]; then
          echo "oc: --podman-arg needs a value" >&2
          return 2
        fi
        podman_args+=("$2")
        shift 2
        ;;
      --podman-arg=*)
        podman_args+=("${1#*=}")
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

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

  # Always start from the latest published image; if the pull fails (e.g.
  # offline), fall back to whatever copy is already present locally.
  local image="ghcr.io/renner/opencode-sandbox:latest"
  podman pull -q "$image" >/dev/null || \
    echo "oc: could not pull $image, using the local copy if present" >&2

  podman run --rm -it \
    "${podman_args[@]}" \
    --userns=keep-id:uid=1000,gid=1000 \
    -v "$PWD":/work:Z \
    -v opencode-home:/home/agent \
    -v "$sock":/run/ssh-agent.sock \
    -e SSH_AUTH_SOCK=/run/ssh-agent.sock \
    --security-opt label=disable \
    --cap-drop=ALL --security-opt no-new-privileges \
    "$image" opencode "$@"
}

