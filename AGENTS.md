# AGENTS.md

This repo is the nix-darwin configuration for a single headless machine: a
MacBook Pro serving Ollama to the homelab over Tailscale. See the
[README](./README.md) for architecture, setup and operations.

## Ground rules

- The machine runs unattended and is touched a few times a year. Prefer
  boring, self-healing, observable changes over clever ones.
- Everything runs as a launchd **daemon**, never an agent. Nothing may depend
  on a user being logged in.
- Ollama stays bound to loopback. Don't expose it on the LAN; the tailnet ACL
  is its only access control. Keep the Caddy `Host` rewrite (see README).
- Scope is chat only. Don't add tool calling, MCP servers or agent frameworks
  unless asked.

## Layout

- `flake.nix`: inputs, the `darwinConfigurations.llm` entry point, and a
  devShell with `apply-nix-darwin-configuration`.
- `configuration.nix`: the whole system config.
- `scripts/`: `apply-system-config` and `upgrade-system`.
- `ssh/authorized_keys`: public keys allowed to SSH in.

## Making changes

- Format with `nix fmt -- *.nix` (bare `nix fmt` errors with this nixfmt).
- Check a change with
  `nix build --no-link .#darwinConfigurations.llm.system`. This builds the
  system closure without activating it, so it is safe to run on any
  aarch64-darwin machine. The flake only sees files tracked by git, so
  `git add` new files first.

## Do not do without explicit confirmation

- Never run `scripts/apply-system-config`, `scripts/upgrade-system`,
  `darwin-rebuild switch`, or any `sudo` command. Only the user applies
  changes.
- Treat `flake.lock` as generated. Don't edit it by hand.
