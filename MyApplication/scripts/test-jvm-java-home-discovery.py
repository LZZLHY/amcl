"""默认宿主 Java 发现的编码回归；只构造仓外目录，不启动或替换任何真实 Java。"""
from pathlib import Path
import importlib.util
import os
from lib.workspace_paths import temporary_directory

script = Path(__file__).with_name('test-jvm-bootstrap-invocation.py')
spec = importlib.util.spec_from_file_location('jvm_bootstrap_invocation', script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
discover = module.java_home_from_properties
java_name = 'java.exe' if os.name == 'nt' else 'java'

with temporary_directory(prefix='amcl-java-home-discovery-') as directory:
    # is_file 仅是发现条件；主脚本随后还会实际运行 java -version 并核验 JVM 动态库。
    ascii_home = Path(directory) / 'java-ascii'
    unicode_home = Path(directory) / 'Java中文目录'
    for home in (ascii_home, unicode_home):
        (home / 'bin').mkdir(parents=True)
        (home / 'bin' / java_name).write_bytes(b'fixture-not-executable')
    junk = b'    user.language = \xff\xfe\x81\n    unrelated.property = \xb2\xe2\xca\xd4\n'
    ascii_line = b'    java.home = ' + str(ascii_home).encode('utf-8') + b'\r\n'
    assert discover(b'', junk + ascii_line, ('utf-8',)) == ascii_home.resolve()
    utf8_line = b'    java.home = ' + str(unicode_home).encode('utf-8') + b'\n'
    assert discover(junk + utf8_line, b'', ('utf-8', 'gbk')) == unicode_home.resolve()
    gbk_line = b'    java.home = ' + str(unicode_home).encode('gbk') + b'\r\n'
    assert discover(None, junk + gbk_line, ('utf-8', 'gbk')) == unicode_home.resolve()
    # 正确编码不等于正确目录；也不能把带同名尾部的其他属性误认成 java.home。
    for bad in (b'', b'    java.home = \n', b'not.java.home = ' + str(ascii_home).encode(),
                b'java.home = ' + str(ascii_home / 'missing').encode()):
        try:
            discover(None, bad, ('utf-8', 'gbk'))
        except RuntimeError:
            pass
        else:
            raise AssertionError('Absent/invalid Java home must fail explicitly')
print('PASS Java home discovery: byte selection, UTF-8/GBK, unrelated invalid bytes, missing paths')
