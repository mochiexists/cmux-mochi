#!/usr/bin/env python3
"""The fork gate must list every automated proof the feature ledger names.

Checks, without any build:
- every `...Tests` suite named in the ledger's "Automated proof" column either
  appears in fork-gate.yml's app-host list or lives in a Swift package that the
  fork-package-suites job runs;
- every suite in the app-host list exists in cmuxTests;
- every ledger suite exists somewhere in the tree (a ledger row that names a
  test that does not exist is not proof of anything).
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
LEDGER = ROOT / "plans/clean-trunk-v0.64.22/FEATURE-LEDGER.md"
WORKFLOW = ROOT / ".github/workflows/fork-gate.yml"


def ledger_suites() -> set[str]:
    suites: set[str] = set()
    for line in LEDGER.read_text(encoding="utf-8").splitlines():
        if not line.startswith("| `"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        suites.update(re.findall(r"`([A-Za-z0-9_+]+Tests)(?:/\w+)?`", cells[4]))
    return suites


def workflow_lists() -> tuple[set[str], set[str]]:
    text = WORKFLOW.read_text(encoding="utf-8")
    block = re.search(r"CMUX_FORK_GATE_APP_HOST_SUITES: >-\n((?:\s{4}\S+\n)+)", text)
    app_host = set(block.group(1).split()) if block else set()
    packages = set(re.findall(r"run_suite \S+ (\w+Tests)", text))
    return app_host, packages


def declared_types(paths) -> set[str]:
    names: set[str] = set()
    for path in paths:
        if "/.build/" in str(path):
            continue
        src = path.read_text(encoding="utf-8", errors="replace")
        names.update(re.findall(r"\b(?:class|struct|actor) (\w+Tests)\b", src))
    return names


def main() -> int:
    ledger = ledger_suites()
    app_host, packages = workflow_lists()
    in_app_target = declared_types(ROOT.glob("cmuxTests/**/*.swift"))
    in_packages = declared_types(ROOT.glob("Packages/**/Tests/**/*.swift"))
    problems: list[str] = []
    for suite in sorted(ledger):
        if suite not in in_app_target and suite not in in_packages:
            problems.append(f"ledger names {suite} but no such suite exists in the tree")
        elif suite not in app_host and suite not in packages:
            problems.append(f"ledger names {suite} but fork-gate.yml does not run it")
    for suite in sorted(app_host):
        if suite not in in_app_target:
            problems.append(f"fork-gate.yml lists {suite} but cmuxTests has no such suite")
    for suite in sorted(packages):
        if suite not in in_packages:
            problems.append(f"fork-gate.yml runs package suite {suite} but no package declares it")
    for problem in problems:
        print(f"ERROR {problem}")
    if problems:
        return 1
    print(f"ok: {len(ledger)} ledger suites covered ({len(app_host)} app-host, {len(packages)} package)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
