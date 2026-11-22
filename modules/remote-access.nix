{ config, lib, ... }:

let
  tsIface = config.services.tailscale.interfaceName;
  tsCfg = config.networking.firewall.interfaces.${tsIface} or { };
  tsTcpPorts = lib.unique (tsCfg.allowedTCPPorts or [ ]);
  tsUdpPorts = lib.unique (tsCfg.allowedUDPPorts or [ ]);

  # Defense-in-depth: global `openFirewall = true` services (Samba, WSDD, Avahi, etc.)
  # open ports on ALL interfaces by default in NixOS. Intercept `tailscale0` at the top
  # of `nixos-fw` so ONLY explicitly allowlisted `tailscale0` ports (+ ping & established
  # flows) are reachable over Tailscale, while leaving physical LAN interfaces untouched.
  mkTailscaleChain = cmd: icmpRules: ''
    ${cmd} -N younix-tailscale-in 2>/dev/null || ${cmd} -F younix-tailscale-in
    ${cmd} -A younix-tailscale-in -m conntrack --ctstate RELATED,ESTABLISHED -j nixos-fw-accept
    ${icmpRules}
    ${lib.concatMapStringsSep "\n" (port:
      "${cmd} -A younix-tailscale-in -p tcp --dport ${toString port} -j nixos-fw-accept"
    ) tsTcpPorts}
    ${lib.concatMapStringsSep "\n" (port:
      "${cmd} -A younix-tailscale-in -p udp --dport ${toString port} -j nixos-fw-accept"
    ) tsUdpPorts}
    ${cmd} -A younix-tailscale-in -j nixos-fw-log-refuse
    ${cmd} -D nixos-fw -i ${lib.escapeShellArg tsIface} -j younix-tailscale-in 2>/dev/null || true
    ${cmd} -I nixos-fw 1 -i ${lib.escapeShellArg tsIface} -j younix-tailscale-in
  '';

  mkTailscaleCleanup = cmd: ''
    ${cmd} -D nixos-fw -i ${lib.escapeShellArg tsIface} -j younix-tailscale-in 2>/dev/null || true
    ${cmd} -F younix-tailscale-in 2>/dev/null || true
    ${cmd} -X younix-tailscale-in 2>/dev/null || true
  '';
in
{
  assertions = [
    {
      assertion = !config.networking.nftables.enable;
      message = "modules/remote-access.nix: ${tsIface} firewall isolation rules use iptables/ip6tables and must be migrated if networking.nftables.enable is enabled.";
    }
    {
      assertion = !(builtins.elem tsIface config.networking.firewall.trustedInterfaces);
      message = "modules/remote-access.nix: ${tsIface} must not be in networking.firewall.trustedInterfaces (strict per-port firewall policy).";
    }
  ];

  # Zero-port-forward remote access via Tailscale (outbound-only WireGuard mesh).
  # Authenticated interactively once on younix (`sudo tailscale up ...`) so no
  # reusable auth keys are ever stored in this public repository.
  services.tailscale = {
    enable = true;
    # Opens UDP 41641 in the local NixOS host firewall for direct peer-to-peer
    # WireGuard NAT traversal (zero router port-forwarding required).
    openFirewall = true;
    # Server-only node: do not advertise subnet routes or act as an exit node.
    useRoutingFeatures = "none";
  };

  networking.firewall = {
    # Loose reverse-path filtering prevents strict rpfilter drops on Tailscale's
    # policy routing table (table 52) while still rejecting unroutable packets.
    checkReversePath = "loose";

    # Strict allowlist for traffic arriving on tailscale0.
    # Only SSH is allowed here; modules/proxy.nix adds TCP 443.
    # LAN services (Samba 445/139, WSDD, Avahi) remain unreachable over Tailscale.
    interfaces.${tsIface}.allowedTCPPorts = [ 22 ];

    extraCommands = ''
      ${mkTailscaleChain "iptables" ''
        iptables -A younix-tailscale-in -p icmp --icmp-type echo-request -j nixos-fw-accept
      ''}
      ${lib.optionalString config.networking.enableIPv6 (mkTailscaleChain "ip6tables" ''
        ip6tables -A younix-tailscale-in -p ipv6-icmp --icmpv6-type echo-request -j nixos-fw-accept
      '')}
    '';

    extraStopCommands = ''
      ${mkTailscaleCleanup "iptables"}
      ${lib.optionalString config.networking.enableIPv6 (mkTailscaleCleanup "ip6tables")}
    '';
  };
}
