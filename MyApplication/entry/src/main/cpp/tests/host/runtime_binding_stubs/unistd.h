#pragma once
// PID 可独立改变，验证 fork 继承快照不可使用，不在宿主真实 fork JVM。
int getpid();
