#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from ccs_platform.operations.loadtest import evaluate_budget, load_performance_budget, run_api_load_test


def main() -> int:
    parser = argparse.ArgumentParser(description="Run repeatable API load test and evaluate budget.")
    parser.add_argument("--base-url", required=True, help="API base URL, e.g. http://127.0.0.1:8040")
    parser.add_argument("--duration", type=int, default=30, help="Test duration in seconds")
    parser.add_argument("--concurrency", type=int, default=8, help="Number of concurrent workers")
    parser.add_argument("--timeout", type=float, default=5.0, help="Per-request timeout seconds")
    parser.add_argument(
        "--budget-file",
        default="config/performance_budgets.json",
        help="Performance budget JSON path",
    )
    parser.add_argument("--budget-name", default="api_smoke", help="Performance budget object key")
    args = parser.parse_args()

    result = run_api_load_test(
        base_url=args.base_url,
        duration_seconds=args.duration,
        concurrency=args.concurrency,
        timeout_seconds=args.timeout,
    )

    budget = load_performance_budget(
        budget_file=Path(args.budget_file).expanduser().resolve(),
        budget_name=args.budget_name,
    )
    violations = evaluate_budget(result=result, budget=budget)
    payload = {
        "result": result,
        "budget": budget,
        "violations": violations,
        "status": "pass" if not violations else "fail",
    }
    print(json.dumps(payload, indent=2))
    return 0 if not violations else 1


if __name__ == "__main__":
    raise SystemExit(main())
