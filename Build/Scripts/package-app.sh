#!/bin/bash
# 只操作构建副本；CI 构建与公开发行共用资源校验、嵌套签名和归档顺序。
set -euo pipefail

fail() { printf '%s\n' "$*" >&2; exit 1; }
[[ $# -eq 2 ]] || fail 'Usage: package-app.sh APP OUTPUT_DIRECTORY'
source_app="$1"
output="$2"
source_root="$(cd "$(dirname "$0")/../.." && pwd)"
revision="${ARCKIT_SOURCE_REVISION:-working-tree}"
[[ -d "$source_app" && "$source_app" == *.app ]] || fail 'App bundle is missing'
[[ ! -e "$output" && ! -L "$output" ]] || fail 'Output directory already exists; choose a new directory'
[[ "$revision" =~ ^[A-Za-z0-9._-]+$ ]] || fail 'Invalid source revision'

# CI 发行使用 ad-hoc 封装，明确不宣称 Developer ID 签名或 Apple 公证。
signing=(--force --sign - --options runtime --timestamp=none)
entitlement_suffix=LocalAdHoc

mkdir -p "$source_root/.build"
work="$(mktemp -d "$source_root/.build/package.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir "$work/image" "$work/assets"
app="$work/image/Arc Kit.app"
ditto "$source_app" "$app"
xattr -cr "$app"
host="$app/Contents/Library/LoginItems/ArcKitRuntimeHost.app"
extension="$app/Contents/PlugIns/ArcKitFinderExtension.appex"

# 不按可执行文件存在就认定完整产品；三组件、架构和运行资源必须同时满足。
python3 - "$app" "$source_root" <<'PY'
import pathlib, plistlib, re, subprocess, sys
app, root = map(pathlib.Path, sys.argv[1:3])
components = [
    (app, 'com.archalo.arckit'),
    (app / 'Contents/Library/LoginItems/ArcKitRuntimeHost.app', 'com.archalo.arckit.runtime-host'),
    (app / 'Contents/PlugIns/ArcKitFinderExtension.appex', 'com.archalo.arckit.finder-extension'),
]
versions = set()
for bundle, identifier in components:
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != identifier:
        raise SystemExit(f'Unexpected identity: {bundle.name}')
    versions.add((info['CFBundleShortVersionString'], info['CFBundleVersion']))
    binary = bundle / 'Contents/MacOS' / info['CFBundleExecutable']
    subprocess.run(['lipo', str(binary), '-verify_arch', 'arm64', 'x86_64'], check=True)
    for language in ('en', 'zh-Hans'):
        if not (bundle / f'Contents/Resources/{language}.lproj').is_dir():
            raise SystemExit(f'Missing {language} resources: {bundle.name}')
if len(versions) != 1:
    raise SystemExit('Product component versions differ')
version, build = versions.pop()
if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version) or not re.fullmatch(r'[1-9][0-9]*', build):
    raise SystemExit('Invalid product version or build')
minimum_system = plistlib.loads((app / 'Contents/Info.plist').read_bytes()).get('LSMinimumSystemVersion', '')
if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?', minimum_system):
    raise SystemExit('Invalid minimum system version')
frameworks = list(app.rglob('*.framework'))
if not frameworks:
    raise SystemExit('Missing embedded frameworks')
for framework in frameworks:
    subprocess.run(['lipo', str(framework / framework.stem), '-verify_arch', 'arm64', 'x86_64'], check=True)
resources = [
    ('Licenses', app / 'Contents/Resources/Licenses'),
    ('Sources/Application/Resources/Brand', app / 'Contents/Frameworks/ArcKitApplication.framework/Resources/Brand'),
    ('Sources/Application/Resources/Aura', app / 'Contents/Frameworks/ArcKitApplication.framework/Resources/Aura'),
]
for bundle, _ in components:
    resources.append(('Sources/Features/Finder/Domain/Resources/NewFileTemplates',
        bundle / 'Contents/Frameworks/ArcKitFinder.framework/Resources/NewFileTemplates'))
for relative, target in resources:
    source = root / relative
    for file in source.rglob('*'):
        if file.is_file() and (target / file.relative_to(source)).read_bytes() != file.read_bytes():
            raise SystemExit(f'Resource differs: {relative}/{file.relative_to(source)}')
print(f'Package input: {version} ({build}), arm64 + x86_64, {len(frameworks)} embedded frameworks')
PY

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
name="ArcKit-${version}-build${build}-universal"
# 项目与第三方许可证同时随包分发，缺少根许可证时禁止打包。
[[ -f "$source_root/LICENSE" ]] || fail 'Project license is missing'
cp "$source_root/LICENSE" "$app/Contents/Resources/Licenses/ArcKit-LICENSE.txt"
while IFS= read -r -d '' framework; do
    # Xcode 会裁掉 Framework 的头文件，需要重签封装；不使用 --deep 重签嵌套助手。
    # Sparkle 的 XPC 和 Updater 保留官方签名，外层与应用一致使用 ad-hoc。
    codesign "${signing[@]}" "$framework"
done < <(find "$app" -type d -name '*.framework' -print0)
codesign "${signing[@]}" --entitlements "$source_root/Targets/ArcKitFinderExtension/Configuration/Signing/ArcKitFinderExtension${entitlement_suffix}.entitlements" "$extension"
codesign "${signing[@]}" --entitlements "$source_root/Targets/ArcKitRuntimeHost/Configuration/Signing/ArcKitRuntimeHost${entitlement_suffix}.entitlements" "$host"
codesign "${signing[@]}" --entitlements "$source_root/Targets/ArcKitApp/Configuration/Signing/ArcKitApp${entitlement_suffix}.entitlements" "$app"
codesign --verify --deep --strict --all-architectures --verbose=2 "$app"

# 同一份应用生成 ZIP 与 DMG；Release 直接发布 Quality 验证过的这些文件。
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/assets/$name.zip"
ln -s /Applications "$work/image/Applications"
hdiutil create -volname 'Arc Kit' -srcfolder "$work/image" -format UDZO "$work/assets/$name.dmg"
hdiutil verify "$work/assets/$name.dmg"
unzip -tq "$work/assets/$name.zip"
python3 - "$work/assets" "$app/Contents/Info.plist" "$revision" <<'PYINFO'
import json, pathlib, plistlib, sys
output, info_path, revision = sys.argv[1:]
info = plistlib.loads(pathlib.Path(info_path).read_bytes())
(pathlib.Path(output) / 'BUILD-INFO.json').write_text(json.dumps({
    'version': info['CFBundleShortVersionString'], 'build': int(info['CFBundleVersion']),
    'minimumSystemVersion': info['LSMinimumSystemVersion'],
    'sourceRevision': revision, 'architectures': ['arm64', 'x86_64'],
    'signing': 'ad-hoc', 'notarized': False,
}, indent=2) + '\n')
PYINFO

(
    cd "$work/assets"
    shasum -a 256 ./*.dmg ./*.zip ./*.json > SHA256SUMS.txt
)
mkdir -p "$(dirname "$output")"
mv "$work/assets" "$output"
printf 'Packages ready: %s\n' "$output"
