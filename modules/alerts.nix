{ config, lib, pkgs, ... }:

let
  cfg = config.younix.alerts;
  ntfyEnvFile = config.sops.templates."ntfy.env".path;

  # Reusable CLI helper for sending ntfy.sh notifications using sops-decrypted
  # credentials. Accepts `--title`, `--priority`, `--tags`, and either a message
  # argument or stdin.
  younixNotifyBin = pkgs.writeShellScriptBin "younix-notify" ''
    set -euo pipefail

    title="younix alert"
    priority="default"
    tags="computer"

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --title)
          title="$2"
          shift 2
          ;;
        --priority)
          priority="$2"
          shift 2
          ;;
        --tags)
          tags="$2"
          shift 2
          ;;
        --)
          shift
          break
          ;;
        -*)
          echo "Unknown option: $1" >&2
          exit 2
          ;;
        *)
          break
          ;;
      esac
    done

    if [ "$#" -gt 0 ]; then
      body="$*"
    else
      body="$(${pkgs.coreutils}/bin/cat)"
    fi

    if [ ! -r ${lib.escapeShellArg ntfyEnvFile} ]; then
      echo "ERROR: ${ntfyEnvFile} not readable; cannot send ntfy notification." >&2
      exit 1
    fi

    set -a
    # shellcheck disable=SC1090
    source ${lib.escapeShellArg ntfyEnvFile}
    set +a

    if [ -z "''${NTFY_URL:-}" ]; then
      echo "ERROR: NTFY_URL is empty in ${ntfyEnvFile}." >&2
      exit 1
    fi

    # Keep payload under ntfy.sh's 4096-byte inline message limit so mobile clients
    # render the alert directly instead of turning it into a text file attachment.
    if [ "''${#body}" -gt 3800 ]; then
      body="$(printf '%s' "$body" | ${pkgs.coreutils}/bin/head -c 3750)"
      body="$body
... [truncated; inspect full logs via journalctl or Beszel]"
    fi

    curl_args=(
      --fail
      --silent
      --show-error
      --max-time 15
      --retry 2
      --retry-delay 3
      -H "Title: $title"
      -H "Priority: $priority"
      -H "Tags: $tags"
    )

    if [ -n "''${NTFY_TOKEN:-}" ]; then
      curl_args+=(-H "Authorization: Bearer $NTFY_TOKEN")
    fi

    printf '%s' "$body" | ${pkgs.curl}/bin/curl "''${curl_args[@]}" --data-binary @- "$NTFY_URL" > /dev/null
  '';

  # Invoked by younix-notify@.service via systemd OnFailure=younix-notify@%n.service
  unitFailureScript = pkgs.writeShellScript "younix-unit-failure-notify" ''
    set -euo pipefail

    unit="''${1:-unknown}"
    host=${lib.escapeShellArg config.networking.hostName}

    result="$(${pkgs.systemd}/bin/systemctl show --property=Result --value "$unit" 2>/dev/null || echo unknown)"
    exit_code="$(${pkgs.systemd}/bin/systemctl show --property=ExecMainStatus --value "$unit" 2>/dev/null || echo unknown)"
    logs="$(${pkgs.systemd}/bin/journalctl -u "$unit" -n 25 --no-pager --output=short-iso 2>/dev/null || true)"

    message="Host: $host
Unit: $unit
Result: $result (exit code: $exit_code)

Recent logs:
$logs"

    printf '%s' "$message" | ${younixNotifyBin}/bin/younix-notify \
      --title "$host: $unit failed" \
      --priority high \
      --tags "rotating_light,warning"
  '';

  # Invoked by smartd via `-m root -M exec <script>` on SMART warnings/errors.
  smartdNotifyScript = pkgs.writeShellScript "younix-smartd-notify" ''
    set -euo pipefail

    host=${lib.escapeShellArg config.networking.hostName}
    device="''${SMARTD_DEVICE:-unknown}"
    failtype="''${SMARTD_FAILTYPE:-alert}"
    body="''${SMARTD_FULLMESSAGE:-''${SMARTD_MESSAGE:-SMART warning triggered on $device}}"

    priority="urgent"
    tags="rotating_light,cd"
    if [ "$failtype" = "EmailTest" ]; then
      priority="default"
      tags="white_check_mark,cd"
    fi

    printf '%s' "$body" | ${younixNotifyBin}/bin/younix-notify \
      --title "$host SMART: $device ($failtype)" \
      --priority "$priority" \
      --tags "$tags"
  '';

  # Invoked by comin after build and deployment attempts; alerts only on failures.
  cominNotifyScript = pkgs.writeShellScript "younix-comin-notify" ''
    set -euo pipefail

    if [ "''${COMIN_STATUS:-}" != "failed" ]; then
      exit 0
    fi

    host="''${COMIN_HOSTNAME:-younix}"
    phase="''${COMIN_PHASE:-deploy}"
    ref="''${COMIN_GIT_REF:-unknown}"
    sha="''${COMIN_GIT_SHA:-unknown}"
    short_sha="''${sha:0:8}"
    commit_subject="$(printf '%s\n' "''${COMIN_GIT_MSG:-}" | ${pkgs.coreutils}/bin/head -n 1)"
    err="''${COMIN_ERROR_MSG:-No error message provided (check journalctl -u comin)}"

    message="Host: $host
Phase: $phase
Branch: $ref ($short_sha)
Commit: $commit_subject

Error:
$err"

    printf '%s' "$message" | ${younixNotifyBin}/bin/younix-notify \
      --title "$host: comin $phase failed ($short_sha)" \
      --priority high \
      --tags "rotating_light,warning"
  '';

  defaultMonitoredUnits =
    [
      "snapraid-precheck"
      "snapraid-sync"
      "snapraid-scrub"
      "restic-backups-offsite"
      "comin"
      "smartd"
    ]
    ++ lib.optionals config.services.postgresql.enable [
      "postgresqlBackup"
      "younix-postgres-hdd-sync"
    ];

  allMonitoredUnits = lib.unique (defaultMonitoredUnits ++ cfg.extraMonitoredUnits);
in
{
  options.younix.alerts = {
    enable = lib.mkEnableOption "younix ntfy.sh system health and failure alerts" // {
      default = true;
    };

    smartdFlags = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "-m root -M exec ${smartdNotifyScript}";
      description = "smartd.conf notification directives appended to DEVICESCAN.";
    };

    extraMonitoredUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional systemd service names (without .service suffix) to wire with OnFailure=younix-notify@%n.service.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      younixNotifyBin
    ];

    # Encrypted ntfy.sh topic URL and optional access token from secrets/secrets.yaml.
    # Leave `ntfy.token` as "" if using a secret unauthenticated topic URL.
    sops.secrets."ntfy/url" = {
      owner = "root";
      group = "root";
      mode = "0400";
    };

    sops.secrets."ntfy/token" = {
      owner = "root";
      group = "root";
      mode = "0400";
    };

    sops.templates."ntfy.env" = {
      owner = "root";
      group = "root";
      mode = "0400";
      content = ''
        NTFY_URL=${config.sops.placeholder."ntfy/url"}
        NTFY_TOKEN=${config.sops.placeholder."ntfy/token"}
      '';
    };

    # Disable NixOS's built-in smartd mail/wall/x11 wrappers so our custom
    # `-m root -M exec ${smartdNotifyScript}` directive in modules/storage.nix is used cleanly.
    services.smartd.notifications = {
      mail.enable = false;
      wall.enable = false;
      x11.enable = false;
    };

    # Alert on comin GitOps build or switch/deployment failures.
    services.comin = {
      postBuildCommand = "${cominNotifyScript}";
      postDeploymentCommand = "${cominNotifyScript}";
    };

    # Reusable systemd failure notifier template + OnFailure wiring for critical units.
    systemd.services =
      {
        "younix-notify@" = {
          description = "Send ntfy.sh failure alert for %i";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${unitFailureScript} %i";
          };
        };
      }
      // lib.genAttrs allMonitoredUnits (_: {
        unitConfig.OnFailure = [ "younix-notify@%n.service" ];
      });
  };
}
