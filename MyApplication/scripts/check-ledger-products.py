"""Verify shared desktop logging routes, including records in the actual HAP."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MODULES = [
    'commons/src/main/ets/utils/ActivityLedger.ets',
    'commons/src/main/ets/utils/EvidenceIo.ets',
    'commons/src/main/ets/utils/SessionCapture.ets',
    'commons/src/main/ets/utils/EvidenceExportSnapshot.ets',
    'entry/src/main/ets/components/EvidenceShareService.ets',
    'entry/src/main/ets/pages/LogShareHistoryPage.ets',
    'commons/src/main/ets/utils/SessionRetention.ets',
    'commons/src/main/ets/utils/GameLogPaths.ets',
    'commons/src/main/ets/utils/LogExport.ets',
    'commons/src/main/ets/utils/LogExportBudget.ets',
    'entry/src/main/ets/components/ActivityLogModel.ets',
    'entry/src/main/ets/components/LogRetentionSettings.ets',
    'entry/src/main/ets/components/LogShareClient.ets',
    'entry/src/main/ets/components/LogShareErrors.ets',
    'entry/src/main/ets/components/LogShareSse.ets',
    'entry/src/main/ets/pages/ActivityLogPage.ets',
    'entry/src/main/ets/pages/DownloadHistoryPage.ets',
    'entry/src/main/ets/pages/tabs/SettingsTab.ets',
]


def source(relative):
    return (ROOT / relative).read_text(encoding='utf-8')


def verify(hap, mapping):
    targets = json.loads(source('entry/build-profile.json5'))['targets']
    products = json.loads(source('config/products.json'))['products']
    desktop_products = [name for name, item in products.items() if item['family'] == 'desktop']
    assert desktop_products, 'no declared desktop product'
    for product in desktop_products:
        target = next(item for item in targets if item['name'] == product)
        for page in ('pages/Index', 'pages/McGamePage', 'pages/ActivityLogPage', 'pages/DownloadHistoryPage', 'pages/LogShareHistoryPage'):
            assert page in target['source']['pages'], (product, page)
        for overlay in target['source']['sourceRoots']:
            for file in (ROOT / 'entry' / overlay).rglob('*.ets'):
                assert file.name not in {Path(item).name for item in MODULES}, file
    runtime = source('entry/src/main/ets/runtime/ProcessRuntime.ets')
    assert "context.filesDir + '/logs/game'" in runtime
    assert 'setLedgerScopeSink(new EntryLedgerScopeSink())' in runtime
    game = source('entry/src/main/ets/pages/McGamePage.ets')
    begin = game.index('ledgerBegin(profile.filesDir, sessionStartedAt, meta)')
    assert begin < game.index('testNapi.amclLedgerSetLaunchActivity(sessionStartedAt)', begin)
    assert begin < game.index('testNapi.mcLaunchWithProfileV2(', begin)
    index = source('entry/src/main/ets/pages/Index.ets')
    assert '@Watch(\'onDesktopSessionChanged\')' in index
    assert 'ledgerEnd(this.context.filesDir, startedAt, outcome)' in index
    assert 'SettingsTab({' in index
    entry = source('entry/src/main/ets/entryability/EntryAbility.ets')
    assert 'SessionMarker.readAndClear(this.context.filesDir)' in entry
    assert "AppStorage.setOrCreate<number>('desktopSessionRevision'" in entry
    maps = json.loads(mapping.read_text(encoding='utf-8'))
    with zipfile.ZipFile(hap) as package:
        abc = package.read('ets/modules.abc')
        pages = json.loads(package.read('resources/base/profile/main_pages.json'))['src']
        profile = json.loads(package.read('resources/rawfile/product-profile.json'))
        assert profile['name'] == 'desktop', profile['name']
        assert profile['build']['mode'] == 'release', profile['build']
        assert 'pages/ActivityLogPage' in pages and 'pages/DownloadHistoryPage' in pages and 'pages/LogShareHistoryPage' in pages
        records = {}
        for module in MODULES:
            keys = [key for key, value in maps.items() if module in value.get('sources', [])]
            assert len(keys) == 1, (module, keys)
            assert keys[0].encode() in abc, ('record absent from ABC', module)
            records[module] = keys[0]
        # Negative control: a missing record must not pass the same membership check.
        assert b'entry|entry|1.0.0|src/main/ets/NonexistentLedgerNegativeControl.ts' not in abc
        for literal in ('https://api.logshare.cn', 'https://amcl.lovedhy.cn/logshare-api',
                        '日志分享暂不可用', 'session-retention.json', '生成脱敏预览'):
            assert literal.encode() in abc, literal
    return dict(product='desktop', mode='release', hapSha256=hashlib.sha256(hap.read_bytes()).hexdigest(),
                sharedSourceProducts=desktop_products, packagedRecords=records,
                pcRuntimeTested=False, note='Source and HAP verification; no PC device runtime claim.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--hap', required=True, type=Path)
    parser.add_argument('--mapping', required=True, type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = verify(args.hap, args.mapping)
    encoded = json.dumps(result, ensure_ascii=False, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding='utf-8')
    print(encoded)
