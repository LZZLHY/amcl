"""固定 Compose 服务的正负契约测试：真实文件/状态机，Docker 边界替身，无引擎副作用。"""
import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts/lib'))
from workspace_paths import temporary_directory
spec=importlib.util.spec_from_file_location('amcl_docker_project',ROOT/'docker/project.py')
project=importlib.util.module_from_spec(spec); spec.loader.exec_module(project)
IMAGE='sha256:'+'a'*64

class ProjectContract(unittest.TestCase):
    """只在仓外独占夹具写状态；每例使用独立临时目录并在退出后由原工具清理。"""
    def setUp(self):
        self.temporary=temporary_directory(prefix='docker-project-')
        self.root=Path(self.temporary.name)
        self.sdk=self.root/'sdk'
        for name in project.SENTINELS:
            path=self.sdk/name; path.parent.mkdir(parents=True,exist_ok=True); path.write_text(name)
        self.calls=[]; self.busy=False; self.foreign=False; self.volume_busy=False
        self.patches=[patch.object(project,'docker',self.docker),
                      patch.dict(os.environ,{'AMCL_WORKSPACE_ROOT':str(self.root)})]
        for item in self.patches: item.start()
    def tearDown(self):
        for item in reversed(self.patches): item.stop()
        self.temporary.cleanup()
    def docker(self,*args):
        self.calls.append(args)
        if args[:2]==('image','inspect'): return IMAGE
        if args[:2]==('ps','-aq'): return 'existing' if self.busy or self.foreign else ''
        if args[0]=='inspect': return json.dumps([{'Config':{'Labels':{
            'amcl.managed':'1','amcl.checkout':'foreign' if self.foreign else str(ROOT)}},
            'State':{'Running':self.busy}}])
        if args[:2]==('ps','-q'): return 'reader' if self.volume_busy else ''
        if args[0]=='volume': return '[]' if args[1]=='inspect' else ''
        if args[0]=='compose': return ''
        raise AssertionError(args)
    def args(self,**changes):
        values=dict(action='build',state_dir=str(self.root/'state'),image='fixture',qa_image=None,
                    sysroot=str(self.sdk),component='smoke',suite='elf',jobs=2,fresh=False,
                    plan_only=False,reuse_manifest=None,recipe_arg=[])
        values.update(changes); return argparse.Namespace(**values)
    def execute(self,**changes):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            code=project.run(self.args(**changes))
        return code,output.getvalue()
    def test_missing_sdk_has_no_engine_calls(self):
        with self.assertRaises(ValueError): self.execute(sysroot=str(self.root/'missing'))
        self.assertEqual(self.calls,[])
    def test_plan_creates_no_state_or_volume(self):
        _,text=self.execute(plan_only=True)
        plan=json.loads(text)
        self.assertEqual(plan['service'],'builder')
        self.assertFalse((self.root/'state').exists())
        self.assertFalse(Path(plan['output']).exists())
        self.assertTrue(all(c[0] in ('image','ps') for c in self.calls))
    def test_running_service_is_never_stopped(self):
        self.busy=True
        with self.assertRaisesRegex(RuntimeError,'running'): self.execute()
        self.assertFalse(any(c[0]=='compose' for c in self.calls))
    def test_foreign_checkout_is_never_replaced(self):
        self.foreign=True
        with self.assertRaisesRegex(RuntimeError,'foreign'): self.execute()
    def test_image_must_be_immutable(self):
        with patch.object(project,'docker',return_value='latest'):
            with self.assertRaises(ValueError): project.image_id('image')
    def test_bind_never_creates_missing_host_path(self):
        with self.assertRaises(ValueError): project.bind(self.root/'absent','/data')
        self.assertFalse((self.root/'absent').exists())
    def test_foreign_state_rejected(self):
        project.write_json(self.root/'state/state.json',{'checkout':'elsewhere'})
        with self.assertRaises(ValueError): self.execute()
    def seed_workspace(self):
        state={'schema':1,'checkout':str(ROOT),'workspaces':{'smoke':{
            'volume':'known-volume','buildId':'known-build',
            'inputs':project.input_identity('smoke',IMAGE,self.sdk)}}}
        project.write_json(self.root/'state/state.json',state)
    def test_default_reuses_volume_but_each_run_has_new_output(self):
        self.seed_workspace()
        _,one=self.execute(plan_only=True); _,two=self.execute(plan_only=True)
        a,b=json.loads(one),json.loads(two)
        self.assertEqual(a['workVolume'],b['workVolume']); self.assertEqual(a['workspaceMode'],'reuse')
        self.assertEqual(a['service'],b['service']); self.assertNotEqual(a['output'],b['output'])
    def test_changed_sdk_requires_explicit_fresh(self):
        self.seed_workspace(); (self.sdk/project.SENTINELS[0]).write_text('changed')
        with self.assertRaisesRegex(ValueError,'identity changed'): self.execute(plan_only=True)
        _,text=self.execute(plan_only=True,fresh=True)
        self.assertEqual(json.loads(text)['workspaceMode'],'fresh')
    def test_lwjgl_vma_patch_is_part_of_reuse_identity(self):
        """真实输入列表必须携带VMA补丁，改补丁不能沿用原构建缓存身份。"""
        key = 'prebuilt/lwjgl3/local-worktree.patch'
        before = project.input_identity('lwjgl', IMAGE, self.sdk)
        self.assertIn(key, before['files'])
        original_digest = project.digest
        with patch.object(project, 'digest', side_effect=lambda p:
                          '0' * 64 if Path(p) == ROOT / key else original_digest(p)):
            after = project.input_identity('lwjgl', IMAGE, self.sdk)
        self.assertNotEqual(before['digest'], after['digest'])
    def test_active_volume_rejected(self):
        self.seed_workspace(); self.volume_busy=True
        with self.assertRaisesRegex(RuntimeError,'in use'): self.execute(plan_only=True)
    def test_success_and_failure_keep_evidence_not_extra_service(self):
        for status in (0,42):
            with patch.object(project,'stream_compose',return_value=status):
                code,_=self.execute()
            self.assertEqual(code,status)
        manifests=list((self.root/'.workspace/build').rglob('build-manifest.json'))
        self.assertEqual(len(manifests),2)
        data=[project.read_json(p) for p in manifests]
        self.assertEqual({p['state'] for p in data},{'completed','failed'})
        self.assertEqual(len({p['workVolume'] for p in data}),1)
        self.assertEqual({p['service'] for p in data},{'builder'})
        for p in data:
            model=project.read_json(p['composeFile'])
            mounts=model['services']['builder']['volumes']
            self.assertTrue(all(not m['bind']['create_host_path'] for m in mounts if m['type']=='bind'))
        self.assertFalse(any(c[0] in ('rm','prune','stop','start') for c in self.calls))
    def test_lock_conflict_keeps_first_owner(self):
        with project.project_lock(self.root/'lock'):
            with self.assertRaises(RuntimeError):
                with project.project_lock(self.root/'lock'): pass
    def test_legacy_catalog_rejects_daily_service_or_writable_mount(self):
        target=self.root/'legacy.json'
        for item in ({'builder':{'read_only':True,'network_mode':'none'}},
                     {'legacy-x':{'read_only':True,'network_mode':'none','volumes':[{'read_only':False}]}}):
            project.write_json(target,{'services':item})
            with self.assertRaises(ValueError): project.legacy_services(target)
    def test_registered_legacy_is_included_and_fingerprint_checked(self):
        target=self.root/'legacy.json'
        project.write_json(target,{'services':{'legacy-x':{'read_only':True,'network_mode':'none'}}})
        state={'legacyConfig':str(target),'legacyConfigSha256':project.digest(target)}
        model=project.include_legacy({'services':{'builder':{}}},state)
        self.assertEqual(set(model['services']),{'builder','legacy-x'})
        target.write_text('{}')
        with self.assertRaisesRegex(ValueError,'identity changed'): project.include_legacy({},state)
    def test_catalog_drift_fails_before_engine_or_output_mutations(self):
        target=self.root/'legacy.json'; target.write_text('{}')
        state={'schema':1,'checkout':str(ROOT),'workspaces':{},'legacyConfig':str(target),
               'legacyConfigSha256':'not-current'}
        project.write_json(self.root/'state/state.json',state)
        with self.assertRaisesRegex(ValueError,'identity changed'): self.execute()
        self.assertEqual(self.calls,[])
        self.assertFalse((self.root/'.workspace').exists())

if __name__=='__main__': unittest.main(verbosity=2)
