{ config, lib, pkgs, ... }:

let
  routes = config.younix.proxy.routes;
  tsIface = config.services.tailscale.interfaceName;

  # Build Caddy with the deSEC DNS-01 plugin so wildcard TLS certificates are
  # issued and renewed automatically without opening any public ports.
  caddyWithDesec = pkgs.caddy.withPlugins {
    plugins = [ "github.com/caddy-dns/desec@v1.1.0" ];
    hash = "sha256-HrLRezw+q5+dRdJS662686n7xsImSxNb3UqlSo61R8E=";
  };

  mkRouteBlock = name: route: ''
    @${name} host ${name}.{$YOUNIX_DOMAIN:example.invalid}
    handle @${name} {
      reverse_proxy ${route.upstream}
      ${route.extraConfig}
    }
  '';
in
{
  options.younix.proxy.routes = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        upstream = lib.mkOption {
          type = lib.types.str;
          description = "Local backend address to reverse-proxy (e.g. 127.0.0.1:8096).";
        };
        extraConfig = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Optional extra Caddy directives inside this route's handle block.";
        };
      };
    });
    default = { };
    description = ''
      Subdomain reverse-proxy routes served under the shared *.{$YOUNIX_DOMAIN}
      wildcard HTTPS certificate (e.g. `younix.proxy.routes.jellyfin.upstream = "127.0.0.1:8096"`).
    '';
  };

  config = {
    assertions = [
      {
        assertion = config.services.tailscale.enable;
        message = "modules/proxy.nix requires modules/remote-access.nix (services.tailscale.enable = true).";
      }
    ];

    # Encrypted base domain and deSEC API token from secrets/secrets.yaml (keeps
    # both the personal domain and DNS credentials out of this public repo).
    sops.secrets."caddy/domain" = {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "caddy.service" ];
    };

    sops.secrets."caddy/desec_token" = {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "caddy.service" ];
    };

    sops.templates."caddy.env" = {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "caddy.service" ];
      content = ''
        YOUNIX_DOMAIN=${config.sops.placeholder."caddy/domain"}
        DESEC_TOKEN=${config.sops.placeholder."caddy/desec_token"}
      '';
    };

    services.caddy = {
      enable = true;
      package = caddyWithDesec;
      environmentFile = config.sops.templates."caddy.env".path;

      # Port 80 is not exposed; keep full automatic HTTPS/ACME but disable :80 redirects.
      globalConfig = ''
        auto_https disable_redirects
      '';

      # Single wildcard site block so individual service hostnames never appear in
      # public Certificate Transparency logs. Default placeholders keep Nix build-time
      # `caddy validate` passing while runtime loads real values from caddy.env.
      extraConfig = ''
        *.{$YOUNIX_DOMAIN:example.invalid} {
          tls {
            dns desec {
              token {$DESEC_TOKEN:placeholder}
            }
            # Wait for deSEC's global Anycast PoPs to sync before checking DNS or
            # triggering Let's Encrypt's multi-region secondary validation.
            propagation_delay 60s
            propagation_timeout 5m
            resolvers 1.1.1.1 9.9.9.9
          }

          header {
            Strict-Transport-Security "max-age=31536000; includeSubDomains"
            X-Content-Type-Options "nosniff"
            Referrer-Policy "strict-origin-when-cross-origin"
            -Server
          }

          # Built-in health endpoint for verifying wildcard TLS & proxy routing
          @health host health.{$YOUNIX_DOMAIN:example.invalid}
          handle @health {
            respond "younix proxy ok\n" 200
          }

          ${lib.concatStringsSep "\n" (lib.mapAttrsToList mkRouteBlock routes)}

          # Drop requests for unconfigured subdomains without leaking information
          handle {
            abort
          }
        }
      '';
    };

    # Expose HTTPS (TCP 443) strictly on tailscale0 (enforced by modules/remote-access.nix).
    networking.firewall.interfaces.${tsIface}.allowedTCPPorts = [ 443 ];
  };
}
