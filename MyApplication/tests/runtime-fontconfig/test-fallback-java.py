#!/usr/bin/env python3
"""执行四代真实 doDeferredInitialisation 方法，复现名字缺失把真实文件替成默认字体。"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def extract_method(source):
    """只截取锁定源码的整个方法；类/文件系统替身负责输入，方法本身不改逻辑。"""
    begin = source.index('    private void doDeferredInitialisation(int slot)')
    opening = source.index('{', begin)
    depth = 0
    for at in range(opening, len(source)):
        depth += (source[at] == '{') - (source[at] == '}')
        if depth == 0:
            return source[begin:at + 1]
    raise ValueError('不完整的方法')


def main():
    """输入每个字节先核 SHA；原/修复方法分别编译，不通过弱化字形比较获得成功。"""
    parser = argparse.ArgumentParser()
    for name in ('sources', 'javac', 'java', 'output'):
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    manifest = json.loads(args.sources.read_text())
    spec = json.loads(Path(__file__).with_name('fallback-cases.json').read_text())['runtimes']
    reports = {}
    for major, entry in manifest['runtimes'].items():
        reports[major] = {}
        for variant in ('before', 'after'):
            item = entry['files']['java'][variant]
            data = (args.sources.parent / item['file']).read_bytes()
            assert hashlib.sha256(data).hexdigest() == item['sha256']
            path = entry['files']['java']['sourcePath']
            expected = spec[major]['files' if variant == 'before' else 'patchedFiles'][path]
            assert item['sha256'] == expected and entry['patchSha256'] == spec[major]['patchSha256']
            code = extract_method(data.decode('utf-8'))
            destination = args.output / (major + '-' + variant)
            destination.mkdir()
            # 替身只提供已知文件、真实名称查找成功/缺席/错误类型等边界；执行的决策方法
            # 就是上游/补后正文，反复访问检查延迟初始化不会变成热路径重复查找。
            program = '''import java.util.Locale;
class Font2D { String name; Font2D(String n){name=n;} String getFontName(Locale l){return name;} }
class PhysicalFont extends Font2D { PhysicalFont(String n){super(n);} }
class FontManager { static final int NO_FALLBACK=0, PHYSICAL_FALLBACK=1; }
class SunFontManager {
 static SunFontManager current; PhysicalFont loaded, fallback=new PhysicalFont("Default");
 Font2D match; int lookups, loads;
 static SunFontManager getInstance(){return current;}
 PhysicalFont initialiseDeferredFont(String f){++loads;return loaded;}
 PhysicalFont getDefaultPhysicalFont(){return fallback;}
 Font2D findFont2D(String n,int s,int kind){++lookups;return match!=null?match:(kind==1?fallback:null);}
}
public class DeferredProbe {
 boolean[] deferredInitialisation={true}; int numSlots=1,style=0;
 String[] componentNames={"FC instance"},componentFileNames={"actual.ttf"};
 PhysicalFont[] components=new PhysicalFont[1];
''' + code + '''
 static void check(boolean condition,String label){if(!condition)throw new AssertionError(label);}
 public static void main(String[] args) {
  boolean repaired=Boolean.parseBoolean(args[0]); int cases=0;
  for(int style=0;style<4;style++) for(int scenario=0;scenario<5;scenario++) {
   DeferredProbe probe=new DeferredProbe(); probe.style=style;
   SunFontManager manager=new SunFontManager(); SunFontManager.current=manager;
   manager.loaded=new PhysicalFont("File default instance");
   if(scenario==1) manager.match=new PhysicalFont("Exact TTC face");
   if(scenario==2) manager.match=new Font2D("Unexpected logical font");
   if(scenario==3) probe.componentNames[0]=manager.loaded.name;
   if(scenario==4) manager.loaded=null;
   probe.doDeferredInitialisation(0);
   PhysicalFont expected=manager.loaded;
   if(scenario==1) expected=(PhysicalFont)manager.match;
   if(scenario==4 || (!repaired && (scenario==0 || scenario==2))) expected=manager.fallback;
   check(probe.components[0]==expected,"style="+style+" case="+scenario);
   int lookups=manager.lookups,loads=manager.loads;
   probe.doDeferredInitialisation(0);
   check(manager.lookups==lookups && manager.loads==loads,"warm lookup did extra work");
   ++cases;
  }
  System.out.println("PASS actual deferred method "+(repaired?"repair":"original bug negative control")+" cases="+cases);
 }
}
'''
            source = destination / 'DeferredProbe.java'
            source.write_text(program, encoding='utf-8', newline='\n')
            with (destination / 'build.log').open('wb') as log:
                subprocess.run([str(args.javac), '-encoding', 'UTF-8', '-d', str(destination), str(source)],
                               check=True, stdout=log, stderr=subprocess.STDOUT)
            result = subprocess.run([str(args.java), '-cp', str(destination), 'DeferredProbe', str(variant == 'after').lower()],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            (destination / 'behavior.log').write_bytes(result.stdout)
            if result.returncode:
                raise RuntimeError(result.stdout.decode('utf-8', errors='replace'))
            print(major, variant, result.stdout.decode().strip(), flush=True)
            reports[major][variant] = {'sourceSha256': item['sha256'], 'cases': 20, 'passed': True}
    (args.output / 'report.json').write_text(json.dumps(reports, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
