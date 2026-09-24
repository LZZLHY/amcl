package com.amcl.launcher;

import java.net.Inet4Address;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.Socket;
import java.net.SocketAddress;
import java.nio.channels.SocketChannel;
import java.util.Enumeration;

/**
 * Ipv6Diagnostics — Java 侧 IPv6 能力诊断（Phase 0 的 P0-b / Q5）
 *
 * 方案：docs/adaptation/JDK_IPV6_ADAPTATION_PLAN.md §3 P0-b
 * 施工记录：docs/refactor/JDK-IPv6施工记录.md
 *
 * ============================================================
 * 它回答什么
 * ============================================================
 * native 侧探针（tests/ipv6_probe_test.cpp）已经逐条复现了 libnet 的
 * IPv6_supported() 四条判据，真机结论是「只有 C3（读 /proc/net/if_inet6）失败」。
 * 但「native 函数返回 false」与「Java 层观测到 false」是两个事实 —— 中间还有
 * preferIPv4Stack 与 JNI_OnLoad 的缓存时序。本类补的就是 Java 这一侧：
 *
 *   Q2  SocketChannel 的实际地址族（= Net.isIPv6Available() 的可观测投影）
 *   Q4  NetworkInterface 枚举到的 IPv6 地址条数（这是**第二个**消费者的基线）
 *   Q5  连一个 IPv6 字面量时抛出的**第一条**异常的类名与 message
 *
 * ============================================================
 * 为什么不需要 IPv6 服务器
 * ============================================================
 * UnsupportedAddressTypeException 由 sun.nio.ch.Net.checkAddress 在**任何网络
 * I/O 之前**抛出 —— 它只比较地址族，不发包。所以拿一个永不可路由的地址就能测：
 * 默认用 2001:db8::1（RFC 3849 文档保留前缀，保证不会真碰到任何主机）。
 *
 * 修复前后的判据也因此是**行为差异**而不是"能不能连上"：
 *   修复前：connect 立刻抛 UnsupportedAddressTypeException（message 为 null）
 *   修复后：connect 不抛，非阻塞下返回 false（pending），随后超时
 *
 * ============================================================
 * 约束
 * ============================================================
 * ⚠️ amcl-launcher.jar 由 scripts/build-amcl-launcher.mjs 以 `--release 8` 编译
 *    （它要能被 JDK 8 加载，见该脚本注释）。所以本类**只能用 Java 8 API**。
 *    这就是这里不用 SocketChannel.open(ProtocolFamily)（Java 15+）而是改用
 *    「bind 到通配地址再读 getLocalAddress()」来判定地址族的原因 ——
 *    后者是 Java 7 API，且完全不碰 sun.nio.ch 内部类，不需要 --add-exports。
 *
 * ⚠️ 只观测，不修改任何状态。全部输出走 stdout，由 forkRunJavaCwd 重定向到日志文件。
 */
public final class Ipv6Diagnostics {

    private static final String DEFAULT_ADDR = "2001:db8::1";
    private static final int DEFAULT_PORT = 25565;

    private Ipv6Diagnostics() {
    }

    /** 把异常渲染成一行。**显式打印 message 是否为 null** —— Q5 的要点就在这里。 */
    private static String describe(Throwable t) {
        if (t == null) {
            return "(no exception)";
        }
        String msg = t.getMessage();
        return t.getClass().getName() + " | message=" + (msg == null ? "<null>" : "\"" + msg + "\"");
    }

    private static void frames(Throwable t, int n) {
        if (t == null) {
            return;
        }
        StackTraceElement[] st = t.getStackTrace();
        for (int i = 0; i < st.length && i < n; i++) {
            System.out.println("        at " + st[i]);
        }
    }

    public static void main(String[] args) {
        String addrText = (args != null && args.length > 0 && args[0].length() > 0)
                ? args[0] : DEFAULT_ADDR;
        int port = DEFAULT_PORT;
        if (args != null && args.length > 1) {
            try {
                port = Integer.parseInt(args[1]);
            } catch (RuntimeException ignored) {
                // 保持默认端口
            }
        }

        System.out.println("========================================");
        System.out.println("AMCL Java 侧 IPv6 诊断 (Phase 0 · P0-b / Q5)");
        System.out.println("只观测，不修改任何状态");
        System.out.println("========================================");
        System.out.println("java.version   = " + System.getProperty("java.version"));
        System.out.println("java.home      = " + System.getProperty("java.home"));
        System.out.println("os.name/arch   = " + System.getProperty("os.name")
                + " / " + System.getProperty("os.arch"));
        System.out.println("测试地址       = [" + addrText + "]:" + port
                + "   （RFC 3849 文档前缀，永不可路由，不会真碰到主机）");
        System.out.println();

        // ---- 相关系统属性 ----
        // preferIPv4Stack=true 会把 IPv6 直接关死；preferIPv6Addresses 决定主机名解析后的排序。
        // 后者在 native 判 false 时**什么也不做**，能力修好之后才开始生效 —— 这正是
        // 方案 §4 路线 B 第 3 条「偏好护栏」要管的东西。
        System.out.println("A) 相关系统属性");
        System.out.println("    java.net.preferIPv4Stack    = "
                + System.getProperty("java.net.preferIPv4Stack"));
        System.out.println("    java.net.preferIPv6Addresses = "
                + System.getProperty("java.net.preferIPv6Addresses"));
        System.out.println();

        // ---- 地址解析本身是否正常（把"地址解析"与"通道地址族"分开）----
        System.out.println("B) 字面量解析（证明失败不是解析造成的）");
        InetAddress v6 = null;
        try {
            v6 = InetAddress.getByName(addrText);
            System.out.println("    InetAddress.getByName -> " + v6
                    + "   class=" + v6.getClass().getName());
        } catch (Throwable t) {
            System.out.println("    ❌ 解析失败：" + describe(t));
        }
        System.out.println();

        // ---- ⭐ Q2：通道的实际地址族 ----
        // SocketChannel.open() 的地址族由 Net.isIPv6Available() 决定：
        //   可用   -> AF_INET6（双栈），bind 通配后本地地址是 ::
        //   不可用 -> AF_INET，  bind 通配后本地地址是 0.0.0.0
        // ⇒ 读 getLocalAddress() 就等于读到了那个 boolean，且全是 Java 7 公开 API。
        System.out.println("C) ⭐ SocketChannel 的实际地址族 = Net.isIPv6Available() 的可观测投影");
        String familyVerdict = "UNKNOWN";
        SocketChannel probe = null;
        try {
            probe = SocketChannel.open();
            probe.bind(new InetSocketAddress(0));
            SocketAddress la = probe.getLocalAddress();
            InetAddress local = (la instanceof InetSocketAddress)
                    ? ((InetSocketAddress) la).getAddress() : null;
            System.out.println("    bind(0) 后 localAddress = " + la);
            if (local instanceof Inet6Address) {
                familyVerdict = "INET6";
                System.out.println("    ⇒ 通道是 AF_INET6（双栈）⇒ Net.isIPv6Available() == true ✅");
            } else if (local instanceof Inet4Address) {
                familyVerdict = "INET";
                System.out.println("    ⇒ 通道是 AF_INET（IPv4-only）⇒ Net.isIPv6Available() == false ❌");
            } else {
                System.out.println("    ⇒ 无法判定（localAddress 形态异常）");
            }
        } catch (Throwable t) {
            System.out.println("    探测失败：" + describe(t));
        } finally {
            close(probe);
        }
        System.out.println();

        // ---- ⭐ Q5：连 IPv6 字面量时的第一条异常 ----
        System.out.println("D) ⭐ NIO 连 IPv6 字面量 —— 抓第一条异常（非阻塞，毫秒级）");
        String nioOutcome = "UNKNOWN";
        if (v6 == null) {
            System.out.println("    跳过（地址没解析出来）");
        } else {
            SocketChannel ch = null;
            try {
                ch = SocketChannel.open();
                ch.configureBlocking(false);
                boolean done = ch.connect(new InetSocketAddress(v6, port));
                nioOutcome = done ? "CONNECTED" : "PENDING";
                System.out.println("    ✅ 未抛异常，connect 返回 " + done
                        + "（" + (done ? "已连上" : "pending，地址族被接受") + "）");
                System.out.println("    ⇒ 地址族这一关过了；连不上只会表现为随后的超时/不可达");
            } catch (Throwable t) {
                nioOutcome = t.getClass().getSimpleName();
                System.out.println("    ❌ 第一条异常：" + describe(t));
                frames(t, 4);
                if (t instanceof java.nio.channels.UnsupportedAddressTypeException) {
                    System.out.println("    ⇒ 与静态审查的预测一致：通道地址族是 INET，装不下 Inet6Address。");
                    System.out.println("       注意 message 为 <null> —— Minecraft ConnectScreen 对它调");
                    System.out.println("       exception.getMessage().replaceAll(...) 就会二次抛 NPE，");
                    System.out.println("       那正是用户看到「像崩溃」的直接原因。");
                }
            } finally {
                close(ch);
            }
        }
        System.out.println();

        // ---- 同一件事在传统 Socket API 上的表现（证明不是 NIO 独有）----
        System.out.println("E) 传统 java.net.Socket 连同一地址（证明不是 NIO 独有）");
        String plainOutcome = "UNKNOWN";
        if (v6 == null) {
            System.out.println("    跳过（地址没解析出来）");
        } else {
            Socket s = null;
            try {
                s = new Socket();
                s.connect(new InetSocketAddress(v6, port), 400);
                plainOutcome = "CONNECTED";
                System.out.println("    未抛异常（居然连上了）");
            } catch (Throwable t) {
                plainOutcome = t.getClass().getSimpleName();
                System.out.println("    第一条异常：" + describe(t));
                frames(t, 3);
            } finally {
                close(s);
            }
        }
        System.out.println();

        // ---- 阳性对照：IPv4 回环必须是"正常的连接失败" ----
        // 若这一条也抛地址族异常，说明整个探针的判读方式有问题，而不是 IPv6 有问题。
        System.out.println("F) 阳性对照：连 127.0.0.1:1（关闭端口）应当是普通的连接被拒");
        try {
            Socket s = new Socket();
            try {
                s.connect(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 1), 400);
                System.out.println("    未抛异常（意外）");
            } finally {
                close(s);
            }
        } catch (Throwable t) {
            System.out.println("    " + describe(t) + "   ⇒ 对照正常（IPv4 通路本身没问题）");
        }
        System.out.println();

        // ---- Q4：NetworkInterface 的 IPv6 枚举（第二个消费者的基线）----
        // 这一条与 Net.isIPv6Available() 是**两个独立**的消费者，都读同一个
        // /proc/net/if_inet6。只改 IPv6_supported()（路线 A）修不到这里。
        System.out.println("G) NetworkInterface 枚举（第二个消费者的基线）");
        int nifCount = 0;
        int v4Count = 0;
        int v6Count = 0;
        try {
            Enumeration<NetworkInterface> nis = NetworkInterface.getNetworkInterfaces();
            if (nis == null) {
                System.out.println("    getNetworkInterfaces() 返回 null（异常状态）");
            } else {
                while (nis.hasMoreElements()) {
                    NetworkInterface ni = nis.nextElement();
                    nifCount++;
                    Enumeration<InetAddress> addrs = ni.getInetAddresses();
                    while (addrs.hasMoreElements()) {
                        InetAddress a = addrs.nextElement();
                        if (a instanceof Inet6Address) {
                            v6Count++;
                            System.out.println("      IPv6: " + ni.getName() + "  " + a);
                        } else {
                            v4Count++;
                        }
                    }
                }
                System.out.println("    接口 " + nifCount + " 个，IPv4 地址 " + v4Count
                        + " 条，IPv6 地址 " + v6Count + " 条");
                if (v6Count == 0) {
                    System.out.println("    ⇒ 0 条。native 侧 getifaddrs 明确看到 5 条（含 2 个 global），");
                    System.out.println("       差异来源：enumIPv6Interfaces() 读 /proc/net/if_inet6 被拒后**静默**返回。");
                }
            }
        } catch (Throwable t) {
            System.out.println("    ❌ 枚举抛异常：" + describe(t));
        }
        System.out.println();

        // ---- 汇总 ----
        System.out.println("========================================");
        System.out.println("汇总: channelFamily=" + familyVerdict
                + "  nio=" + nioOutcome
                + "  plainSocket=" + plainOutcome
                + "  nifIPv6=" + v6Count);
        if ("INET".equals(familyVerdict)) {
            System.out.println("结论: Java 侧确认 Net.isIPv6Available() == false ⇒ 与 native 判据一致。");
        } else if ("INET6".equals(familyVerdict)) {
            System.out.println("结论: Java 侧 IPv6 可用。若这是修复后的复跑，D 段应当不再抛地址族异常。");
        } else {
            System.out.println("结论: 地址族未判定，上面 C 段有原因。");
        }
        System.out.println("Java 侧 IPv6 诊断完成");
        System.out.println("========================================");
        System.out.flush();
    }

    private static void close(java.io.Closeable c) {
        if (c == null) {
            return;
        }
        try {
            c.close();
        } catch (Throwable ignored) {
            // 诊断路径，关不掉也不影响结论
        }
    }
}
