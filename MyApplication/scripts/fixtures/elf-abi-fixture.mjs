/** 仅用于元数据门禁的微型 ELF，不包含可执行测试代码，不授予运行资格。 */
export const providerFixtureSymbols = ['__cxa_guard_acquire', '__cxa_throw', '__gxx_personality_v0',
  '_Unwind_RaiseException', '_Unwind_Resume', 'amcl_unwind_register_image', 'amcl_unwind_unregister_image'];

/** 动态表在 LOAD 内，私有 symtab 在 LOAD 外，便于复现剥离后隐藏第二份 unwinder 的反例。 */
export function elfAbiFixture(definitions = [], privateDefinitions = []) {
  const data = Buffer.alloc(4096);
  Buffer.from([0x7f, 0x45, 0x4c, 0x46, 2, 1, 1]).copy(data);
  data.writeUInt16LE(3, 16); data.writeUInt16LE(183, 18); data.writeUInt32LE(1, 20);
  data.writeBigUInt64LE(64n, 32); data.writeBigUInt64LE(2048n, 40);
  data.writeUInt16LE(64, 52); data.writeUInt16LE(56, 54); data.writeUInt16LE(1, 56);
  data.writeUInt16LE(64, 58); data.writeUInt16LE(privateDefinitions.length ? 5 : 3, 60);
  data.writeUInt32LE(1, 64); data.writeUInt32LE(5, 68);
  data.writeBigUInt64LE(1024n, 96); data.writeBigUInt64LE(1024n, 104); data.writeBigUInt64LE(4096n, 112);
  const table = (names, index, kind, offset, stringOffset, local = false) => {
    const strings = Buffer.from('\0' + names.join('\0') + (names.length ? '\0' : ''));
    strings.copy(data, stringOffset);
    const header = 2048 + index * 64;
    data.writeUInt32LE(kind, header + 4); data.writeBigUInt64LE(BigInt(offset), header + 24);
    data.writeBigUInt64LE(BigInt((names.length + 1) * 24), header + 32);
    data.writeUInt32LE(index + 1, header + 40); data.writeBigUInt64LE(24n, header + 56);
    const stringHeader = header + 64;
    data.writeUInt32LE(3, stringHeader + 4); data.writeBigUInt64LE(BigInt(stringOffset), stringHeader + 24);
    data.writeBigUInt64LE(BigInt(strings.length), stringHeader + 32);
    let nameAt = 1;
    names.forEach((name, item) => {
      const symbol = offset + (item + 1) * 24;
      data.writeUInt32LE(nameAt, symbol); data[symbol + 4] = local ? 2 : 0x12;
      data.writeUInt16LE(1, symbol + 6); data.writeBigUInt64LE(200n, symbol + 8);
      nameAt += Buffer.byteLength(name) + 1;
    });
  };
  table(definitions, 1, 11, 256, 576);
  if (privateDefinitions.length) table(privateDefinitions, 3, 2, 1280, 1536, true);
  return data;
}

/** libentry元数据正例显式承载产品的原生TLS合同；普通provider样本仍不自动获得此槽。
 * 私有符号表位于LOAD外，PT_TLS和对应.tbss节表示24字节POD，不能视为可执行生命周期测试。
 */
export function entryAbiFixture(definitions = [], privateDefinitions = []) {
  const slot = '_ZN4amcl10tlsstorage6detail4slotE';
  const data = elfAbiFixture(definitions, [...privateDefinitions, slot]);
  data.writeUInt16LE(2, 56); data.writeUInt16LE(6, 60);
  const tls = 64 + 56;
  data.writeUInt32LE(7, tls); data.writeUInt32LE(4, tls + 4);
  data.writeBigUInt64LE(768n, tls + 8); data.writeBigUInt64LE(768n, tls + 16);
  data.writeBigUInt64LE(24n, tls + 40); data.writeBigUInt64LE(8n, tls + 48);
  const section = 2048 + 5 * 64;
  data.writeUInt32LE(8, section + 4); data.writeBigUInt64LE(0x403n, section + 8);
  data.writeBigUInt64LE(768n, section + 16); data.writeBigUInt64LE(768n, section + 24);
  data.writeBigUInt64LE(24n, section + 32); data.writeBigUInt64LE(8n, section + 48);
  const symbol = 1280 + (privateDefinitions.length + 1) * 24;
  data[symbol + 4] = 6; data.writeUInt16LE(5, symbol + 6);
  data.writeBigUInt64LE(0n, symbol + 8); data.writeBigUInt64LE(24n, symbol + 16);
  return data;
}
