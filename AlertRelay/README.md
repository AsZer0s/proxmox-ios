# Proxmox Alert Relay

Small self-hosted APNs relay for real background alerts. The iOS app sends only its APNs token, selected cluster UUIDs, and alert rules. Proxmox credentials remain on this relay and should use a dedicated, read-only API token.

1. Copy `config.example.json` to `config.json`, add the APNs `.p8` key and PVE clusters.
2. Keep `enrollmentToken` private and expose the service through HTTPS.
3. Run `docker build -t proxmox-alert-relay .` and mount `/data` with the config/key.
4. Enter the HTTPS relay URL and enrollment token under Alert Settings in the app.

`GET /healthz` is unauthenticated. Device enrollment endpoints require `Authorization: Bearer <enrollmentToken>`. Device state is written atomically to `/data/devices.json`.

For strict TLS, the relay intentionally rejects self-signed PVE certificates. Terminate them with a trusted internal CA or reverse proxy. The `allowInsecureTLS` config key is reserved and is not honored.
