#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Exercise release identity, trust, expiry, and idempotent publication failures."""

import base64
import contextlib
import copy
import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import plistlib
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


candidate = load("release-candidate")
environments = load("release-environments")
SOURCE = "a" * 40


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)
        command = patch.object(candidate, "run", return_value="")
        command.start()
        self.addCleanup(command.stop)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.env = patch.dict(os.environ, {"GITHUB_REPOSITORY": "fairchild/workspaces", "GITHUB_RUN_ID": "42", "GITHUB_RUN_ATTEMPT": "1"})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.args = SimpleNamespace(directory=self.directory, source=SOURCE, tag="v0.28.0", version="0.28.0", build="36", channel="stable", ci_run_id="12", previous_stable_tag="v0.27.0", reviewed_prs="1,2")
        manifest = {**candidate.expected(self.args), "assets": {}}
        for key, name, content in (("dmg", "WorkSpaces-0.28.0.dmg", b"signed-dmg"), ("latestDmg", "WorkSpaces-latest.dmg", b"signed-dmg"), ("appcast", "appcast.xml", b"signed-appcast")):
            path = self.directory / name
            path.write_bytes(content)
            manifest["assets"][key] = {"name": name, "size": len(content), "sha256": candidate.digest(path)}
        (self.directory / "release-manifest.json").write_text(json.dumps(manifest))
        (self.directory / "benchmark-check.txt").write_text("PASS")
        with patch.object(candidate, "release_notes", return_value="Reviewed notes\n"):
            candidate.seal(self.args)
        self.args.candidate_sha256 = candidate.digest(self.directory / "candidate.json")

    def test_exact_candidate_survives_a_failed_job_retry(self):
        with patch.dict(os.environ, {"GITHUB_RUN_ATTEMPT": "2"}):
            self.assertEqual(candidate.verify(self.args)["commitSha"], SOURCE)

    def test_replaced_installer_cannot_be_published(self):
        (self.directory / "WorkSpaces-0.28.0.dmg").write_bytes(b"replacement")
        with patch.object(candidate, "api") as api, self.assertRaisesRegex(ValueError, "changed"):
            candidate.publish(self.args)
        api.assert_not_called()

    def test_replaced_manifest_and_installer_cannot_reseal_identity(self):
        data = json.loads((self.directory / "candidate.json").read_text())
        data["commitSha"] = "b" * 40
        (self.directory / "candidate.json").write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "identity changed"):
            candidate.verify(self.args)

    def test_candidate_from_another_run_is_rejected(self):
        with patch.dict(os.environ, {"GITHUB_RUN_ID": "43"}), self.assertRaisesRegex(ValueError, "runId mismatch"):
            candidate.verify(self.args)

    def test_expired_and_future_candidates_require_a_new_preparation(self):
        for delta in (dt.timedelta(days=8), dt.timedelta(seconds=-10)):
            with self.subTest(delta=delta), patch.object(candidate, "now", return_value=candidate.now() + delta):
                with self.assertRaisesRegex(ValueError, "expired"):
                    candidate.verify(self.args)

    def test_symlinked_asset_is_rejected(self):
        path = self.directory / "WorkSpaces-0.28.0.dmg"
        path.unlink()
        path.symlink_to(self.directory / "WorkSpaces-latest.dmg")
        with self.assertRaisesRegex(ValueError, "regular"):
            candidate.verify(self.args)

    def test_unlisted_file_and_changed_notes_are_rejected(self):
        extra = self.directory / "unexpected.txt"
        extra.write_text("surprise")
        with self.assertRaisesRegex(ValueError, "file set"):
            candidate.verify(self.args)
        extra.unlink()
        (self.directory / "release-notes.md").write_text("Different release notes")
        with self.assertRaisesRegex(ValueError, "release-notes.md"):
            candidate.verify(self.args)

    def test_older_candidate_does_not_replace_newer_latest(self):
        with patch.object(candidate, "optional_api", return_value={"tag_name": "v0.29.0"}), patch.object(candidate, "api") as api:
            with self.assertRaisesRegex(ValueError, "newer stable"):
                candidate.publish(self.args)
            api.assert_not_called()

    def test_conflicting_stable_tag_is_not_moved(self):
        def lookup(path):
            return {"tag_name": "v0.27.0"} if path.endswith("latest") else {"object": {"type": "commit", "sha": "b" * 40}}
        with patch.object(candidate, "optional_api", side_effect=lookup), patch.object(candidate, "api") as api:
            with self.assertRaisesRegex(ValueError, "different source"):
                candidate.publish(self.args)
            api.assert_not_called()

    def test_publication_resumes_only_its_own_draft_and_verifies_before_publish(self):
        marker = f"<!-- candidate:{self.args.candidate_sha256} source:{SOURCE} -->"
        release = {"id": 7, "tag_name": self.args.tag, "draft": True, "body": candidate.publication_notes(self.args), "prerelease": False, "name": f"WorkSpaces {self.args.tag}", "target_commitish": SOURCE, "assets": [{"name": "appcast.xml"}]}
        calls = []
        def lookup(path):
            return {"tag_name": "v0.27.0"} if path.endswith("latest") else {"object": {"type": "commit", "sha": SOURCE}}
        def execute(*args, **kwargs):
            calls.append(args)
            if args[:2] == ("gh", "api"):
                return json.dumps([[release]])
            if args[:3] == ("gh", "release", "download"):
                directory = Path(args[args.index("--dir") + 1])
                for name in ("WorkSpaces-0.28.0.dmg", "WorkSpaces-latest.dmg", "appcast.xml", "release-manifest.json"):
                    (directory / name).write_bytes((self.directory / name).read_bytes())
            return ""
        with patch.object(candidate, "optional_api", side_effect=lookup), patch.object(candidate, "run", side_effect=execute), patch.object(candidate, "api") as api:
            candidate.publish(self.args)
            uploads = [args for args in calls if args[:3] == ("gh", "release", "upload")]
            self.assertEqual(len(uploads), 3)
            self.assertTrue(all("--clobber" not in args for args in uploads))
            api.assert_called_once_with("repos/fairchild/workspaces/releases/7", method="PATCH", data={"draft": False, "make_latest": "true"})
        release["body"] = "another candidate"
        with patch.object(candidate, "optional_api", side_effect=lookup), patch.object(candidate, "run", side_effect=execute), patch.object(candidate, "api") as api:
            with self.assertRaisesRegex(ValueError, "another candidate"):
                candidate.publish(self.args)
            api.assert_not_called()

    def test_notes_match_exact_section_not_neighboring_versions(self):
        notes = "# Changelog\n\n## [0.28.0] - today\n\nChosen notes\n\n## [0.27.0] - yesterday\nOld notes\n"
        self.assertEqual(candidate.release_notes(notes, "0.28.0"), "Chosen notes\n")
        with self.assertRaises(ValueError):
            candidate.release_notes(notes, "0.29.0")

    def test_corrupted_remote_asset_blocks_final_publication(self):
        marker = f"<!-- candidate:{self.args.candidate_sha256} source:{SOURCE} -->"
        assets = ["WorkSpaces-0.28.0.dmg", "WorkSpaces-latest.dmg", "appcast.xml", "release-manifest.json"]
        release = {"id": 7, "tag_name": self.args.tag, "draft": True, "body": candidate.publication_notes(self.args), "prerelease": False, "name": f"WorkSpaces {self.args.tag}", "target_commitish": SOURCE, "assets": [{"name": n} for n in assets]}
        def execute(*args, **kwargs):
            if args[:2] == ("gh", "api"):
                return json.dumps([[release]])
            if args[:3] == ("gh", "release", "download"):
                directory = Path(args[args.index("--dir") + 1])
                for name in assets:
                    (directory / name).write_bytes(b"wrong" if name == "appcast.xml" else (self.directory / name).read_bytes())
            return ""
        def lookup(path):
            return {"tag_name": "v0.27.0"} if path.endswith("latest") else {"object": {"type": "commit", "sha": SOURCE}}
        with patch.object(candidate, "optional_api", side_effect=lookup), patch.object(candidate, "run", side_effect=execute), patch.object(candidate, "api") as api:
            with self.assertRaisesRegex(ValueError, "Uploaded asset differs"):
                candidate.publish(self.args)
            api.assert_not_called()

    def test_transient_retry_reconciles_same_candidate_but_never_retries_rejection(self):
        with patch.object(candidate, "publish", side_effect=[RuntimeError("uncertain upload"), None]) as publish, patch.object(candidate.time, "sleep"):
            candidate.publish_with_retry(self.args)
            self.assertEqual(publish.call_args_list, [unittest.mock.call(self.args), unittest.mock.call(self.args)])
        with patch.object(candidate, "publish", side_effect=ValueError("identity changed")) as publish, patch.object(candidate.time, "sleep") as sleep:
            with self.assertRaises(ValueError):
                candidate.publish_with_retry(self.args)
            self.assertEqual(publish.call_count, 1)
            sleep.assert_not_called()

    def test_publication_metadata_cannot_change_under_an_intact_marker(self):
        release = {"id": 7, "body": candidate.publication_notes(self.args), "prerelease": False,
                   "name": f"WorkSpaces {self.args.tag}", "target_commitish": SOURCE}
        for field, value in (("body", "Changed notes\n" + release["body"]), ("prerelease", True),
                             ("name", "Different title"), ("target_commitish", "b" * 40)):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "metadata differs"):
                candidate.check_publication_metadata(self.args, {**release, field: value}, {"id": 6})

    def test_downstream_only_retry_rejects_tester_promoted_to_stable(self):
        self.args.channel = "tester"
        self.args.tag = "workspaces-v0.28.0-main.42"
        manifest_path = self.directory / "release-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["tag"] = self.args.tag
        manifest_path.write_text(json.dumps(manifest))
        with patch.object(candidate, "release_notes", return_value="Reviewed notes\n"):
            candidate.seal(self.args)
        self.args.candidate_sha256 = candidate.digest(self.directory / "candidate.json")
        self.args.published_directory = self.directory
        names = ("WorkSpaces-0.28.0.dmg", "WorkSpaces-latest.dmg", "appcast.xml", "release-manifest.json")
        release = {"id": 7, "body": candidate.publication_notes(self.args), "prerelease": True,
                   "name": f"WorkSpaces {self.args.tag}", "target_commitish": SOURCE, "draft": False,
                   "assets": [{"name": n} for n in names]}
        with patch.object(candidate, "api", return_value=release), patch.object(candidate, "optional_api", return_value={"id": 6}):
            candidate.verify_publication(self.args)
            release["prerelease"] = False
            with self.assertRaisesRegex(ValueError, "metadata differs"):
                candidate.verify_publication(self.args)
            release["prerelease"] = True
        with patch.object(candidate, "api", return_value=release), patch.object(candidate, "optional_api", return_value={"id": 7}):
            with self.assertRaisesRegex(ValueError, "latest stable"):
                candidate.verify_publication(self.args)


class TrustTests(unittest.TestCase):
    def test_newer_release_tooling_blocks_older_source(self):
        with patch.object(candidate, "run", return_value="scripts/notarize.sh\n"), self.assertRaisesRegex(ValueError, "tooling changed"):
            candidate.check_control_source(SOURCE)

    def test_notes_base_must_match_actual_metadata_merge_parent(self):
        parent = "b" * 40
        pr = {"merge_commit_sha": SOURCE, "merged_at": "2026-09-07T00:00:00Z", "base": {"ref": "main", "repo": {"full_name": "fairchild/workspaces"}},
              "body": f"<!-- release-entrypoint:0.28.0 -->\n<!-- release-base:{parent} -->"}
        with patch.object(candidate, "api", return_value=[pr]), patch.object(candidate, "run", return_value=parent):
            candidate.check_release_base("fairchild/workspaces", SOURCE, "0.28.0")
            pr["body"] = pr["body"].replace(parent, "c" * 40)
            with self.assertRaisesRegex(ValueError, "Main advanced"):
                candidate.check_release_base("fairchild/workspaces", SOURCE, "0.28.0")

    def test_actual_reviewed_range_rejects_bypassed_or_stale_approvals(self):
        pr = {"number": 1, "merge_commit_sha": SOURCE, "merged_at": "2026-09-07T00:02:00Z", "base": {"ref": "main", "repo": {"full_name": "fairchild/workspaces"}}, "head": {"sha": "b" * 40}, "user": {"login": "author"}}
        reviews = [{"state": "APPROVED", "commit_id": "b" * 40, "submitted_at": "2026-09-07T00:01:00Z", "user": {"login": "reviewer"}}]
        def execute(*args, **kwargs):
            if args[:2] == ("git", "rev-list"):
                return SOURCE
            if args[:2] == ("gh", "api"):
                return json.dumps([reviews])
            return ""
        with patch.object(candidate, "run", side_effect=execute), patch.object(candidate, "api", return_value=[pr]):
            self.assertEqual(candidate.check_reviewed_range("fairchild/workspaces", SOURCE, {"tag_name": "v0.27.0"}), [1])
            for field, value in (("state", "DISMISSED"), ("commit_id", "c" * 40), ("submitted_at", "2026-09-07T00:03:00Z"), ("user", {"login": "author"})):
                original = copy.deepcopy(reviews[0])
                reviews[0][field] = value
                with self.subTest(field=field), self.assertRaisesRegex(ValueError, "approving review"):
                    candidate.check_reviewed_range("fairchild/workspaces", SOURCE, {"tag_name": "v0.27.0"})
                reviews[0] = original
            reviews.append({**reviews[0], "state": "CHANGES_REQUESTED", "submitted_at": "2026-09-07T00:01:30Z"})
            with self.assertRaisesRegex(ValueError, "approving review"):
                candidate.check_reviewed_range("fairchild/workspaces", SOURCE, {"tag_name": "v0.27.0"})
        with patch.object(candidate, "run", side_effect=execute), patch.object(candidate, "api", return_value=[]):
            with self.assertRaisesRegex(ValueError, "no unambiguous merged main PR"):
                candidate.check_reviewed_range("fairchild/workspaces", SOURCE, {"tag_name": "v0.27.0"})

    def test_rebase_merged_pr_covers_all_introduced_commits_once(self):
        pr = {"number": 1, "merge_commit_sha": SOURCE, "merged_at": "2026-09-07T00:02:00Z", "base": {"ref": "main", "repo": {"full_name": "fairchild/workspaces"}}, "head": {"sha": "b" * 40}, "user": {"login": "author"}}
        reviews = [{"state": "APPROVED", "commit_id": "b" * 40, "submitted_at": "2026-09-07T00:01:00Z", "user": {"login": "reviewer"}}]
        review_reads = 0
        def execute(*args, **kwargs):
            nonlocal review_reads
            if args[:2] == ("git", "rev-list"):
                return SOURCE + "\n" + "c" * 40
            if args[:2] == ("gh", "api"):
                review_reads += 1
                return json.dumps([reviews])
            return ""
        with patch.object(candidate, "run", side_effect=execute), patch.object(candidate, "api", return_value=[pr]):
            self.assertEqual(candidate.check_reviewed_range("fairchild/workspaces", SOURCE, {"tag_name": "v0.27.0"}), [1])
        self.assertEqual(review_reads, 1)

    def test_only_metadata_commit_after_successful_main_ci_automatically_qualifies(self):
        ci = {"id": 12, "workflow_id": 9, "head_sha": SOURCE, "head_branch": "main", "event": "push", "head_repository": {"full_name": "fairchild/workspaces"}, "status": "completed", "conclusion": "success", "html_url": "https://github.com/fairchild/workspaces/actions/runs/12"}
        metadata = plistlib.dumps({"CFBundleShortVersionString": "0.28.0", "CFBundleVersion": "36", "CFBundleIdentifier": "com.cloudcompute.workspaces", "SUPublicEDKey": "public"}).decode()
        changed = [candidate.PLIST, "CHANGELOG.md"]
        title = "release: v0.28.0 (#123)"
        def execute(*args, **kwargs):
            if args[:2] == ("git", "diff-tree"):
                return "\n".join(changed)
            if args[:3] == ("git", "show", "-s"):
                return title
            if args[:2] == ("git", "show"):
                return metadata
            return ""
        def read(path):
            return {"id": 9} if path.endswith("ci.yml") else ci
        with tempfile.TemporaryDirectory() as temp:
            event = Path(temp) / "event.json"
            event.write_text(json.dumps({"workflow_run": ci}))
            env = {"GITHUB_EVENT_PATH": str(event), "GITHUB_REPOSITORY": "fairchild/workspaces", "GITHUB_REF": "refs/heads/main", "GITHUB_EVENT_NAME": "workflow_run"}
            with patch.dict(os.environ, env), patch.object(candidate, "run", side_effect=execute), patch.object(candidate, "api", side_effect=read), patch.object(candidate, "optional_api", return_value=None), patch.object(candidate, "check_reviewed_range", return_value=[1]), patch.object(candidate, "check_release_base"), patch.object(candidate, "emit") as emit:
                candidate.source(SimpleNamespace(channel="stable"))
                self.assertEqual(emit.call_args.args[0]["source"], SOURCE)
                self.assertEqual(emit.call_args.args[0]["eligible"], "true")
                changed.append("Sources/Unexpected.swift")
                candidate.source(SimpleNamespace(channel="stable"))
                emit.assert_called_with({"eligible": "false"})
                changed.pop()
                title = "chore: routine metadata cleanup"
                candidate.source(SimpleNamespace(channel="stable"))
                emit.assert_called_with({"eligible": "false"})
                ci["head_repository"] = {"full_name": "foreign/workspaces"}
                with self.assertRaisesRegex(ValueError, "trusted main CI"):
                    candidate.source(SimpleNamespace(channel="stable"))

    def test_only_successful_main_ci_for_this_repo_and_sha_qualifies(self):
        good = {"workflow_id": 9, "head_sha": SOURCE, "head_branch": "main", "event": "push", "head_repository": {"full_name": "fairchild/workspaces"}, "status": "completed", "conclusion": "success"}
        with patch.object(candidate, "api", return_value={"id": 9}):
            candidate.check_ci("fairchild/workspaces", SOURCE, good)
            for key, value in (("workflow_id", 8), ("head_sha", "b" * 40), ("head_branch", "feature"), ("event", "pull_request"), ("head_repository", {"full_name": "attacker/workspaces"}), ("conclusion", "failure"), ("status", "in_progress")):
                with self.subTest(key=key), self.assertRaises(ValueError):
                    candidate.check_ci("fairchild/workspaces", SOURCE, {**good, key: value})

    def test_missing_publication_gate_or_broad_signing_refs_fail_closed(self):
        signing = {"protection_rules": [], "deployment_branch_policy": environments.POLICY}
        human = {"type": "required_reviewers", "reviewers": [{"type": "User", "reviewer": {"id": 2037, "type": "User"}}]}
        publication = {**signing, "protection_rules": [human], "can_admins_bypass": False}
        def read(path):
            if path.endswith("deployment-branch-policies"):
                return {"branch_policies": [{"name": "main", "type": "branch"}]}
            return ({**publication, "protection_rules": [human]} if path.endswith("/release") else publication if path.endswith("release-publication") else signing)
        with patch.object(environments, "api", side_effect=read):
            environments.check("fairchild/workspaces")
            publication["protection_rules"] = []
            with self.assertRaisesRegex(ValueError, "human reviewer"):
                environments.check("fairchild/workspaces")
            publication["protection_rules"] = [human]
            signing["protection_rules"] = [human]
            with self.assertRaisesRegex(ValueError, "still requires approval"):
                environments.check("fairchild/workspaces")
            signing["protection_rules"] = []
            with patch.object(environments, "main_only", return_value=False), self.assertRaisesRegex(ValueError, "only the main"):
                environments.check("fairchild/workspaces")

    def test_migration_refuses_unmerged_workflow_before_any_write(self):
        with patch.object(environments, "api", return_value={"content": base64.b64encode(b"old workflow").decode()}) as api:
            with self.assertRaisesRegex(ValueError, "Merge the reviewed"):
                environments.apply("fairchild/workspaces")
            self.assertEqual(api.call_count, 1)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.fail_publication_policy = False
        self.publication_secrets = set()
        self.candidate_secrets = environments.SIGNING_SECRETS.copy()
        self.human = {"type": "User", "reviewer": {"type": "User", "id": 2037}}
        self.values = {"release": {"protection_rules": [{"type": "required_reviewers", "reviewers": [self.human]}], "deployment_branch_policy": environments.POLICY, "can_admins_bypass": False}}
        self.policies = {"release": [{"name": "main", "type": "branch", "id": 1}, {"name": "v*", "type": "tag", "id": 2}]}

    def api(self, path, method="GET", data=None):
        self.calls.append((path, method, copy.deepcopy(data)))
        if "/contents/" in path:
            return {"content": base64.b64encode((ROOT / ".github/workflows/release.yml").read_bytes()).decode()}
        if "/rules/branches/" in path:
            return [{"type": "pull_request", "parameters": {"required_approving_review_count": 1}}]
        name = path.split("/environments/")[1].split("/")[0]
        if "/secrets?" in path:
            names = self.publication_secrets if name == "release-publication" else self.candidate_secrets
            return {"secrets": [{"name": n} for n in names]}
        if "deployment-branch-policies" in path:
            if method == "POST":
                if self.fail_publication_policy and name == "release-publication":
                    raise RuntimeError("policy creation failed")
                self.policies[name].append({**data, "id": 3})
            elif method == "DELETE":
                self.policies[name] = [p for p in self.policies[name] if p["id"] != int(path.split("/")[-1])]
            return {"branch_policies": copy.deepcopy(self.policies[name])}
        if method == "PUT":
            self.assertNotEqual(name, "release", "legacy environment must never be mutated")
            if name == "release-candidate" and not data["reviewers"]:
                self.assertTrue(environments.reviewers(self.values["release-publication"]))
                self.assertFalse(self.publication_secrets)
                self.assertEqual(self.candidate_secrets, environments.SIGNING_SECRETS)
                for gate in ("release-candidate", "release-publication"):
                    self.assertEqual([(p["name"], p["type"]) for p in self.policies[gate]], [("main", "branch")])
            self.values[name] = {**data, "protection_rules": [{"type": "required_reviewers", "reviewers": [self.human]}] if data["reviewers"] else []}
            self.policies.setdefault(name, [])
        if name not in self.values:
            raise RuntimeError("HTTP 404")
        return copy.deepcopy(self.values[name])

    def test_legacy_gate_survives_initial_setup_and_idempotent_resume(self):
        before = copy.deepcopy(self.values["release"])
        with patch.object(environments, "api", side_effect=self.api):
            environments.apply("fairchild/workspaces")
            environments.apply("fairchild/workspaces")
        self.assertEqual(self.values["release"], before)
        self.assertFalse(environments.reviewers(self.values["release-candidate"]))
        self.assertTrue(environments.reviewers(self.values["release-publication"]))

    def test_missing_credentials_leave_new_signing_gate_approved_only(self):
        self.candidate_secrets.remove("SPARKLE_PRIVATE_KEY")
        with patch.object(environments, "api", side_effect=self.api), self.assertRaisesRegex(ValueError, "SPARKLE_PRIVATE_KEY"):
            environments.apply("fairchild/workspaces")
        self.assertTrue(environments.reviewers(self.values["release-candidate"]))
        self.assertTrue(environments.reviewers(self.values["release"]))

    def test_publication_secrets_block_signing_configuration(self):
        self.publication_secrets.add("SPARKLE_PRIVATE_KEY")
        with patch.object(environments, "api", side_effect=self.api), self.assertRaisesRegex(ValueError, "Publication environment contains secrets"):
            environments.apply("fairchild/workspaces")
        self.assertNotIn("release-candidate", self.values)

    def test_failed_new_gate_leaves_legacy_and_candidate_untouched(self):
        self.fail_publication_policy = True
        with patch.object(environments, "api", side_effect=self.api), self.assertRaisesRegex(RuntimeError, "policy creation"):
            environments.apply("fairchild/workspaces")
        self.assertNotIn("release-candidate", self.values)
        self.assertTrue(environments.reviewers(self.values["release"]))


if __name__ == "__main__":
    unittest.main()
