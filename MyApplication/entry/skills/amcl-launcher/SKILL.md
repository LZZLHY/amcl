---
name: amcl-launcher
description: 查询及管理 AMCL 的游戏实例、下载资源、账号、控制布局、设置、活动记录与支持；通过原启动器完成用户确认。
---

## 触发场景

用户明确希望在 AMCL 中查询实例、安装游戏、管理资源或调整设置时，选择下面语义匹配的方法。需要账号授权、文件选择、公开分享或删除确认时，提示用户在原界面继续。
游戏内角色操作、系统备份指令、任意网址、任意文件读写、设备命令和开发 QA 授权不属于这些方法。
busy 表示另一调用或业务操作正在进行；unavailable 表示产品、当前页面或准入条件不符；unknown 表示结果尚未证实，先读取原任务或产品状态。不要重放不确定的写操作。
遇到 needsUser 且 reason 为 awaitingUser 时，先请用户完成当前界面决定。用 getLauncherHandoff 传回原 method 与 operationRef 查询原结果。只要该引用仍在等待，就不要重新发起原操作。
以下为 ExecuteResult.result 的契约；code 表示脚本处理结果，业务状态单独判断。位置参数按 arg1、arg2 的次序传入；省略中间可选值时须在该位置传空字符串。

## 业务方法

按用户目标读取对应的一层能力契约。每个方法给出调用话术、位置参数、返回状态和使用边界。

- [账号、登录与离线外观](references/account-layout-1.md)
- [皮肤披风、角色与布局清单](references/account-layout-2.md)
- [布局导入导出和工作台](references/account-layout-3.md)
- [控件编辑、输入与保存结果](references/account-layout-4.md)
- [导出范围、检查计划、保存与任务结果](references/exports-1.md)
- [首页、实例清单与版本设置](references/instances-1.md)
- [版本安装、启动、存档与文件](references/instances-2.md)
- [实例文件、目录与资源目标](references/instances-3.md)
- [资源搜索、安装与已装内容](references/instances-4.md)
- [模组检查、更新与下载队列](references/instances-5.md)
- [队列控制、整合包选择与资源来源](references/instances-6.md)
- [版本维护、详情与运行要求](references/instances-7.md)
- [查找设置、外观、内存与存储](references/settings-1.md)
- [图形、分辨率、日志与设备输入](references/settings-2.md)
- [诊断、Java 版本与启动器更新](references/settings-3.md)
- [更新进度、设置交接与移动端输入](references/settings-4.md)
- [启动、日志、消息与关于](references/support-1.md)
- [发布记录、活动证据与分享](references/support-2.md)
- [存储、通知、技术支持及备份](references/support-3.md)
- [分享、用户选择及操作回执](references/support-4.md)
