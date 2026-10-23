/**
 * CurseForge 指纹的纯增量 MurmurHash2 状态。
 * 初始化需要剔除空白后的总字节数，跨块保留不足四字节的尾部，不逐块独立哈希。
 * 无文件、网络与框架依赖，供工作线程和已知样本回归共同调用。
 */
export class CurseForgeMurmur2 {
  private hash_: number;
  private word_: number = 0;
  private tailBytes_: number = 0;
  private consumed_: number = 0;
  private expected_: number;

  /** totalBytes 是实际参与算法的长度；CF 文件指纹的 seed 固定为 1。 */
  constructor(totalBytes: number, seed: number = 1) {
    this.expected_ = totalBytes;
    this.hash_ = (seed ^ totalBytes) >>> 0;
  }

  /** 输入一个参与哈希的字节；调用方负责跳过 CF 规定的四种空白字节。 */
  append(byte: number): void {
    this.word_ = (this.word_ | ((byte & 255) << (8 * this.tailBytes_))) >>> 0;
    this.tailBytes_++;
    this.consumed_++;
    if (this.tailBytes_ === 4) {
      let word = Math.imul(this.word_, 0x5bd1e995) >>> 0;
      word = (word ^ (word >>> 24)) >>> 0;
      word = Math.imul(word, 0x5bd1e995) >>> 0;
      this.hash_ = (Math.imul(this.hash_, 0x5bd1e995) ^ word) >>> 0;
      this.word_ = 0;
      this.tailBytes_ = 0;
    }
  }

  /** 结束时核对两遍读取长度；不一致表明文件变化，不能发布一个错误指纹。 */
  finish(): number {
    if (this.consumed_ !== this.expected_) throw new Error('Fingerprint input changed');
    let hash = this.hash_;
    if (this.tailBytes_ > 0) hash = Math.imul((hash ^ this.word_) >>> 0, 0x5bd1e995) >>> 0;
    hash = (hash ^ (hash >>> 13)) >>> 0;
    hash = Math.imul(hash, 0x5bd1e995) >>> 0;
    return (hash ^ (hash >>> 15)) >>> 0;
  }
}

/** 保留已有公开纯函数的任意 seed 语义；这里不做空白过滤。 */
export function murmur2(data: Uint8Array, seed: number): number {
  const state = new CurseForgeMurmur2(data.length, seed);
  for (let i = 0; i < data.length; i++) state.append(data[i]);
  return state.finish();
}
