"""将已按 Java 8 编译并验明 class 头的诊断字节写为固定 C++ 数组；输出路径由调用者提供。"""
import hashlib
from pathlib import Path
import sys

source, compiled, output = map(Path, sys.argv[1:])
data = compiled.read_bytes()
if data[:8] != bytes.fromhex('cafebabe00000034'):
    raise SystemExit('Expected non-preview Java 8 class file')
lines = [
    '/** 由 docker/tests/HelloWorld.java 以 Java 8 字节码生成；保留四代诊断能力。',
    ' * 生成器：tests/runtime-jni/emit-header.py；编译入口：tests/runtime-jni/run-host.sh。',
    f' * Java 源（统一 LF）SHA-256：{hashlib.sha256(source.read_bytes().replace(bytes([13, 10]), bytes([10]))).hexdigest()}',
    f' * class SHA-256：{hashlib.sha256(data).hexdigest()}。不要手工修改数组。 */',
    'static const unsigned char kHelloWorldClass[] = {',
]
lines += ['    ' + ','.join(f'0x{byte:02x}' for byte in data[index:index + 20]) + ',' for index in range(0, len(data), 20)]
lines += ['};', f'static const int kHelloWorldClassLen = {len(data)};', '']
output.write_text('\n'.join(lines), encoding='utf-8')
