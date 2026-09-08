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

# Tests excluded from the gate by name, with the reason and the owner
# decision they are waiting on. This list may only shrink.
KNOWN_FAILING = {
    "SessionPersistenceTests/testRestoreDoesNotPassDeletedAgentHookCwdToTerminalRuntime": (
        "Inherited from upstream 0.64.22 unchanged; fails deterministically on the "
        "fork (restore hands the temp directory to the terminal runtime when the "
        "saved cwd was deleted, test expects nil). Needs an owner call on whether "
        "the fork's restore behaviour or the upstream expectation is right."
    ),
}
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


def workflow_lists() -> tuple[set[str], set[str], set[str]]:
    text = WORKFLOW.read_text(encoding="utf-8")
    block = re.search(r"CMUX_FORK_GATE_APP_HOST_SUITES: >-\n((?:\s{4}\S+\n)+)", text)
    app_host = set(block.group(1).split()) if block else set()
    packages = set(re.findall(r"run_suite \S+ (\w+Tests)", text))
    sim_block = re.search(r"CMUX_FORK_GATE_IOS_SIMULATOR_SUITES: >-\n((?:\s{4}\S+\n)+)", text)
    ios_simulator = set(sim_block.group(1).split()) if sim_block else set()
    return app_host, packages, ios_simulator


def workflow_skipped() -> set[str]:
    text = WORKFLOW.read_text(encoding="utf-8")
    block = re.search(r"CMUX_FORK_GATE_SKIPPED_TESTS: >-\n((?:\s{4}\S+\n)+)", text)
    return set(block.group(1).split()) if block else set()


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
    app_host, packages, ios_simulator = workflow_lists()
    in_app_target = declared_types(ROOT.glob("cmuxTests/**/*.swift"))
    in_packages = declared_types(ROOT.glob("Packages/**/Tests/**/*.swift"))
    in_ios_packages = declared_types(ROOT.glob("Packages/iOS/**/Tests/**/*.swift"))
    problems: list[str] = []
    for suite in sorted(ledger):
        if suite not in in_app_target and suite not in in_packages:
            problems.append(f"ledger names {suite} but no such suite exists in the tree")
        elif suite not in app_host and suite not in packages and suite not in ios_simulator:
            problems.append(f"ledger names {suite} but fork-gate.yml does not run it")
    for suite in sorted(ios_simulator):
        if suite not in in_ios_packages:
            problems.append(f"fork-gate.yml defers {suite} to the iOS simulator lane but no iOS package declares it")
    for suite in sorted(app_host):
        if suite not in in_app_target:
            problems.append(f"fork-gate.yml lists {suite} but cmuxTests has no such suite")
    for suite in sorted(packages):
        if suite not in in_packages:
            problems.append(f"fork-gate.yml runs package suite {suite} but no package declares it")
    skipped = workflow_skipped()
    for entry in sorted(skipped):
        if entry not in KNOWN_FAILING:
            problems.append(f"fork-gate.yml skips {entry} without a reason in KNOWN_FAILING")
        suite, _, test = entry.partition("/")
        src = "".join(p.read_text(encoding="utf-8", errors="replace") for p in ROOT.glob("cmuxTests/**/*.swift"))
        if not re.search(rf"func {re.escape(test)}\(", src):
            problems.append(f"fork-gate.yml skips {entry} but no such test exists; delete the entry")
        if suite not in app_host:
            problems.append(f"fork-gate.yml skips {entry} but {suite} is not a gated suite")
    for entry in sorted(KNOWN_FAILING):
        if entry not in skipped:
            problems.append(f"KNOWN_FAILING lists {entry} but fork-gate.yml does not skip it")
    for problem in problems:
        print(f"ERROR {problem}")
    if problems:
        return 1
    print(f"ok: {len(ledger)} ledger suites covered ({len(app_host)} app-host, {len(packages)} package, {len(ios_simulator)} iOS simulator); {len(skipped)} known-failing test(s) excluded by name")
    return 0


if __name__ == "__main__":
    sys.exit(main())
