# MacBook Pro LLM server

Configures a spare 36 GB MacBook Pro as an unattended local LLM server for the
[homelab](https://github.com/dnjstrom/homelab), using
[nix-darwin](https://github.com/nix-darwin/nix-darwin) and
[Determinate Nix](https://docs.determinate.systems/). Same shape as
[dotfiles](https://github.com/dnjstrom/dotfiles), but nothing on it is meant
for interactive use.

It serves [Ollama](https://ollama.com/)'s API at `https://llm.<tailnet>.ts.net`,
which a Matrix bot on the homelab Pi talks to. **Chat only: no tool calling.**

## Architecture

```
tailnet ──https──► tailscale serve :443 ──► caddy 127.0.0.1:11435 ──► ollama 127.0.0.1:11434
```

- Everything runs as **launchd daemons**, so it all starts at boot without
  anyone logging in. There is no auto-login.
- Nothing listens on the LAN. Ollama has no authentication, so the only way
  in is over the tailnet, and the Tailscale ACL decides who can reach it.
- Caddy is there only to rewrite the `Host` header. When Ollama listens on
  loopback it rejects any `Host` that isn't localhost (DNS-rebinding
  protection), and `tailscale serve` forwards the original
  `llm.<tailnet>.ts.net`, so without Caddy every request gets a 403.
- Models are pulled automatically at activation and at boot. See `models` in
  `configuration.nix`.
- Ollama comes from nixpkgs-unstable, because new model architectures need new
  Ollama releases. Everything else uses the release branch.

## Fresh install

1. **Set up macOS.** In Setup Assistant:
   - Create the user `daniel`. The config assumes that name.
   - Turn **FileVault off**. With FileVault on, any unplanned reboot (a power
     cut, a crash, a forced update) waits at the pre-boot unlock screen, and the
     server stays down until someone types the password at the machine.
2. Install [Determinate Nix](https://docs.determinate.systems/).
3. Clone the repo:
   `nix shell nixpkgs#git --command git clone https://github.com/dnjstrom/macbook-pro-llm-server.git`
4. Apply the config: `cd macbook-pro-llm-server; ./scripts/apply-system-config`
5. **Join the tailnet:** `sudo tailscale up`, then log in through the printed
   link. The node shows up as `llm`. The `tailscale-serve` daemon retries every
   minute until this step is done, so you don't need to re-run anything.
6. **Disable key expiry** for `llm` in the
   [Tailscale admin console](https://login.tailscale.com/admin/machines). If you
   don't, the node silently drops off the tailnet after 180 days.
7. **Cap battery charging at ~80%.** A laptop on AC power 24/7 will eventually
   swell its battery. Use System Settings → Battery if your macOS version has
   a charge limit; otherwise install AlDente or `batt`. This step is not in the
   config.
8. Close the lid and put it somewhere ventilated.

## Verify

From the Mac:

```bash
ollama ps                    # after the first request: PROCESSOR should say "100% GPU"
ollama list                  # the models from configuration.nix
sysctl iogpu.wired_limit_mb  # 28672
pmset -g                     # sleep 0, disablesleep 1
```

From another tailnet device:

```bash
curl https://llm.<tailnet>.ts.net/api/version
curl https://llm.<tailnet>.ts.net/api/generate -d '{"model": "qwen3:30b-a3b-instruct-2507-q4_K_M", "prompt": "Hello", "stream": false}'
```

If `ollama ps` reports CPU instead of GPU, the nixpkgs build has lost Metal
support. Check that `otool -L $(which ollama)` lists `Metal.framework`.

## Access control

Ollama itself has no authentication, so the tailnet ACL is the only
gate. Restrict `llm:443` to the nodes that need it: the Matrix bot's
sidecar and your own devices. Fold this into your existing policy rather than
pasting it as-is:

```json
"hosts": { "llm": "<llm's 100.x address>" },
"grants": [
  { "src": ["tag:container", "autogroup:admin"], "dst": ["llm"], "ip": ["443"] }
]
```

## Operations

- **SSH:** `ssh daniel@llm`. The key comes from `ssh/authorized_keys`.
- **Apply changes:** `git pull && ./scripts/apply-system-config`
- **Upgrade everything:** `./scripts/upgrade-system`. This updates
  `flake.lock`; commit it so the machine can be rebuilt exactly.
- **Change models:** edit `models` in `configuration.nix` and apply. Models
  that are no longer listed are not deleted; remove them with `ollama rm`.
- **macOS updates are not installed automatically**, so updates never reboot
  the machine on their own schedule. Apply them by hand now and then.
- **Logs:** `~/Library/Logs/ollama*.log` and `/var/log/tailscale-serve.log`,
  rotated by newsyslog at 10 MB.
- **Restart a service:** `sudo launchctl kickstart -k system/org.nixos.ollama`

## Tuning

| Setting | Where | Notes |
| --- | --- | --- |
| GPU-wired memory | `gpuWiredLimitMb` | macOS defaults to ~75% of RAM. 28 GB leaves 8 GB for the OS. |
| Context length | `OLLAMA_CONTEXT_LENGTH` | Larger contexts use more KV-cache memory on top of the model weights. |
| Keep-alive | `OLLAMA_KEEP_ALIVE` | `-1` keeps the model loaded; a cold load takes tens of seconds. |
