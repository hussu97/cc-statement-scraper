# SLO and Alert Policy

## SLO source
Policy file: `config/slo_alert_rules.yaml`

Objectives:
- API availability
- API average latency
- Job success rate
- Queue backlog SLO health

## Evaluation command

```bash
PYTHONPATH=src python scripts/evaluate_slo.py \
  --metrics-url http://127.0.0.1:8040/api/v1/metrics
```

Or evaluate from stored snapshot:

```bash
PYTHONPATH=src python scripts/evaluate_slo.py --metrics-file /path/to/metrics.json
```

## Alert handling
- `overall_status=alert` pages primary on-call.
- Escalate after 15 minutes without mitigation.
- Use this runbook with `docs/security/network-hardening-baseline.md` and backup drill outputs during incident triage.
