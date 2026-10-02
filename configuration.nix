# For docs on the nix-darwin config options
# https://nix-darwin.github.io/nix-darwin/manual/

{
  config,
  pkgs,
  inputs,
  username,
  hostname,
  ...
}:

let
  # Ollama needs a new release for each new model architecture, far faster
  # than the nixpkgs release branch picks it up, so it tracks unstable.
  unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
  };
  ollama = unstable.ollama;

  home = "/Users/${username}";
  logDir = "${home}/Library/Logs";

  # Pulled on activation and at every boot; already-present models are a
  # no-op. Check https://ollama.com/library for what is current.
  #
  # The M3 Pro's ~150 GB/s memory bandwidth caps a dense 30B model at ~7
  # tok/s; this MoE reads only ~3B parameters per token. The instruct
  # variant answers directly instead of reasoning first. The full tag pins
  # the quantization, which floating tags like `qwen3:30b` do not.
  models = [ "qwen3:30b-a3b-instruct-2507-q4_K_M" ];

  ollamaPort = 11434;
  proxyPort = 11435;

  # macOS caps GPU-wired memory at ~75% of RAM by default (~27 GB of 36 GB)
  # and resets any override on reboot. 28 GB leaves 8 GB for macOS itself.
  gpuWiredLimitMb = 28 * 1024;
in
{
  networking = {
    hostName = hostname;
    computerName = hostname;
    localHostName = hostname;
  };

  environment.systemPackages = [ ollama ];

  # ─── Unattended operation ───────────────────────────────────────────────

  power = {
    sleep = {
      computer = "never";
      display = 1;
      harddisk = "never";
    };
    restartAfterFreeze = true;
  };

  system.activationScripts.postActivation.text = ''
    # Keep running with the lid closed and no external display. Without this
    # a closed lid sleeps the machine regardless of the settings above.
    pmset -a disablesleep 1
  '';

  # An OS update reboots on its own schedule. Apply updates by hand instead.
  system.defaults.SoftwareUpdate.AutomaticallyInstallMacOSUpdates = false;

  # ─── Access ─────────────────────────────────────────────────────────────

  # A launchd daemon, so the node is up before (or without) anyone logging in.
  # Needs a one-time `sudo tailscale up`; see README.
  services.tailscale.enable = true;

  services.openssh.enable = true;
  users.users.${username}.openssh.authorizedKeys.keyFiles = [ ./ssh/authorized_keys ];

  # ─── LLM serving ────────────────────────────────────────────────────────
  #
  #   tailnet ──https──► tailscale serve :443 ──► caddy 127.0.0.1:11435
  #                                                  └─► ollama 127.0.0.1:11434
  #
  # Ollama listens on loopback only. In that mode it rejects any Host header
  # that isn't localhost (DNS-rebinding protection), and `tailscale serve`
  # forwards the original `llm.<tailnet>.ts.net` Host — so requests through
  # serve alone get a 403. Caddy rewrites the Host header in between.

  launchd.daemons.gpu-wired-limit.serviceConfig = {
    ProgramArguments = [
      "/usr/sbin/sysctl"
      "iogpu.wired_limit_mb=${toString gpuWiredLimitMb}"
    ];
    RunAtLoad = true;
  };

  launchd.daemons.ollama.serviceConfig = {
    ProgramArguments = [
      "${ollama}/bin/ollama"
      "serve"
    ];
    EnvironmentVariables = {
      HOME = home; # Models are stored under ~/.ollama/models
      OLLAMA_HOST = "127.0.0.1:${toString ollamaPort}";
      # Keep the model resident; a cold load takes tens of seconds.
      OLLAMA_KEEP_ALIVE = "-1";
      OLLAMA_CONTEXT_LENGTH = "16384";
    };
    UserName = username;
    RunAtLoad = true;
    KeepAlive = true;
    StandardOutPath = "${logDir}/ollama.log";
    StandardErrorPath = "${logDir}/ollama.log";
  };

  launchd.daemons.ollama-proxy.serviceConfig = {
    ProgramArguments = [
      "${pkgs.caddy}/bin/caddy"
      "run"
      "--adapter"
      "caddyfile"
      "--config"
      (toString (
        pkgs.writeText "Caddyfile" ''
          {
            admin off
            auto_https off
            persist_config off
          }

          # No hostname in the site address: it must match whatever Host
          # tailscale serve forwards. `bind` is what keeps it loopback-only.
          http://:${toString proxyPort} {
            bind 127.0.0.1
            reverse_proxy 127.0.0.1:${toString ollamaPort} {
              header_up Host localhost
              # Stream tokens as they are generated.
              flush_interval -1
            }
          }
        ''
      ))
    ];
    EnvironmentVariables.HOME = home;
    UserName = username;
    RunAtLoad = true;
    KeepAlive = true;
    StandardOutPath = "${logDir}/ollama-proxy.log";
    StandardErrorPath = "${logDir}/ollama-proxy.log";
  };

  # Serve config is persisted in tailscaled's state, so this only has to
  # succeed once; it retries until `tailscale up` has been run.
  launchd.daemons.tailscale-serve = {
    script = ''
      ${config.services.tailscale.package}/bin/tailscale serve --bg --https=443 \
        http://127.0.0.1:${toString proxyPort}
    '';
    serviceConfig = {
      RunAtLoad = true;
      KeepAlive.SuccessfulExit = false;
      ThrottleInterval = 60;
      StandardOutPath = "/var/log/tailscale-serve.log";
      StandardErrorPath = "/var/log/tailscale-serve.log";
    };
  };

  # Retries until Ollama is up and the network is reachable.
  launchd.daemons.ollama-pull-models = {
    script = ''
      set -eu
      ${builtins.concatStringsSep "\n" (map (m: "${ollama}/bin/ollama pull ${m}") models)}
    '';
    environment = {
      HOME = home;
      OLLAMA_HOST = "127.0.0.1:${toString ollamaPort}";
    };
    serviceConfig = {
      UserName = username;
      RunAtLoad = true;
      KeepAlive.SuccessfulExit = false;
      ThrottleInterval = 60;
      StandardOutPath = "${logDir}/ollama-pull-models.log";
      StandardErrorPath = "${logDir}/ollama-pull-models.log";
    };
  };

  # Rotate at 10 MB, keep 5. Nothing else would ever trim these.
  environment.etc."newsyslog.d/llm-server.conf".text = ''
    # logfilename                                  [owner:group]  mode count size when  flags
    ${logDir}/ollama.log                           ${username}:staff 644 5 10240 *     N
    ${logDir}/ollama-proxy.log                     ${username}:staff 644 5 10240 *     N
    ${logDir}/ollama-pull-models.log               ${username}:staff 644 5 10240 *     N
    /var/log/tailscale-serve.log                   root:wheel     644  5     10240 *     N
  '';
}
