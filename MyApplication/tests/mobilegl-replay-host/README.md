# MobileGL host replay 外部资格

此目录只调度fork现有CMake/CLI及唯一trace manifest，不实现GL或SSIM，也不授予产品准入。
`provider_observer.c`只记录replay真正dlsym的GL/EGL函数归属与当前进程mapped DSO；不替换返回。
薄证据门在宿主Node执行，拒绝缺golden、foreign/fallback、旧PID、强杀、坏报告和缺必需case。
fixture来自实际成功host报告，仅用于schema负例，不当作再次执行或规范oracle。

主工程固定Compose入口：

```powershell
python -B docker/project.py test --suite mobilegl-replay-host `
  --mobilegl-source <完整钉版standalone Git种子> --mobilegl-expected-source <40位独立提交> `
  --mobilegl-icd <可选已验ICD输入目录> --mobilegl-artifacts <可选明确已验host artifacts>
  # 使用artifacts时另加 --mobilegl-artifact-proof-sha <宿主独立实取build-source.json SHA>
```

默认跑OpenRA的DirectGLES/DirectVulkan。通过test-arg传`--mode controls`执行三真实负控；
通过`--backends DirectGLES`可明确限定host域，不能借为现役DirectVulkan资格。
直接公共克隆/CI可运行`run-host.py --source ... --output <仓外路径> --expected-source ...`采集，
随后宿主`node scripts/check-mobilegl-replay-evidence.mjs --bundle <输出> --required-runs <独立请求JSON>`
另传`--host-artifacts`、`--host-source`、`--expected-source`、`--host-proof-sha`及适用的`--host-icd`裁决；
官方project.py已把两段串成一门。独立手调不可仅把Python采集0当qualified。
Node门直接重新读取原result/provider/invocation/maps/PNG，重新计算宿主指定DSO、CLI、
trace/golden/source/ICD字节SHA；不使用evidence.json快照授予资格。PNG摘要在Popen事务
实取后固定，随后替换或截断不能借旧SSIM；PNG校验只读完整容器/CRC，不重算像素比较。
源码/输出路径均显式，不要求维护者盘符。必需LFS实际archive/golden、submodule和known_good
缺失就失败/NOT_RUN，不生成模板数据或静默skip。

fresh构建从Git objects展开仓外snapshot，每个必需submodule验证完整pin，glslang external
依known_good恢复；tracy/Diligent/frametrim测试在原配置disabled时不伪装已初始化。
`host-glx-display.patch`仅是本轮Linux GCC13 type lookup测试来源delta，不在prebuilt设patches
目录，不修改消费fork或OHOS pin；原fields/ownership/行为不变，必须在机器收据显式标为
base+delta。正式依赖更新仍按MobileGL fork commit治理流程办理。

reuse artifacts必须含`build-source.json`的base commit、hostDeltaSha256、改动文件SHA、
两个实际文件SHA及原build manifest关联。它减少重复编译，不能从filename/版本字符串猜
来源。调用方必须另传独立实取的收据SHA，不能让可修改收据用自己的摘要验证自己。
原CMake cache、image ID、compiler/flags及完整构建记录须作为外部收据保留。

ICD目录需提供`lvp-runtime.json`/`libvulkan_lvp.so`以及可追溯source-receipt。runner只在本次
输出改JSON library_path，不改driver/system/image。无ICD的DirectVulkan环境失败不转隐藏
window或普通GL；最终进程maps必须包含指定driver，摘要也必须一致。

固定OpenRA/golden来源在forkmanifest，历史捕获GPU/driver未完全记录，结果只能写固定
fixture回归。显式GLReadBuffer/error适配仍如实记录；不得称完整GL/CTS/OHOS/GPU/世界或
生命周期通过。便宜Node负例进入graphics-profile-inventory，完整host suite是显式较重门。
