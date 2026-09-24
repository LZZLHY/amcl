/**
 * Ipv6PreferenceGuard.test.ets — IPv6 偏好护栏（方案 §四·五 R2）
 *
 * ⭐ 这份测试存在的直接原因：这条护栏的失效形态**既不抛异常也不打告警**。
 *
 * 能力层（elf_loader 的 /proc/net/if_inet6 垫片）一落地，Mojang version manifest 自带的
 * `-Djava.net.preferIPv6Addresses=system` 就**开始生效**（在那之前 native 判 IPv6 不可用，
 * 这条参数什么也不做）。而本仓已有真机记录：本平台存在「有 IPv6 路由但该主机 IPv6 不通」
 * （CHANGELOG 1000467，下载器为此专门加了每主机地址族选择），MC / Netty **没有**这种回退。
 * ⇒ 护栏没了的后果是：为修好少数人的 IPv6 直连，让**多数人**的主机名连接变慢或偶发失败。
 * 那个后果不会出现在任何异常里，只会变成"最近连服务器有点慢"这类无法归因的反馈。
 *
 * 真机那一侧（R5.3）要启动一次游戏才能看到最终参数；这里的判定每次 `hvigorw test` 都跑。
 *
 * 创建日期：2026-08-29
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  applyIpv6PreferenceGuard, IPV6_PREFER_ADDRESSES_KEY, Ipv6PreferenceGuardResult,
} from 'launch';

export default function ipv6PreferenceGuardTest() {
  describe('Ipv6PreferenceGuard', () => {
    const GUARD: string = IPV6_PREFER_ADDRESSES_KEY + 'false';

    it('键前缀带等号（防止误伤同前缀的其它参数）', 0, () => {
      expect(IPV6_PREFER_ADDRESSES_KEY).assertEqual('-Djava.net.preferIPv6Addresses=');
    });

    it('manifest 的 =system 被剔除，最终只剩一条 =false', 0, () => {
      // 这是真实形态：1.20.4 的官方 version manifest 里就有这一条。
      let args: string[] = [
        '-Xmx4096m',
        '-Djava.net.preferIPv6Addresses=system',
        '-Dminecraft.launcher.brand=amcl',
      ];
      let r: Ipv6PreferenceGuardResult = applyIpv6PreferenceGuard(args);

      expect(r.replaced.length).assertEqual(1);
      expect(r.replaced[0]).assertEqual('-Djava.net.preferIPv6Addresses=system');

      let hits: number = 0;
      for (let a of r.args) {
        if (a.indexOf(IPV6_PREFER_ADDRESSES_KEY) === 0) hits++;
      }
      // 只剩一条 —— R5.3 的验收要"从启动日志肉眼读出最终值"，留两条就得靠推理谁在后面
      expect(hits).assertEqual(1);
      expect(r.args[r.args.length - 1]).assertEqual(GUARD);
    });

    it('多条同键项全部被剔除（=true / =system 混在一起也一样）', 0, () => {
      let args: string[] = [
        '-Djava.net.preferIPv6Addresses=true',
        '-Xmx2048m',
        '-Djava.net.preferIPv6Addresses=system',
      ];
      let r: Ipv6PreferenceGuardResult = applyIpv6PreferenceGuard(args);
      expect(r.replaced.length).assertEqual(2);
      expect(r.replaced[0]).assertEqual('-Djava.net.preferIPv6Addresses=true');
      expect(r.replaced[1]).assertEqual('-Djava.net.preferIPv6Addresses=system');
      expect(r.args.length).assertEqual(2);
      expect(r.args[0]).assertEqual('-Xmx2048m');
      expect(r.args[1]).assertEqual(GUARD);
    });

    it('manifest 没有这一条时也要钉上（不是"只在有的时候才管"）', 0, () => {
      // 不同 MC 版本的 manifest 不一定都带那条参数。护栏必须无条件成立，
      // 否则"能不能生效"会随版本漂移，而漂移的方向恰好是难以察觉的那一侧。
      let args: string[] = ['-Xmx1024m'];
      let r: Ipv6PreferenceGuardResult = applyIpv6PreferenceGuard(args);
      expect(r.replaced.length).assertEqual(0);
      expect(r.args.length).assertEqual(2);
      expect(r.args[1]).assertEqual(GUARD);
    });

    it('空参数列表：只产出护栏项', 0, () => {
      let r: Ipv6PreferenceGuardResult = applyIpv6PreferenceGuard([]);
      expect(r.replaced.length).assertEqual(0);
      expect(r.args.length).assertEqual(1);
      expect(r.args[0]).assertEqual(GUARD);
    });

    it('其它参数原样保留且**顺序不变**', 0, () => {
      // 这条不是形式主义：jvmArgs 里有带顺序依赖的参数（--add-opens / -javaagent /
      // GC 选择器），护栏顺手重排它们会造成与 IPv6 完全无关的故障。
      let args: string[] = [
        '-Xmx4096m',
        '--add-opens=java.base/java.lang=ALL-UNNAMED',
        '-Djava.net.preferIPv6Addresses=system',
        '-javaagent:/data/x/authlib.jar=https://example.invalid',
        '-XX:+UseG1GC',
      ];
      let r: Ipv6PreferenceGuardResult = applyIpv6PreferenceGuard(args);
      expect(r.args.length).assertEqual(5);
      expect(r.args[0]).assertEqual('-Xmx4096m');
      expect(r.args[1]).assertEqual('--add-opens=java.base/java.lang=ALL-UNNAMED');
      expect(r.args[2]).assertEqual('-javaagent:/data/x/authlib.jar=https://example.invalid');
      expect(r.args[3]).assertEqual('-XX:+UseG1GC');
      expect(r.args[4]).assertEqual(GUARD);
    });

    it('同前缀但不同键的参数不被误伤', 0, () => {
      // -Djava.net.preferIPv4Stack 与 -Djava.net.preferIPv6Addresses 是两个键；
      // 前者若被顺手剔掉，等于悄悄改变了另一个与本方向相反的开关。
      let args: string[] = [
        '-Djava.net.preferIPv4Stack=false',
        '-Djava.net.preferIPv6AddressesFoo=1',
      ];
      let r: Ipv6PreferenceGuardResult = applyIpv6PreferenceGuard(args);
      expect(r.replaced.length).assertEqual(0);
      expect(r.args.length).assertEqual(3);
      expect(r.args[0]).assertEqual('-Djava.net.preferIPv4Stack=false');
      expect(r.args[1]).assertEqual('-Djava.net.preferIPv6AddressesFoo=1');
      expect(r.args[2]).assertEqual(GUARD);
    });

    it('裸写（无等号）的同名属性刻意不剔除，但护栏仍排在它之后', 0, () => {
      // `-Djava.net.preferIPv6Addresses`（无等号）JVM 视为空值。它与带等号的那条不同键面，
      // 我们不动它；而护栏项排在末尾，JVM 取最后一个 ⇒ 最终仍是 false。
      // 把这个边界写成断言，是为了让它是**决定**而不是巧合。
      let args: string[] = ['-Djava.net.preferIPv6Addresses'];
      let r: Ipv6PreferenceGuardResult = applyIpv6PreferenceGuard(args);
      expect(r.replaced.length).assertEqual(0);
      expect(r.args.length).assertEqual(2);
      expect(r.args[0]).assertEqual('-Djava.net.preferIPv6Addresses');
      expect(r.args[1]).assertEqual(GUARD);
    });

    it('幂等：连跑两次不会堆出两条护栏项', 0, () => {
      // 调用点只在 build() 里一处，但"再调一次会怎样"必须是确定的 ——
      // 否则将来有人在另一条路径上补一次调用，命令行会静默多出一条。
      let once: Ipv6PreferenceGuardResult = applyIpv6PreferenceGuard(['-Xmx1g']);
      let twice: Ipv6PreferenceGuardResult = applyIpv6PreferenceGuard(once.args);
      expect(twice.replaced.length).assertEqual(1);
      expect(twice.args.length).assertEqual(2);
      expect(twice.args[0]).assertEqual('-Xmx1g');
      expect(twice.args[1]).assertEqual(GUARD);
    });
  });
}
