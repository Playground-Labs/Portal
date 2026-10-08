#!/usr/bin/env python3
"""Add a release to a Sparkle appcast.

Usage: update-appcast.py APPCAST VERSION BUILD ZIP_URL 'sparkle:edSignature="..." length="..."'
       update-appcast.py --self-test
"""
import re
import sys
import xml.etree.ElementTree as ET
from email.utils import formatdate
from pathlib import Path

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)


def sp(tag):
    return f'{{{SPARKLE}}}{tag}'


def add_release(appcast, version, build, url, sign_output):
    signature = re.search(r'sparkle:edSignature="([^"]+)"', sign_output)
    length = re.search(r'length="(\d+)"', sign_output)
    if not (signature and length):
        raise SystemExit('sign_update output must contain sparkle:edSignature and length')
    path = Path(appcast)
    if path.exists():
        tree = ET.parse(path)
    else:
        rss = ET.Element('rss', {'version': '2.0'})
        channel = ET.SubElement(rss, 'channel')
        ET.SubElement(channel, 'title').text = 'Portal'
        tree = ET.ElementTree(rss)
    channel = tree.getroot().find('channel')
    for item in channel.findall('item'):
        if item.findtext(sp('version')) == build or item.findtext(sp('shortVersionString')) == version:
            raise SystemExit(f'Appcast already contains version {version} or build {build}')

    item = ET.Element('item')
    ET.SubElement(item, 'title').text = f'Version {version}'
    ET.SubElement(item, 'pubDate').text = formatdate(usegmt=True)
    ET.SubElement(item, sp('version')).text = build
    ET.SubElement(item, sp('shortVersionString')).text = version
    ET.SubElement(item, sp('minimumSystemVersion')).text = '14.0'
    ET.SubElement(item, 'enclosure', {
        'url': url,
        'length': length.group(1),
        'type': 'application/octet-stream',
        sp('edSignature'): signature.group(1),
    })
    children = list(channel)
    first_item = next((i for i, child in enumerate(children) if child.tag == 'item'), len(children))
    channel.insert(first_item, item)
    ET.indent(tree)
    tree.write(path, encoding='utf-8', xml_declaration=True)


def self_test():
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        appcast = Path(tmp) / 'appcast.xml'
        add_release(appcast, '0.1.0', '1', 'https://example.com/0.1.0.zip', 'sparkle:edSignature="AAA=" length="10"')
        add_release(appcast, '0.2.0', '2', 'https://example.com/0.2.0.zip', 'sparkle:edSignature="BBB=" length="20"')
        items = ET.parse(appcast).getroot().find('channel').findall('item')
        assert [i.findtext(sp('version')) for i in items] == ['2', '1']
        enclosure = items[0].find('enclosure')
        assert enclosure.get('url') == 'https://example.com/0.2.0.zip'
        assert enclosure.get('length') == '20' and enclosure.get(sp('edSignature')) == 'BBB='
        assert items[0].findtext(sp('minimumSystemVersion')) == '14.0'
        assert 'xmlns:sparkle=' in appcast.read_text()
        try:
            add_release(appcast, '0.2.0', '3', 'https://example.com/x.zip', 'sparkle:edSignature="C" length="1"')
        except SystemExit:
            pass
        else:
            raise AssertionError('duplicate version accepted')
        assert len(ET.parse(appcast).getroot().find('channel').findall('item')) == 2
    print('update-appcast self-test passed')


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-test']:
        self_test()
    elif len(sys.argv) == 6:
        add_release(*sys.argv[1:])
    else:
        raise SystemExit(__doc__)
