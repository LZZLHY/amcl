#!/usr/bin/env python3
"""从四代锁定小型childproc源生成非活动OHOS候选；不写series或任何生产参数。

原文件逐个核SHA/commit，变换锚点必须唯一，输出独占外置目录与可审查patch。
原平台分支按原字节逻辑保留；宿主用__OHOS__只验证候选分支，不能借此宣称目标支持。
"""
import argparse
import datetime
import difflib
import hashlib
import json
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def digest(data):
    """所有身份基于实际字节；候选文件与源文件的摘要分别保存。"""
    return hashlib.sha256(data).hexdigest()


def replace_one(source, old, new):
    """源版本变化/锚点重复直接拒绝，不能悄悄打到近似版本。"""
    if source.count(old) != 1:
        raise ValueError("source anchor mismatch: " + old[:90])
    return source.replace(old, new, 1)


def wrap_body(source, name, prefix):
    """仅包住指定函数体；掩掉注释/字符串再计花括号，不靠附近文本长度猜测。"""
    token = r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\''
    masked = re.sub(token, lambda m: " " * len(m[0]), source, flags=re.S)
    matches = list(re.finditer(r"(?m)^" + re.escape(name) + r"\s*\([^;{}]*\)\s*\{", masked))
    if len(matches) != 1:
        raise ValueError("function boundary mismatch: " + name)
    start = matches[0].end() - 1
    depth = 1
    end = start + 1
    while depth:
        depth += (masked[end] == "{") - (masked[end] == "}")
        end += 1
    body = source[start + 1:end - 1]
    return source[:start] + "{\n#ifdef __OHOS__\n" + prefix + "\n#else" + body + "\n#endif\n}" + source[end:]


def candidate(source):
    """复用原PATH循环/ENOEXEC helper，只改变OHOS所选执行路径与FD失败传播。"""
    source = replace_one(source, '#include "childproc.h"',
        '#include "childproc.h"\n#ifdef __OHOS__\n#include "amcl_child_fd_cleanup.h"\n#endif')
    source = wrap_body(source, "closeDescriptors",
        "    /* OHOS: 真机close_range触发SIGSYS，固定使用已验证的raw getdents64；不得试探受限syscall。 */\n"
        "    return amcl_child_fd_cleanup(FAIL_FILENO + 1, AMCL_CHILD_FD_DENTS_ONLY, NULL) == 0;")
    # 25把旧数字判断帮助函数设成static；OHOS不再调用它，避免正常-Werror构建出现死函数警告。
    if "static int\nisAsciiDigit" in source:
        old = """static int
isAsciiDigit(char c)
{
  return c >= '0' && c <= '9';
}"""
        source = replace_one(source, old, "#ifndef __OHOS__\n" + old + "\n#endif")
    source = wrap_body(source, "execve_with_shell_fallback",
        "    /* OHOS: FORK/VFORK均复用已有execve和ENOEXEC回退，不改全局environ或调用execvp。 */\n"
        "    (void)mode;\n"
        "    execve(file, (char **) argv, (char **) envp);\n"
        "    if (errno == ENOEXEC)\n"
        "        execve_as_traditional_shell_script(file, argv, envp);")
    old = """    if (envp == NULL || (char **) envp == environ) {
        execvp(file, (char **) argv);
        return;
    }"""
    source = replace_one(source, old, """#ifdef __OHOS__
    /* OHOS: NULL保留继承环境；路径沿用fork前建立的parentPathv，不在child分配/解析getenv。 */
    if (envp == NULL)
        envp = (const char * const *)environ;
#else
""" + old + "\n#endif")
    old = """    /* close everything */
    if (closeDescriptors() == 0) { /* failed,  close the old way */
        int max_fd = (int)sysconf(_SC_OPEN_MAX);
        int fd;
        for (fd = FAIL_FILENO + 1; fd < max_fd; fd++)
            if (close(fd) == -1 && errno != EBADF)
                goto WhyCantJohnnyExec;
    }"""
    source = replace_one(source, old, """#ifdef __OHOS__
    /* OHOS: raw getdents64清理失败就报告原errno；不以不完备上界或百万次close掩盖失败。 */
    if (closeDescriptors() == 0)
        goto WhyCantJohnnyExec;
#else
""" + old + "\n#endif")
    return source


def java_candidate(source, major):
    """仅未显式选择时查询本地真实系统身份；原显式值解析/验证与错误行为全部保留。"""
    declaration = """    // OHOS默认机制只来自本地uname，不能被可覆写的os.name或其他Java属性伪造。
    private static native boolean isOhosPlatform();

"""
    anchor = "    private static enum LaunchMechanism {"
    source = replace_one(source, anchor, declaration + anchor)
    if major == "17":
        source = replace_one(source, "                        lm = defaultLaunchMechanism;",
            "                        lm = isOhosPlatform() ? LaunchMechanism.FORK : defaultLaunchMechanism;")
    else:
        source = replace_one(source, "            return LaunchMechanism.POSIX_SPAWN;",
            "            return isOhosPlatform() ? LaunchMechanism.FORK : LaunchMechanism.POSIX_SPAWN;")
    return source


def native_platform_candidate(source):
    """JNI查询只在Java父侧类初始化调用；不更改fork协议或child全局状态。"""
    return replace_one(source, '#include "childproc.h"', """#include "childproc.h"
#include "amcl_process_platform.h"

/* 默认机制只识别本目标的真实内核身份；非OHOS构建/其他uname仍返回原平台默认。
 * 本入口不读取或写入Java属性，不在exec失败后降级，也不改变任何显式选择。 */
JNIEXPORT jboolean JNICALL
Java_java_lang_ProcessImpl_isOhosPlatform(JNIEnv *env, jclass clazz) {
    (void)env;
    (void)clazz;
    return amcl_process_is_ohos() ? JNI_TRUE : JNI_FALSE;
}
""")


def apply_prior_series(major, entries, baseline):
    """先对本候选涉及的真实源文件应用全部现役前置patch；不手抄0017的上下文。
    其他文件由git apply --include严格排除，独立记录本组实际消费的前置patch摘要。
    """
    baseline.mkdir()
    for item in entries:
        target = baseline / item["upstreamPath"]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((HERE / "reference" / item["relative"]).read_bytes())
    directory = ROOT / "prebuilt/jdk" / major / "patches"
    series = (directory / "series").read_text(encoding="utf-8-sig").splitlines()
    includes = [item["upstreamPath"] for item in entries]
    consumed = []
    for line in series:
        name = line.split("#", 1)[0].strip()
        if not name or name == "0024-ohos-childproc-safe-fork.patch":
            continue
        patch = directory / name
        text = patch.read_text(encoding="utf-8")
        if not any("+++ b/" + path + "\n" in text for path in includes):
            continue
        # 独立克隆/Windows维护者都保持上游LF；不能让全局autocrlf改变实际测试/补丁字节。
        args = ["git", "-c", "core.autocrlf=false", "-c", "core.eol=lf", "apply", "--whitespace=nowarn"] + \
            ["--include=" + path for path in includes] + [str(patch)]
        subprocess.run(args, cwd=baseline, check=True, capture_output=True)
        consumed.append({"name": name, "sha256": digest(patch.read_bytes())})
    return consumed


def main():
    """一次生成一个独占外置候选；源身份和完整patch可供后续系列准入复核。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    if output == ROOT or ROOT in output.parents:
        raise ValueError("candidate output must stay outside the source repository")
    output.mkdir(parents=True, exist_ok=False)
    reference = HERE / "reference"
    sources = json.loads((reference / "source.json").read_text(encoding="utf-8"))
    lock = json.loads((ROOT / "prebuilt/jdk/build-inputs.json").read_text(encoding="utf-8"))
    tested_helper = (HERE / "child_fd_cleanup_candidate.h").read_bytes()
    body = tested_helper[tested_helper.index(b"#ifndef AMCL_CHILD_FD_CLEANUP_CANDIDATE_H"):]
    # 只更新生成文件的用途说明；函数体逐字节继承已经在目标探针执行的权威候选。
    helper = ("/* OHOS childproc清理实现：函数体与独立资格探针一致。\n"
              " * 生产调用固定DENTS_ONLY；商业目标已证close_range触发SIGSYS，不作运行时试探。\n"
              " * 返回失败必须沿原JDK fail pipe退出；保留stdio/FAIL_FILENO，不改变非OHOS分支。\n"
              " */\n").encode("utf-8") + body
    receipt = {"schema": 1, "preparedAt": datetime.datetime.now().astimezone().isoformat(),
               "activeSeriesChanged": False, "productionMechanismChanged": False,
               "generatorSha256": digest(Path(__file__).read_bytes()),
               "testedFdHelperBodySha256": digest(body), "variants": {}}
    for major in ("8", "17", "21", "25"):
        entries = [item for item in sources["files"] if item["major"] == major]
        names = [Path(item["relative"]).name for item in entries]
        if not {"childproc.c", "childproc.h"}.issubset(names) or len(set(names)) != len(names):
            raise ValueError("missing reference pair " + major)
        dest = output / major
        dest.mkdir()
        prior = apply_prior_series(major, entries, dest / "baseline")
        record = {"inputs": [], "outputs": {}, "priorSeriesConsumed": prior}
        patch = ""
        for item in entries:
            original = (reference / item["relative"]).read_bytes()
            pinned = lock["runtimes"][major]
            if (digest(original) != item["sha256"] or item["commit"] != pinned["commit"] or
                    item["repository"] != pinned["repository"]):
                raise ValueError("reference identity mismatch " + item["relative"])
            record["inputs"].append(item)
            name = Path(item["relative"]).name
            before = (dest / "baseline" / item["upstreamPath"]).read_bytes()
            if name == "childproc.c":
                changed = candidate(before.decode("utf-8")).encode("utf-8")
            elif name == "ProcessImpl.java":
                changed = java_candidate(before.decode("utf-8"), major).encode("utf-8")
            elif name == "ProcessImpl_md.c":
                changed = native_platform_candidate(before.decode("utf-8")).encode("utf-8")
            else:
                changed = before
            (dest / name).write_bytes(changed)
            record["outputs"][name] = digest(changed)
            if changed != before:
                patch += "".join(difflib.unified_diff(before.decode("utf-8").splitlines(True),
                    changed.decode("utf-8").splitlines(True), fromfile="a/" + item["upstreamPath"],
                    tofile="b/" + item["upstreamPath"], n=3))
        (dest / "amcl_child_fd_cleanup.h").write_bytes(helper)
        record["outputs"]["amcl_child_fd_cleanup.h"] = digest(helper)
        location = next(x["upstreamPath"] for x in entries if Path(x["upstreamPath"]).name == "childproc.c")
        helper_path = str(Path(location).parent / "amcl_child_fd_cleanup.h").replace("\\", "/")
        patch += "".join(difflib.unified_diff([], helper.decode("utf-8").splitlines(True),
            fromfile="/dev/null", tofile="b/" + helper_path, n=3))
        if major != "8":
            platform = (HERE / "amcl_process_platform.h").read_bytes()
            (dest / "amcl_process_platform.h").write_bytes(platform)
            record["outputs"]["amcl_process_platform.h"] = digest(platform)
            platform_path = str(Path(location).parent / "amcl_process_platform.h").replace("\\", "/")
            patch += "".join(difflib.unified_diff([], platform.decode("utf-8").splitlines(True),
                fromfile="/dev/null", tofile="b/" + platform_path, n=3))
        (dest / "candidate.patch").write_text(patch, encoding="utf-8", newline="\n")
        record["outputs"]["candidate.patch"] = digest((dest / "candidate.patch").read_bytes())
        receipt["variants"][major] = record
    (output / "source-candidate.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n",
                                                encoding="utf-8")
    print(json.dumps({"output": str(output), "majors": list(receipt["variants"]), "activeSeriesChanged": False}))


if __name__ == "__main__":
    main()
