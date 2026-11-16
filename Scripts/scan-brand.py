#!/usr/bin/env python3
"""Inventory all source/config/test/resource brand references, and fail on business literals."""
from pathlib import Path
import argparse
import hashlib
import json
import re
from urllib.parse import urlsplit

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', default='.build/brand-scan.json', help='Repository-relative report; historical reports are never overwritten by default.')
args = parser.parse_args()
legacy_storage = {
    'SharedServices/RemoteConfigService.swift': {'LegacyNetworkClient'},
    'iOSAdapters/UserSystemLogger.swift': {'LegacyNetworkClient'},
}

production = {'App','SharedDomain','SharedServices','iOSAdapters','TunnelContract','NetworkPacketTunnel'}
hits = []
violations = []
assets = []
files = 0
for path in sorted(root.rglob('*')):
    relative = path.relative_to(root)
    if not path.is_file() or any(x in relative.parts for x in ['.git','.build']) or path.suffix in ['.log','.xcuserstate']:
        continue
    if relative.parts[0] in ['Documentation', 'Vendor']:
        continue  # Immutable historical evidence and third-party code are inventoried separately.
    if path.suffix in ['.png','.svg']:
        assets.append({'path':str(relative),'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
            'role':'archived-test-screenshot' if relative.parts[0]=='Documentation' else 'replaceable branded build resource' if path.suffix=='.png' and 'BrandFixtures' not in relative.parts else 'test fixture' if 'BrandFixtures' in relative.parts else 'template UI asset'})
    if path.suffix not in ['.swift','.json','.xcstrings','.xcconfig','.plist','.pbxproj','.md','.py','.sh','.template','.xcscheme']:
        continue
    files += 1
    source = path.read_text(errors='replace')
    for number,line in enumerate(source.splitlines(),1):
        reasons = []
        urls = re.findall(r'https?://[A-Za-z0-9][^\s"<>\\]*', line)
        strings = re.findall(r'"([^"\n]*)"',line)
        name = any(re.search(r'retiredbrand|retiredvpnbrand|retiredclientbrand', value, re.I) for value in strings)
        if name or re.search(r'retiredbrand|retiredvpnbrand|retiredclientbrand', line, re.I): reasons.append('brand-or-stable-identifier')
        if urls: reasons.append('URL')
        if re.search(r'BrandLocalLogo|BRAND_LOCAL_LOGO|AppIcon',line): reasons.append('build-resource-reference')
        if not reasons: continue
        is_source = path.suffix=='.swift' and relative.parts[0] in production
        category = 'documentation-or-tooling'
        if relative.parts[0] == 'Resources': category = 'replaceable-config-or-resource'
        elif relative.parts[0] == 'Configuration' or path.name=='project.pbxproj': category = 'build-time-configuration'
        elif relative.parts[0] in ['Tests','UITests']: category = 'isolated-test-data-or-module-identity'
        elif is_source:
            category = 'legacy-storage-compatibility' if str(relative) in legacy_storage else 'active-source-reference'
            if any(re.search(r'retiredbrand|retiredvpnbrand', v, re.I) for v in strings):
                violations.append({'path':str(relative),'line':number,'kind':'production brand display literal'})
            if any('retiredclientbrand' in v.lower() and v not in legacy_storage.get(str(relative), set()) for v in strings):
                violations.append({'path':str(relative),'line':number,'kind':'unapproved branded string'})
            for url in urls:
                host = urlsplit(url).hostname or ''
                if host and not (host.endswith('.invalid') or host in ['localhost','127.0.0.1','::1']):
                    violations.append({'path':str(relative),'line':number,'kind':'production endpoint literal'})
            if re.search(r'Image\(\s*"[^"]*(?:BrandLocalLogo|Logo)',line):
                violations.append({'path':str(relative),'line':number,'kind':'fixed brand image path'})
        if is_source:
            # Catch branded type/module/flag identifiers as well as display strings.
            code_without_strings = re.sub(r'"[^"\n]*"', '', line).split('//', 1)[0]
            if re.search(r'retiredbrand|retiredvpnbrand|retiredclientbrand', code_without_strings, re.I):
                violations.append({'path':str(relative),'line':number,'kind':'branded internal source identity'})
        hits.append({'path':str(relative),'line':number,'category':category,'reasons':reasons,'text':line.strip()[:250]})
# Pages must not own palette literals; transparency is not a brand color.
for path in (root/'App').rglob('*.swift'):
    for number,line in enumerate(path.read_text().splitlines(),1):
        if re.search(r'Color\((?:red:|\.sRGB)|\.(?:foregroundStyle|tint|background)\(\.(?:indigo|purple|green|blue|red|white|black)',line):
            violations.append({'path':str(path.relative_to(root)),'line':number,'kind':'page-owned palette'})
result={'textFilesScanned':files,'references':hits,'assets':assets,'violations':violations,
        'notes':['Stable Keychain/cache/defaults and internal Swift module identities are intentionally preserved.',
                 'Brand values and production endpoints are allowed only in replaceable configuration/build resources.',
                 'Generated build files/logs, immutable historical documentation and third-party code are excluded; template SVG colors are tinted by ThemeProvider.']}
out=root/args.output;out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps(result,ensure_ascii=False,indent=2))
print(json.dumps({'textFilesScanned':files,'references':len(hits),'assets':len(assets),'violations':violations},ensure_ascii=False,indent=2))
raise SystemExit(bool(violations))
