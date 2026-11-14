#!/usr/bin/env python3
"""从明确列举的资格/权限源构建 class52、确定性 JAR 与 TestHooks 头；输出显式外置。"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile


def sha(path: Path) -> str:
    """身份绑定真实文件字节，不能以 javac 的显示版本替代可执行文件摘要。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--javac", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--header", type=Path, required=True)
    args = parser.parse_args()
    source = Path(__file__).with_name("RuntimeQualification.java")
    permission_source = Path(__file__).resolve().parent.parent / "runtime-permissions/PermissionCopyProbe.java"
    cf_source = Path(__file__).resolve().parent.parent / "runtime-jit/CompletableFutureQualification.java"
    extended_source = Path(__file__).resolve().parent.parent / "runtime-extended/ExtendedRuntimeQualification.java"
    sound_source = Path(__file__).resolve().parent.parent / "java-sound/JavaSoundQualification.java"
    process_source = Path(__file__).resolve().parent.parent / "runtime-childproc/JavaProcessQualification.java"
    capture_source = Path(__file__).resolve().parent.parent / "java-sound/JavaSoundCaptureQualification.java"
    devices_source = Path(__file__).resolve().parent.parent / "java-sound/NativeSoundDevicesQualification.java"
    native_temp_source = Path(__file__).resolve().parent.parent / "runtime-native-temp/NativeTempVmQualification.java"
    # 同一JAR固定携带CF策略夹具；两个directive的真实源字节也随头冻结，不能在设备上
    # 接受任意外部JVM选项。全部源码仍由同一次--release 8约束。
    directive_root = cf_source.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    classes = output / "classes"
    classes.mkdir()
    # --release 8 同时约束字节码与 API，避免仅 -target 8 却误用了更高版本标准库。
    identity = subprocess.check_output([str(args.javac), "-version"], stderr=subprocess.STDOUT, text=True).strip()
    command = [str(args.javac), "--release", "8", "-encoding", "UTF-8", "-g", "-d", str(classes),
               str(source), str(permission_source), str(cf_source), str(extended_source), str(sound_source), str(process_source), str(capture_source), str(devices_source), str(native_temp_source)]
    subprocess.run(command, check=True)
    jar = output / "qualification.jar"
    inventory = []
    with zipfile.ZipFile(jar, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for file in sorted(classes.rglob("*.class")):
            data = file.read_bytes()
            if data[:4] != b"\xca\xfe\xba\xbe" or int.from_bytes(data[6:8], "big") != 52:
                raise RuntimeError(f"not Java8 bytecode: {file}")
            relative = file.relative_to(classes).as_posix()
            item = zipfile.ZipInfo(relative, (1980, 1, 1, 0, 0, 0))
            item.external_attr = 0o100644 << 16
            item.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(item, data)
            inventory.append({"path": relative, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), "classMajor": 52})
    data = jar.read_bytes()
    rows = [", ".join(f"0x{byte:02x}" for byte in data[start:start + 16]) for start in range(0, len(data), 16)]
    # 生成头只被 MC_OHOS_BUILD_TESTS TU 包含；源摘要直接随 HAP，便于连接真机证据和夹具版本。
    header = """// 自动生成的 Java 资格 JAR。修改 tests/runtime-java/RuntimeQualification.java 后运行 build-fixture.py。
// 字节码逐项校验为 class52；此测试载荷不得作为普通产品功能装载。
#pragma once
#include <cstddef>
namespace amcl::jdkqualification {
"""
    header += f'inline constexpr char FixtureJarSha256[] = "{sha(jar)}";\n'
    header += f'inline constexpr char FixtureSourceSha256[] = "{sha(source)}";\n'
    header += f'inline constexpr char PermissionSourceSha256[] = "{sha(permission_source)}";\n'
    header += f'inline constexpr char CfSourceSha256[] = "{sha(cf_source)}";\n'
    header += f'inline constexpr char ExtendedSourceSha256[] = "{sha(extended_source)}";\n'
    header += f'inline constexpr char SoundSourceSha256[] = "{sha(sound_source)}";\n'
    header += f'inline constexpr char ProcessSourceSha256[] = "{sha(process_source)}";\n'
    header += f'inline constexpr char CaptureSourceSha256[] = "{sha(capture_source)}";\n'
    header += f'inline constexpr char NativeDevicesSourceSha256[] = "{sha(devices_source)}";\n'
    header += f'inline constexpr char NativeTempVmSourceSha256[] = "{sha(native_temp_source)}";\n'
    for name, filename in (("CfFullDirectives", "cf_full_directives.json"),
                           ("CfC2OnlyDirectives", "cf_c2_only_v2_directives.json")):
        text = (directive_root / filename).read_text(encoding="utf-8")
        # JSON字符串转义与本资源所需C++普通字符串字面量兼容；不使用可能冲突的raw终止符。
        header += f'inline constexpr char {name}[] = {json.dumps(text, ensure_ascii=True)};\n'
    header += "inline constexpr unsigned char FixtureJar[] = {\n    " + ",\n    ".join(rows) + "\n};\n"
    header += "inline constexpr std::size_t FixtureJarSize = sizeof(FixtureJar);\n}\n"
    args.header.parent.mkdir(parents=True, exist_ok=True)
    args.header.write_text(header, encoding="utf-8", newline="\n")
    receipt = {"javac": str(args.javac.resolve()), "javacVersion": identity, "javacSha256": sha(args.javac),
               "source": str(source.resolve()), "sourceSha256": sha(source), "command": command,
               "additionalSources": [{"path": str(path), "sha256": sha(path)} for path in
                   (permission_source, cf_source, extended_source, sound_source, process_source, capture_source, devices_source, native_temp_source, directive_root / "cf_full_directives.json",
                    directive_root / "cf_c2_only_v2_directives.json")],
               "jar": str(jar), "jarSha256": sha(jar), "jarBytes": len(data),
               "header": str(args.header.resolve()), "headerSha256": sha(args.header), "classes": inventory}
    (output / "build-receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"jar": str(jar), "sha256": sha(jar), "bytes": len(data), "classes": len(inventory)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
