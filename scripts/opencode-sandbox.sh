# Default image to pull; overridden by OC_IMAGE env var, or --no-pull flag.
: "${OC_IMAGE:=ghcr.io/renner/opencode-sandbox:latest}"

oc() {
  local sock="$XDG_RUNTIME_DIR/agent-sandbox.sock"
  local rc
  local -a podman_args=()
  local instance="default"
  local copy_from=""

  # Parse oc's own options.
  local do_pull=1
  local image="$OC_IMAGE"
  # Repeat --podman-arg once per podman argument, e.g.:
  #   oc --podman-arg -p --podman-arg 4321:4321
  # Use -- to stop parsing and pass the remaining arguments to opencode.
  # --no-pull: skip the podman pull, use $image as-is (for local builds).
  # --instance NAME: use named instance for isolation (default: "default")
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
      --no-pull)
        do_pull=0
        shift
        ;;
      --instance)
        if [ $# -lt 2 ]; then
          echo "oc: --instance needs a value" >&2
          return 2
        fi
        instance="$2"
        shift 2
        ;;
      --instance=*)
        instance="${1#*=}"
        shift
        ;;
      --copy-config-from)
        if [ $# -lt 2 ]; then
          echo "oc: --copy-config-from needs a value" >&2
          return 2
        fi
        copy_from="$2"
        shift 2
        ;;
      --copy-config-from=*)
        copy_from="${1#*=}"
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

  # Instance-specific socket path
  sock="$XDG_RUNTIME_DIR/agent-sandbox-${instance}.sock"

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

  # Pull the image unless --no-pull was specified. If the pull fails (e.g.
  # offline), fall back to whatever copy is already present locally.
  if [ "$do_pull" -eq 1 ]; then
    podman pull -q "$image" >/dev/null || \
      echo "oc: could not pull $image, using the local copy if present" >&2
  fi

  # Pass every podman secret named oc_env_<VAR> into the container as $VAR
  # (see README); without any, start as usual.
  local -a extra=()
  local name
  while IFS= read -r name; do
    case $name in
      oc_env_?*) extra+=(--secret "$name,type=env,target=${name#oc_env_}") ;;
    esac
  done < <(podman secret ls --format '{{.Name}}' 2>/dev/null)

  # Copy config from a template instance if requested and the new instance's volume doesn't exist yet
  if [ -n "$copy_from" ] && ! podman volume inspect "opencode-home-${instance}" >/dev/null 2>&1; then
    echo "oc: copying config from instance '$copy_from' to '$instance'" >&2
    podman run --rm -v "opencode-home-${copy_from}":/src:ro -v "opencode-home-${instance}":/dst "$image" sh -c "cp -r /src/. /dst/ 2>/dev/null || true"
  fi

  podman run --rm -it \
    "${podman_args[@]}" \
    ${extra[@]+"${extra[@]}"} \
    --name "opencode-sandbox-${instance}" \
    --userns=keep-id:uid=1000,gid=1000 \
    -v "$PWD":/work:Z \
    -v "opencode-home-${instance}":/home/agent \
    -v "$sock":/run/ssh-agent.sock \
    -e SSH_AUTH_SOCK=/run/ssh-agent.sock \
    --security-opt label=disable \
    --cap-drop=ALL --security-opt no-new-privileges \
    "$image" opencode "$@"
}

