#!/usr/bin/env python3
"""审核真实 ABI 库和兼容外壳，不以库名或链接成功代替实现资格。

本门仅证明供应者身份和链接边界。并发 guard、跨 DSO 异常与 TLS 析构必须另做
行为测试，不能把目标 SDK 的存在当作自定义 ELF 加载器已经支持展开。
"""
import argparse
import hashlib
import json
from pathlib import Path
from package_runtime import elf_facts

REQUIRED = {'__cxa_guard_acquire', '__cxa_guard_release', '__cxa_guard_abort',
            '__cxa_allocate_exception', '__cxa_throw', '__cxa_begin_catch', '__cxa_end_catch',
            '__cxa_rethrow', '__dynamic_cast', '__gxx_personality_v0', '__cxa_thread_atexit',
            '_Unwind_RaiseException', '_Unwind_Resume', '__register_frame', '__deregister_frame',
            '_ZTVN10__cxxabiv117__class_type_infoE', '_ZTVN10__cxxabiv120__si_class_type_infoE',
            '_ZTVN10__cxxabiv121__vmi_class_type_infoE', '_Znwm', '_ZdlPv'}


def verify(provider, facade):
    """外壳不得覆盖 ABI；真实 provider 必须带基础能力和应用命名空间。"""
    actual, bridge = elf_facts(provider), elf_facts(facade)
    exported = set(actual['resolvableExports'])
    missing = REQUIRED - exported
    if missing:
        raise ValueError('Incomplete real C++ ABI provider: ' + ', '.join(sorted(missing)))
    if not any(name.startswith('_ZNSt4__n1') for name in exported):
        raise ValueError('C++ provider is not the application __n1 ABI')
    forbidden = [name for name in bridge['exports']
                 if name.startswith(('__cxa_', '__gxx_', '__dynamic_cast', '_Unwind_', '_ZT', '_Zn', '_Zd'))]
    if forbidden or 'libc++_shared.so' not in bridge['needed']:
        raise ValueError('ABI facade shadows real implementation or omits provider: ' + repr(forbidden))
    return {'schema': 1, 'namespace': 'std::__n1', 'soname': 'libc++_shared.so',
            'providerSha256': hashlib.sha256(provider).hexdigest(),
            'facadeSha256': hashlib.sha256(facade).hexdigest(),
            'requiredSymbols': sorted(REQUIRED), 'behaviorQualification': 'not-claimed'}


def main():
    """以真实产物和头文件生成可随打包收据传递的输入身份。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provider', type=Path, required=True)
    parser.add_argument('--facade', type=Path, required=True)
    parser.add_argument('--headers', type=Path, required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args()
    receipt = verify(args.provider.read_bytes(), args.facade.read_bytes())
    receipt['headers'] = {name: hashlib.sha256((args.headers / name).read_bytes()).hexdigest()
                          for name in ('__config', '__config_site')}
    args.receipt.write_text(json.dumps(receipt, indent=2) + '\n')
    print('PASS real C++ ABI dependency and symbol boundary')


if __name__ == '__main__':
    main()
