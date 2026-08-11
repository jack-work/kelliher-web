# Shared systemd hardening baseline, applied to both the Caddy and
# cloudflared units. Merged into each unit's serviceConfig with `//` so a
# unit can override individual keys (e.g. DynamicUser, User/Group).
{
  ProtectHome = true;
  PrivateTmp = true;
  NoNewPrivileges = true;
  ProtectSystem = "strict";
  PrivateDevices = true;
  PrivateUsers = true;
  ProtectKernelTunables = true;
  ProtectKernelModules = true;
  ProtectKernelLogs = true;
  ProtectControlGroups = true;
  RestrictAddressFamilies = [
    "AF_INET"
    "AF_INET6"
  ];
  RestrictNamespaces = true;
  RestrictRealtime = true;
  RestrictSUIDSGID = true;
  LockPersonality = true;
  MemoryDenyWriteExecute = true;
  SystemCallFilter = [ "@system-service" ];
  SystemCallArchitectures = "native";
  SystemCallErrorNumber = "EPERM";
  CapabilityBoundingSet = "";
}
