"""执行候选包中实际 AArch64 Platform 叶函数，不执行 JVM/OHOS 系统调用。

依赖 unicorn 与 pyelftools（调用者环境提供）。仅模拟 JNI NewStringUTF 出口以读取
真实只读段字符串，不替换被审查函数逻辑；结果不能宣称等同于设备启动或物理播放。
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import struct
from zipfile import ZipFile
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn import arm64_const as reg
from elftools.elf.elffile import ELFFile


def main():
    """使用显式 archive/out 路径；任何目标函数、字符串或掩码不符均非零失败。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    with ZipFile(args.archive) as archive:
        data = archive.read('jre/lib/aarch64/libjsound.so')
    elf = ELFFile(io.BytesIO(data))
    assert elf['e_machine'] == 'EM_AARCH64'
    symbols = {s.name:int(s['st_value']) for s in elf.get_section_by_name('.dynsym').iter_symbols()}
    engine = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    engine.mem_map(0,0x100000)
    for segment in elf.iter_segments():
        if segment['p_type'] == 'PT_LOAD': engine.mem_write(int(segment['p_vaddr']),segment.data())
    engine.mem_map(0x200000,0x10000)
    engine.reg_write(reg.UC_ARM64_REG_SP,0x20f000)
    end = 0x80000
    def call(name, value=0):
        """最多执行 100 条指令，并要求确实返回到 LR，防止把预算用尽误判为返回成功。"""
        engine.reg_write(reg.UC_ARM64_REG_X2,value)
        engine.reg_write(reg.UC_ARM64_REG_X30,end)
        engine.emu_start(symbols['Java_com_sun_media_sound_Platform_'+name],end,count=100)
        assert engine.reg_read(reg.UC_ARM64_REG_PC) == end, 'leaf did not return'
        return engine.reg_read(reg.UC_ARM64_REG_W0)
    masks = [call('nGetLibraryForFeature',feature) for feature in (0,1,2,3,4)]
    assert masks == [0,0,0,0,0], masks
    assert call('nIsBigEndian') == 0
    assert call('nIsSigned8') == 0
    env, table, callback = 0x200100,0x201000,0x81000
    engine.mem_write(env,struct.pack('<Q',table))
    engine.mem_write(table+167*8,struct.pack('<Q',callback))
    engine.mem_write(callback,struct.pack('<I',0xd65f03c0))
    strings = []
    def hook(uc,address,size,user):
        """记录 NewStringUTF 参数；模拟返回不改变实际 Platform 分支。"""
        if address == callback:
            pointer = uc.reg_read(reg.UC_ARM64_REG_X1)
            strings.append(bytes(uc.mem_read(pointer,128)).split(b'\0',1)[0].decode())
            uc.reg_write(reg.UC_ARM64_REG_X0,0x200500)
    engine.hook_add(UC_HOOK_CODE,hook)
    engine.reg_write(reg.UC_ARM64_REG_X0,env)
    call('nGetExtraLibraries')
    assert strings == [''], strings
    result = {'result':'PASS','scope':'actual AArch64 Platform leaf functions, not OHOS JVM/device',
              'archiveSha256':hashlib.sha256(args.archive.read_bytes()).hexdigest(),
              'jsoundSha256':hashlib.sha256(data).hexdigest(),'features':masks,'extraLibraries':strings}
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result,indent=2))


if __name__ == '__main__': main()
