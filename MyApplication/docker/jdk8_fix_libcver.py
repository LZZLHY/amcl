#!/usr/bin/env python3
# 临时补丁脚本：把 os_linux.cpp 里 glibc 专属的 gnu_get_libc_version()/release()
# 调用用 __GLIBC__ 包起来，musl 走 "musl" 兜底字符串。幂等。
import re, sys
p = "/build/jdk8u/hotspot/src/os/linux/vm/os_linux.cpp"
s = open(p).read()
if "#ifdef __GLIBC__\n     jio_snprintf(_gnu_libc_version" in s:
    print("already patched"); sys.exit(0)
pat = re.compile(
    r'jio_snprintf\(_gnu_libc_version, sizeof\(_gnu_libc_version\),\s*'
    r'"glibc %s %s", gnu_get_libc_version\(\), gnu_get_libc_release\(\)\);',
    re.S)
repl = ('#ifdef __GLIBC__\n'
        '     jio_snprintf(_gnu_libc_version, sizeof(_gnu_libc_version), '
        '"glibc %s %s", gnu_get_libc_version(), gnu_get_libc_release());\n'
        '#else\n'
        '     jio_snprintf(_gnu_libc_version, sizeof(_gnu_libc_version), "musl");\n'
        '#endif')
s2, n = pat.subn(repl, s)
if n != 1:
    print("ERROR: expected 1 match, got", n); sys.exit(1)
open(p, "w").write(s2)
print("patched os_linux.cpp glibc version block")
