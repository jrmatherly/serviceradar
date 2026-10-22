"""Contract tests for OCI push target declarations."""

from pathlib import Path
import re
import unittest


class PushTargetsTest(unittest.TestCase):
    def setUp(self):
        self.push_calls = []
        self.template_calls = []
        # Inventory entries carry the image NAME only; the registry and project
        # come from stamped workspace status (STABLE_OCI_REGISTRY / _PROJECT).
        inventory = [
            {
                "image": "alpha_image_amd64",
                "repository": "alpha",
            },
            {
                "image": "bravo_image_amd64",
                "push_image": "bravo_image_multiarch",
                "repository": "bravo",
            },
        ]

        namespace = {
            "PUBLISHABLE_IMAGES": inventory,
            "command": lambda **_kwargs: None,
            "expand_template": lambda **kwargs: self.template_calls.append(kwargs),
            "immutable_push_tags": lambda **_kwargs: None,
            "load": lambda *_args: None,
            "multirun": lambda **_kwargs: None,
            "oci_push": lambda **kwargs: self.push_calls.append(kwargs),
        }
        exec(
            compile(Path(__file__).with_name("fork_registry.bzl").read_text(), "fork_registry.bzl", "exec"),
            namespace,
        )
        self.fork = {k: namespace[k] for k in ("FORK_OCI_REGISTRY", "FORK_OCI_PROJECT")}
        source = Path(__file__).with_name("push_targets.bzl").read_text()
        exec(compile(source, "push_targets.bzl", "exec"), namespace)
        namespace["declare_oci_push_targets"]()

    def test_commit_only_targets_use_only_the_stamped_commit_tag(self):
        commit_only_calls = {
            call["name"]: call
            for call in self.push_calls
            if call["name"].endswith("_push_commit_only")
        }

        self.assertEqual(
            commit_only_calls,
            {
                "alpha_image_amd64_push_commit_only": {
                    "name": "alpha_image_amd64_push_commit_only",
                    "image": ":alpha_image_amd64",
                    "repository_file": ":alpha_image_amd64_repository",
                    "remote_tags": ":alpha_image_amd64_commit_tag",
                    "visibility": ["//visibility:public"],
                },
                "bravo_image_amd64_push_commit_only": {
                    "name": "bravo_image_amd64_push_commit_only",
                    "image": ":bravo_image_multiarch",
                    "repository_file": ":bravo_image_amd64_repository",
                    "remote_tags": ":bravo_image_amd64_commit_tag",
                    "visibility": ["//visibility:public"],
                },
            },
        )

    def test_repository_is_stamped_from_registry_and_project(self):
        repo_templates = {
            call["name"]: call
            for call in self.template_calls
            if call["name"].endswith("_repository")
        }
        self.assertEqual(
            sorted(repo_templates),
            ["alpha_image_amd64_repository", "bravo_image_amd64_repository"],
        )
        alpha = repo_templates["alpha_image_amd64_repository"]
        self.assertEqual(
            alpha["template"], ["{{STABLE_OCI_REGISTRY}}/{{STABLE_OCI_PROJECT}}/alpha"]
        )
        self.assertEqual(alpha["stamp"], 1)
        self.assertEqual(
            alpha["stamp_substitutions"],
            {
                "{{STABLE_OCI_REGISTRY}}": "{{STABLE_OCI_REGISTRY}}",
                "{{STABLE_OCI_PROJECT}}": "{{STABLE_OCI_PROJECT}}",
            },
        )
        # Unstamped builds still produce a usable, fork-owned default.
        self.assertEqual(
            alpha["substitutions"],
            {
                "{{STABLE_OCI_REGISTRY}}": self.fork["FORK_OCI_REGISTRY"],
                "{{STABLE_OCI_PROJECT}}": self.fork["FORK_OCI_PROJECT"],
            },
        )
        for call in self.push_calls:
            self.assertNotIn("repository", call)

    def test_bulk_push_target_pattern_excludes_commit_only_targets(self):
        commit_only_names = [
            call["name"]
            for call in self.push_calls
            if call["name"].endswith("_push_commit_only")
        ]

        self.assertEqual(len(commit_only_names), 2)
        for name in commit_only_names:
            self.assertIsNone(re.fullmatch(r".*_push", name))


if __name__ == "__main__":
    unittest.main()
