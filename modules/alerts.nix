{ config, lib, pkgs, ... }:

let
  cfg = config.younix.alerts;
  ntfyEnvFile = config.sops.templates."ntfy.env".path;

  # ===========================================================================
  # Alert Policy — what triggers ntfy.sh notifications & their priority
  #
  # Priorities: min | low | default | high | urgent
  # ===========================================================================

  # 1. Systemd services monitored via OnFailure= (alerts include last 25 log lines)
  monitoredServices =
    {
      # Storage & SnapRAID parity (unmounted drives, >100 deletions, sync/scrub errors)
      snapraid-precheck = { priority = "high"; tags = "rotating_light,warning"; };
      snapraid-sync     = { priority = "high"; tags = "rotating_light,warning"; };
      snapraid-scrub    = { priority = "high"; tags = "rotating_light,warning"; };

      # Offsite Backblaze B2 backups (upload, prune, or integrity check errors)
      restic-backups-offsite = { priority = "high"; tags = "rotating_light,warning"; };

      # Core daemons (if the daemon itself crashes)
      comin  = { priority = "high"; tags = "rotating_light,warning"; };
      smartd = { priority = "high"; tags = "rotating_light,warning"; };
    }
    # Local PostgreSQL dumps (when PostgreSQL is enabled)
    // lib.optionalAttrs config.services.postgresql.enable {
      postgresqlBackup         = { priority = "high"; tags = "rotating_light,warning"; };
      younix-postgres-hdd-sync = { priority = "high"; tags = "rotating_light,warning"; };
    }
    # Any additional services added via `younix.alerts.extraMonitoredUnits`
    // lib.genAttrs cfg.extraMonitoredUnits (_: {
      priority = "high";
      tags = "rotating_light,warning";
    });

  # 2. S.M.A.R.T. disk health alerts (smartd -M exec on all SATA HDDs & NVMe SSDs)
  smartdAlert = {
    priority = "urgent";
    tags = "rotating_light,cd";
  };

  # 3. GitOps deployment alerts (comin postBuild & postDeployment hooks)
  cominAlerts = {
    failure        = { priority = "high";    tags = "rotating_light,warning"; };
    rebootRequired = { priority = "default"; tags = "arrows_counterclockwise,warning"; };
    success        = { priority = "low";     tags = "white_check_mark,rocket"; };
  };

  # ===========================================================================
  # Implementation (ntfy.sh sender, hooks, and systemd wiring)
  # ===========================================================================

  younixNotifyBin = pkgs.writeShellScriptBin "younix-notify" ''
    set -euo pipefail

    title="younix alert"
    priority="default"
    tags="computer"

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --title)    title="$2";    shift 2 ;;
        --priority) priority="$2"; shift 2 ;;
        --tags)     tags="$2";     shift 2 ;;
        --)         shift; break ;;
        -*)         echo "Unknown option: $1" >&2; exit 2 ;;
        *)          break ;;
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

    # Keep payload under ntfy.sh's 4096-byte inline message limit so mobile apps
    # render the alert inline instead of turning it into a text file attachment.
    if [ "''${#body}" -gt 3800 ]; then
      body="$(printf '%s' "$body" | ${pkgs.coreutils}/bin/head -c 3750)"
      body="$body
... [truncated; inspect full logs via journalctl or Beszel]"
    fi

    curl_args=(
      --fail --silent --show-error
      --max-time 15 --retry 2 --retry-delay 3
      -H "Title: $title"
      -H "Priority: $priority"
      -H "Tags: $tags"
    )
    if [ -n "''${NTFY_TOKEN:-}" ]; then
      curl_args+=(-H "Authorization: Bearer $NTFY_TOKEN")
    fi

    printf '%s' "$body" | ${pkgs.curl}/bin/curl "''${curl_args[@]}" --data-binary @- "$NTFY_URL" > /dev/null
  '';

  unitFailureScript = pkgs.writeShellScript "younix-unit-failure-notify" ''
    set -euo pipefail

    unit="''${1:-unknown}"
    host=${lib.escapeShellArg config.networking.hostName}

    priority="high"
    tags="rotating_light,warning"
    case "$unit" in
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: rule: ''
        ${name}|${name}.service)
          priority=${lib.escapeShellArg rule.priority}
          tags=${lib.escapeShellArg rule.tags}
          ;;
      '') monitoredServices)}
    esac

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
      --priority "$priority" \
      --tags "$tags"
  '';

  smartdNotifyScript = pkgs.writeShellScript "younix-smartd-notify" ''
    set -euo pipefail

    host=${lib.escapeShellArg config.networking.hostName}
    device="''${SMARTD_DEVICE:-unknown}"
    failtype="''${SMARTD_FAILTYPE:-alert}"
    body="''${SMARTD_FULLMESSAGE:-''${SMARTD_MESSAGE:-SMART warning triggered on $device}}"

    priority=${lib.escapeShellArg smartdAlert.priority}
    tags=${lib.escapeShellArg smartdAlert.tags}
    if [ "$failtype" = "EmailTest" ]; then
      priority="default"
      tags="white_check_mark,cd"
    fi

    printf '%s' "$body" | ${younixNotifyBin}/bin/younix-notify \
      --title "$host SMART: $device ($failtype)" \
      --priority "$priority" \
      --tags "$tags"
  '';

  cominNotifyScript = pkgs.writeShellScript "younix-comin-notify" ''
    set -euo pipefail

    host="''${COMIN_HOSTNAME:-younix}"
    phase="''${COMIN_PHASE:-deploy}"
    status="''${COMIN_STATUS:-}"
    ref="''${COMIN_GIT_REF:-unknown}"
    sha="''${COMIN_GIT_SHA:-unknown}"
    short_sha="''${sha:0:8}"
    commit_subject="$(printf '%s\n' "''${COMIN_GIT_MSG:-}" | ${pkgs.coreutils}/bin/head -n 1)"

    if [ "$status" = "failed" ]; then
      err="''${COMIN_ERROR_MSG:-No error message provided (check journalctl -u comin)}"
      message="Host: $host
Phase: $phase
Branch: $ref ($short_sha)
Commit: $commit_subject

Error:
$err"
      printf '%s' "$message" | ${younixNotifyBin}/bin/younix-notify \
        --title "$host: comin $phase failed ($short_sha)" \
        --priority ${lib.escapeShellArg cominAlerts.failure.priority} \
        --tags ${lib.escapeShellArg cominAlerts.failure.tags}
    elif [ "$phase" = "deploy" ] && [ "$status" = "done" ]; then
      gen="''${COMIN_GENERATION:-unknown}"
      reboot_reasons=()
      for item in kernel initrd kernel-modules; do
        booted="$(${pkgs.coreutils}/bin/readlink -f "/run/booted-system/$item" 2>/dev/null || true)"
        current="$(${pkgs.coreutils}/bin/readlink -f "/run/current-system/$item" 2>/dev/null || true)"
        if [ -n "$booted" ] && [ -n "$current" ] && [ "$booted" != "$current" ]; then
          reboot_reasons+=("$item")
        fi
      done
      if [ -r /run/booted-system/kernel-params ] && [ -r /run/current-system/kernel-params ] && \
         ! ${pkgs.diffutils}/bin/cmp -s /run/booted-system/kernel-params /run/current-system/kernel-params; then
        reboot_reasons+=("kernel-params")
      fi

      message="Host: $host
Generation: $gen
Branch: $ref ($short_sha)
Commit: $commit_subject"

      if [ "''${#reboot_reasons[@]}" -gt 0 ]; then
        changed="$(printf '%s, ' "''${reboot_reasons[@]}")"
        changed="''${changed%, }"
        message="$message

Reboot required (changed: $changed).
Run 'sudo reboot' on $host when convenient."
        printf '%s' "$message" | ${younixNotifyBin}/bin/younix-notify \
          --title "$host: deployed gen $gen — reboot required" \
          --priority ${lib.escapeShellArg cominAlerts.rebootRequired.priority} \
          --tags ${lib.escapeShellArg cominAlerts.rebootRequired.tags}
      else
        printf '%s' "$message" | ${younixNotifyBin}/bin/younix-notify \
          --title "$host: deployed gen $gen ($short_sha)" \
          --priority ${lib.escapeShellArg cominAlerts.success.priority} \
          --tags ${lib.escapeShellArg cominAlerts.success.tags}
      fi
    fi
  '';
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
    environment.systemPackages = [ younixNotifyBin ];

    # Encrypted ntfy.sh topic URL and optional access token from secrets/secrets.yaml.
    # Leave `ntfy.token` as "" if using a secret unauthenticated topic URL.
    sops.secrets."ntfy/url" = { owner = "root"; group = "root"; mode = "0400"; };
    sops.secrets."ntfy/token" = { owner = "root"; group = "root"; mode = "0400"; };
    sops.templates."ntfy.env" = {
      owner = "root";
      group = "root";
      mode = "0400";
      content = ''
        NTFY_URL=${config.sops.placeholder."ntfy/url"}
        NTFY_TOKEN=${config.sops.placeholder."ntfy/token"}
      '';
    };

    # Disable NixOS's built-in smartd wrappers so our custom `-m root -M exec` hook is used.
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

    # Reusable systemd failure notifier template + OnFailure wiring for every monitored service.
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
      // lib.mapAttrs (_: _: {
        unitConfig.OnFailure = [ "younix-notify@%n.service" ];
      }) monitoredServices;
  };
}
