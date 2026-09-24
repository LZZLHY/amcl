/**
 * McErrorIpv6.test.ets — IPv6 地址族错误的分类（方案 §四·五 R3 表现层）
 *
 * ⭐ 这份测试存在的直接原因：**分类器的失效形态是静默退化，不是报错。**
 *
 * 规则匹配不上时，`classifyMcError` 会一路落到 `buildUnknownDiagnosis`，给出
 * 「游戏意外退出 / 复制日志反馈」—— 一条永远不会失败、也永远没有信息量的结论。
 * 也就是说：这条分类坏掉之后，门禁全绿、日志无告警、真机看不出差别，只有真正遇到
 * IPv6 服务器的那个用户会拿到一句废话。所以判定必须钉在离线测试里。
 *
 * 三种被识别的形态都来自真机取证（`docs/refactor/JDK-IPv6施工记录.md`）：
 *   1. NIO 路径 `UnsupportedAddressTypeException`，**message 为 null** —— MC/Netty 走这条；
 *   2. 传统 Socket 路径 `SocketException: IPv6 protocol family unavailable`；
 *   3. Minecraft `ConnectScreen` 拿形态 1 去调 `getMessage().replaceAll(...)` 的二次 NPE ——
 *      用户看到的往往只有这一条，形态 1 被 `CompletableFuture` 吞掉不进日志尾部。
 *
 * 两类判定在这里同等重要：
 *   - **正向**：三种形态都要归到 `ipv6_unsupported`，且 errorKind 按形态分开（合并成一个值
 *     会让活动记录与上传日志的 meta 丢掉子形态，到了真机就查不下去）；
 *   - **反向**：形态 3 的特征（"getMessage() 为 null"）本身很泛，别的 NPE 也长这样。
 *     所以必须叠加连接上下文才归因 —— 缺上下文时**不许**认领，否则这条规则会变成
 *     一台把无关 NPE 都吞进来的机器，比不分类更糟。
 *
 * 创建日期：2026-08-29
 */
import { describe, it, expect } from '@ohos/hypium';
import { classifyMcError, McDiagnosis, McSuggestion } from 'launch';

/** 真机里形态 1 的日志尾部（MC/Netty 的 NIO 路径，注意 message 是 null）。 */
const TAIL_NIO: string =
  '[17:39:02] [Render thread/ERROR]: Couldn\'t connect to server\n'
  + 'java.nio.channels.UnsupportedAddressTypeException: null\n'
  + '\tat java.base/sun.nio.ch.Net.checkAddress(Net.java:156)\n'
  + '\tat java.base/sun.nio.ch.SocketChannelImpl.connect(SocketChannelImpl.java:846)\n'
  + '\tat io.netty.channel.socket.nio.NioSocketChannel.doConnect(NioSocketChannel.java:337)\n';

/** 形态 2：传统 java.net.Socket 路径，message 非空且自带结论。 */
const TAIL_SOCKET: string =
  '[17:41:10] [Render thread/ERROR]: Couldn\'t connect to server\n'
  + 'java.net.SocketException: IPv6 protocol family unavailable\n'
  + '\tat java.base/sun.nio.ch.Net.connect0(Native Method)\n'
  + '\tat java.base/java.net.Socket.connect(Socket.java:751)\n';

/** 形态 3：MC ConnectScreen 的二次 NPE（形态 1 没进尾部时用户只看得到这个）。 */
const TAIL_MC_NPE: string =
  '[17:43:55] [Render thread/FATAL]: Unreported exception thrown!\n'
  + 'java.lang.NullPointerException: Cannot invoke "String.replaceAll(String, String)" '
  + 'because the return value of "java.lang.Exception.getMessage()" is null\n'
  + '\tat net.minecraft.client.gui.screens.ConnectScreen.lambda$connect$2(ConnectScreen.java:145)\n';

/** 同样的 null-message NPE，但**与连接无关** —— 这条不许被认领。 */
const TAIL_UNRELATED_NPE: string =
  '[17:44:20] [Render thread/FATAL]: Unreported exception thrown!\n'
  + 'java.lang.NullPointerException: Cannot invoke "String.replaceAll(String, String)" '
  + 'because the return value of "java.lang.Exception.getMessage()" is null\n'
  + '\tat com.example.somemod.CrashHandler.report(CrashHandler.java:22)\n';

const MC: string = '1.20.4';

/** 找出 desc 里含指定文本的建议（找不到返回 null）。 */
function findSuggestion(list: McSuggestion[], needle: string): McSuggestion | null {
  for (let i = 0; i < list.length; i++) {
    if (list[i].desc.indexOf(needle) >= 0 || list[i].title.indexOf(needle) >= 0) return list[i];
  }
  return null;
}

export default function mcErrorIpv6Test() {
  describe('McErrorIpv6', () => {

    // ---------- 正向：三种形态都要认出来 ----------

    it('形态 1：NIO 的 UnsupportedAddressTypeException（message 为 null）', 0, () => {
      let d: McDiagnosis = classifyMcError('', TAIL_NIO, MC);
      expect(d.category).assertEqual('ipv6_unsupported');
      expect(d.errorKind).assertEqual('UnsupportedAddressTypeException');
    });

    it('形态 2：SocketException: IPv6 protocol family unavailable', 0, () => {
      let d: McDiagnosis = classifyMcError('', TAIL_SOCKET, MC);
      expect(d.category).assertEqual('ipv6_unsupported');
      // errorKind 按形态分开给：合并成一个值就等于把两条不同的成因压成同一个错误码。
      expect(d.errorKind).assertEqual('SocketException');
    });

    it('形态 3：MC ConnectScreen 的二次 NPE 也要归到 IPv6，而不是"未知错误"', 0, () => {
      let d: McDiagnosis = classifyMcError('', TAIL_MC_NPE, MC);
      expect(d.category).assertEqual('ipv6_unsupported');
      expect(d.errorKind).assertEqual('NullPointerException');
      // 技术详情要写明"看到的 NPE 只是二次现象"，否则开发者会去查 MC 的 GUI 代码。
      expect(d.techDetail.indexOf('ConnectScreen') >= 0).assertTrue();
    });

    it('只有 summary 没有 logTail 时同样能归因（两个调用方传的组合不同）', 0, () => {
      let d: McDiagnosis = classifyMcError('java.net.SocketException: IPv6 protocol family unavailable', '', MC);
      expect(d.category).assertEqual('ipv6_unsupported');
    });

    // ---------- 反向：不许把无关的 NPE 吞进来 ----------

    it('同样的 null-message NPE 但没有连接上下文 ⇒ 不认领', 0, () => {
      let d: McDiagnosis = classifyMcError('', TAIL_UNRELATED_NPE, MC);
      // 归到哪儿由后续规则决定，这里只钉"不是 IPv6"——
      // 认领它等于让这条规则变成吞掉一切 NPE 的机器，比不分类更糟。
      expect(d.category === 'ipv6_unsupported').assertFalse();
    });

    it('UnsupportedClassVersionError 仍归 jdk_version，不被 IPv6 规则截胡', 0, () => {
      let tail = 'java.lang.UnsupportedClassVersionError: net/minecraft/client/main/Main has been '
        + 'compiled by a more recent version of the Java Runtime (class file version 65.0), this '
        + 'version of the Java Runtime only recognizes class file versions up to 61.0\n';
      let d: McDiagnosis = classifyMcError('', tail, MC);
      expect(d.category).assertEqual('jdk_version');
    });

    // ---------- 顺序：IPv6 不能被后段规则吞掉 ----------

    it('尾部同时有 NoSuchFileException / module not found 时，IPv6 仍然优先', 0, () => {
      // 这是本条规则真实的风险：崩溃日志的尾部什么都有，而 missing_file / launch_arg
      // 都排在 IPv6 之后。顺序错了不会报错，只会给出一条方向完全错的建议
      //（"重新下载该版本" / "复制日志给开发者"），用户照着做等于白忙。
      let tail = TAIL_NIO
        + '[17:39:03] [Worker/WARN]: java.nio.file.NoSuchFileException: '
        + '/data/.minecraft/versions/1.20.4/1.20.4.jar\n'
        + '[17:39:03] [Worker/WARN]: module not found: org.lwjgl.glfw\n';
      let d: McDiagnosis = classifyMcError('', tail, MC);
      expect(d.category).assertEqual('ipv6_unsupported');
    });

    // ---------- 文案里必须带上的两件事 ----------

    it('第一条建议是"更新 AMCL"且被标为推荐（根因已在启动器侧修掉）', 0, () => {
      let d: McDiagnosis = classifyMcError('', TAIL_NIO, MC);
      expect(d.suggestions.length >= 2).assertTrue();
      expect(d.suggestions[0].recommended).assertTrue();
      expect(d.suggestions[0].title.indexOf('更新') >= 0).assertTrue();
    });

    it('建议里必须给出 [IPv6]:port 的方括号写法（R3.2 的唯一落点）', 0, () => {
      // 方案原先写的是"在直连输入框做输入规范化"，但那个输入框是 Minecraft 自己的界面
      //（在 XComponent 里），AMCL 改不到。所以正确写法只能写进建议文字。
      let d: McDiagnosis = classifyMcError('', TAIL_NIO, MC);
      let s: McSuggestion | null = findSuggestion(d.suggestions, '[2001:db8::1]:25565');
      expect(s !== null).assertTrue();
    });

    it('没有一键修复就不假装有：primaryActionKey 为 null，兜底建议走 copy_log', 0, () => {
      let d: McDiagnosis = classifyMcError('', TAIL_SOCKET, MC);
      // Index.handleMcErrorAction_ 只路由 6 个键；编一个不存在的键会让主按钮点了没反应。
      expect(d.primaryActionKey === null).assertTrue();
      let s: McSuggestion | null = findSuggestion(d.suggestions, '已经是最新版');
      expect(s !== null).assertTrue();
      if (s !== null) {
        expect(s.actionKey).assertEqual('copy_log');
      }
    });
  });
}
