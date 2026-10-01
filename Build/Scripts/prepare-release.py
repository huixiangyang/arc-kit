#!/usr/bin/env python3
"""将同一份 CI 安装包生成 GitHub Release 附件与 Sparkle 签名订阅。"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('input', 'output', 'sparkle-bin'):
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--repository', required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    info = json.loads((args.input / 'BUILD-INFO.json').read_text())
    assert re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', args.tag), 'Invalid release tag'
    assert args.tag == 'v' + info['version'], 'Tag does not match built app'
    assert re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repository), 'Invalid repository'
    assert info['signing'] == 'ad-hoc' and info['notarized'] is False, 'Unexpected signing mode'
    assert info['architectures'] == ['arm64', 'x86_64'], 'Expected universal build'
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    assert info['sourceRevision'] == os.environ.get('GITHUB_SHA', revision), 'Build source does not match release source'
    notes = root / 'Documentation/Releases' / (info['version'] + '.md')
    assert notes.is_file(), 'Missing release notes'
    verified_files = set()
    for line in (args.input / 'SHA256SUMS.txt').read_text().splitlines():
        digest, filename = line.split(maxsplit=1)
        assert Path(filename).name == filename.removeprefix('./'), 'Invalid checksum path'
        assert re.fullmatch(r'[a-f0-9]{64}', digest), 'Invalid checksum digest'
        filename = filename.removeprefix('./')
        assert filename not in verified_files, 'Duplicate checksum entry'
        assert sha256(args.input / filename) == digest, 'Input checksum mismatch'
        verified_files.add(filename)
    expected_files = {path.name for path in args.input.iterdir() if path.is_file() and path.name != 'SHA256SUMS.txt'}
    assert verified_files == expected_files and len(verified_files) == 3, 'Incomplete input checksums'
    assert not args.output.exists(), 'Output directory already exists'
    private_key = os.environ.get('SPARKLE_PRIVATE_KEY')
    assert private_key, 'Missing SPARKLE_PRIVATE_KEY'
    args.output.mkdir(parents=True)
    files = {}
    prefix = f'https://github.com/{args.repository}/releases/download/{args.tag}/'
    for kind in ('dmg', 'zip'):
        matches = list(args.input.glob('*.' + kind))
        assert len(matches) == 1, f'Expected exactly one {kind}'
        target = args.output / f'ArcKit-universal.{kind}'
        shutil.copy2(matches[0], target)
        files[kind] = {'name': target.name, 'url': prefix + target.name, 'size': target.stat().st_size, 'sha256': sha256(target)}
    shutil.copy2(args.input / 'BUILD-INFO.json', args.output / 'BUILD-INFO.json')
    # 密钥只经 stdin 交给官方工具，不写入产物、参数或日志。
    def run_tool(name, *arguments):
        subprocess.run([str(args.sparkle_bin / name), *map(str, arguments)],
                       input=private_key + '\n', text=True, check=True)
    with tempfile.TemporaryDirectory(prefix='arc-kit-appcast-') as temporary:
        staging = Path(temporary)
        shutil.copy2(args.output / files['zip']['name'], staging / files['zip']['name'])
        (staging / 'ArcKit-universal.md').write_text(notes.read_text())
        run_tool('generate_appcast', '--ed-key-file', '-', '--download-url-prefix', prefix,
                 '--embed-release-notes', '--link', 'https://arc-kit.com/download/', '--maximum-deltas', '0', staging)
        feed = staging / 'appcast.xml'
        run_tool('sign_update', '--ed-key-file', '-', '--verify', feed)
        item = ET.parse(feed).find('./channel/item')
        ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
        assert item is not None and item.findtext(ns + 'version') == str(info['build']), 'Feed build mismatch'
        enclosure = item.find('enclosure')
        assert enclosure is not None and enclosure.attrib['url'] == files['zip']['url'], 'Feed URL mismatch'
        assert int(enclosure.attrib['length']) == files['zip']['size'], 'Feed length mismatch'
        run_tool('sign_update', '--ed-key-file', '-', '--verify', args.output / files['zip']['name'], enclosure.attrib[ns + 'edSignature'])
        shutil.copy2(feed, args.output / 'appcast.xml')
    metadata = {
        'schemaVersion': 1, 'version': info['version'], 'build': info['build'], 'tag': args.tag,
        'publishedAt': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'minimumSystemVersion': info['minimumSystemVersion'], 'architectures': info['architectures'],
        'signing': 'ad-hoc', 'notarized': False,
        'releaseNotesURL': f'https://github.com/{args.repository}/releases/tag/{args.tag}', 'assets': files,
    }
    (args.output / 'release.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
    (args.output / 'SHA256SUMS.txt').write_text(''.join(f'{sha256(p)}  {p.name}\n' for p in sorted(args.output.iterdir()) if p.is_file() and p.name != 'SHA256SUMS.txt'))
    print(f'Release artifacts verified: {args.tag}, build {info["build"]}')


if __name__ == '__main__':
    main()
