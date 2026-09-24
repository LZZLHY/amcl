"""Linux 宿主包装器输出边界回归：真实执行 shell 编排，编译器边界替换为无副作用命令。"""
from pathlib import Path
import os
import re
import subprocess
import sys
from lib.workspace_paths import temporary_directory

ROOT = Path(__file__).resolve().parent.parent
if os.name == "nt":
    # Windows 不把 POSIX shell 行为替换成模型；在 WSL 中执行同一份回归。
    script = subprocess.check_output(["wsl", "-d", "Ubuntu", "--exec", "wslpath", "-a", Path(__file__).resolve().as_posix()], text=True).strip()
    subprocess.run(["wsl", "-d", "Ubuntu", "--exec", "python3", "-B", script], check=True)
    sys.exit(0)

with temporary_directory(prefix="amcl-host-output-policy-") as directory:
    fixture = Path(directory)
    commands = fixture / "commands"
    commands.mkdir()
    for name in ("c++", "cmake", "ninja", "ctest"):
        tool = commands / name
        tool.write_text('#!/bin/sh\nif [ "${1:-}" = "--version" ]; then printf "fixture tool 1\\n"; fi\nprintf "%s\\n" "$0 $*" >> "$AMCL_OUTPUT_POLICY_TRACE"\n', encoding="utf-8")
        tool.chmod(0o755)
    for category in ("archive", "home"):
        parent = fixture / category
        parent.mkdir()
        sentinel = parent / "keep-original.txt"
        sentinel.write_bytes(b"original user content\x00\r\n")
        trace = fixture / (category + "-commands.log")
        env = {**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"],
               "AMCL_HOST_TEST_BUILD_DIR": str(parent), "AMCL_OUTPUT_POLICY_TRACE": str(trace)}
        script = ROOT / "scripts/run-host-tests-docker.sh"
        preview = subprocess.run(["bash", str(script), "--print-build-dir"], cwd=fixture, env=env, capture_output=True, text=True)
        assert preview.returncode == 0, preview.stderr
        assert preview.stdout.strip() == str(parent)
        assert list(parent.iterdir()) == [sentinel], "路径预检不能创建或删除父目录内容"
        result = subprocess.run(["bash", str(script)], cwd=fixture, env=env, capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
        assert sentinel.read_bytes() == b"original user content\x00\r\n", "显式归档/home 父目录必须原样保留"
        created = [item for item in parent.iterdir() if item != sentinel]
        assert len(created) == 1 and created[0].is_dir() and created[0].name.startswith("run-")
        assert "build directory: " + str(created[0]) in result.stdout
        assert "--build " + str(created[0]) in trace.read_text()
        assert "--test-dir " + str(created[0]) in trace.read_text()
    invalid = subprocess.run(["bash", str(script), "--print-build-dir"], cwd=fixture,
        env={**env, "AMCL_HOST_TEST_BUILD_DIR": str(ROOT / "diagnostics/new-build")}, capture_output=True, text=True)
    assert invalid.returncode != 0 and "outside the project" in invalid.stderr
    assert not (ROOT / "diagnostics").exists()
print("Host shell output policy PASS: archive/home sentinels preserved; unique child build; repository output rejected")
