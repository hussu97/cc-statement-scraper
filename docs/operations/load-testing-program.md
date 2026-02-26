# Load and Performance Testing Program

## Standard API load test

```bash
PYTHONPATH=src python scripts/load_test_api.py \
  --base-url http://127.0.0.1:8040 \
  --duration 60 \
  --concurrency 12
```

The tool:
- runs a mixed request profile against health/readiness/metrics endpoints,
- reports throughput and p50/p95/p99 latency,
- enforces budgets from `config/performance_budgets.json`.

## Budget management
- Use `config/performance_budgets.json` as versioned source-of-truth.
- Tighten budgets only after stable passing runs in staging.

## Operational cadence
- Run per release candidate.
- Run weekly against staging to detect regressions.
