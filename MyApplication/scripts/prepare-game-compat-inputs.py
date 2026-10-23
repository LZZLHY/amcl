"""显式下载并校验游戏兼容层输入；可在无 AMCL 根目录的独立公开克隆中使用。"""
import argparse
import json
from lib.game_compat_inputs import LOCK, digest, prepare


def main():
    """下载仅由 --download 授权，收据包含实际 SHA256，但不记录机器环境或秘密。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", help="External cache directory; or AMCL_GAME_COMPAT_INPUTS")
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--include-tests", action="store_true", help="Also prepare the fixed old/new Create control artifacts")
    args = parser.parse_args()
    result = prepare(args.output, args.download, args.include_tests)
    receipt = {"schema": 1, "lockSha256": digest(LOCK.read_text(encoding="utf-8").encode("utf-8")), "files": [
        {"path": str(path), "size": path.stat().st_size, "sha256": digest(path.read_bytes())}
        for path in [*result["paths"].values(), *result["libraries"]]]}
    result["directory"].mkdir(parents=True, exist_ok=True)
    (result["directory"] / "verified-inputs.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print("[game-compat-inputs] verified " + str(len(receipt["files"])) + " files in " + str(result["directory"]))


if __name__ == "__main__":
    main()
