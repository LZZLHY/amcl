/*
 * log_coalesce_test.cpp — 连续重复行合并的纯策略用例（日志系统重构 · P2）
 *
 * ⭐ 这份测试最承重的不是「重复行被合并了」，而是**无损性**：
 *   任何两条不逐字相同的日志，都不许被合并掉。
 *   合并的失效形态是**静默吞行** —— 日志少了几行不会报错、不会告警，
 *   只有当事人在排障时发现「明明打了却没有」。这与本仓多次付过学费的形状相同。
 *
 * 背景：真机实测一句逐字相同的 INFO 心跳占 amcl_launcher.log 的 72.9% 字节，
 * 把 12 MiB 预算的有效保留时长从 511 h 压到 143.9 h（施工记录 §S03.1 / §S04.2）。
 */

#include "../../utils/amcl_log_coalesce.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static int g_failed = 0;

static void check(const char* name, bool cond, const std::string& extra = "") {
    if (cond) {
        std::printf("  ok   %s\n", name);
    } else {
        g_failed++;
        std::printf("  FAIL %s%s%s\n", name, extra.empty() ? "" : "\n       ", extra.c_str());
    }
}

/**
 * 把一串日志喂给策略，产出「最终会落盘的行」。
 * 这是 amcl_log.cpp 里 emitEntry + flushCoalescedLocked 的等价复刻，
 * 只是把 fwrite 换成 push_back。
 */
struct Rec {
    int level; long long activityId; std::string tag; std::string msg; long long ts;
};

static std::vector<std::string> run(const std::vector<Rec>& in) {
    AmclCoalesceState st;
    amclCoalesceReset(&st);
    std::vector<std::string> out;

    auto flush = [&](int keepRun) {
        if (!amclCoalescePending(&st)) { if (!keepRun) st.active = 0; return; }
        char body[256];
        int n = amclCoalesceFormatBody(&st, body, sizeof(body));
        if (n > 0) out.push_back(std::string("META:") + body);
        amclCoalesceAfterFlush(&st, keepRun);
    };

    for (const Rec& r : in) {
        if (amclCoalesceMatches(&st, r.level, r.activityId, r.tag.c_str(), r.msg.c_str())) {
            if (amclCoalesceNoteRepeat(&st, r.ts)) flush(1);
            continue;
        }
        flush(0);
        out.push_back(r.tag + "|" + r.msg);
        amclCoalesceBegin(&st, r.level, r.activityId, r.tag.c_str(), r.msg.c_str(), r.ts);
    }
    flush(0);
    return out;
}

static bool hasMeta(const std::vector<std::string>& v, const char* needle) {
    for (const std::string& s : v) {
        if (s.rfind("META:", 0) == 0 && s.find(needle) != std::string::npos) return true;
    }
    return false;
}
static int countNonMeta(const std::vector<std::string>& v) {
    int n = 0;
    for (const std::string& s : v) if (s.rfind("META:", 0) != 0) n++;
    return n;
}

int main() {
    std::printf("=== log_coalesce_test ===\n");

    // ── 1. 基本合并：逐字相同的连续行只留首行 + 一条计数
    {
        std::vector<Rec> in;
        for (int i = 0; i < 100; i++) in.push_back({1, 0, "McGamePage", "heartbeat gen=36", 1000 + i});
        auto out = run(in);
        check("100 条逐字相同 ⇒ 1 行正文 + 1 行计数", out.size() == 2, "size=" + std::to_string(out.size()));
        check("首行原样保留", out[0] == "McGamePage|heartbeat gen=36");
        check("计数行报出 99 次（不含首行）", hasMeta(out, "repeated 99 more times"), out.size() > 1 ? out[1] : "");
        check("计数行带持续时长", hasMeta(out, "over 99 s"));
    }

    // ── 2. ⭐ 承重：无损性。只要有一个字段不同就不许合并
    {
        // 正文差一个字符
        auto a = run({{1, 0, "T", "value=1", 10}, {1, 0, "T", "value=2", 11}});
        check("正文不同 ⇒ 两行都在", countNonMeta(a) == 2);

        // 级别不同
        auto b = run({{1, 0, "T", "same", 10}, {3, 0, "T", "same", 11}});
        check("级别不同 ⇒ 两行都在", countNonMeta(b) == 2);

        // tag 不同
        auto c = run({{1, 0, "T1", "same", 10}, {1, 0, "T2", "same", 11}});
        check("tag 不同 ⇒ 两行都在", countNonMeta(c) == 2);

        // 活动归属不同 —— 合并会把 B 活动的行记到 A 名下，那正是账本要根除的问题
        auto d = run({{1, 7, "T", "same", 10}, {1, 8, "T", "same", 11}});
        check("activityId 不同 ⇒ 两行都在（不许跨活动合并）", countNonMeta(d) == 2);
    }

    // ── 3. ⭐ 承重：不连续就不合并。中间插一行不同的，两段各自保留
    {
        auto out = run({
            {1, 0, "T", "A", 10}, {1, 0, "T", "A", 11},
            {1, 0, "T", "B", 12},
            {1, 0, "T", "A", 13}, {1, 0, "T", "A", 14},
        });
        check("A,A,B,A,A ⇒ 三行正文（A B A）", countNonMeta(out) == 3, std::to_string(countNonMeta(out)));
        check("第二段 A 没有被第一段吸收", out[0] == "T|A" && out.back() != "T|B");
    }

    // ── 4. 攒满条数上限 ⇒ 中途落一次计数，且游程继续
    {
        std::vector<Rec> in;
        in.push_back({1, 0, "T", "x", 0});
        for (unsigned i = 0; i < AMCL_COALESCE_MAX_RUN + 10; i++) in.push_back({1, 0, "T", "x", 1});
        auto out = run(in);
        check("超过条数上限 ⇒ 至少两条计数行", out.size() >= 3, "size=" + std::to_string(out.size()));
        check("正文仍只有一行（游程没有被重开）", countNonMeta(out) == 1);
    }

    // ── 5. 攒够时长上限 ⇒ 落一次计数（长时间只有心跳时，读日志的人要看得到）
    {
        std::vector<Rec> in;
        in.push_back({1, 0, "T", "x", 0});
        in.push_back({1, 0, "T", "x", 1});
        in.push_back({1, 0, "T", "x", AMCL_COALESCE_MAX_SECONDS + 1});
        auto out = run(in);
        check("超过时长上限 ⇒ 计数行已落地", out.size() >= 2, "size=" + std::to_string(out.size()));
    }

    // ── 6. 单次出现不产生计数行（不许给正常日志加噪声）
    {
        auto out = run({{1, 0, "T", "once", 10}, {1, 0, "T", "twice", 11}});
        check("每行只出现一次 ⇒ 不产生任何计数行", out.size() == 2, "size=" + std::to_string(out.size()));
    }

    // ── 7. reset 之后不许与上个生命周期的最后一行比较
    {
        AmclCoalesceState st;
        amclCoalesceReset(&st);
        amclCoalesceBegin(&st, 1, 0, "T", "x", 10);
        amclCoalesceReset(&st);
        check("reset 后 matches 恒假", amclCoalesceMatches(&st, 1, 0, "T", "x") == 0);
        check("reset 后没有待落计数", amclCoalescePending(&st) == 0);
    }

    // ── 8. 真实语料形状：心跳 + 偶发其它行，验证收益量级
    {
        std::vector<Rec> in;
        long long t = 0;
        for (int block = 0; block < 50; block++) {
            for (int i = 0; i < 50; i++) in.push_back({1, 0, "McGamePage", "heartbeat gen=36", t++});
            in.push_back({1, 0, "Other", "real event " + std::to_string(block), t++});
        }
        auto out = run(in);
        // 50 段心跳 ⇒ 50 行正文 + 50 行计数；50 条真实事件各自一行
        check("2550 条 ⇒ 输出 150 行", out.size() == 150, "size=" + std::to_string(out.size()));
        check("50 条真实事件一条不少", countNonMeta(out) == 100, std::to_string(countNonMeta(out)));
    }

    std::printf(g_failed == 0 ? "\nALL PASS\n" : "\n%d FAILED\n", g_failed);
    return g_failed == 0 ? 0 : 1;
}
