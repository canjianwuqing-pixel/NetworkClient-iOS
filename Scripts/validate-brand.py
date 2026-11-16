#!/usr/bin/env python3
"""Read-only build-brand preflight. No dependencies or network access."""
from pathlib import Path
import json
import os
import re
import struct
import sys
import zlib

root = Path(__file__).resolve().parents[1]
def setting(key):
    value = os.environ.get(key, '').strip()
    assert value, f'{key} must be supplied by the active build configuration'
    return value
def config_resource(key):
    name = setting(key)
    return json.loads((root/'Resources'/f'{name}.json').read_text())
def validate_png(path):
    data = path.read_bytes()
    assert data.startswith(b'\x89PNG\r\n\x1a\n'), f'{path} is not a PNG'
    offset = 8
    chunks = []
    dimensions = None
    while offset < len(data):
        assert offset + 12 <= len(data), f'{path} has a truncated PNG chunk'
        length = struct.unpack('>I', data[offset:offset + 4])[0]
        chunk_type = data[offset + 4:offset + 8]
        chunk_end = offset + 12 + length
        assert chunk_end <= len(data), f'{path} has an invalid PNG chunk length'
        payload = data[offset + 8:offset + 8 + length]
        expected_crc = struct.unpack('>I', data[offset + 8 + length:chunk_end])[0]
        assert zlib.crc32(chunk_type + payload) & 0xffffffff == expected_crc, f'{path} has an invalid PNG CRC'
        chunks.append(chunk_type)
        if chunk_type == b'IHDR':
            assert length == 13 and dimensions is None, f'{path} has an invalid IHDR'
            dimensions = struct.unpack('>II', payload[:8])
        offset = chunk_end
        if chunk_type == b'IEND':
            break
    assert chunks and chunks[0] == b'IHDR' and chunks[-1] == b'IEND', f'{path} has an invalid PNG structure'
    assert offset == len(data), f'{path} has trailing data after IEND'
    assert dimensions == (1024, 1024), f'{path} must be 1024x1024'
    return data
assert setting('BRAND_LOCAL_LOGO_RESOURCE') == 'BrandLocalLogo'
assert not (root/'Resources'/f"{setting('BRAND_LOCAL_LOGO_RESOURCE')}.png").exists(), 'BrandLocalLogo must be generated from the selected source image'
source_image = Path(setting('BRAND_SOURCE_IMAGE_PATH'))
validate_png(source_image)
if setting('BRAND_APP_ICON') == 'AppIcon':
    icon_set = root/'Resources/Assets.xcassets/AppIcon.appiconset'
    contents = json.loads((icon_set/'Contents.json').read_text())
    filenames = [image.get('filename') for image in contents.get('images', []) if image.get('filename')]
    assert filenames == ['AppIcon.png'], 'Public AppIcon catalog must reference the single AppIcon.png source'
    assert source_image.resolve() == (icon_set/'AppIcon.png').resolve(), 'Public build must use the tracked AppIcon source'
colors = config_resource('BRAND_THEME_RESOURCE')['colors']
for key in ['background','card','field','text','secondary','tertiary','border','divider','accent','emphasis','tint','error','website','support','warning','onAccent','announcement','success','shadow']:
    assert len(colors[key])==2 and all(re.fullmatch('[0-9a-fA-F]{6}([0-9a-fA-F]{2})?',v) for v in colors[key]), key
network = config_resource('BRAND_NETWORK_RESOURCE')
assert network['apiRoot'].startswith('/') and not network['apiRoot'].endswith('/')
assert network['customerServiceEmbed'].startswith('https://')
assert len(network['paths']) == 23
assert network['paths']['accountDeleteRequestPath'] == '/user/account/delete-request'
for key,path in network['paths'].items(): assert path.startswith('/') and '://' not in path and '..' not in path, key
bootstrap = json.loads(Path(setting('BOOTSTRAP_INPUT_PATH')).read_text())
assert bootstrap['CloudConfig']
print('Active build logo, theme, bootstrap and 23 endpoint paths validated.')
