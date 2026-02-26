# Network Hardening Baseline

## Ingress Policy
- Public ingress is limited to the reverse proxy (`80/443`).
- API and frontend containers are not published directly; they are only exposed on internal service networks.

## Egress Policy
- API/worker egress should be restricted to:
  - bank login/download endpoints,
  - managed database endpoint,
  - object storage endpoint,
  - package mirrors required for runtime updates.
- Deny all other outbound destinations by default in production firewall rules.

## Segmentation
- Keep API and worker workloads on isolated internal network segments.
- Reverse proxy is the only service with public network attachment.
- Use independent worker pools (`default` vs `scrape`) to isolate browser-heavy traffic.

## Identity and Transport
- Enforce TLS for all external traffic.
- Prefer workload identity / OIDC over static long-lived credentials.
- Use signed container images only (Cosign verification gate before deploy).

## Verification Checklist
- Confirm no direct `ports:` mapping on API/worker services.
- Validate firewall rules block non-allowlisted ingress/egress paths.
- Validate health checks and job processing after policy changes.
- Record verification evidence in deployment ticket.
