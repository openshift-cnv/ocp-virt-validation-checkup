#!/usr/bin/env python3

import argparse
import json
from pathlib import Path
from typing import Optional
from xml.etree.ElementTree import Element, ElementTree, SubElement


def read_json(path: Path) -> dict:
    if not path.exists():
        return {}

    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return {}


def read_stderr(path: Optional[Path]) -> list[str]:
    if path is None or not path.exists():
        return []

    return [line for line in path.read_text().splitlines() if line.strip()]


def failure_message(result: dict) -> str:
    for message in result.get("report_messages") or []:
        if isinstance(message, str) and message.startswith("FAIL:"):
            return message[5:].strip()

    if result.get("cancelled"):
        return f'{result.get("testpath", "validator check")} timed out'

    errors = result.get("errors") or []
    if errors:
        return str(errors[0])

    return result.get("testpath", "validator check")


def testcase_output(result: dict, stderr_lines: list[str]) -> str:
    sections: list[str] = []

    for section_name in ("log", "errors", "warnings"):
        values = result.get(section_name) or []
        lines = [str(value) for value in values if str(value).strip()]
        if not lines:
            continue
        if sections:
            sections.append("")
        sections.append(f"[{section_name}]")
        sections.extend(lines)

    if stderr_lines:
        if sections:
            sections.append("")
        sections.append("[stderr]")
        sections.extend(stderr_lines)

    return "\n".join(sections)


def write_junit(path: Path, suite_name: str, results: list[dict], stderr_lines: list[str]) -> None:
    tests = len(results)
    failures = sum(1 for result in results if not result.get("success", False))
    total_duration = sum(int(result.get("duration") or 0) for result in results)

    testsuites = Element("testsuites", name=suite_name)
    testsuite = SubElement(
        testsuites,
        "testsuite",
        name=suite_name,
        tests=str(tests),
        failures=str(failures),
        errors="0",
        skipped="0",
        time=f"{total_duration:.3f}",
    )

    for result in results:
        name = result.get("testpath") or "validator-check"
        testcase = SubElement(
            testsuite,
            "testcase",
            classname=suite_name,
            name=name,
            time=f"{int(result.get('duration') or 0):.3f}",
        )

        output_text = testcase_output(result, stderr_lines if tests == 1 else [])
        if output_text:
            system_out = SubElement(testcase, "system-out")
            system_out.text = output_text

        if not result.get("success", False):
            failure = SubElement(testcase, "failure", message=failure_message(result))
            failure.text = output_text or failure_message(result)

    path.parent.mkdir(parents=True, exist_ok=True)
    ElementTree(testsuites).write(path, encoding="unicode", xml_declaration=True)


def write_dry_run_junit(path: Path, suite_name: str, checks: list[str]) -> None:
    testsuites = Element("testsuites", name=suite_name)
    testsuite = SubElement(
        testsuites,
        "testsuite",
        name=suite_name,
        tests=str(len(checks)),
        failures="0",
        errors="0",
        skipped=str(len(checks)),
        time="0.000",
    )

    for check in checks:
        testcase = SubElement(
            testsuite,
            "testcase",
            classname=suite_name,
            name=check,
            time="0.000",
        )
        SubElement(testcase, "skipped")

    path.parent.mkdir(parents=True, exist_ok=True)
    ElementTree(testsuites).write(path, encoding="unicode", xml_declaration=True)


def synthetic_failure_results(stderr_lines: list[str]) -> list[dict]:
    message = "validator did not produce valid JSON output"
    if stderr_lines:
        message = stderr_lines[0]

    return [
        {
            "testpath": "virt-cluster-validate",
            "success": False,
            "duration": 0,
            "report_messages": [f"FAIL: {message}"],
            "log": [],
            "errors": stderr_lines or [message],
            "warnings": [],
        }
    ]


def emit_run_log(results: list[dict]) -> None:
    print(f"collecting ... collected {len(results)} items")

    passed = 0
    failed = 0
    duration = 0
    for result in results:
        success = bool(result.get("success", False))
        status = "PASSED" if success else "FAILED"
        print(f'TEST: {result.get("testpath", "validator-check")} STATUS: {status}')
        duration += int(result.get("duration") or 0)
        if success:
            passed += 1
        else:
            failed += 1

    print(f"{passed} passed, {failed} failed in {duration} seconds")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--suite-name", required=True)
    parser.add_argument("--junit-output", required=True)
    parser.add_argument("--input-json")
    parser.add_argument("--stderr-file")
    parser.add_argument("--dry-run-check", action="append", default=[])
    parser.add_argument("--emit-run-log", action="store_true")
    args = parser.parse_args()

    junit_output = Path(args.junit_output)

    if args.dry_run_check:
        checks = sorted(args.dry_run_check)
        write_dry_run_junit(junit_output, args.suite_name, checks)
        print(f"collecting ... collected {len(checks)} items")
        return

    stderr_lines = read_stderr(Path(args.stderr_file)) if args.stderr_file else []
    data = read_json(Path(args.input_json)) if args.input_json else {}
    results = data.get("results")
    used_fallback = not isinstance(results, list) or not results
    if used_fallback:
        results = synthetic_failure_results(stderr_lines)

    write_junit(junit_output, args.suite_name, results, stderr_lines)
    if args.emit_run_log:
        emit_run_log(results)
    if used_fallback:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
