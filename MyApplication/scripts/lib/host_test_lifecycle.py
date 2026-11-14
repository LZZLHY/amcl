"""Python 宿主回归的亲建夹具生命周期，与 JS host-test-lifecycle 的保现场边界一致。

只接受仓外绝对父目录，并由本对象亲自 mkdtemp 创建可删除的子目录。调用者先结束
子进程/文件句柄并保存小汇总，再显式 close；失败或调试保留不修改现场。这里不清理
共享父目录、历史运行、SDK 缓存或任何由调用者直接指定的待删路径。
"""
import os
from pathlib import Path
import stat
import tempfile

from .workspace_paths import external_output_path


def _reparse(info):
    """同时识别 POSIX symlink 和 Windows junction，目录链接始终只处理链接本身。"""
    return stat.S_ISLNK(info.st_mode) or bool(getattr(info, "st_file_attributes", 0)
        & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400))


def _remove_no_follow(directory):
    """只遍历真实目录；嵌套链接不跟随，避免把其他运行域或证据原件纳入回收。"""
    with os.scandir(directory) as entries:
        for entry in entries:
            info = entry.stat(follow_symlinks=False)
            if _reparse(info):
                # Windows junction 使用 rmdir 删除链接；普通文件和 symlink 使用 unlink。
                if stat.S_ISDIR(info.st_mode):
                    os.rmdir(entry.path)
                else:
                    os.unlink(entry.path)
            elif stat.S_ISDIR(info.st_mode):
                _remove_no_follow(entry.path)
            else:
                os.unlink(entry.path)
    os.rmdir(directory)


class HostTestScope:
    """独占本轮子目录，close 的 success 必须来自真实测试结果，不能用目录存在推断。

    根目录、父目录的物理身份及 inode/dev 在创建时固定。关闭前被替换、移动或引入
    junction 时直接失败且保留剩余内容；不猜测恢复路径，不删除共享父目录。
    """

    def __init__(self, prefix, *, parent):
        """校验父目录并原子创建运行域；不修改 TEMP/TMP，也不初始化真实生产依赖。"""
        if not prefix or "/" in prefix or "\\" in prefix or prefix == "..":
            raise ValueError("Invalid host test scope prefix")
        parent = Path(parent)
        if not parent.is_absolute():
            raise ValueError("Host test output parent must be absolute")
        self.parent = external_output_path(parent)
        self.parent.mkdir(parents=True, exist_ok=True)
        self.directory = Path(tempfile.mkdtemp(prefix=prefix, dir=self.parent))
        self.prefix = prefix
        info = self.directory.lstat()
        parent_info = self.parent.lstat()
        self.identity = (info.st_dev, info.st_ino, self.directory.resolve())
        self.parent_identity = (parent_info.st_dev, parent_info.st_ino, self.parent.resolve())
        self.removed = False

    def close(self, *, success=True):
        """成功且未要求调试保留时回收；返回是否已删除，异常必须由 runner 报为失败。

        业务失败直接保留断言结束时的字节，不执行取消等可能改写 journal 的动作。
        调用者负责先关闭自己启动的异步资源；本方法只接受本对象保存的亲建目录。
        """
        if self.removed:
            return True
        if not success or os.environ.get("AMCL_KEEP_TEST_OUTPUT") == "1":
            print("Host test evidence retained: " + str(self.directory))
            return False
        info = self.directory.lstat()
        parent_info = self.parent.lstat()
        if (_reparse(info) or not stat.S_ISDIR(info.st_mode)
                or (info.st_dev, info.st_ino, self.directory.resolve()) != self.identity
                or (parent_info.st_dev, parent_info.st_ino, self.parent.resolve()) != self.parent_identity
                or self.directory.parent != self.parent or not self.directory.name.startswith(self.prefix)):
            raise ValueError("Host test cleanup directory identity changed; evidence retained")
        external_output_path(self.directory)
        _remove_no_follow(self.directory)
        self.removed = True
        return True
