#!/usr/bin/env python3
"""Fingerprint the pinned client's complete Bitrate wire-to-encoder conversion.

This is a research-time verifier. It deliberately consumes the user's extracted
original files and emits only small structural evidence; it never redistributes
the input binaries or JavaScript.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from importlib.metadata import version
from pathlib import Path
from typing import Any

import dnfile
from dncil.cil.body.reader import read_method_body_from_bytes


CLIENT_SHA256 = "5a2a6dd5d1370a15577b0c09bc2d021059e2f9e7dba6a2e40cc41b4685e0c8ff"
RECORDER_SHA256 = "96afe76e120982f257a6eda99ce33bb0dc3e8013459d1fad8b85108375333a01"
CREATE_CONFIG_TOKEN = 0x0600125D
GET_BITRATE_TOKEN = 0x0600134E
BITRATE_BACKING_FIELD_TOKEN = 0x040013F7

CLIENT_CONVERSION = (
    "async function ry(e,t){switch(e){case De.Hotkeys:return{hotkeys:await iy(t||[])};"
    "case De.AudioModeConfig:return H4(t);case De.MicSoundGain:case De.AudioNotificationVolume:"
    "return t/100;case De.VideoOverlayConfig:return await Wt(tt.VideoOverlayEnabled)?t:[];"
    "case De.ExternalFileSources:return JSON.stringify(t);default:return t}}"
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_hash(path: Path, expected: str) -> None:
    actual = sha256(path)
    if actual != expected:
        raise RuntimeError(f"unexpected SHA-256 for {path}: {actual}")


def type_method_ranges(pe: dnfile.dnPE) -> list[tuple[set[int], str]]:
    rows = pe.net.mdtables.TypeDef.rows
    result: list[tuple[set[int], str]] = []
    for row in rows:
        if not row.MethodList:
            continue
        namespace = str(row.TypeNamespace)
        name = str(row.TypeName)
        result.append(({item.row_index for item in row.MethodList},
                       f"{namespace}.{name}" if namespace else name))
    return result


def method_owner(ranges: list[tuple[set[int], str]], row_index: int) -> str:
    for methods, owner in ranges:
        if row_index in methods:
            return owner
    raise RuntimeError(f"method row {row_index} has no declaring type")


def token_value(operand: Any) -> int | None:
    value = getattr(operand, "value", None)
    if isinstance(value, int):
        return value
    table = getattr(operand, "table", None)
    rid = getattr(operand, "rid", None)
    if isinstance(table, int) and isinstance(rid, int):
        return (table << 24) | rid
    text = str(operand)
    if text.startswith("token(0x") and text.endswith(")"):
        return int(text[6:-1], 16)
    return None


def instruction_record(instruction: Any) -> dict[str, Any]:
    operand = instruction.operand
    token = token_value(operand)
    if token is not None:
        operand_value: Any = f"0x{token:08X}"
    elif operand is None or isinstance(operand, (bool, float, int, str)):
        operand_value = operand
    else:
        operand_value = str(operand)
    return {
        "offset": instruction.offset,
        "opcode": instruction.opcode.name,
        "operand": operand_value,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--client", type=Path, required=True)
    parser.add_argument("--recorder", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    require_hash(args.client, CLIENT_SHA256)
    require_hash(args.recorder, RECORDER_SHA256)

    client_text = args.client.read_text(encoding="utf-8")
    if client_text.count(CLIENT_CONVERSION) != 1:
        raise RuntimeError("pinned getRecorderValueToSend conversion predicate did not match exactly once")
    if "case De.Bitrate:" in CLIENT_CONVERSION:
        raise RuntimeError("the pinned client predicate unexpectedly transforms Bitrate")

    pe = dnfile.dnPE(str(args.recorder))
    if not pe.net or not pe.net.mdtables.MethodDef:
        raise RuntimeError("recorder has no managed MethodDef table")
    ranges = type_method_ranges(pe)
    create_row_index = CREATE_CONFIG_TOKEN & 0x00FFFFFF
    bitrate_row_index = GET_BITRATE_TOKEN & 0x00FFFFFF
    create_row = pe.net.mdtables.MethodDef.rows[create_row_index - 1]
    bitrate_row = pe.net.mdtables.MethodDef.rows[bitrate_row_index - 1]
    if str(create_row.Name) != "CreateConfig" or method_owner(ranges, create_row_index) != "MedalEncoder.RecordingSession":
        raise RuntimeError("CreateConfig token or declaring type changed")
    if str(bitrate_row.Name) != "get_Bitrate" or method_owner(ranges, bitrate_row_index) != "MedalEncoder.Settings":
        raise RuntimeError("get_Bitrate token or declaring type changed")

    field_index = BITRATE_BACKING_FIELD_TOKEN & 0x00FFFFFF
    field_row = pe.net.mdtables.Field.rows[field_index - 1]
    if str(field_row.Name) != "<Bitrate>k__BackingField":
        raise RuntimeError("Bitrate backing-field token changed")

    body = read_method_body_from_bytes(pe.get_data(create_row.Rva, 16384))
    instructions = body.instructions
    expected = [
        ("call", GET_BITRATE_TOKEN),
        ("ldloc.0", None),
        ("callvirt", 0x0A00048B),
        ("conv.u4", None),
        ("ldc.i4", 1_000_000),
        ("mul", None),
    ]
    match_index: int | None = None
    for index in range(len(instructions) - len(expected) + 1):
        matches = True
        for instruction, (opcode, operand) in zip(instructions[index:index + len(expected)], expected):
            if instruction.opcode.name != opcode:
                matches = False
                break
            actual_operand = token_value(instruction.operand) if opcode in {"call", "callvirt"} else instruction.operand
            if operand is not None and actual_operand != operand:
                matches = False
                break
        if matches:
            if match_index is not None:
                raise RuntimeError("Bitrate multiplier IL sequence matched more than once")
            match_index = index
    if match_index is None:
        raise RuntimeError("Bitrate multiplier IL sequence was not found")

    result = {
        "schemaVersion": 1,
        "scope": "pinned-client-2637.461.1-and-recorder-2638.2751.1",
        "inputs": {
            "clientMainSha256": CLIENT_SHA256,
            "recorderExecutableSha256": RECORDER_SHA256,
        },
        "client": {
            "function": "getRecorderValueToSend (minified symbol ry)",
            "exactPredicateMatches": 1,
            "bitrateCasePresent": False,
            "defaultBranch": "return t",
            "conclusion": "Bitrate numeric value crosses the client-to-recorder settings wire unchanged.",
        },
        "recorder": {
            "declaringType": "MedalEncoder.RecordingSession",
            "method": "CreateConfig",
            "methodToken": f"0x{CREATE_CONFIG_TOKEN:08X}",
            "settingsGetterToken": f"0x{GET_BITRATE_TOKEN:08X}",
            "backingFieldToken": f"0x{BITRATE_BACKING_FIELD_TOKEN:08X}",
            "il": [instruction_record(item) for item in instructions[match_index:match_index + len(expected)]],
            "conclusion": "The effective Bitrate setting is converted to UInt32 and multiplied by 1,000,000 for the native encoder configuration.",
        },
        "mapping": {
            "wireUnit": "decimal megabits per second",
            "nativeUnit": "bits per second",
            "formula": "nativeBitsPerSecond = round(wireValue * 1000000)",
            "fixedExamples": [
                {"wire": 1, "nativeBitsPerSecond": 1_000_000},
                {"wire": 7, "nativeBitsPerSecond": 7_000_000},
                {"wire": 15, "nativeBitsPerSecond": 15_000_000},
                {"wire": 27.5, "nativeBitsPerSecond": 27_500_000},
                {"wire": 100, "nativeBitsPerSecond": 100_000_000},
            ],
        },
        "researchDependencies": {
            "dnfile": version("dnfile"),
            "dncil": version("dncil"),
        },
    }
    encoded = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    else:
        print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
