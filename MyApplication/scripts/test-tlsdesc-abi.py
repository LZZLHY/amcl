"""执行实际 ELF 的 AArch64 TLSDESC 跳板，替身 C helper 按常规 ABI 破坏调用者寄存器。"""
from pathlib import Path
import argparse,sys,json,struct
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description='对真实 AArch64 ELF 的 TLSDESC 跳板执行寄存器保存回归')
parser.add_argument('--elf',type=Path,default=root/'entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libentry.so')
parser.add_argument('--tools-dir',type=Path,help='可选：本地安装 unicorn==2.1.4 的目录；脚本不自动安装依赖')
parser.add_argument('--expect-broken',action='store_true',help='仅用于旧产物负对照，要求实际观察到寄存器损坏')
args=parser.parse_args()
if args.tools_dir:sys.path.insert(0,str(args.tools_dir.resolve()))
try:
    from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
    from unicorn import arm64_const as reg
    from elftools.elf.elffile import ELFFile
except ImportError as error:
    raise SystemExit('需要 unicorn==2.1.4 和 pyelftools；可用 --tools-dir 指向独立的测试依赖目录：'+str(error))

with args.elf.open('rb') as file:
    elf=ELFFile(file)
    symbols=elf.get_section_by_name('.dynsym')
    symbol=next(s for s in symbols.iter_symbols() if s.name=='_Z20tlsdesc_resolver_asmv')
    start,size=int(symbol['st_value']),int(symbol['st_size'])
    section=elf.get_section(symbol['st_shndx'])
    code=section.data()[start-section['sh_addr']:start-section['sh_addr']+size]
calls=[]
for offset in range(0,len(code),4):
    word=struct.unpack_from('<I',code,offset)[0]
    if word & 0xfc000000 == 0x94000000:
        immediate=word & 0x3ffffff
        if immediate & (1<<25):immediate-=1<<26
        calls.append(start+offset+immediate*4)
assert len(calls)==1,calls
helper=calls[0]
engine=Uc(UC_ARCH_ARM64,UC_MODE_ARM)
engine.mem_map(0,0x800000)
engine.mem_write(start,code)
engine.mem_write(helper,struct.pack('<I',0xd65f03c0))  # 正常 C helper 的返回指令。
engine.mem_map(0x2000000,0x10000)
engine.mem_map(0x3000000,0x10000)
descriptor=0x2001000
engine.mem_write(descriptor,struct.pack('<QQ',start,0x2002000))
initial={}
for i in range(1,31):
    name=getattr(reg,'UC_ARM64_REG_X'+str(i))
    initial[name]=0x10000000+i
    engine.reg_write(name,initial[name])
initial[reg.UC_ARM64_REG_X30]=0x1000
initial[reg.UC_ARM64_REG_SP]=0x300f000
initial[reg.UC_ARM64_REG_NZCV]=0xa0000000
for key,value in initial.items():engine.reg_write(key,value)
vectors={getattr(reg,'UC_ARM64_REG_Q'+str(i)):(0x1122334455667788+i)<<64|0x8899aabbccddeeff for i in range(32)}
for key,value in vectors.items():engine.reg_write(key,value)
engine.reg_write(reg.UC_ARM64_REG_CPACR_EL1,3<<20)
engine.reg_write(reg.UC_ARM64_REG_X0,descriptor)
helper_calls=0
def on_instruction(uc,address,size,_):
    global helper_calls
    if address!=helper:return
    helper_calls+=1
    assert uc.reg_read(reg.UC_ARM64_REG_X0)==0x2002000,'descriptor argument was corrupted'
    for i in range(1,19):uc.reg_write(getattr(reg,'UC_ARM64_REG_X'+str(i)),0xdead0000+i)
    for i in range(32):
        key=getattr(reg,'UC_ARM64_REG_Q'+str(i))
        # AAPCS64 只要求普通 C 调用保留 v8..v15 的低 64 位；TLSDESC 必须保留完整向量。
        low=uc.reg_read(key)&((1<<64)-1) if 8<=i<=15 else 0xcafe0000+i
        uc.reg_write(key,(0xdead0000+i)<<64|low)
    uc.reg_write(reg.UC_ARM64_REG_NZCV,0)
    uc.reg_write(reg.UC_ARM64_REG_X0,0x1234)
engine.hook_add(UC_HOOK_CODE,on_instruction)
engine.emu_start(start,0x1000,count=10000)
assert helper_calls==1 and engine.reg_read(reg.UC_ARM64_REG_X0)==0x1234
changed=[]
for i in range(1,31):
    key=getattr(reg,'UC_ARM64_REG_X'+str(i))
    if engine.reg_read(key)!=initial[key]:changed.append('x'+str(i))
for i in range(32):
    key=getattr(reg,'UC_ARM64_REG_Q'+str(i))
    if engine.reg_read(key)!=vectors[key]:changed.append('q'+str(i))
for name,key in [('sp',reg.UC_ARM64_REG_SP),('nzcv',reg.UC_ARM64_REG_NZCV)]:
    if engine.reg_read(key)!=initial[key]:changed.append(name)
print(json.dumps({'elf':str(args.elf),'resolver':hex(start),'helperCalls':helper_calls,'clobbered':changed},indent=2))
assert bool(changed)==args.expect_broken,'TLSDESC preservation did not match expected control'
