#!/usr/bin/env python3
"""Validate project subnet settings through the launcher and real Compose parser."""

import ipaddress
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
COMPOSE = os.environ.get("MYCODEX_TEST_COMPOSE", "docker compose")


@unittest.skipUnless(shutil.which(shlex.split(COMPOSE)[0]), "Docker Compose is required")
class NetworkConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mycodex-network-test-")
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name) / "first-project"
        self.project.mkdir()
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("MYCODEX_", "CODEX_", "COMPOSE_"))
        }
        self.env["MYCODEX_COMPOSE"] = COMPOSE

    def config(self, *args):
        result = subprocess.run(
            ["bash", str(ROOT / "bin/myCodex"), *args, "config", "--format", "json"],
            cwd=self.project, env=self.env, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def subnet(self, config):
        return config["networks"]["default"]["ipam"]["config"][0].get("subnet", "")

    def test_default_requests_small_automatic_subnet_per_project(self):
        first = self.config()
        self.assertEqual(self.subnet(first), "0.0.0.0/28")
        self.assertEqual(ipaddress.ip_network(self.subnet(first)).num_addresses, 16)
        self.assertEqual(set(first["services"]["codex"]["networks"]), {"default"})
        self.assertNotIn("network_mode", first["services"]["codex"])
        self.assertFalse(first["networks"]["default"].get("external", False))
        self.project = Path(self.temp.name) / "second-project"
        self.project.mkdir()
        second = self.config()
        self.assertEqual(self.subnet(second), "0.0.0.0/28")
        self.assertNotEqual(first["networks"]["default"]["name"],
                            second["networks"]["default"]["name"])

    def test_larger_automatic_subnet(self):
        self.env["MYCODEX_NETWORK_SUBNET"] = "0.0.0.0/24"
        self.assertEqual(self.subnet(self.config()), "0.0.0.0/24")

    def test_fixed_subnet(self):
        self.env["MYCODEX_NETWORK_SUBNET"] = "10.231.0.0/28"
        self.assertEqual(self.subnet(self.config()), "10.231.0.0/28")

    def test_explicit_empty_value_restores_daemon_allocation(self):
        self.env["MYCODEX_NETWORK_SUBNET"] = ""
        self.assertEqual(self.subnet(self.config()), "")

    def test_port_override_keeps_small_subnet(self):
        override = Path(self.temp.name) / "ports.yaml"
        override.write_text('services:\n  codex:\n    ports:\n      - "3000:3000"\n')
        config = self.config("-f", str(override))
        self.assertEqual(self.subnet(config), "0.0.0.0/28")
        self.assertEqual(config["services"]["codex"]["ports"][0]["target"], 3000)


if __name__ == "__main__":
    unittest.main()
