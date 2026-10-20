#!/usr/bin/env python3
"""Turn the daemon's ws contract (contract/wsContract.json) into Swift for VHContract.

The contract is the server's ws command book (core/usage, published by `vh_usage --json`), vendored here from
`web/src/util/generated/wsContract.json` in the server repository. This tool writes

  Sources/VHContract/Generated/WsContract.swift          WsCommand, WsContract, one WsRequest type per command
  Tests/VHContractTests/Generated/ContractSamples.swift   a minimal and a full JSON sample per payload and response

  gen-contract.py                     regenerate both from contract/wsContract.json
  gen-contract.py --check             exit 1 when the committed Swift is not what the contract generates
  gen-contract.py --from ../vaulthalla
                                      vendor the server's contract (and record its version), then regenerate

Type mapping, kept faithful rather than clever (the web's generated TypeScript is the reference):
  string -> String (a payload string with `enum` -> a nested String enum), integer -> Int64, number -> Double,
  boolean -> Bool, object with `fields` -> a nested struct, object naming a server `model` or with no fields ->
  JSONObject, array -> [element], several non-null types -> JSONValue.
  required -> T; required and nullable -> T? (the key is always sent); optional -> T? (the key is omitted when nil);
  optional and nullable -> Nullable<T>? (nil omits the key, .null sends null: "clear" and "leave alone" differ).
Standard library only.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
CONTRACT_JSON = ROOT / "contract" / "wsContract.json"
SOURCE_JSON = ROOT / "contract" / "SOURCE.json"
SERVER_CONTRACT = "web/src/util/generated/wsContract.json"
SWIFT_OUT = ROOT / "Sources" / "VHContract" / "Generated" / "WsContract.swift"
SAMPLES_OUT = ROOT / "Tests" / "VHContractTests" / "Generated" / "ContractSamples.swift"
LINE_LIMIT = 120

AUTH_LEVELS = {"public", "session", "human", "share", "pairing", "device"}
INPUTS = {"payload", "none", "token"}

SWIFT_KEYWORDS = {
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
    "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows", "static",
    "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default", "defer", "do",
    "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch", "where", "while",
    "Any", "as", "await", "false", "is", "nil", "self", "Self", "super", "throws", "true", "try",
}
# Type names the generated code refers to (or that Swift reserves as member types): a nested type with one of these
# names would shadow it, so nested types get a "Value" suffix and command segments are refused.
RESERVED_TYPES = {
    "Type", "Protocol", "Self", "Any", "Payload", "Response", "CodingKeys", "ShareMode", "String", "Bool", "Int64",
    "Double", "Duration", "JSONValue", "JSONObject", "Nullable", "WsCommand", "WsRequest", "WsEmpty", "WsNoPayload",
    "WsAuth", "Codable", "Hashable", "Sendable", "Decoder", "Encoder", "Optional", "Array", "Dictionary",
}
ACRONYMS = {"id": "ID", "ids": "IDs", "url": "URL", "uuid": "UUID", "ip": "IP", "api": "API"}


class ContractError(Exception):
    pass


# ---- names -----------------------------------------------------------------------------------------------------

def words(name: str) -> list[str]:
    """snake_case and dotted names split into words; camelCase segments stay one word ("isAuthenticated")."""
    return [w for w in re.split(r"[._\-]", name) if w]


def upper_first(word: str) -> str:
    return word[:1].upper() + word[1:]


def type_name(name: str) -> str:
    out = "".join(ACRONYMS.get(w, upper_first(w)) for w in words(name))
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", out):
        raise ContractError(f"{name!r} does not make a Swift type name")
    return out


def member_name(name: str) -> str:
    ws = words(name)
    if not ws:
        raise ContractError(f"empty name {name!r}")
    out = ws[0] + "".join(ACRONYMS.get(w, upper_first(w)) for w in ws[1:])
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", out):
        raise ContractError(f"{name!r} does not make a Swift identifier")
    return out


def escaped(identifier: str) -> str:
    return f"`{identifier}`" if identifier in SWIFT_KEYWORDS else identifier


def nested_type_name(name: str, array: bool) -> str:
    base = type_name(name)
    # The element of `recipient_role_assignments` is a `RecipientRoleAssignment`.
    if array:
        base = base[:-1] if base.endswith("s") and not base.endswith("ss") else base + "Item"
    return base + "Value" if base in RESERVED_TYPES else base


def swift_string(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def doc_lines(text: str, indent: int) -> list[str]:
    pad = " " * indent + "/// "
    out: list[str] = []
    line = ""
    for word in text.split():
        if line and len(pad) + len(line) + 1 + len(word) > LINE_LIMIT:
            out.append(pad + line)
            line = word
        else:
            line = f"{line} {word}".strip()
    if line:
        out.append(pad + line)
    return out


def wrap_list(prefix: str, items: list[str], suffix: str, indent: int, separator: str = ", ") -> list[str]:
    """`prefix a, b, c suffix`, continued on further lines indented under the prefix when too long."""
    pad = " " * indent
    one = pad + prefix + separator.join(items) + suffix
    if len(one) <= LINE_LIMIT:
        return [one]
    lines: list[str] = []
    line = pad + prefix
    cont = " " * (indent + len(prefix))
    for i, item in enumerate(items):
        piece = item + (separator.rstrip() if i < len(items) - 1 else suffix)
        candidate = (line + piece) if line.endswith(prefix) else (line + " " + piece)
        if len(candidate) > LINE_LIMIT and line.strip() != prefix.strip():
            lines.append(line)
            line = cont + piece
        else:
            line = candidate
    lines.append(line)
    return lines


# ---- type model ------------------------------------------------------------------------------------------------

class Field:
    """One contract member resolved to Swift: its type, its optionality and how it is coded."""

    def __init__(self, raw: dict[str, Any], owner: "Struct", in_payload: bool):
        self.raw = raw
        self.json_name: str = raw["name"]
        self.swift_name = member_name(self.json_name)
        self.required: bool = raw["required"]
        types: list[str] = raw["types"]
        if not types:
            raise ContractError(f"{owner.path}.{self.json_name}: no types")
        self.nullable = "null" in types
        concrete = [t for t in types if t != "null"]
        self.notes: list[str] = []
        self.nested: Struct | None = None
        self.enum: SwiftEnum | None = None

        if len(concrete) == 1:
            self.base = self.resolve(concrete[0], owner, in_payload)
        else:
            self.base = "JSONValue"
            self.notes.append(self.union_note(concrete))
        if self.base == "JSONValue":
            # JSONValue carries null itself, so a nullable union needs no extra wrapper.
            self.kind = "required" if self.required else "optional_json"
        elif self.required:
            self.kind = "required_nullable" if self.nullable else "required"
        else:
            self.kind = "optional_nullable" if self.nullable else "optional"

    def union_note(self, concrete: list[str]) -> str:
        parts = []
        for t in concrete:
            if t == "array" and self.raw.get("items"):
                items = self.raw["items"]
                if self.raw.get("item_enum"):
                    items += " (" + ", ".join(self.raw["item_enum"]) + ")"
                parts.append(f"array of {items}")
            else:
                parts.append(t)
        return "JSON: " + " | ".join(parts) + "."

    def resolve(self, json_type: str, owner: "Struct", in_payload: bool) -> str:
        raw = self.raw
        if json_type == "string":
            if raw.get("enum"):
                if in_payload:
                    self.enum = SwiftEnum(nested_type_name(self.json_name, False), raw["enum"])
                    owner.enums.append(self.enum)
                    return self.enum.name
                # A response enum stays a String: a newer daemon may add values.
                self.notes.append("One of: " + ", ".join(raw["enum"]) + ".")
            return "String"
        if json_type == "integer":
            return "Int64"
        if json_type == "number":
            return "Double"
        if json_type == "boolean":
            return "Bool"
        if json_type == "object":
            if raw.get("fields"):
                self.nested = Struct(nested_type_name(self.json_name, False), raw["fields"], in_payload,
                                     f"{owner.path}.{self.json_name}")
                owner.structs.append(self.nested)
                return self.nested.name
            if raw.get("model"):
                self.notes.append(f"The server's `{raw['model']}` model (not typed by the contract).")
            return "JSONObject"
        if json_type == "array":
            return "[" + self.element(owner, in_payload) + "]"
        raise ContractError(f"{owner.path}.{self.json_name}: unknown JSON type {json_type!r}")

    def element(self, owner: "Struct", in_payload: bool) -> str:
        raw = self.raw
        items = raw.get("items", "")
        if items == "string":
            if raw.get("item_enum"):
                if in_payload:
                    self.enum = SwiftEnum(nested_type_name(self.json_name, True), raw["item_enum"])
                    owner.enums.append(self.enum)
                    return self.enum.name
                self.notes.append("Each one of: " + ", ".join(raw["item_enum"]) + ".")
            return "String"
        if items == "integer":
            return "Int64"
        if items == "number":
            return "Double"
        if items == "boolean":
            return "Bool"
        if items == "object":
            if raw.get("fields"):
                self.nested = Struct(nested_type_name(self.json_name, True), raw["fields"], in_payload,
                                     f"{owner.path}.{self.json_name}[]")
                owner.structs.append(self.nested)
                return self.nested.name
            if raw.get("model"):
                self.notes.append(f"Elements are the server's `{raw['model']}` model (not typed by the contract).")
            return "JSONObject"
        self.notes.append("The contract does not type the elements.")
        return "JSONValue"

    @property
    def swift_type(self) -> str:
        if self.kind == "required":
            return self.base
        if self.kind == "optional_nullable":
            return f"Nullable<{self.base}>?"
        return self.base + "?"

    @property
    def doc(self) -> str:
        text = self.raw.get("description", "").strip()
        extra = list(self.notes)
        if "minimum" in self.raw:
            extra.append(f"Minimum {self.raw['minimum']}.")
        if "maximum" in self.raw:
            extra.append(f"Maximum {self.raw['maximum']}.")
        if self.kind == "required_nullable":
            extra.append("Always sent; nil is null.")
        elif self.kind == "optional_nullable":
            extra.append("nil omits it, `.null` sends null.")
        elif self.kind == "optional_json":
            extra.append("nil omits it.")
        return " ".join(([text] if text else []) + extra)


class SwiftEnum:
    def __init__(self, name: str, values: list[str]):
        self.name = name
        self.values = values
        self.cases = [member_name(v) for v in values]
        if len(set(self.cases)) != len(self.cases):
            raise ContractError(f"enum {name}: values collide as Swift cases: {values}")


class Struct:
    def __init__(self, name: str, fields: list[dict[str, Any]], in_payload: bool, path: str):
        self.name = name
        self.path = path
        self.structs: list[Struct] = []
        self.enums: list[SwiftEnum] = []
        self.fields = [Field(f, self, in_payload) for f in fields]
        names = [f.swift_name for f in self.fields]
        if len(set(names)) != len(names):
            raise ContractError(f"{path}: members collide in Swift: {names}")
        nested = [s.name for s in self.structs] + [e.name for e in self.enums]
        if len(set(nested)) != len(nested):
            raise ContractError(f"{path}: nested types collide in Swift: {nested}")

    def fields_raw(self) -> list[dict[str, Any]]:
        return [f.raw for f in self.fields]

    @property
    def custom_coding(self) -> bool:
        # Synthesized Codable decodes and encodes T and T? correctly; nullable members need to tell absent from null.
        return any(f.kind in ("required_nullable", "optional_nullable", "optional_json") for f in self.fields)

    def lines(self, indent: int) -> list[str]:
        pad = " " * indent
        inner = " " * (indent + 4)
        out = [f"{pad}public struct {self.name}: Codable, Hashable, Sendable {{"]
        for f in self.fields:
            if f.doc:
                out.extend(doc_lines(f.doc, indent + 4))
            out.append(f"{inner}public var {escaped(f.swift_name)}: {f.swift_type}")
        if self.fields:
            out.append("")

        params = [f"{f.swift_name}: {f.swift_type}" + ("" if f.kind == "required" else " = nil") for f in self.fields]
        out.extend(wrap_list("public init(", params, ") {", indent + 4))
        for f in self.fields:
            out.append(f"{inner}    self.{f.swift_name} = {escaped(f.swift_name)}")
        out.append(f"{inner}}}")

        if self.fields:
            out.append("")
            out.append(f"{inner}enum CodingKeys: String, CodingKey {{")
            for f in self.fields:
                raw = "" if f.swift_name == f.json_name else f" = {swift_string(f.json_name)}"
                out.append(f"{inner}    case {escaped(f.swift_name)}{raw}")
            out.append(f"{inner}}}")

        if self.custom_coding:
            out.extend(self.coding_lines(indent + 4))

        for e in self.enums:
            out.append("")
            out.append(f"{inner}public enum {e.name}: String, Codable, Hashable, Sendable, CaseIterable {{")
            for case, value in zip(e.cases, e.values):
                raw = "" if case == value else f" = {swift_string(value)}"
                out.append(f"{inner}    case {escaped(case)}{raw}")
            out.append(f"{inner}}}")
        for s in self.structs:
            out.append("")
            out.extend(s.lines(indent + 4))
        out.append(f"{pad}}}")
        return out

    def coding_lines(self, indent: int) -> list[str]:
        pad = " " * indent
        body = " " * (indent + 4)
        out = Lines()
        out += ["", f"{pad}public init(from decoder: any Decoder) throws {{",
               f"{body}let container = try decoder.container(keyedBy: CodingKeys.self)"]
        for f in self.fields:
            key = f".{escaped(f.swift_name)}"
            target = f"{f.swift_name}"
            if f.kind == "required":
                out.append(f"{body}{target} = try container.decode({f.base}.self, forKey: {key})")
            elif f.kind == "required_nullable":
                out.append(f"{body}{target} = try container.decode({f.base}?.self, forKey: {key})")
            elif f.kind == "optional":
                out.append(f"{body}{target} = try container.decodeIfPresent({f.base}.self, forKey: {key})")
            else:
                wrapped = f"Nullable<{f.base}>" if f.kind == "optional_nullable" else f.base
                out.append(f"{body}{target} = container.contains({key})")
                out.append(f"{body}    ? try container.decode({wrapped}.self, forKey: {key}) : nil")
        out.append(f"{pad}}}")
        out.append("")
        out.append(f"{pad}public func encode(to encoder: any Encoder) throws {{")
        out.append(f"{body}var container = encoder.container(keyedBy: CodingKeys.self)")
        for f in self.fields:
            key = f".{escaped(f.swift_name)}"
            method = "encode" if f.kind in ("required", "required_nullable") else "encodeIfPresent"
            out.append(f"{body}try container.{method}({f.swift_name}, forKey: {key})")
        out.append(f"{pad}}}")
        return list(out)


class Lines(list):
    """Code lines; one too long is broken after its first `(` with the arguments on a continuation line."""

    def append(self, line: str) -> None:
        if len(line) > LINE_LIMIT and "(" in line:
            head, args = line.split("(", 1)
            continuation = " " * (len(line) - len(line.lstrip()) + 4)
            super().append(head + "(")
            super().append(continuation + args)
        else:
            super().append(line)


# ---- commands --------------------------------------------------------------------------------------------------

class Command:
    def __init__(self, raw: dict[str, Any]):
        self.raw = raw
        self.name: str = raw["command"]
        self.segments = [type_name(s) for s in self.name.split(".")]
        for s in self.segments:
            if s in RESERVED_TYPES:
                raise ContractError(f"{self.name}: segment {s} would shadow a type the generated code uses")
        self.case = member_name(self.name.replace(".", "_"))
        self.swift_path = "Ws." + ".".join(self.segments)
        if raw["auth"] not in AUTH_LEVELS:
            raise ContractError(f"{self.name}: unknown auth level {raw['auth']!r}")
        if raw["input"] not in INPUTS:
            raise ContractError(f"{self.name}: unknown input {raw['input']!r}")
        self.forms = [Form(self, None, raw["payload"], raw["response"], raw["description"])]
        for v in raw["variants"]:
            if v.get("mode") != "share":
                raise ContractError(f"{self.name}: unknown variant mode {v.get('mode')!r}")
            self.forms.append(Form(self, "ShareMode", v["payload"], v["response"], v.get("description", "")))


class Form:
    """A request type: the command's own shape, or a session-mode variant nested in it."""

    def __init__(self, command: Command, variant: str | None, payload: list[dict[str, Any]],
                 response: list[dict[str, Any]], description: str):
        self.command = command
        self.variant = variant
        self.description = description
        self.swift_path = command.swift_path + (f".{variant}" if variant else "")
        self.payload_input = command.raw["input"] == "payload"
        self.payload = Struct("Payload", payload, True, f"{command.name} payload") \
            if self.payload_input and payload else None
        self.response = Struct("Response", response, False, f"{command.name} response") if response else None
        if not self.payload_input and payload:
            raise ContractError(f"{command.name}: input {command.raw['input']!r} but payload fields are listed")

    def lines(self, indent: int) -> list[str]:
        pad = " " * indent
        inner = " " * (indent + 4)
        name = self.variant or self.command.segments[-1]
        out = doc_lines(self.description, indent) if self.description else []
        out.append(f"{pad}public enum {name}: WsRequest {{")
        out.append(f"{inner}public static let command = WsCommand.{escaped(self.command.case)}")
        if self.payload:
            out.append("")
            out.extend(self.payload.lines(indent + 4))
        elif self.payload_input:
            out.append(f"{inner}public typealias Payload = WsEmpty")
        else:
            reads = "nothing" if self.command.raw["input"] == "none" else "the envelope token"
            out.append(f"{inner}/// The daemon reads {reads}; the payload is sent as null.")
            out.append(f"{inner}public typealias Payload = WsNoPayload")
        if self.response:
            out.append("")
            out.extend(self.response.lines(indent + 4))
        else:
            if self.payload:
                out.append("")
            out.append(f"{inner}public typealias Response = WsEmpty")
        out.append(f"{pad}}}")
        return out


# ---- Swift output ----------------------------------------------------------------------------------------------

def source_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def header(contract: dict[str, Any], text: str, what: str) -> list[str]:
    return [
        f"// Generated by tools/gen-contract.py from contract/wsContract.json: {what}. Do not edit.",
        "// Refresh from the server with `python3 tools/gen-contract.py --from <server repo>`.",
        f"// contract_version {contract['contract_version']}, ws_hash {contract['ws_hash']}",
        f"// source sha256 {source_hash(text)}",
    ]


def swift_text(text: str, indent: int) -> list[str]:
    """A string literal; one too long for a line becomes a multi-line literal with line continuations."""
    pad = " " * indent
    single = pad + swift_string(text)
    if len(single) <= LINE_LIMIT:
        return [single]
    body = text.replace("\\", "\\\\").replace('"""', '\\"""')
    lines: list[str] = []
    line = ""
    for word in body.split(" "):
        # A continued line keeps its separating space at the start of the next line (never trailing whitespace).
        piece = word if not line else " " + word
        if line and len(pad) + len(line) + len(piece) + 2 > LINE_LIMIT:
            lines.append(line + "\\")
            line = " " + word
        else:
            line += piece
    lines.append(line)
    return [pad + '"""'] + [pad + l for l in lines] + [pad + '"""']


def grouped_switch(commands: list[Command], value_of, render, indent: int, default: str | None = None) -> list[str]:
    """A switch over WsCommand with one `case` per distinct value (cases listed in contract order). `render` turns a
    value into the lines of its expression at an indent."""
    pad = " " * indent
    groups: dict[str, list[str]] = {}
    order: list[str] = []
    for c in commands:
        v = value_of(c)
        if default is not None and render(v, 0) == [default]:
            continue
        key = json.dumps(v, sort_keys=True)
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append("." + escaped(c.case))
    out = [f"{pad}switch self {{"]
    for key in order:
        out.extend(wrap_list("case ", groups[key], ":", indent))
        out.extend(render(json.loads(key), indent + 4))
    if default is not None:
        out.append(f"{pad}default: {default}")
    out.append(f"{pad}}}")
    return out


def generate_swift(contract: dict[str, Any], text: str) -> str:
    commands = [Command(c) for c in contract["ws"]]
    names = [c.case for c in commands]
    if len(set(names)) != len(names):
        raise ContractError("command names collide as Swift cases")
    command_names = {c.name for c in commands}

    out = header(contract, text, "the ws command book as Swift")
    out += [
        "",
        "/// The contract this file was generated from. `meta.contract.get` answers the daemon's own `ws_hash`:",
        "/// when the two differ, the daemon was built from another command book and commands may have changed shape.",
        "public enum WsContract {",
        f"    public static let contractVersion = {contract['contract_version']}",
        f"    public static let wsHash = {swift_string(contract['ws_hash'])}",
        "}",
        "",
        f"/// Every command the contract types ({len(commands)}). Commands the daemon has but the contract doesn't",
        "/// type yet go through `WsClient.send(command:payload:)`.",
        "public enum WsCommand: String, CaseIterable, Sendable {",
    ]
    for c in commands:
        out.extend(doc_lines(c.raw["description"], 4))
        out.append(f"    case {escaped(c.case)} = {swift_string(c.name)}")

    out += ["", "    /// What the session must be before the router runs the command.",
            "    public var auth: WsAuth {"]
    out += grouped_switch(commands, lambda c: c.raw["auth"], lambda v, i: [" " * i + f".{escaped(v)}"], 8)
    out += ["    }", "",
            "    /// How long a client waits before reporting \"no answer yet\" (never \"failed\": the daemon may",
            "    /// still be working on it).",
            "    public var clientTimeout: Duration {"]
    out += grouped_switch(commands, lambda c: c.raw["client_timeout_ms"],
                          lambda v, i: [" " * i + f".milliseconds({v})"], 8)
    out += ["    }", "",
            "    /// The `OperationSpec` the command runs, when it is one of the daemon's catalogued operations.",
            "    public var operation: String? {"]
    out += grouped_switch(commands, lambda c: c.raw["operation"],
                          lambda v, i: [" " * i + ("nil" if v is None else swift_string(v))], 8, default="nil")
    out += ["    }", "",
            "    /// The refusals the command can answer with: the generic kinds (`denied`, `not_found`, `invalid`,",
            "    /// `conflict`, `unauthorized`, `error`) plus its NeedsConfirmation codes.",
            "    public var refusalCodes: [String] {"]
    out += grouped_switch(commands, lambda c: c.raw["refusal_codes"],
                          lambda v, i: wrap_list("[", [swift_string(x) for x in v], "]", i), 8)
    out += ["    }", "",
            "    /// The command book's description.",
            "    public var summary: String {",
            "        switch self {"]
    for c in commands:
        out.append(f"        case .{escaped(c.case)}:")
        out.extend(swift_text(c.raw["description"], 12))
    out += ["        }", "    }", "}", ""]

    # Namespaces: every dotted prefix that is not itself a command.
    out += ["/// Request types, namespaced like the command names: `auth.user.change_password` is",
            "/// `Ws.Auth.User.ChangePassword`. Each one ties a `WsCommand` to its `Payload` and `Response`.",
            "public enum Ws {}", ""]
    namespaces: list[list[str]] = []
    seen: set[str] = set()
    for c in commands:
        parts = c.name.split(".")
        for i in range(1, len(parts)):
            prefix = ".".join(parts[:i])
            if prefix not in command_names and prefix not in seen:
                seen.add(prefix)
                namespaces.append([type_name(p) for p in parts[:i]])
    for ns in namespaces:
        parent = ".".join(["Ws"] + ns[:-1])
        out.append(f"extension {parent} {{ public enum {ns[-1]} {{}} }}")
    out.append("")

    for c in commands:
        parent = ".".join(["Ws"] + c.segments[:-1])
        out.append(f"extension {parent} {{")
        out.extend(c.forms[0].lines(4))
        out.append("}")
        out.append("")
        for form in c.forms[1:]:
            out.append(f"extension {c.swift_path} {{")
            out.extend(form.lines(4))
            out.append("}")
            out.append("")
    return "\n".join(out).rstrip("\n") + "\n"


# ---- samples (test fixtures) -----------------------------------------------------------------------------------

def sample_value(raw: dict[str, Any], full: bool) -> Any:
    types = [t for t in raw["types"] if t != "null"]
    if not full and raw["required"] and "null" in raw["types"]:
        return None
    t = types[0]
    if t == "string":
        return (raw.get("enum") or ["x"])[0]
    if t == "integer":
        return raw.get("minimum", 0) + 1
    if t == "number":
        return 1.5
    if t == "boolean":
        return True
    if t == "object":
        if raw.get("fields"):
            return sample_object(raw["fields"], full)
        return {"k": "v"} if full else {}
    if t == "array":
        if not full:
            return []
        items = raw.get("items", "")
        if items == "string":
            return [(raw.get("item_enum") or ["x"])[0]]
        if items == "integer":
            return [1]
        if items == "number":
            return [1.5]
        if items == "boolean":
            return [True]
        if items == "object":
            return [sample_object(raw["fields"], full) if raw.get("fields") else {"k": "v"}]
        return ["x"]
    raise ContractError(f"no sample for type {t!r}")


def sample_object(fields: list[dict[str, Any]], full: bool) -> dict[str, Any]:
    return {f["name"]: sample_value(f, full) for f in fields if full or f["required"]}


def sample_literal(value: Any, indent: int) -> list[str]:
    """A raw string literal holding `value` as JSON: compact when it fits, else pretty-printed over several lines."""
    pad = " " * indent
    compact = json.dumps(value, separators=(",", ":"), sort_keys=True, ensure_ascii=False)
    if len(pad) + len(compact) + 5 <= LINE_LIMIT:
        return [f'{pad}#"{compact}"#,']
    pretty = json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False).splitlines()
    return [f'{pad}#"""'] + [pad + line for line in pretty] + [f'{pad}"""#,']


def generate_samples(contract: dict[str, Any], text: str) -> str:
    commands = [Command(c) for c in contract["ws"]]
    out = header(contract, text, "JSON samples for VHContractTests")
    out += ["", "import VHContract", "",
            "/// A minimal (required members only) and a full sample per payload and response, built from the",
            "/// contract.",
            "/// The input `none`/`token` commands send a null payload.",
            "let contractSamples: [ContractSample] = ["]
    for c in commands:
        for form in c.forms:
            if form.payload is not None:
                fields = form.payload.fields_raw()
                payload = [sample_object(fields, False), sample_object(fields, True)]
            else:
                payload = [{}, {}] if form.payload_input else [None, None]
            response_raw = form.response.fields_raw() if form.response else []
            response = [sample_object(response_raw, False), sample_object(response_raw, True)]
            out.append("    ContractSample(")
            out.append(f"        {form.swift_path}.self,")
            out.append("        payload: [")
            for value in payload:
                out.extend(sample_literal(value, 12))
            out.append("        ],")
            out.append("        response: [")
            for value in response:
                out.extend(sample_literal(value, 12))
            out.append("        ]")
            out.append("    ),")
    out.append("]")
    return "\n".join(out) + "\n"


# ---- CLI -------------------------------------------------------------------------------------------------------

def outputs(text: str) -> dict[Path, str]:
    contract = json.loads(text)
    for key in ("contract_version", "ws_hash", "ws"):
        if key not in contract:
            raise ContractError(f"contract/wsContract.json has no {key!r}")
    # Same canonical form as the server (core/usage/src/contract/Export.cpp): catches a hand-edited vendored copy.
    canonical = json.dumps(contract["ws"], sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    if source_hash(canonical) != contract["ws_hash"]:
        raise ContractError("contract/wsContract.json does not match its ws_hash (edited by hand?)")
    return {SWIFT_OUT: generate_swift(contract, text), SAMPLES_OUT: generate_samples(contract, text)}


def vendor(server: Path) -> None:
    source = server / SERVER_CONTRACT
    if not source.is_file():
        raise ContractError(f"{source} not found (is {server} the vaulthalla repository?)")
    shutil.copyfile(source, CONTRACT_JSON)
    version = (server / "VERSION").read_text(encoding="utf-8").strip() if (server / "VERSION").is_file() else None
    commit = subprocess.run(["git", "-C", str(server), "rev-parse", "--short", "HEAD"],
                            check=True, capture_output=True, text=True).stdout.strip()
    record = {"server_version": version, "server_commit": commit, "source": SERVER_CONTRACT}
    SOURCE_JSON.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(f"vendored {SERVER_CONTRACT} from {server} (server {version}, {commit})")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="exit 1 when the committed Swift drifts from the contract")
    mode.add_argument("--from", dest="server", metavar="SERVER_REPO",
                      help="copy the server's generated contract into contract/, then regenerate")
    args = parser.parse_args(argv)

    try:
        if args.server:
            vendor(Path(args.server).expanduser().resolve())
        text = CONTRACT_JSON.read_text(encoding="utf-8")
        generated = outputs(text)
    except (ContractError, OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"gen-contract: {error}", file=sys.stderr)
        return 1

    if args.check:
        drift = []
        for path, expected in generated.items():
            committed = path.read_text(encoding="utf-8") if path.exists() else ""
            if committed != expected:
                diff = list(difflib.unified_diff(committed.splitlines(), expected.splitlines(),
                                                 f"{path.relative_to(ROOT)} (committed)",
                                                 f"{path.relative_to(ROOT)} (generated)", lineterm="", n=1))
                changed = sum(1 for d in diff if d[:1] in "+-" and d[:3] not in ("+++", "---"))
                shown = diff[:40] + ([f"... ({len(diff) - 40} more diff lines)"] if len(diff) > 40 else [])
                drift.append(f"{path.relative_to(ROOT)}: {changed} lines differ\n" + "\n".join(shown))
        if drift:
            print("contract drift: the committed Swift is not what contract/wsContract.json generates", file=sys.stderr)
            for d in drift:
                print(d, file=sys.stderr)
            print("fix: python3 tools/gen-contract.py", file=sys.stderr)
            return 1
        print("contract: generated Swift matches contract/wsContract.json")
        return 0

    for path, content in generated.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    contract = json.loads(text)
    print(f"wrote {SWIFT_OUT.relative_to(ROOT)} and {SAMPLES_OUT.relative_to(ROOT)} "
          f"({len(contract['ws'])} commands, ws_hash {contract['ws_hash'][:12]})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
