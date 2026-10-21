# Sandbox 3000

**Sandbox 3000** is a small [podman](https://podman.io) setup for running
[opencode](https://opencode.ai) in a throwaway container. The directory you
launch it from is mounted at `/work`, and your host SSH agent is forwarded in,
so commits can be signed without private keys ever entering the container.

## Contents

| File | Purpose |
| --- | --- |
| `Containerfile` | Builds the `opencode-sandbox` image |
| `opencode-sandbox.sh` | Defines the `oc()` shell function that launches it |

## Requirements

- `podman`
- A private SSH key at `~/.ssh/agent_sandbox` on the host (see [SSH keys](#ssh-keys))
- `XDG_RUNTIME_DIR` set — already the case on systemd systems
  (`/run/user/$(id -u)`)
- SELinux hosts are supported: the script relabels the project directory with
  `:Z` and disables the container label for the forwarded agent socket

## Build

From the repository root:

```sh
podman build -t opencode-sandbox .
```

The image is openSUSE Tumbleweed with `git`, `ripgrep`, `curl`, `tar`, `gzip`,
`openssh-clients` and `opencode` installed. It runs as an unprivileged `agent`
user (uid 1000) with `/work` as the working directory.

The image name `opencode-sandbox` is hard-coded at the end of `oc()`, so if you
build under another name, update the script to match.

## Install the shell integration

`opencode-sandbox.sh` only *defines* a function, so it has to be **sourced**;
running it as a script does nothing.

```sh
mkdir -p ~/.config/shell
install -m 0644 opencode-sandbox.sh ~/.config/shell/opencode-sandbox.sh
```

Now add this line to your shell's startup file:

```sh
[ -f "$HOME/.config/shell/opencode-sandbox.sh" ] && \
  . "$HOME/.config/shell/opencode-sandbox.sh"
```

Which file that is depends on how your shells start:

| Shell | Startup file |
| --- | --- |
| Interactive bash (a terminal window) | `~/.bashrc` |
| Login shells | `~/.profile` (or `~/.bash_profile` if present) |

For bash, `~/.bashrc` alone is usually enough: login shells read
`~/.bash_profile`, `~/.bash_login` or `~/.profile` — whichever exists first —
and most distributions' default `.profile` sources `~/.bashrc`. Put the line in
one file only; sourcing it twice works, but just redefines the same function.

The function uses `local`, so source it from bash (or another shell that
supports `local`) rather than a strict POSIX `sh`.

## Usage

```sh
cd ~/src/some-project
oc
```

`oc` mounts the **current directory** at `/work` and runs `opencode` there.
Because the path is taken from `$PWD` at launch time, always `cd` to the project
you want to work on before calling `oc`. Extra arguments are passed through to
opencode:

```sh
oc --help
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
