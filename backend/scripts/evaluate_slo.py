#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from urllib import request

from ccs_platform.operations.slo import evaluate_slo_policy, load_slo_policy


def _load_metrics_from_endpoint(url: str) -> dict:
    req = request.Request(url=url)
    with request.urlopen(req, timeout=10.0) as response:  # noqa: S310
        return json.loads(response.read().decode("utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate SLO/alert policy against metrics snapshot.")
    parser.add_argument("--policy-file", default="config/slo_alert_rules.yaml", help="SLO policy YAML")
    parser.add_argument("--metrics-file", default="", help="Metrics JSON file (optional)")
    parser.add_argument("--metrics-url", default="", help="Metrics endpoint URL (optional)")
    args = parser.parse_args()

    if not args.metrics_file and not args.metrics_url:
        raise SystemExit("Provide either --metrics-file or --metrics-url")

    policy = load_slo_policy(Path(args.policy_file).expanduser().resolve())
    if args.metrics_file:
        metrics = json.loads(Path(args.metrics_file).expanduser().resolve().read_text(encoding="utf-8"))
    else:
        metrics = _load_metrics_from_endpoint(args.metrics_url)

    report = evaluate_slo_policy(policy=policy, metrics=metrics)
    print(json.dumps(report, indent=2))
    return 0 if report.get("overall_status") == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())
