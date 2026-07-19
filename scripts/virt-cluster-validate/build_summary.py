#!/usr/bin/env python3

import argparse
import json
from pathlib import Path


def load_single_result(path: Path) -> dict:
    data = json.loads(path.read_text())
    results = data.get("results", [])
    if len(results) != 1:
        raise ValueError(f"{path} expected exactly 1 result, got {len(results)}")
    return results[0]


def build_summary_string(results: list[dict]) -> str:
    passed = sum(1 for result in results if result.get("success"))
    failed = len(results) - passed
    cancelled = sum(1 for result in results if result.get("cancelled"))

    summary = f"Passed: {passed}, Failed: {failed}"
    if cancelled:
        summary += f", Cancelled: {cancelled}"
    summary += f", Total: {len(results)}"
    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw-dir", required=True)
    parser.add_argument("--combined-json", required=True)
    args = parser.parse_args()

    raw_dir = Path(args.raw_dir)
    results = [load_single_result(path) for path in sorted(raw_dir.glob("*.json"))]

    combined = {
        "summary": build_summary_string(results),
        "results": results,
    }
    Path(args.combined_json).write_text(json.dumps(combined, indent=2) + "\n")


if __name__ == "__main__":
    main()
