"""真实DH原件生成独立负控，编译生产策略并验证；成功后只保留结果与收据，回收本轮夹具。"""
import argparse, hashlib, io, json, os, shutil, subprocess, zipfile
from datetime import datetime
from pathlib import Path
from lib.workspace_paths import external_output_path


def main():
    """输出路径必须是外置新目录；失败保留最小复现，成功回收已关闭且亲建的fixtures。"""
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['output','dh','java','javac']: p.add_argument('--'+name,required=True)
    a=p.parse_args();root=Path(__file__).resolve().parents[1];out=external_output_path(a.output);out.mkdir(parents=True,exist_ok=False)
    fixtures=out/'fixtures';fixtures.mkdir();(fixtures/'files/tmp').mkdir(parents=True);(fixtures/'public').mkdir()
    steps=[];passed=False
    try:
        original=Path(a.dh);registry=root/'JavaApp/resources/com/amcl/launcher/sqlite-bindings.properties'
        entries={line.split('=',1)[0].split('.',1)[1]:line.split('=',1)[1] for line in registry.read_text().splitlines() if line.startswith(('class.','resource.'))}
        with zipfile.ZipFile(original) as z: values={n:z.read(n) for n in entries}
        assert len(values)==130 and all(hashlib.sha256(b).hexdigest()==entries[n] for n,b in values.items())
        def archive(data):
            buff=io.BytesIO()
            with zipfile.ZipFile(buff,'w',zipfile.ZIP_DEFLATED) as z:
                for n,b in data.items():z.writestr(n,b)
            return buff.getvalue()
        native='dh_sqlite/native/Linux-Musl/aarch64/libsqlitejdbc.so';clazz='dh_sqlite/core/NativeDB.class'
        for name in ['changed-class','missing-class','extra-class','changed-native','missing-native','mr']:
            case=dict(values)
            if name=='changed-class':case[clazz]=b'changed'
            if name=='missing-class':del case[clazz]
            if name=='extra-class':case['dh_sqlite/Extra.class']=b'unknown'
            if name=='changed-native':case[native]=b'changed'
            if name=='missing-native':del case[native]
            if name=='mr':case['META-INF/versions/21/'+clazz]=case[clazz]
            (fixtures/(name+'.jar')).write_bytes(archive(case))
        (fixtures/'shadow.jar').write_bytes(archive({native:values[native]}))
        for label,entry in [('resource-dir',native),('class-dir',clazz)]:
            file=fixtures/label/entry;file.parent.mkdir(parents=True);file.write_bytes(values[entry])
        (fixtures/'nested.jar').write_bytes(archive({'META-INF/jars/sqlite.jar':archive(values),'fabric.mod.json':b'{"jars":[{"file":"META-INF/jars/sqlite.jar"}]}'}))
        os.link(original,fixtures/'copy.jar')
        classes=fixtures/'classes';classes.mkdir();pkg=root/'JavaApp/src/com/amcl/launcher'
        command=[a.javac,'-encoding','UTF-8','--release','8','-d',str(classes),*[str(pkg/n)for n in ['NativeBindingInspector.java','JarJarMetadata.java','SqliteNativeTempBootstrap.java']],str(root/'JavaApp/test/com/amcl/launcher/SqliteBootstrapContractTest.java')]
        result=subprocess.run(command,capture_output=True);(out/'compile.log').write_bytes(result.stdout+result.stderr);steps.append({'command':command,'exitCode':result.returncode});assert not result.returncode,result.stderr.decode('utf-8','replace')
        shutil.copyfile(registry,classes/'com/amcl/launcher/sqlite-bindings.properties')
        command=[a.java,'-cp',str(classes),'com.amcl.launcher.SqliteBootstrapContractTest',str(fixtures),str(original)]
        result=subprocess.run(command,capture_output=True,timeout=90);(out/'contract.log').write_bytes(result.stdout+result.stderr);steps.append({'command':command,'exitCode':result.returncode});print(result.stdout.decode('utf-8','replace'));assert not result.returncode,result.stderr.decode('utf-8','replace')
        passed=True
    finally:
        (out/'receipt.json').write_text(json.dumps({'at':datetime.now().astimezone().isoformat(),'passed':passed,'steps':steps,'scope':'binding and private directory selection; no ARM native execution','fixturesRetired':passed},indent=2)+'\n')
        if passed:
            assert fixtures.resolve().parent==out.resolve() and fixtures.name=='fixtures'
            shutil.rmtree(fixtures)

if __name__=='__main__':main()
