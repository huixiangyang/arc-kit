#!/usr/bin/env python3
"""用仓库中的最小 OOXML 定义生成空白文件；--check 校验提交资源可重现。"""
import argparse
import io
from pathlib import Path
import xml.etree.ElementTree as ET
from zipfile import ZipFile, ZipInfo, ZIP_STORED


ROOT = Path(__file__).resolve().parents[2]
DESTINATION = ROOT / 'Sources/Features/Finder/Domain/Resources/NewFileTemplates'
RELATIONSHIPS = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
XML_HEADER = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'


def relationships(entries):
    return ('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            + ''.join(f'<Relationship Id="rId{index}" Type="{RELATIONSHIPS}/{kind}" Target="{target}"/>'
                      for index, (kind, target) in enumerate(entries, 1)) + '</Relationships>')


def package(parts, main, extra_relationships=None):
    content_types = ('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
                     '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
                     '<Default Extension="xml" ContentType="application/xml"/>')
    for path, (kind, _) in parts.items():
        content_types += f'<Override PartName="/{path}" ContentType="application/vnd.openxmlformats-officedocument.{kind}+xml"/>'
    files = {path: xml for path, (_, xml) in parts.items()}
    files['[Content_Types].xml'] = content_types + '</Types>'
    files['_rels/.rels'] = relationships([('officeDocument', main)])
    files.update(extra_relationships or {})
    result = io.BytesIO()
    with ZipFile(result, 'w', compression=ZIP_STORED) as archive:
        for path, xml in sorted(files.items()):
            data = (XML_HEADER + xml).encode('utf-8')
            ET.fromstring(data)
            # 固定时间、权限与条目顺序；不包含个人信息，也不依赖压缩库版本。
            entry = ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, data)
    return result.getvalue()


def templates():
    yield 'word.docx', package({
        'word/document.xml': ('wordprocessingml.document.main',
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
            '<w:body><w:p/><w:sectPr><w:pgSz w:w="12240" w:h="15840"/>'
            '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/>'
            '</w:sectPr></w:body></w:document>'),
    }, 'word/document.xml')
    yield 'excel.xlsx', package({
        'xl/workbook.xml': ('spreadsheetml.sheet.main',
            '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
            f'xmlns:r="{RELATIONSHIPS}"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/>'
            '</sheets></workbook>'),
        'xl/worksheets/sheet1.xml': ('spreadsheetml.worksheet',
            '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData/></worksheet>'),
    }, 'xl/workbook.xml', {'xl/_rels/workbook.xml.rels': relationships([('worksheet', 'worksheets/sheet1.xml')])})
    yield 'powerPoint.pptx', package({
        'ppt/presentation.xml': ('presentationml.presentation.main',
            '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
            '<p:sldIdLst/><p:sldSz cx="9144000" cy="6858000" type="screen4x3"/>'
            '<p:notesSz cx="6858000" cy="9144000"/></p:presentation>'),
    }, 'ppt/presentation.xml')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    for name, data in templates():
        path = DESTINATION / name
        if args.check:
            if not path.is_file() or path.read_bytes() != data:
                raise SystemExit(f'模板不可重现，请运行本脚本重新生成：{name}')
        else:
            path.write_bytes(data)
        print(f'{"Checked" if args.check else "Generated"}: {name}')


if __name__ == '__main__':
    main()
