#!/usr/bin/env python3
"""Validate this starter pack's documents/evidence. Does not test a native port."""
from __future__ import annotations
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent

def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)

def main() -> int:
    required = [
        'START_HERE.md', 'AGENTS.md', 'CODEX_MASTER_PROMPT.md',
        'PLATFORM_CROSSCHECK.md', 'ACCEPTANCE_TESTS.md',
        'LINUX_CONTINUATION_PROMPT.md', 'SOURCES.md', 'FEATURE_LEDGER.json',
        'research/PROTOCOL.md', 'research/FINDINGS.md', 'research/PATCH_PLAN.json',
        'research/tools/extract_medal.py', 'research/tests/original_client.cjs',
        'research/tests/make_media.py', 'templates/HANDOFF_LINUX.md',
        'validation/README.md', 'validation/protocol_results.json',
        'validation/media_result.json', 'validation/extraction-report.json',
    ]
    for rel in required:
        require((ROOT / rel).is_file(), f'Missing required file: {rel}')
    ledger = json.loads((ROOT / 'FEATURE_LEDGER.json').read_text())
    expected = {'recorder_methods': 34, 'client_handlers': 40, 'recorder_settings': 60,
                'product_workflows': 30}
    ids = set()
    states = set(ledger['allowed_platform_statuses'])
    test_ids = set(re.findall(r'^\| ([ABMLEEP]\d{2}) \|',
                             (ROOT / 'ACCEPTANCE_TESTS.md').read_text(), re.M))
    for category, count in expected.items():
        require(len(ledger[category]) == count, f'Unexpected {category} count')
        for item in ledger[category]:
            require(item['id'] not in ids, f'Duplicate inventory ID: {item["id"]}')
            ids.add(item['id'])
            source = item['source'].split('#', 1)[0]
            require((ROOT / source).is_file(), f'Missing ledger source: {source}')
            for platform in ['macos', 'linux']:
                require(item[platform]['status'] in states, f'Bad state in {item["id"]}')
            for test in item.get('acceptance_test_ids', []):
                require(test in test_ids, f'Unknown acceptance ID: {test}')
    metadata = json.loads((ROOT / 'research/evidence/recorder_metadata.json').read_text())
    require({x['name'] for x in ledger['recorder_methods']} ==
            {x['first_string'] for x in metadata['rpc_methods']}, 'RPC inventory drift')
    settings = json.loads((ROOT / 'research/evidence/settings_catalog.json').read_text())
    require({x['name'] for x in ledger['recorder_settings']} == set(settings['recorderKeys']),
            'Settings inventory drift')
    handlers = json.loads((ROOT / 'research/evidence/client_handlers.json').read_text())
    require({x['name'] for x in ledger['client_handlers']} == {x['method'] for x in handlers},
            'Client handler inventory drift')
    baseline = json.loads((ROOT / 'validation/protocol_results.json').read_text())
    require(len(baseline['tests']) == 12 and all(t['status'] == 'passed' for t in baseline['tests']),
            'Reproduction does not contain the recorded 12 passing isolated checks')
    sources = (ROOT / 'SOURCES.md').read_text()
    require(len(set(re.findall(r'\*\*(S\d{2}) —', sources))) == 31, 'Source inventory changed')
    for path in ROOT.rglob('*.json'):
        json.loads(path.read_text())
    # Check authored documents, not imported code snippets that can contain literal fences.
    for path in list(ROOT.glob('*.md')) + list((ROOT / 'templates').glob('*.md')):
        require(len(re.findall(r'^```', path.read_text(), re.M)) % 2 == 0,
                f'Unbalanced fenced block: {path.name}')
    print(f'PASS starter-pack consistency: {len(required)} required files; '
          f'34 RPCs; 40 handlers; 60 settings; 30 workflows; {len(test_ids)} acceptance IDs; 31 sources.')
    print('Reference evidence: 12/12 inherited isolated checks. This validator does NOT test native client/capture/GPU functionality.')
    return 0

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f'FAIL: {exc}', file=sys.stderr)
        raise SystemExit(1)
