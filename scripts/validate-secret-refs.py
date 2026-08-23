#!/usr/bin/env python3
"""Validate Kubernetes secret references without decrypting SOPS values.

SOPS leaves mapping keys in plaintext, so Secret names and data keys can be
compared with secretKeyRef/secretRef declarations using only the encrypted
files. This parser intentionally handles the small Kubernetes YAML subset used
by this repository and has no third-party dependencies.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
YAML_FILES = ("*.yaml", "*.yml")
FIELD = re.compile(r"^(?P<indent>\s*)(?P<key>[^#][^:]*):(?:\s*(?P<value>.*))?$")


@dataclass(frozen=True)
class SecretDefinition:
    name: str
    keys: frozenset[str]
    path: Path


@dataclass(frozen=True)
class SecretReference:
    name: str
    key: str | None
    path: Path
    line: int


def yaml_files() -> list[Path]:
    files: set[Path] = set()
    for pattern in YAML_FILES:
        files.update(ROOT.rglob(pattern))
    return sorted(path for path in files if ".git" not in path.parts)


def unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def child_fields(lines: list[str], start: int) -> dict[str, tuple[str, int]]:
    """Return scalar descendants before indentation leaves the parent block."""
    parent_indent = len(lines[start]) - len(lines[start].lstrip())
    fields: dict[str, tuple[str, int]] = {}
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if indent <= parent_indent:
            break
        match = FIELD.match(line)
        if match and match.group("value"):
            fields[match.group("key").strip()] = (
                unquote(match.group("value")),
                index + 1,
            )
    return fields


def parse_secret(path: Path) -> SecretDefinition | None:
    lines = path.read_text(encoding="utf-8").splitlines()
    if not any(re.match(r"^kind:\s*Secret\s*$", line) for line in lines):
        return None

    name: str | None = None
    keys: set[str] = set()
    for index, line in enumerate(lines):
        if re.match(r"^metadata:\s*$", line):
            name = child_fields(lines, index).get("name", (None, 0))[0]
        if re.match(r"^(data|stringData):\s*$", line):
            section_indent = len(line) - len(line.lstrip())
            for child in lines[index + 1 :]:
                if not child.strip() or child.lstrip().startswith("#"):
                    continue
                indent = len(child) - len(child.lstrip())
                if indent <= section_indent:
                    break
                match = FIELD.match(child)
                if match and indent > section_indent:
                    keys.add(unquote(match.group("key")))

    if not name:
        raise ValueError(f"{path.relative_to(ROOT)}: Secret has no metadata.name")
    return SecretDefinition(name, frozenset(keys), path)


def parse_references(path: Path) -> list[SecretReference]:
    if path.name.endswith(".sops.yaml") or path.name.endswith(".sops.yml"):
        return []
    lines = path.read_text(encoding="utf-8").splitlines()
    references: list[SecretReference] = []
    for index, line in enumerate(lines):
        match = re.match(r"^\s*(secretKeyRef|secretRef):\s*$", line)
        if not match:
            continue
        kind = match.group(1)
        fields = child_fields(lines, index)
        name = fields.get("name", ("", index + 1))[0]
        key = fields.get("key", (None, 0))[0] if kind == "secretKeyRef" else None
        if not name or (kind == "secretKeyRef" and not key):
            raise ValueError(
                f"{path.relative_to(ROOT)}:{index + 1}: incomplete {kind}"
            )
        references.append(SecretReference(name, key, path, index + 1))
    return references


def main() -> int:
    errors: list[str] = []
    definitions: dict[str, SecretDefinition] = {}

    try:
        for path in yaml_files():
            if not (path.name.endswith(".sops.yaml") or path.name.endswith(".sops.yml")):
                continue
            definition = parse_secret(path)
            if definition is None:
                continue
            if definition.name in definitions:
                first = definitions[definition.name].path.relative_to(ROOT)
                errors.append(
                    f"{path.relative_to(ROOT)}: duplicate encrypted Secret "
                    f"{definition.name!r}; first declared in {first}"
                )
            definitions[definition.name] = definition

        for path in yaml_files():
            for reference in parse_references(path):
                location = f"{path.relative_to(ROOT)}:{reference.line}"
                definition = definitions.get(reference.name)
                if definition is None:
                    errors.append(
                        f"{location}: references undeclared encrypted Secret "
                        f"{reference.name!r}"
                    )
                elif reference.key is not None and reference.key not in definition.keys:
                    errors.append(
                        f"{location}: Secret {reference.name!r} has no key "
                        f"{reference.key!r}"
                    )
    except (OSError, UnicodeError, ValueError) as error:
        errors.append(str(error))

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print(
        f"Validated secret references against {len(definitions)} encrypted Secrets."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
