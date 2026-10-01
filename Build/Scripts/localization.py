#!/usr/bin/env python3
"""校验模块 String Catalog；语言名单来自 XcodeGen 工程，编译与符号生成交给 Apple。"""
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def units(node):
    if 'stringUnit' in node:
        yield node['stringUnit']
    for name, value in node.items():
        if name != 'stringUnit' and isinstance(value, dict):
            yield from units(value)


def validate_catalog(path, source_language, languages):
    catalog = json.loads(path.read_text())
    label = str(path.relative_to(ROOT))
    assert catalog['sourceLanguage'] == source_language, f'{label}: sourceLanguage must be {source_language}'
    assert catalog['strings'], f'{label}: empty catalog'
    for key, entry in catalog['strings'].items():
        context = f'{label}: {key}'
        assert re.fullmatch(r'[a-zA-Z][a-zA-Z0-9.]*', key), f'{context}: invalid semantic key'
        assert set(entry.get('localizations', {})) == languages, f'{context}: expected languages {sorted(languages)}'
        assert entry.get('comment'), f'{context}: add translator context'
        for language, value in entry['localizations'].items():
            translations = list(units(value))
            assert translations, f'{context}/{language}: no translation'
            for unit in translations:
                assert unit['state'] == 'translated' and unit['value'], f'{context}/{language}: incomplete translation'
                assert language != 'en' or not re.search('[\u3400-\u9fff]', unit['value']), f'{context}: untranslated English'
    return len(catalog['strings'])


def main():
    catalogs = sorted([*ROOT.glob('Sources/**/Resources/Localization/*.xcstrings'),
                       *ROOT.glob('Targets/**/Resources/Localization/*.xcstrings')])
    assert catalogs, 'No String Catalogs found'
    with tempfile.TemporaryDirectory(prefix='ArcKit-Catalog-') as folder:
        temporary = Path(folder)
        spec_path = temporary / 'project.json'
        subprocess.run(['xcodegen', 'dump', '--spec', str(ROOT / 'project.yml'), '--type', 'json',
                        '--quiet', '--file', str(spec_path)], check=True)
        spec = json.loads(spec_path.read_text())
        source_language = spec['options']['developmentLanguage']
        languages = set(spec['options']['knownRegions']) - {'Base'}
        assert source_language in languages, 'Development language must be a known region'
        package = (ROOT / 'Package.swift').read_text()
        declared = re.search(r'defaultLocalization:\s*"([^"]+)"', package)
        assert declared and declared[1] == source_language, 'SwiftPM defaultLocalization differs from Xcode'
        for target, settings in spec['targets'].items():
            declared = settings.get('info', {}).get('properties', {}).get('CFBundleLocalizations')
            if declared is not None:
                assert set(declared) == languages, f'{target}: CFBundleLocalizations differs from knownRegions'

        count = 0
        for index, path in enumerate(catalogs):
            count += validate_catalog(path, source_language, languages)
            output = temporary / str(index)
            output.mkdir()
            subprocess.run(['xcrun', 'xcstringstool', 'compile', str(path), '-o', str(output)], check=True,
                           stdout=subprocess.DEVNULL)
            if path.name != 'InfoPlist.xcstrings':
                subprocess.run(['xcrun', 'xcstringstool', 'generate-symbols', str(path), '-o', str(output), '-l', 'swift'],
                               check=True, stdout=subprocess.DEVNULL)
        # 不提交工具输出，也不保留旧查表 API；编译负责验证实际符号与 Bundle。
        for path in [*ROOT.glob('Sources/**/*.swift'), *ROOT.glob('Targets/**/Sources/**/*.swift')]:
            assert not path.name.startswith('GeneratedStringSymbols_'), f'{path}: generated symbols belong in build output'
            text = path.read_text()
            assert 'L10n.text(' not in text and '.ArcKit.' not in text, f'{path}: old localization API remains'
    print(f'String Catalog OK: {len(catalogs)} catalogs, {count} entries, {", ".join(sorted(languages))}; Apple compilation and symbols verified')


if __name__ == '__main__':
    main()
