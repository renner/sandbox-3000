# Sandbox 3000

**Sandbox 3000** is a small [podman](https://podman.io) setup for running
[opencode](https://opencode.ai) in a throwaway container. The directory you
launch it from is mounted at `/work`, and your host SSH agent is forwarded in,
so commits can be signed without private keys ever entering the container.

## Quick start

```sh
./scripts/install.sh
cd ~/src/some-project
oc
```

That's it. `oc` launches opencode in a sandbox with your SSH agent available.

## Requirements

- `podman` (≥ 3.2 for podman secrets)
- `XDG_RUNTIME_DIR` set — already the case on systemd systems (`/run/user/$(id -u)`)
- A private SSH key at `~/.ssh/agent_sandbox` on the host is **recommended** (see [SSH keys](#ssh-keys))
- SELinux hosts are supported: the script relabels the project directory with `:Z`

## Install the shell integration

`scripts/opencode-sandbox.sh` only *defines* a function, so it has to be
**sourced**; running it as a script does nothing. `scripts/install.sh` takes
care of that:

```sh
./scripts/install.sh
```

It copies `scripts/opencode-sandbox.sh` to `~/.config/shell/`, adds a marked block to
`~/.bashrc` that sources it, and reminds you if `~/.ssh/agent_sandbox` is missing.
Open a new shell afterwards.

The script is safe to re-run. Running it again after a `git pull` updates the
installed function, and the `~/.bashrc` block is never added twice.

| Option | Effect |
| --- | --- |
| `--no-pull` | Skip pre-pulling the image |
| `--rc-file FILE` | Hook into `FILE` instead of `~/.bashrc` |
| `--uninstall` | Remove the function file and the `~/.bashrc` block |

`--uninstall` leaves the `opencode-home` volume and your SSH key alone.

### Manual install

To do it by hand, copy the file and add this line to your shell's startup file:

```sh
install -D -m 0644 scripts/opencode-sandbox.sh ~/.config/shell/opencode-sandbox.sh

[ -f "$HOME/.config/shell/opencode-sandbox.sh" ] && \
  . "$HOME/.config/shell/opencode-sandbox.sh"
```

Which startup file that is depends on how your shells start:

| Shell | Startup file |
| --- | --- |
| Interactive bash (a terminal window) | `~/.bashrc` |
| Login shells | `~/.profile` (or `~/.bash_profile` if present) |

For bash, `~/.bashrc` alone is usually enough: login shells read
`~/.bash_profile`, `~/.bash_login` or `~/.profile` — whichever exists first —
and most distributions' default `.profile` sources `~/.bashrc`. Put the line in
one file only; sourcing it twice works, but just redefines the same function.

The function uses `local`, so source it from bash or zsh rather than a strict
POSIX `sh`.

## Usage

```sh
cd ~/src/some-project
oc
```

`oc` mounts the **current directory** at `/work` and runs opencode there.

### Running multiple instances

By default (no `--instance`), `oc` uses the legacy unsuffixed resources:
- SSH agent socket: `$XDG_RUNTIME_DIR/agent-sandbox.sock`
- Named volume: `opencode-home`
- Container name: `opencode-sandbox`

To run isolated instances (e.g., for different projects simultaneously), use
`--instance NAME`:

```sh
oc --instance project1
oc --instance project2
```

Each explicitly named instance gets:
- Its own SSH agent socket: `$XDG_RUNTIME_DIR/agent-sandbox-NAME.sock`
- Its own named volume: `opencode-home-NAME`
- Its own container name: `opencode-sandbox-NAME`

`--instance default` is treated as an explicit instance name and uses the
suffixed `*-default` resources; it does **not** refer to the legacy unsuffixed
default.

Because the path is taken from `$PWD` at launch time, always `cd` to the project
you want to work on before calling `oc`. Extra arguments are passed through to
opencode:

```sh
oc --help
```

### Copying config from a template instance

When creating a new instance, you can copy the home directory from an existing
instance using `--copy-config-from`. This is useful for setting up a new
project with a known-good configuration:

```sh
# Copy from the legacy unsuffixed default (opencode-home)
oc --instance newproject --copy-config-from

# Copy from an explicit named instance
oc --instance newproject --copy-config-from baseconfig
```

If a name is provided, it must refer to an existing explicit instance volume
(e.g. `--copy-config-from default` requires `opencode-home-default`; it does
not fall back to the legacy `opencode-home`). If the source volume does not
exist, `oc` exits with an error.

The copy only happens if the new instance's volume doesn't already exist, so
running the same command again won't overwrite existing configuration.

The copy is performed with a one-time container run that copies all files from
the source instance's home directory to the new instance's home directory. The
source volume is mounted read-only for safety.

| Option | Effect |
| --- | --- |
| `--no-pull` | Skip pre-pulling the image |
| `--instance NAME` | Use an explicitly named instance for isolation |
| `--copy-config-from [NAME]` | Copy home directory on first launch; omit NAME to copy from the legacy unsuffixed default |

### Passing options to podman

`oc` consumes its own `--podman-arg` options and forwards each value to
`podman run`; all other arguments still go to opencode. Repeat the option once
per podman argument, for example to publish a dev server's port:

```sh
oc --podman-arg -p --podman-arg 4321:4321
```

The `--podman-arg=VALUE` form works too. Use `--` to stop parsing if an
opencode argument itself starts with `--podman-arg`. A dev server started
inside the container has to listen on `0.0.0.0` (not only `127.0.0.1`) for the
published port to be reachable from the host.

### Override the container image

`oc` pulls `ghcr.io/renner/opencode-sandbox:latest` on every launch. To use a
different image, set `OC_IMAGE` before launching `oc`:

```sh
OC_IMAGE=my-registry/opencode-sandbox:dev oc
```

To skip the pull entirely (for example when testing a local build), use
`--no-pull`:

```sh
./scripts/install.sh --no-pull   # skip pre-pull during install
podman build -t ghcr.io/renner/opencode-sandbox:latest .
oc --no-pull             # use the local image without pulling
```

## SSH keys

The private key never enters the container. Instead, `oc()`:

1. Uses an agent socket at `$XDG_RUNTIME_DIR/agent-sandbox.sock`.
2. Checks whether an agent is listening there with `ssh-add -l`. Exit status `2`
   means nothing is listening.
3. If nothing is listening, removes the stale socket file and starts
   `ssh-agent -a "$sock"`.
4. If the agent holds no identities, loads `~/.ssh/agent_sandbox` with
   `ssh-add -c`, so **every use of the key is confirmed on the host**.
5. Bind-mounts the socket into the container at `/run/ssh-agent.sock` and sets
   `SSH_AUTH_SOCK`, so `git` and `ssh` inside the container talk to the host
   agent.

What it expects:

- the private key file `~/.ssh/agent_sandbox` exists on the host
- `XDG_RUNTIME_DIR` is set; if it is empty the socket path degrades to
  `/agent-sandbox.sock`, which `ssh-agent` cannot create
- the same key is registered on GitHub as an **authentication** key if you push
  over SSH, and as a **signing** key if you sign commits

### Verify the installation

After installing, verify the function is available:

```sh
type oc
# should print: oc is a function
```

### Commit signing inside the container

The container has no key files, so `user.signingkey` has to be the public key
itself rather than a path:

```sh
git config --global gpg.format ssh
git config --global user.signingkey "key::$(ssh-add -L | head -1)"
git config --global commit.gpgsign true
```

Run this inside the sandbox. `~/.gitconfig` there lives in the `opencode-home`
volume, so it survives restarts.

## API keys

Store provider API keys (for example `PROVIDER_API_KEY`) as
[podman secrets](https://docs.podman.io/en/latest/markdown/podman-secret-create.1.html)
on the host. Every secret named `oc_env_<VAR>` is passed into the container by
`oc()` as the environment variable `<VAR>`:

```sh
./scripts/set-podman-secret.sh PROVIDER_API_KEY
```

The script prompts for the value without echoing it, creates or replaces the
secret `oc_env_PROVIDER_API_KEY`, and prints the matching row from
`podman secret ls`. It needs a podman with `secret create --replace` (4.x or
newer). For automation, pipe the value in instead:

```sh
printf '%s' "$PROVIDER_API_KEY" | ./scripts/set-podman-secret.sh PROVIDER_API_KEY
```

Without any such secret, `oc` starts as usual. The keys are not written to the
image, the `opencode-home` volume, your shell startup files or `podman inspect`
output. To rotate one, run the script again with the same name:

```sh
./scripts/set-podman-secret.sh PROVIDER_API_KEY
```

To see what is configured, or to remove a key entirely:

```sh
podman secret ls
podman secret rm oc_env_PROVIDER_API_KEY
```

Reference the variables from opencode's config (`~/.config/opencode/opencode.json`
inside the container, which lives in the `opencode-home` volume) as
`{env:PROVIDER_API_KEY}` rather than pasting the key into the file.

The secrets protect the keys from image layers, the `opencode-home` volume, and
shell history — but not from processes running inside the container. Use
dedicated keys with spend limits.

## What persists

- `/work` — the directory you launched `oc` from, bind-mounted read-write.
- `/home/agent` — the named volume `opencode-home`; holds opencode config, git
  config and shell history.
- Everything else lives in the container's writable layer and is discarded when
  it exits, because the container runs with `--rm`.

## Container hardening

The container is started with `--cap-drop=ALL` and
`--security-opt no-new-privileges`, and runs as the unprivileged `agent` user.
Private keys stay on the host; only the agent socket is shared. Note that the
project directory is mounted read-write.

## Repository layout

| File | Purpose |
| --- | --- |
| `Containerfile` | Builds the `opencode-sandbox` image |
| `scripts/opencode-sandbox.sh` | Defines the `oc()` shell function that launches it (supports `--instance` for multiple instances) |
| `scripts/install.sh` | Installs, updates or removes the shell integration |
| `scripts/set-podman-secret.sh` | Creates or rotates an `oc_env_<VAR>` podman secret |
| `LICENSE` | MIT license |
| `.github/workflows/build.yml` | GitHub Actions workflow to build and push the image |

## Building locally

If you need a local build, run:

```sh
podman build -t opencode-sandbox .
```

The image is openSUSE Tumbleweed with `git`, `ripgrep`, `curl`, `tar`, `gzip`,
`openssh-clients`, `opencode` and a set of common agent tools installed: shell
utilities (`findutils`, `diffutils`, `patch`, `file`, `which`, `gawk`, `less`),
JSON/YAML processing (`jq`, `yq`), archive support (`unzip`, `zip`, `bzip2`,
`zstd`), navigation and inspection (`tree`, `fd`, `sqlite3`), process and
network debugging (`lsof`, `iproute2`, `psmisc`, `socat`), `rsync`, and the
agent workflow tools `gh`, `ast-grep`, `ShellCheck`, `shfmt`, `just` and
`git-delta`. It runs as an unprivileged `agent` user (uid 1000) with `/work` as
the working directory.

`oc` defaults to pulling `ghcr.io/renner/opencode-sandbox:latest` from GHCR,
which the GitHub Actions workflow publishes on pushes to `main`. If the pull
fails, it falls back to whatever copy is already present locally. To use a
locally built image, either tag it as `ghcr.io/renner/opencode-sandbox:latest`
or use `oc --no-pull`.

## Troubleshooting

- **`XDG_RUNTIME_DIR` not set**: the ssh-agent socket won't be created. Set it
  or run on a systemd system.
- **Nothing listening on agent socket**: `oc()` restarts `ssh-agent`; if it
  still fails, verify `~/.ssh/agent_sandbox` exists.
- **Port unreachable**: a dev server inside the container must bind to
  `0.0.0.0` (not `127.0.0.1`) for `--podman-arg -p` to work.
- **Offline / no pull**: `oc` falls back to a local image copy if the pull fails.
- **SELinux**: the `:Z` option relabels the project directory for the container.

## License

MIT license — see `LICENSE` for details.
