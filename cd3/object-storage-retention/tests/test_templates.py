"""Offline guardrails for the shipped examples; not an OCI authorization simulator."""

import ast
import datetime
import os
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
POLICIES = ROOT / "policies"
EXECUTOR = "dynamic-group id <CD3_EXECUTOR_DYNAMIC_GROUP_OCID>"
SCOPE = "in compartment id <LOGGING_COMPARTMENT_OCID>"
BUCKET = "target.bucket.name='<EVIDENCE_BUCKET_NAME>'"


def statements(filename):
    return [
        line.strip()
        for line in (POLICIES / filename).read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def permissions(statement):
    return set(re.findall(r"request\.permission='([A-Z_]+)'", statement))


class TemplateChecks(unittest.TestCase):
    def test_runtime_has_three_statements(self):
        self.assertEqual(len(statements("01-cd3-runtime.txt")), 3)

    def test_runtime_principal_and_read_only_discovery(self):
        lines = statements("01-cd3-runtime.txt")
        self.assertTrue(all(s.startswith(f"Allow {EXECUTOR} to ") for s in lines))
        self.assertEqual(lines[0], f"Allow {EXECUTOR} to read objectstorage-namespaces in tenancy")
        self.assertEqual(lines[1], f"Allow {EXECUTOR} to inspect buckets {SCOPE}")

    def test_runtime_exact_mutation_allowlist(self):
        stmt = statements("01-cd3-runtime.txt")[2]
        self.assertIn(f"to manage buckets {SCOPE} where all {{", stmt)
        self.assertIn(BUCKET, stmt)
        self.assertEqual(permissions(stmt), {
            "BUCKET_READ", "BUCKET_UPDATE", "RETENTION_RULE_MANAGE"
        })

    def test_create_is_separate_and_bucket_scoped(self):
        lines = statements("02-create-bucket-optional.txt")
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith(f"Allow {EXECUTOR} to manage buckets {SCOPE}"))
        self.assertIn(BUCKET, lines[0])
        self.assertEqual(permissions(lines[0]), {"BUCKET_CREATE"})

    def test_lock_approvers_are_separate_human_group(self):
        lines = statements("03-lock-approvers-optional.txt")
        self.assertEqual(len(lines), 3)
        self.assertTrue(all(s.startswith("Allow group id <RETENTION_LOCK_APPROVERS_GROUP_OCID> to ") for s in lines))
        self.assertIn(BUCKET, lines[2])
        self.assertIn(SCOPE, lines[2])
        self.assertEqual(permissions(lines[2]), {
            "BUCKET_READ", "BUCKET_UPDATE", "RETENTION_RULE_MANAGE", "RETENTION_RULE_LOCK"
        })

    def test_discovery_is_not_iam_administration(self):
        self.assertEqual(statements("04-compartment-discovery-optional.txt"), [
            f"Allow {EXECUTOR} to inspect compartments in tenancy"
        ])

    def test_no_broad_grants_or_real_ocids(self):
        for path in POLICIES.glob("*.txt"):
            for stmt in statements(path.name):
                with self.subTest(file=path.name):
                    self.assertTrue(stmt.startswith("Allow "))
                    self.assertNotRegex(stmt, r"\b(all-resources|object-family|objects|policies|dynamic-groups)\b")
                    self.assertNotIn("ocid1.", stmt)
                    self.assertNotIn("!=", stmt)
                    self.assertEqual(stmt.count("{"), stmt.count("}"))
                    self.assertEqual(stmt.count("'") % 2, 0)

    def test_only_approver_template_grants_lock(self):
        for path in POLICIES.glob("*.txt"):
            granted = set().union(*(permissions(s) for s in statements(path.name)))
            self.assertEqual("RETENTION_RULE_LOCK" in granted, path.name == "03-lock-approvers-optional.txt")

    def test_readme_contains_required_safety_gates(self):
        guide = (ROOT / "README.md").read_text(encoding="utf-8")
        for text in (
            "seven-year-security-evidence::7::YEARS",
            "does not cancel another grant",
            "Terraform-state bucket",
            "complete existing statement list",
            "at least 14 days",
            "not proof of deployment",
        ):
            self.assertTrue(text in guide, f"Missing documented safety gate: {text}")


@unittest.skipUnless(os.environ.get("CD3_SOURCE_DIR"), "optional trusted upstream checkout not specified")
class CD3ParserContract(unittest.TestCase):
    """Execute only the pure retention parsing block, never SDK/client setup.

    Supply a trusted checkout: Python source is executable input. No upstream
    files or spreadsheets are modified, and no authentication is requested.
    """

    @classmethod
    def setUpClass(cls):
        source = Path(os.environ["CD3_SOURCE_DIR"]) / (
            "cd3_automation_toolkit/ocicloud/python/storage/objectstorage/create_terraform_oss.py"
        )
        tree = ast.parse(source.read_text(encoding="utf-8"))
        matches = [node for node in ast.walk(tree) if isinstance(node, ast.If)
                   and ast.unparse(node.test) == "columnname == 'Retention Rules' and columnvalue != ''"]
        if len(matches) != 1:
            raise AssertionError("Expected exactly one known CD3 retention parsing block")
        module = ast.Module(body=matches, type_ignores=[])
        cls.parser = compile(ast.fix_missing_locations(module), str(source), "exec")

    def parse_rule(self, value):
        context = {
            "columnname": "Retention Rules", "columnvalue": value,
            "df": {"Retention Rules": {0: value}}, "i": 0,
            "re": re, "datetime": datetime,
        }
        exec(self.parser, context)
        return context["tempdict"]["retention_rules"]

    def test_seven_year_example_has_no_lock(self):
        self.assertEqual(self.parse_rule("seven-year-security-evidence::7::YEARS"), [{
            "retention_rule_display_name": "seven-year-security-evidence",
            "time_amount": 7, "time_unit": "YEARS", "time_rule_locked": None,
        }])

    def test_disposable_example_has_no_lock(self):
        rule = self.parse_rule("validation-retention::1::DAYS")[0]
        self.assertEqual((rule["time_amount"], rule["time_unit"], rule["time_rule_locked"]), (1, "DAYS", None))

    def test_multiple_rules_are_preserved(self):
        rules = self.parse_rule("first::1::DAYS\nsecond::7::YEARS")
        self.assertEqual(len(rules), 2)
        self.assertTrue(all(r["time_rule_locked"] is None for r in rules))


if __name__ == "__main__":
    unittest.main()
