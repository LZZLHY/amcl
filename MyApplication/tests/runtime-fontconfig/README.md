# 字体 provider 与 FreeType 补全验证

`test_elf_names.py` 检查 provider 动态名称转换的严格边界。`test_source_inputs.py`
检查固定 Meson/gperf 归档首次展开和复用时的正文身份，漂移时保留现场并失败。
该检查只读构建时已下载的固定归档，不联网，不执行其中程序。

`prepare-freetype-inputs.py` 接受三个真实 JDK 仓库及显式外部输出位置，在新建
Git 工作树重放各代完整 series，并重复应用以核对幂等性。按版本来源逐文件
核对后导出六份补前/补后源码 tar 和 `sources.json`。新工作树复用原仓对象库，
故二者及其恢复映射必须一并登记、保留，不能删除原对象库。

标准入口执行行为验证：

```powershell
python -B docker/project.py test --suite fontconfig-freetype --fontconfig-sources <外部目录>/sources.json
```

固定 QA 服务只读挂载该清单与归档；所有解包树、对象、二进制和日志写本轮
独占 `/output/freetype-behavior/`。每代分别编译原有及补全后的所有 `.c`，保持
JDK 自带配置头，使用 ASan/UBSan/LSan。`report.json` 保存实际库和日志摘要。

自有小字体由 `make-fixtures.py` 生成，包含 BDF、PCF 的一个 4×4 字形以及
TrueType 的一个正方形字形。行为驱动真正加载各自构建的库，逐像素比较，
并验证字符编码、charset、atom/integer/cardinal 属性、缺失属性及 SFNT 的
BDF ppem 选择。字体没有借用外部字形素材或测试机系统字体。

负对照必须同时证明原库版本正确、原有 TrueType 渲染正常、BDF 查询导出及
BDF/PCF 驱动缺席，才返回 77。编译失败、任意其他退出码、超时和 sanitizer
错误都使测试失败。补后必须返回 0；不能把不明失败归为“原问题已复现”。

该套件只授予宿主字体服务行为资格。OHOS 完整 JDK 构建、实际 provider 的
所有导入闭包、沙箱字体读取、缓存冷/热复用和 Java Font/ImageIO 必须另验。
