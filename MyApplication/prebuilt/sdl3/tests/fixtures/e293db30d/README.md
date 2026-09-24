# SDL 宿主初始化测试的冻结上游输入

本目录不是 SDL 源码替代实现。`src/SDL.c`、`src/events/SDL_events.c` 和
`LICENSE.txt` 是从 `icculus/SDL` 的精确提交
`e293db30d74cca888eafba4e27f0c894f128e67d` 通过 `git show <commit>:<path>`
取得的完整、未修改文件；本地 `git hash-object --no-filters` 与该提交中对应 blob
逐项核对一致。原文件头及完整 Zlib 许可证原样保留，不能删除或改署名。

`manifest.json` 冻结每个文件的大小、SHA-256、Git blob SHA-1、来源 URL、提交和许可证。
目录内 `.gitattributes` 禁止自动 CRLF 转换，摘要按原始字节核对，不通过规范化修复坏文件。

用途只有一个：普通 CI 不初始化 SDL 仓库时，`scripts/test-sdl3-host-runtime.mjs`
仍能把实际 pinned 上游源码与 AMCL 的 0013 补丁在内存合并，编译执行相同的
`SDL_InitSubSystem` 和递归、引用计数、宿主准备函数，不能跳过行为测试。

- `--repo <path>` 明确指定只读 SDL 仓库；路径无效或缺 pin 必须失败，不回退。
- 默认依次检查 `prebuilt/sdl3/sdl3_src`、工作区相邻的 `sdl3-ohos`；都未初始化才使用本目录。
- `--fixture-only` 强制无 SDL 仓库路线，仍执行完整宿主编译和运行。
- 有仓库时同时验证 fixture，并将仓库的 pinned blob 与 fixture 原始字节逐项对照。
- `deps.lock` 的 SDL commit 变化、摘要不符、缺文件或元数据失效均必须失败。

升级 SDL pin 时，应从新的精确 Git 提交重新冻结完整文件和许可证、记录来源与摘要，
并同时验证 repo/fixture 两条路径；不得只改 manifest 来掩盖经过手工修补的输入。
