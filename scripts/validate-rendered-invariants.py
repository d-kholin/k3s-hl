#!/usr/bin/env python3
"""Validate operationally critical values in rendered Kubernetes YAML."""

from __future__ import annotations

import re
import sys
from pathlib import Path


EXPECTED_IP = "172.20.0.7"
EXPECTED_HOST = "proxy.thegriffiths.ca"


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <rendered-newt.yaml>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    if not path.is_file() or path.stat().st_size == 0:
        print(f"ERROR: rendered manifest is missing or empty: {path}", file=sys.stderr)
        return 2

    rendered = path.read_text(encoding="utf-8")
    ip_count = len(
        re.findall(rf"^\s+ip: {re.escape(EXPECTED_IP)}$", rendered, re.MULTILINE)
    )
    host_count = len(
        re.findall(rf"^\s+- {re.escape(EXPECTED_HOST)}$", rendered, re.MULTILINE)
    )

    errors: list[str] = []
    if ip_count != 2:
        errors.append(
            f"Newt render must contain exactly two hostAliases entries for "
            f"{EXPECTED_IP}; found {ip_count}"
        )
    if host_count != 2:
        errors.append(
            f"Newt render must contain exactly two hostAliases entries for "
            f"{EXPECTED_HOST}; found {host_count}"
        )
    if re.search(
        r"newt-shared-config|PANGOLIN_LAN_IP|^\s+ip: 0\.0\.0\.0$",
        rendered,
        re.MULTILINE,
    ):
        errors.append("Newt render contains an unresolved or generated hostAliases value")

    if errors:
        for error in errors:
            print(f"::error::{error}", file=sys.stderr)
        return 1

    print("Validated rendered Newt hostAliases invariants.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
