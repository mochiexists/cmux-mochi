import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
DEPLOY_WORKFLOW = ROOT / ".github/workflows/docs-deploy-reusable.yml"
DOCS_VERCEL_CONFIG = ROOT / "web/vercel.docs-channel.json"
PRODUCTION_VERCEL_CONFIG = ROOT / "web/vercel.json"
HEALTH_WORKFLOW = ROOT / ".github/workflows/vercel-auth-health.yml"
CHANNELS_WORKFLOW = ROOT / ".github/workflows/docs-channels.yml"


def active_triggers(workflow: Path) -> set[str]:
    """Trigger names under `on:` that are live, ignoring commented-out ones."""
    triggers: set[str] = set()
    in_on_block = False
    for line in workflow.read_text().splitlines():
        if line.startswith("on:"):
            in_on_block = True
            continue
        if not in_on_block:
            continue
        if line.strip() and not line.startswith(" "):
            break
        if line.strip().startswith("#"):
            continue
        match = re.match(r"^  ([a-z_]+):", line)
        if match:
            triggers.add(match.group(1))
    return triggers


class DocsDeployAuthGuardTests(unittest.TestCase):
    def test_docs_deploy_uses_pinned_vercel_cli(self) -> None:
        workflow = DEPLOY_WORKFLOW.read_text()

        self.assertIn('bun-version: "1.3.14"', workflow)
        self.assertIn("bunx vercel@56.3.1 deploy", workflow)
        self.assertNotIn("bunx vercel deploy", workflow)
        self.assertNotIn("--token", workflow)

    def test_docs_deploy_excludes_production_crons(self) -> None:
        workflow = DEPLOY_WORKFLOW.read_text()
        config = json.loads(DOCS_VERCEL_CONFIG.read_text())
        production_config = json.loads(PRODUCTION_VERCEL_CONFIG.read_text())

        self.assertIn(
            "cp web/vercel.docs-channel.json web/vercel.json",
            workflow,
        )
        self.assertNotIn("--local-config", workflow)
        self.assertNotIn("crons", config)
        self.assertEqual(
            config,
            {key: value for key, value in production_config.items() if key != "crons"},
        )

    def test_vercel_auth_check_is_dispatch_only(self) -> None:
        # Fork overlay: upstream runs this canary on a daily cron. The fork has
        # no VERCEL_TOKEN, so a live schedule is a guaranteed daily red run.
        # The check itself stays intact and hand-runnable.
        workflow = HEALTH_WORKFLOW.read_text()

        self.assertEqual(active_triggers(HEALTH_WORKFLOW), {"workflow_dispatch"})
        self.assertIn('#   - cron: "17 6 * * *"', workflow)
        self.assertIn('bun-version: "1.3.14"', workflow)
        self.assertIn("bunx vercel@56.3.1 whoami", workflow)
        self.assertIn("VERCEL_TOKEN: ${{ secrets.VERCEL_TOKEN }}", workflow)
        self.assertNotIn("--token", workflow)

    def test_docs_channels_deploy_is_dispatch_only(self) -> None:
        # Fork overlay: upstream deploys the docs site on pushes to main and on
        # v* tags. The fork ships the macOS app and owns no Vercel project, so
        # both jobs can only fail on missing credentials. The push trigger is
        # preserved as a comment so a rebase against upstream stays readable.
        workflow = CHANNELS_WORKFLOW.read_text()

        self.assertEqual(active_triggers(CHANNELS_WORKFLOW), {"workflow_dispatch"})
        self.assertIn("#   branches: [main]", workflow)
        self.assertIn('#   tags: ["v*"]', workflow)


if __name__ == "__main__":
    unittest.main()
