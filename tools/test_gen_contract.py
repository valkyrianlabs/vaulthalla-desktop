#!/usr/bin/env python3
"""Tests for tools/gen-contract.py's compatibility baseline: which response members it makes optional, how they are
generated, and (with a Swift toolchain) that the generated type decodes a daemon answer that leaves them out.

  python3 tools/test_gen_contract.py
"""

from __future__ import annotations

import copy
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("gen_contract", HERE / "gen-contract.py")
gen = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules["gen_contract"] = gen
spec.loader.exec_module(gen)


def field(name: str, types: list[str], required: bool = True, **extra) -> dict:
    return {"name": name, "types": types, "required": required, **extra}


def command(name: str, payload: list[dict], response: list[dict], **extra) -> dict:
    return {
        "auth": "human", "client_timeout_ms": 15000, "command": name, "confirmations": [], "description": name,
        "input": "payload", "operation": None, "payload": payload, "refusal_codes": [], "refusal_kinds": [],
        "response": response, "response_model": None, "untyped_refusals": [], "variants": [], **extra,
    }


def contract(models: list[dict], ws: list[dict], version: int = 2) -> dict:
    doc = {"contract_version": version, "models": models, "ws": ws}
    doc["models_hash"] = gen.canonical_hash(models)
    doc["ws_hash"] = gen.canonical_hash(ws)
    return doc


ENTRY_BASE = [field("id", ["integer"]), field("name", ["string"]), field("note", ["string", "null"]),
              field("tag", ["string"], required=False)]
ENTRY_NOW = ENTRY_BASE[:2] + [field("note", ["string"]), field("tag", ["string"]),
                              field("metadata_version", ["integer"])]


def baseline_doc() -> dict:
    return contract(
        [{"name": "Entry", "fields": copy.deepcopy(ENTRY_BASE)}],
        [command("fs.get", [field("id", ["integer"])],
                 [field("entry", ["object"], model="Entry"),
                  field("stats", ["object"], fields=[field("count", ["integer"])])])],
    )


def current_doc() -> dict:
    return contract(
        [{"name": "Entry", "fields": copy.deepcopy(ENTRY_NOW)},
         {"name": "Fresh", "fields": [field("x", ["integer"])]}],
        [command("fs.get", [field("id", ["integer"]), field("since", ["integer"])],
                 [field("entry", ["object"], model="Entry"),
                  field("stats", ["object"], fields=[field("count", ["integer"]), field("bytes", ["integer"])]),
                  field("cursor", ["string"])]),
         command("fs.new", [], [field("y", ["integer"])])],
    )


class RelaxTests(unittest.TestCase):
    def test_marks_only_what_the_baseline_does_not_guarantee(self) -> None:
        now = current_doc()
        relaxed = gen.relax(now, baseline_doc())
        self.assertEqual(sorted(relaxed), sorted([
            "Entry.note",              # nullable in the baseline, not here
            "Entry.tag",               # optional in the baseline
            "Entry.metadata_version",  # absent from the baseline
            "fs.get.stats.bytes",      # nested inline object
            "fs.get.cursor",           # absent from the baseline's response
        ]))
        entry = {f["name"]: f for f in now["models"][0]["fields"]}
        self.assertNotIn(gen.RELAXED, entry["id"])
        # Models and commands the baseline doesn't have keep their members: an older daemon never sends them.
        self.assertNotIn(gen.RELAXED, now["models"][1]["fields"][0])
        self.assertNotIn(gen.RELAXED, now["ws"][1]["response"][0])
        # Payloads stay as the current contract says.
        self.assertTrue(all(gen.RELAXED not in f for f in now["ws"][0]["payload"]))

    def test_share_variants_and_response_models(self) -> None:
        base = baseline_doc()
        base["ws"][0]["variants"] = [{"mode": "share", "payload": [], "response": [field("a", ["integer"])]}]
        now = current_doc()
        now["ws"][0]["variants"] = [{"mode": "share", "payload": [],
                                     "response": [field("a", ["integer"]), field("b", ["integer"])]}]
        now["ws"].append(command("entry.get", [], copy.deepcopy(ENTRY_NOW), response_model="Entry"))
        relaxed = gen.relax(now, base)
        self.assertIn("fs.get (share).b", relaxed)
        # A response_model command is marked like its model (and not listed twice).
        self.assertEqual(now["ws"][-1]["response"], now["models"][0]["fields"])
        self.assertFalse(any(r.startswith("entry.get") for r in relaxed))

    def test_relaxed_member_is_generated_optional(self) -> None:
        now = current_doc()
        book = gen.Book(now, baseline_doc(), {"server_version": "1.17.0", "ws_hash": "h"})
        swift = "\n".join(book.models["Entry"].struct.lines(0))
        self.assertIn("public var id: Int64\n", swift)
        self.assertIn("public var metadataVersion: Int64?", swift)
        self.assertIn("public var note: String?", swift)
        self.assertIn("compatibility baseline doesn't guarantee it", swift)
        # The minimal sample leaves relaxed members out (the generated tests decode it), the full one keeps them.
        minimal = gen.sample_object(now["models"][0]["fields"], False, book.models)
        self.assertEqual(sorted(minimal), ["id", "name"])
        full = gen.sample_object(now["models"][0]["fields"], True, book.models)
        self.assertIn("metadata_version", full)
        contract_swift = gen.generate_contract_swift(book, json.dumps(now))
        self.assertIn('public static let baselineServerVersion = "1.17.0"', contract_swift)
        self.assertIn('"Entry.metadata_version"', contract_swift)

    def test_contract_version_3_is_accepted(self) -> None:
        gen.validate(contract([], [], version=3))
        with self.assertRaises(gen.ContractError):
            gen.validate(contract([], [], version=4))

    @unittest.skipUnless(shutil.which("swiftc"), "needs a Swift toolchain")
    def test_generated_type_decodes_without_the_newer_member(self) -> None:
        now = current_doc()
        book = gen.Book(now, baseline_doc(), {"server_version": "1.17.0", "ws_hash": "h"})
        struct = "\n".join(book.models["Entry"].struct.lines(0))
        program = "import Foundation\n" + struct + """

// What a 1.17 daemon sends: no metadata_version, no tag, a null note.
let old = #"{"id": 7, "name": "a", "note": null}"#
let decoded = try JSONDecoder().decode(Entry.self, from: Data(old.utf8))
precondition(decoded.id == 7 && decoded.metadataVersion == nil && decoded.tag == nil && decoded.note == nil)
let current = #"{"id": 7, "name": "a", "note": "n", "tag": "t", "metadata_version": 3}"#
let newer = try JSONDecoder().decode(Entry.self, from: Data(current.utf8))
precondition(newer.metadataVersion == 3)
print("ok")
"""
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "main.swift"
            source.write_text(program, encoding="utf-8")
            binary = Path(tmp) / "decode"
            built = subprocess.run(["swiftc", "-o", str(binary), str(source)], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertEqual(result.stdout.strip(), "ok")


if __name__ == "__main__":
    unittest.main()
