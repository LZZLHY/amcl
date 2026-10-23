"""测试子进程的显式所有权；Windows 用原子 JobList 创建，POSIX 由调用方独立 session。

只使用公开 Win32 API 和 ctypes，不读 Popen 私有句柄、不扫描系统 PID、不按进程名清理。
PROC_THREAD_ATTRIBUTE_JOB_LIST 在用户代码运行前把根进程加入本方 job；后代继承归属，
即使根进程已退出，job 句柄仍能回收继承 stdout 的后代。Win10+ 不支持时失败关闭。
公开 API 来源：Microsoft Learn 的 UpdateProcThreadAttribute/CreateProcessW/Job Objects，
以及微软 2023-02-09 “A more direct and mistake-free way of creating a process in a job object”。
"""
import ctypes
import math
import os
import subprocess
import time


class WindowsJobProcess:
    """窄 Popen 接口：stdout/pid/returncode/poll/wait；拥有且仅拥有本次 job 和进程句柄。"""
    def __init__(self, command, cwd):
        if os.name != "nt":
            raise RuntimeError("WindowsJobProcess requires Windows")
        import msvcrt
        from ctypes import wintypes as w
        self.api = ctypes.WinDLL("kernel32", use_last_error=True)
        self.job = self.handle = None
        self.returncode = None
        self.observed = {}
        self.stdout = None
        self.pid = None
        size_t = ctypes.c_size_t
        ulong64 = ctypes.c_uint64

        class Security(ctypes.Structure):
            _fields_ = [("length", w.DWORD), ("descriptor", w.LPVOID), ("inherit", w.BOOL)]
        class BasicLimits(ctypes.Structure):
            _fields_ = [("processTime", ctypes.c_int64), ("jobTime", ctypes.c_int64), ("flags", w.DWORD),
                        ("minimumWorking", size_t), ("maximumWorking", size_t), ("activeLimit", w.DWORD),
                        ("affinity", size_t), ("priority", w.DWORD), ("scheduling", w.DWORD)]
        class IoCounters(ctypes.Structure):
            _fields_ = [(name, ulong64) for name in ("readOperations", "writeOperations", "otherOperations",
                                                    "readBytes", "writeBytes", "otherBytes")]
        class ExtendedLimits(ctypes.Structure):
            _fields_ = [("basic", BasicLimits), ("io", IoCounters), ("processMemory", size_t),
                        ("jobMemory", size_t), ("peakProcessMemory", size_t), ("peakJobMemory", size_t)]
        class Accounting(ctypes.Structure):
            _fields_ = [("userTime", ctypes.c_int64), ("kernelTime", ctypes.c_int64),
                        ("periodUserTime", ctypes.c_int64), ("periodKernelTime", ctypes.c_int64),
                        ("pageFaults", w.DWORD), ("totalProcesses", w.DWORD),
                        ("activeProcesses", w.DWORD), ("terminatedProcesses", w.DWORD)]
        class Startup(ctypes.Structure):
            _fields_ = [("cb", w.DWORD), ("reserved", w.LPWSTR), ("desktop", w.LPWSTR), ("title", w.LPWSTR),
                        *[(name, w.DWORD) for name in ("x", "y", "width", "height", "columns", "rows", "fill", "flags")],
                        ("show", w.WORD), ("reservedSize", w.WORD), ("reservedBytes", ctypes.POINTER(w.BYTE)),
                        ("stdin", w.HANDLE), ("stdout", w.HANDLE), ("stderr", w.HANDLE)]
        class StartupEx(ctypes.Structure):
            _fields_ = [("startup", Startup), ("attributes", w.LPVOID)]
        class ProcessInfo(ctypes.Structure):
            _fields_ = [("process", w.HANDLE), ("thread", w.HANDLE), ("pid", w.DWORD), ("tid", w.DWORD)]
        self.Accounting = Accounting

        def bind(name, result, arguments):
            """固定 pointer-sized HANDLE/SIZE_T ABI，避免 ctypes 默认 int 截断64位句柄。"""
            function = getattr(self.api, name); function.restype = result; function.argtypes = arguments
            return function
        bind("CloseHandle", w.BOOL, [w.HANDLE])
        bind("CreateJobObjectW", w.HANDLE, [w.LPVOID, w.LPCWSTR])
        bind("SetInformationJobObject", w.BOOL, [w.HANDLE, ctypes.c_int, w.LPVOID, w.DWORD])
        bind("QueryInformationJobObject", w.BOOL, [w.HANDLE, ctypes.c_int, w.LPVOID, w.DWORD, w.LPVOID])
        bind("TerminateJobObject", w.BOOL, [w.HANDLE, w.UINT])
        bind("CreatePipe", w.BOOL, [ctypes.POINTER(w.HANDLE), ctypes.POINTER(w.HANDLE), ctypes.POINTER(Security), w.DWORD])
        bind("SetHandleInformation", w.BOOL, [w.HANDLE, w.DWORD, w.DWORD])
        bind("CreateFileW", w.HANDLE, [w.LPCWSTR, w.DWORD, w.DWORD, ctypes.POINTER(Security), w.DWORD, w.DWORD, w.HANDLE])
        bind("InitializeProcThreadAttributeList", w.BOOL, [w.LPVOID, w.DWORD, w.DWORD, ctypes.POINTER(size_t)])
        bind("UpdateProcThreadAttribute", w.BOOL, [w.LPVOID, w.DWORD, size_t, w.LPVOID, size_t, w.LPVOID, w.LPVOID])
        bind("DeleteProcThreadAttributeList", None, [w.LPVOID])
        bind("CreateProcessW", w.BOOL, [w.LPCWSTR, w.LPWSTR, w.LPVOID, w.LPVOID, w.BOOL, w.DWORD,
                                        w.LPVOID, w.LPCWSTR, w.LPVOID, ctypes.POINTER(ProcessInfo)])
        bind("GetExitCodeProcess", w.BOOL, [w.HANDLE, ctypes.POINTER(w.DWORD)])
        bind("WaitForSingleObject", w.DWORD, [w.HANDLE, w.DWORD])
        bind("OpenProcess", w.HANDLE, [w.DWORD, w.BOOL, w.DWORD])
        bind("IsProcessInJob", w.BOOL, [w.HANDLE, w.HANDLE, ctypes.POINTER(w.BOOL)])
        read, write = w.HANDLE(), w.HANDLE()
        null_input = None
        attributes = None
        attributes_initialized = False
        info = ProcessInfo()
        try:
            self.job = self.api.CreateJobObjectW(None, None)
            self._check(self.job, "CreateJobObjectW")
            limits = ExtendedLimits(); limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            self._check(self.api.SetInformationJobObject(self.job, 9, ctypes.byref(limits), ctypes.sizeof(limits)), "SetInformationJobObject")
            security = Security(ctypes.sizeof(Security), None, True)
            self._check(self.api.CreatePipe(ctypes.byref(read), ctypes.byref(write), ctypes.byref(security), 0), "CreatePipe")
            self._check(self.api.SetHandleInformation(read, 1, 0), "SetHandleInformation")
            null_input = self.api.CreateFileW("NUL", 0x80000000, 3, ctypes.byref(security), 3, 0x80, None)
            self._check(null_input and null_input != ctypes.c_void_p(-1).value, "CreateFileW(NUL)")
            required = size_t()
            # 首次调用的预期结果是 FALSE/ERROR_INSUFFICIENT_BUFFER，返回所需字节数。
            self.api.InitializeProcThreadAttributeList(None, 2, 0, ctypes.byref(required))
            if ctypes.get_last_error() != 122 or required.value == 0:
                raise ctypes.WinError(ctypes.get_last_error())
            attributes = ctypes.create_string_buffer(required.value)
            self._check(self.api.InitializeProcThreadAttributeList(attributes, 2, 0, ctypes.byref(required)), "InitializeProcThreadAttributeList")
            attributes_initialized = True
            jobs = (w.HANDLE * 1)(self.job)
            handles = (w.HANDLE * 2)(write.value, null_input)
            self._check(self.api.UpdateProcThreadAttribute(attributes, 0, 0x2000D, ctypes.byref(jobs), ctypes.sizeof(jobs), None, None), "UpdateProcThreadAttribute(JOB_LIST)")
            self._check(self.api.UpdateProcThreadAttribute(attributes, 0, 0x20002, ctypes.byref(handles), ctypes.sizeof(handles), None, None), "UpdateProcThreadAttribute(HANDLE_LIST)")
            startup = StartupEx(); startup.startup.cb = ctypes.sizeof(StartupEx)
            startup.startup.flags = 0x100 | 1  # USESTDHANDLES | USESHOWWINDOW
            startup.startup.show = 0  # SW_HIDE
            startup.startup.stdin = null_input; startup.startup.stdout = write.value; startup.startup.stderr = write.value
            startup.attributes = ctypes.cast(attributes, w.LPVOID).value
            arguments = list(map(str, command))
            command_line = ctypes.create_unicode_buffer(subprocess.list2cmdline(arguments))
            # JobList原子赋值发生在任何用户指令执行前，无spawn→Assign之间的逃逸窗口。
            self._check(self.api.CreateProcessW(arguments[0], command_line, None, None, True,
                0x80000 | 0x08000000, None, str(cwd), ctypes.byref(startup), ctypes.byref(info)), "CreateProcessW(job-owned)")
            self.handle = info.process; self.pid = int(info.pid)
            self.api.CloseHandle(info.thread); info.thread = None
            # CRT fd 接管读句柄；后续只能经 stdout.close() 关闭，避免双 CloseHandle。
            fd = msvcrt.open_osfhandle(read.value, os.O_RDONLY | os.O_BINARY); read = w.HANDLE()
            try:
                self.stdout = os.fdopen(fd, "r", encoding="utf-8", errors="replace")
            except BaseException:
                os.close(fd); raise
        except BaseException:
            self.close()
            raise
        finally:
            if attributes_initialized:
                self.api.DeleteProcThreadAttributeList(attributes)
            for handle in (read.value, write.value, null_input, info.thread):
                if handle and handle != ctypes.c_void_p(-1).value:
                    self.api.CloseHandle(handle)

    @staticmethod
    def _check(result, operation):
        """API失败保留系统错误；不降级为不受job保护的普通创建。"""
        if not result:
            raise OSError(ctypes.get_last_error(), operation + ": " + ctypes.FormatError(ctypes.get_last_error()))

    def poll(self):
        """以进程句柄signal状态判断结束，避免把合法退出码259误读成STILL_ACTIVE。"""
        state = self.api.WaitForSingleObject(self.handle, 0)
        if state == 258:
            return None
        if state != 0:
            self._raise_wait_failure(state, "poll root pid=" + str(self.pid))
        return self._read_exit_code()

    def _read_exit_code(self):
        """仅在已确认根进程句柄signal后取退出码，不把STILL_ACTIVE数值当作信号判据。"""
        from ctypes import wintypes as w
        value = w.DWORD(); self._check(self.api.GetExitCodeProcess(self.handle, ctypes.byref(value)), "GetExitCodeProcess")
        self.returncode = int(value.value); return self.returncode

    @staticmethod
    def _raise_wait_failure(state, operation):
        """只有WAIT_FAILED可以读取GetLastError；其他非预期返回值直接保留其数值。"""
        if state == 0xFFFFFFFF:
            error = ctypes.get_last_error()
            raise OSError(error, "WaitForSingleObject WAIT_FAILED " + operation + ": " + ctypes.FormatError(error))
        raise RuntimeError("WaitForSingleObject unexpected result=" + hex(state) + " " + operation)

    def _wait_until(self, handle, deadline, operation, total_limit):
        """按同一个绝对deadline等signal；258仅是正常超时状态，不能转成Errno0。

        TerminateJobObject等同逐进程TerminateProcess；外部终止是异步，Job记账归零
        不证明每个进程内核对象已signal。每轮仅使用剩余预算，任何child都不重开5秒。
        """
        while True:
            remaining = None if deadline is None else max(0, deadline - time.monotonic())
            milliseconds = 0xFFFFFFFF if remaining is None else min(0xFFFFFFFE, math.ceil(remaining * 1000))
            state = self.api.WaitForSingleObject(handle, milliseconds)
            if state == 0:  # WAIT_OBJECT_0：唯一可以记录signaled的结果。
                return state
            if state == 258:  # WAIT_TIMEOUT：保留绝对deadline，必要时用尚余预算继续等待。
                if deadline is None:
                    raise RuntimeError("WaitForSingleObject returned WAIT_TIMEOUT for INFINITE wait: " + operation)
                if time.monotonic() >= deadline:
                    raise subprocess.TimeoutExpired("WaitForSingleObject WAIT_TIMEOUT " + operation, total_limit)
                continue
            self._raise_wait_failure(state, operation)

    def wait(self, timeout=None):
        """等待只受本对象持有的根进程句柄；后代回收另用job完整生命周期。"""
        deadline = None if timeout is None else time.monotonic() + max(0, timeout)
        self._wait_until(self.handle, deadline, "root pid=" + str(self.pid), timeout)
        return self._read_exit_code()

    def observe_owned_child(self, pid):
        """只打开日志报告的单PID，先证明属于本job再保存句柄；不扫描或操作其他进程。"""
        from ctypes import wintypes as w
        if pid in self.observed:
            return
        handle = self.api.OpenProcess(0x1000 | 0x100000, False, pid)  # QUERY_LIMITED_INFORMATION | SYNCHRONIZE
        self._check(handle, "OpenProcess(observed child)")
        member = w.BOOL()
        try:
            self._check(self.api.IsProcessInJob(handle, self.job, ctypes.byref(member)), "IsProcessInJob")
            if not member.value:
                raise RuntimeError("Reported child is not owned by suite job")
            self.observed[pid] = handle
        except BaseException:
            self.api.CloseHandle(handle); raise

    def terminate_owned(self, timeout=5):
        """根进程已退出也终止job；同一总deadline内分别核记账、全部child/root实际signal。"""
        started = time.monotonic()
        deadline = started + timeout
        self._check(self.api.TerminateJobObject(self.job, 1), "TerminateJobObject")
        accounting = self.Accounting()
        while True:
            self._check(self.api.QueryInformationJobObject(self.job, 1, ctypes.byref(accounting), ctypes.sizeof(accounting), None), "QueryInformationJobObject")
            if accounting.activeProcesses == 0:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("Owned job did not reach zero active processes before cleanup deadline")
            time.sleep(min(0.01, max(0, deadline - time.monotonic())))
        children = []
        for pid, handle in self.observed.items():
            result = self._wait_until(handle, deadline, "observed owned child pid=" + str(pid), timeout)
            children.append({"pid": pid, "ownedJobBeforeCleanup": True, "processHandleSignaledAfterCleanup": True,
                             "waitResult": result})
        root_result = self._wait_until(self.handle, deadline, "owned root pid=" + str(self.pid), timeout)
        self._read_exit_code()
        return {"kind": "windows-job-list", "atomicJobAssignment": True, "activeProcessesAfterCleanup": 0,
                "observedChildren": children, "rootProcessHandleSignaledAfterCleanup": True, "rootWaitResult": root_result,
                "cleanupBudgetSeconds": timeout, "cleanupElapsedSeconds": round(time.monotonic() - started, 6)}

    def close(self):
        """任何分支关闭本方job触发KillOnClose兜底；只关闭自己持有的句柄。"""
        if self.job:
            self.api.CloseHandle(self.job); self.job = None
        for handle in self.observed.values():
            self.api.CloseHandle(handle)
        self.observed.clear()
        if self.handle:
            self.api.CloseHandle(self.handle); self.handle = None
