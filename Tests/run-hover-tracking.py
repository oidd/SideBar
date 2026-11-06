#!/usr/bin/env python3
"""Run production tracking methods against an in-memory platform backend."""
import argparse
from pathlib import Path
import re
import subprocess
import sys

BASELINE = 'd63b89230528eb1a7294013f6c1aef9e6a56000c'
REPO = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', action='store_true', help='Run unchanged upstream source; known regression assertions must fail.')
args = parser.parse_args()
source_path = 'Sources/SideBar/WindowSession.swift'
if args.baseline:
    source = subprocess.check_output(['git', 'show', f'{BASELINE}:{source_path}'], cwd=REPO).decode()
else:
    source = (REPO / source_path).read_text()

methods = []
for name in ['checkMouseForCollapse', 'collapseWindow', 'expandWindow', 'startMouseTrackingTimer']:
    # A top-level method closes at four spaces; nested closures are more indented.
    matches = list(re.finditer(r'(?:    @discardableResult\n)?    private func ' + name + r'\(.*?\n    }', source, re.S))
    if len(matches) != 1:
        raise SystemExit(f'Expected exactly one production method: {name}')
    methods.append(matches[0].group())
state = re.search(r'enum SnapState:.*?\n}', source, re.S)
if state is None:
    raise SystemExit('Missing production SnapState')
fixture = (REPO / 'Tests/TrackingHarness.swift.txt').read_text()
fixture = fixture.replace('__SNAP_STATE__', state.group()).replace('__METHODS__', '\n\n'.join(methods))
fixture += '\n' + (REPO / 'Tests/TrackingTests.swift.txt').read_text()
output = REPO / 'build/tests/hover-tracking' / ('baseline' if args.baseline else 'current')
output.mkdir(parents=True, exist_ok=True)
(output / 'main.swift').write_text(fixture)
compiled = subprocess.run(['swiftc', str(output / 'main.swift'), '-framework', 'ApplicationServices', '-o', str(output / 'tests')], capture_output=True, text=True)
(output / 'compile.log').write_text(compiled.stdout + compiled.stderr)
if compiled.returncode:
    print(compiled.stdout + compiled.stderr, file=sys.stderr)
    raise SystemExit(compiled.returncode)
result = subprocess.run([str(output / 'tests')], capture_output=True, text=True)
(output / 'tests.log').write_text(result.stdout + result.stderr)
print(result.stdout, end='')
if result.stderr:
    print(result.stderr, end='', file=sys.stderr)
sys.exit(result.returncode)
