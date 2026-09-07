from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ios-testflight.yml"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"


def workflow_text() -> str:
    return WORKFLOW.read_text(encoding="utf-8")


def workflow_job(text: str, name: str) -> str:
    marker = f"\n  {name}:\n"
    start = text.index(marker) + 1
    next_job = text.find("\n  ", start + len(marker))
    while next_job != -1:
        line_end = text.find("\n", next_job + 1)
        if line_end == -1:
            break
        candidate = text[next_job + 3 : line_end]
        if candidate.endswith(":") and " " not in candidate:
            return text[start:next_job]
        next_job = text.find("\n  ", line_end)
    return text[start:]


def test_upload_uses_the_fork_internal_identity() -> None:
    upload_job = workflow_job(workflow_text(), "upload")

    assert (
        "if: needs.decide.outputs.should_build == 'true' "
        "&& github.ref == 'refs/heads/main'"
        in upload_job
    )
    assert "IOS_BETA_BUNDLE_ID: com.cmux-mochi.ios" in upload_job
    assert "IOS_BETA_DISPLAY_NAME: cmux INTERNAL" in upload_job
    assert "testFlightInternalTestingOnly=YES" in upload_job
    assert "ARGS=(--lane beta --signing manual)" in upload_job


def test_external_distribution_is_rejected_instead_of_silently_routed() -> None:
    upload_job = workflow_job(workflow_text(), "upload")

    assert "marketing_version_override drives the external TestFlight lane" in upload_job
    assert "Dispatch without marketing_version_override." in upload_job
    assert "python3 ./ios/scripts/resolve_testflight_distribution.py" not in upload_job
    assert "IOS_BETA_BUNDLE_ID: dev.cmux.app.beta" not in upload_job
    assert "IOS_BETA_BUNDLE_ID: dev.cmux.app.demo" not in upload_job


def test_uploaded_build_is_assigned_to_the_internal_group() -> None:
    text = workflow_text()
    assignment_job = workflow_job(text, "assign-internal-group")

    assert "\n  assign-external-group:\n" not in text
    assert "needs: [decide, upload]" in assignment_job
    assert "github.ref == 'refs/heads/main'" in assignment_job
    assert "python3 ./ios/scripts/asc_assign_internal_testflight_group.py" in assignment_job
    assert "--bundle-id com.cmux-mochi.ios" in assignment_job
    assert "name: ios-testflight-assignment-state-complete" in assignment_job


def test_ci_executes_this_fork_distribution_guard() -> None:
    ci_text = CI_WORKFLOW.read_text(encoding="utf-8")

    assert "run: python3 tests/test_ios_testflight_fork_distribution.py" in ci_text
    assert "run: python3 tests/test_ios_testflight_pro_distribution.py" not in ci_text


if __name__ == "__main__":
    test_upload_uses_the_fork_internal_identity()
    test_external_distribution_is_rejected_instead_of_silently_routed()
    test_uploaded_build_is_assigned_to_the_internal_group()
    test_ci_executes_this_fork_distribution_guard()
    print("all fork iOS TestFlight distribution tests passed")
