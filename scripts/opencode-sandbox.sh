# Default image to pull; overridden by OC_IMAGE env var, or --no-pull flag.
: "${OC_IMAGE:=ghcr.io/renner/opencode-sandbox:latest}"

oc() {
  local rc
  local -a podman_args=()
  local instance=""
  local instance_set=0
  local copy_from=""
  local copy_from_set=0
  local force=0

  # Parse oc's own options.
  local do_pull=1
  local image="$OC_IMAGE"
  # Repeat --podman-arg once per podman argument, e.g.:
  #   oc --podman-arg -p --podman-arg 4321:4321
  # Use -- to stop parsing and pass the remaining arguments to opencode.
  # --no-pull: skip the podman pull, use $image as-is (for local builds).
  # --instance NAME: use named instance for isolation
  # --copy-config-from [NAME]: copy config files from an instance; omit NAME for legacy default
  # --force: allow copying config to an existing volume (overwrites files)
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
        instance_set=1
        shift 2
        ;;
      --instance=*)
        instance="${1#*=}"
        instance_set=1
        shift
        ;;
      --copy-config-from)
        copy_from_set=1
        if [ $# -ge 2 ] && [[ "$2" != -* ]]; then
          copy_from="$2"
          shift 2
        else
          copy_from=""
          shift
        fi
        ;;
      --copy-config-from=*)
        copy_from="${1#*=}"
        copy_from_set=1
        shift
        ;;
      --force)
        force=1
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

  local sock volume container_name source_volume
  if [ "$instance_set" -eq 1 ]; then
    sock="$XDG_RUNTIME_DIR/agent-sandbox-${instance}.sock"
    volume="opencode-home-${instance}"
    container_name="opencode-sandbox-${instance}"
  else
    sock="$XDG_RUNTIME_DIR/agent-sandbox.sock"
    volume="opencode-home"
    container_name="opencode-sandbox"
  fi

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

  # Copy config from a template instance if requested
  if [ "$copy_from_set" -eq 1 ]; then
    # Determine source volume
    if [ -n "$copy_from" ]; then
      source_volume="opencode-home-${copy_from}"
    else
      source_volume="opencode-home"
    fi

    # Check source exists
    if ! podman volume inspect "$source_volume" >/dev/null 2>&1; then
      if [ -n "$copy_from" ]; then
        echo "oc: source instance '$copy_from' (volume $source_volume) does not exist" >&2
      else
        echo "oc: legacy source volume $source_volume does not exist" >&2
      fi
      return 1
    fi

    # Check if destination exists and requires --force
    local dest_exists=0
    if podman volume inspect "$volume" >/dev/null 2>&1; then
      dest_exists=1
      if [ "$force" -eq 0 ]; then
        echo "oc: volume $volume already exists; use --force to overwrite config files" >&2
        return 1
      fi
    fi

    # Determine what to copy
    local desc
    if [ -n "$copy_from" ]; then
      desc="instance '$copy_from'"
    else
      desc="legacy default"
    fi
    local target_desc
    if [ "$instance_set" -eq 1 ]; then
      target_desc="instance '${instance}'"
    else
      target_desc="legacy default"
    fi

    echo "oc: copying config files from $desc to $target_desc" >&2

    # Copy only specific config files
    podman run --rm -v "$source_volume":/src:ro -v "$volume":/dst "$image" sh -c '
      mkdir -p /dst/.config/opencode
      for f in .config/opencode/opencode.json .gitconfig .bash_history; do
        if [ -f "/src/$f" ]; then
          cp "/src/$f" "/dst/$f"
          echo "  copied: $f" >&2
        fi
      done
    '
  fi

  podman run --rm -it \
    "${podman_args[@]}" \
    ${extra[@]+"${extra[@]}"} \
    --name "$container_name" \
    --userns=keep-id:uid=1000,gid=1000 \
    -v "$PWD":/work:Z \
    -v "$volume":/home/agent \
    -v "$sock":/run/ssh-agent.sock \
    -e SSH_AUTH_SOCK=/run/ssh-agent.sock \
    --security-opt label=disable \
    --cap-drop=ALL --security-opt no-new-privileges \
    "$image" opencode "$@"
}
