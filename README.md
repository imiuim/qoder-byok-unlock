# Qoder BYOK Unlock

一键解锁 Qoder（Windows）自定义模型 / 自带 Provider（BYOK）在**全部产品面**的使用——包括普通会话与**智能体团队（多智能体）**。

适用版本：**Qoder 0.5.x**（0.5.6 / 0.5.7 均已适配）。

> **0.5.7 用户注意**：Qoder 更新后把 `app.asar` 从 `.qoder-versions\<版本>\resources\` 移到了 `<安装目录>\resources\`。旧版 `unlock.ps1` 和看门狗会继续盯着旧目录，导致"补丁在位"但实际运行的是未打补丁的新版本，团队对话失效并回退到官方模型（服务端返回 403 code 112）。**请用 `unlock-v2.ps1`**（自动识别两种布局）；`watchdog.ps1 -AutoRepair` 已同步支持新布局。

## 逆向后发现的三层锁

| 层 | 位置 | 锁 |
|---|---|---|
| UI 层 | `resources/app.asar`（渲染层 bundle） | 模型目录 `filter(M=>!M.byok&&!M.outerProvider)` 删光自定义模型；provider 只留 `default` |
| 主进程 | 同上 | 能力门 `zXe/R7x` 把 turn 请求的模型吞成 undefined；团队表单 `E=V==="cloud"` 把成员模型选择整体接管成官方目录 |
| Worker | `app.asar.unpacked/.../qoder-worker-runtime.obf.mjs` | `allow_byok>=2` 服务端阈值；团队 daemon 的 `customProviderSettings` 未装配 → 路由 403「Custom Provider model not available」 |

另外 `Qoder.exe` 开启了 **Electron ASAR Integrity fuse**——app.asar 改一个字节就拒绝启动，脚本会先翻转该 fuse。

## 使用

要求：Windows + Node.js（>=18，用于 @electron/fuses 与语法自检）+ npm。

```powershell
# 应用全部补丁（自动结束 Qoder 进程）
powershell -ExecutionPolicy Bypass -File unlock.ps1

# 一键回滚
powershell -ExecutionPolicy Bypass -File unlock.ps1 -Rollback
```

脚本行为：

1. 自动定位 Qoder 安装（启动器 ini / 注册表 / 各盘符 `Qoder` 目录 / `%LOCALAPPDATA%\Programs\Qoder`），取 `.qoder-versions` 下语义化版本最新的一个；
2. 结束 Qoder 进程并等待真正退出；
3. **先备份 Qoder.exe，再**翻转 ASAR integrity fuse（顺序保证备份是修改前的原版）；
4. 打 6 处补丁（P1–P4 改 app.asar，P5–P6 改 worker；全部等长/内容锚点校验、唯一性检查、`.bak-unlock` 备份、幂等可重跑，app.asar 与 worker 均原子写盘）；
5. 有补丁未命中时以非零码失败并明确列出，不会假报成功。

补丁清单：

- **P1** 渲染层模型目录不再删除 BYOK/外部 provider 模型
- **P2** 渲染层 provider 过滤门放行
- **P3** 主进程模型吞没门恒放行（`R7x`/`zXe` 两种形态自动识别）
- **P4** 智能体团队表单 `E=V==="cloud"` 恒假（成员模型可选）
- **P5** worker `allow_byok` 阈值 `>=2 → >=1`（团队 turn 的服务端开关校验降级）
- **P6** worker SE 路由函数注入**同步回退**：团队 daemon 的 registry 未注册 provider 时，现场从 `~/.qoder/settings.json` 读取 providers 重建注册表再解析 route（这是「系统发生异常」的根因修复）

## 回滚

所有被改文件都有同目录 `.bak-unlock` 备份，`-Rollback` 一键还原（asar + worker + exe），并通过 `restore-fuse.ps1` 重新开启 ASAR integrity fuse，恢复出厂的完整性校验行为。也可以手动把备份复制回原名后单独执行：

```powershell
powershell -ExecutionPolicy Bypass -File restore-fuse.ps1 -ExePath "E:\Qoder\.qoder-versions\<ver>\Qoder.exe"
```

> 注：由 v1.x 脚本（fuse 备份顺序有误的旧版）创建的 `.bak-unlock` exe 备份本身就是 fuse 已关闭的状态，用旧备份回滚后请务必补跑 `restore-fuse.ps1`。

## 更新日志

### 2026-11-09（v1.5 fuse 与 BOM 两个致命 bug）

- **fuse 翻转静默失效**：`@electron/fuses@1.3.0` 的 `FuseV1Options` 只导出 `RunAsNode`/`EnableCookieEncryption` 两项，`EnableEmbeddedAsarIntegrityValidation` 为 `undefined`，`flipFuses` 收到 `{"undefined":false}` 什么都不做。结果：脚本报"fuse 已关闭"，但 wire 里 index 4 仍是 `49`(开)，改完 asar 后 Qoder 直接拒绝启动。
  修复：`unlock-v2.ps1` / `restore-fuse.ps1` 不再依赖枚举，按 wire 布局(`SENTINEL + 2 + 4`)直接读写字节，并在改 asar 前二次校验确认为 `48`(关)。
- **settings.json BOM**：PowerShell 5.1 的 `Set-Content -Encoding UTF8` 会写 BOM，Qoder 解析时报 `[main-model-anchor] read user settings failed: SyntaxError: Unexpected token '\uFEFF'`，导致默认模型/上次选中模型读不到 → 新窗口回退官方 `auto` → 走服务端 403 `code 112` → 弹"无法继续团队对话"。
  修复：`watchdog.ps1` / `migrate.ps1` 一律改用 `UTF8Encoding($false)` 无 BOM 写入。
- 0.5.7 实测：重启后 `main-model-anchor` 报错消失、112=0、自定义模型 18/18 可见且 `group/chain` enabled、fuse=48、providers=1。

### 2026-11-09（v1.4 适配 Qoder 0.5.7 自动更新）

- **根因**：0.5.7 起 `app.asar` 改为 `<安装目录>\resources\app.asar`(根目录布局)，不再在 `.qoder-versions\<版本>\`。自动更新后旧补丁全部落空，运行的是干净版本；团队会话回退到官方 `auto` 模型 → 请求打向 Qoder 服务端 → 403 `code 112` → 提示无法继续团队对话。
- **新增 `unlock-v2.ps1`**：自动识别两种布局；P3 门控在 0.5.7 已移除则跳过；P6 按版本自适应(`SE/hn` → `DE/En`)，改为保留原函数的最小注入(通过 `process.getBuiltinModule` 读 settings.json，不依赖混淆名)，写入前对整个 worker 执行 `node --check`；fuse、备份、原子写、幂等一并具备。
  ```powershell
  powershell -ExecutionPolicy Bypass -File unlock-v2.ps1
  ```
- **watchdog 同步**：优先识别根目录布局，兼容两种 P6 特征，自动修复改调 `unlock-v2.ps1`，日志标注布局。
- 0.5.7 实测：P1/P2/P4/P5/P6 全部命中(P3 无需)，watchdog 报告 `Qoder (root布局) 补丁在位`。

### 2026-11-09（v1.3 迁移可靠性 + 配置自愈）

- **新增 `migrate.ps1`**：把 Qoder 用户数据安全迁到其他盘（junction 方式），修复手工迁移导致"重启后自定义模型消失"的三个 bug：
  1. 目标目录存在就报 `skip-done`，但源目录根本不是 junction —— 迁移假成功；现在先判断源是否合法 junction，是则只验证；
  2. 建完 junction 不验证属性，被应用重建/替换也无人发现；现在验证 `ReparsePoint` 属性与目标可达性，失败自动回滚；
  3. 迁移不校验 `settings.json` 的 BYOK providers，配置丢失无感知；现在按"谁有 providers 谁为准"合并，并校验结果。
  ```powershell
  # 迁移到 E 盘（自动停 Qoder、迁移、建 junction、校验、重启）
  powershell -ExecutionPolicy Bypass -File migrate.ps1 -TargetRoot E:\QoderData
  # 只体检，不改动
  powershell -ExecutionPolicy Bypass -File migrate.ps1 -TargetRoot E:\QoderData -VerifyOnly
  ```
- **watchdog 增加 provider 配置自愈**：每次检查维护 `~/.qoder/providers.snapshot.json` 快照；发现 `settings.json` 的 providers 为空（重启/迁移后模型消失的主因）时，日志报警，`-AutoRepair` 模式下自动从快照恢复。实测通过。

### 2026-11-08（v1.2 看门狗）

- **新增 `watchdog.ps1`**：定时校验当前运行版本的 BYOK 补丁是否在位（只读检查，node 校验 asar/worker 特征串）；失效时可选 `-AutoRepair` 自动重跑 unlock.ps1 并重启 Qoder。日志写入 `watchdog.log`，状态存 `watchdog.state.json`（避免每次轮询刷日志）。
  ```powershell
  # 只查一次
  powershell -ExecutionPolicy Bypass -File watchdog.ps1 -CheckOnce
  # 常驻看门狗：每 5 分钟检查，失效自动修复（会结束并重启 Qoder）
  powershell -ExecutionPolicy Bypass -File watchdog.ps1 -AutoRepair
  # 自定义间隔
  powershell -ExecutionPolicy Bypass -File watchdog.ps1 -IntervalSec 600 -AutoRepair
  ```
  注意：看门狗只能修复"客户端补丁丢失"（Qoder 更新/版本切换覆盖了 asar 或 worker）；智能体团队的服务端模型目录限制、BYOK 服务未就绪的瞬时抖动不属于可修复范围。

### 2026-11-08（v1.1 安全与健壮性修复）

- **修复 fuse 备份顺序**：旧版先翻转 fuse 再备份 Qoder.exe，导致 `.bak-unlock` 存的是已修改状态，回滚无法恢复原版；现在先备份后翻转。
- **新增 `restore-fuse.ps1`**：回滚时重新开启 ASAR integrity fuse，恢复 Qoder.exe 出厂校验行为。
- **修复 launcher ini 探测正则**：`$` 单行模式下永不命中，改为逐行匹配 `^installDir=`。
- **修复诊断函数反斜杠丢失**：`Show-LauncherDiag` 源码损坏导致路径全是 `%LOCALAPPDATAQoder...` 垃圾输出，已重写为正确路径。
- **修复版本目录排序**：字符串排序在 0.5.10 起会选错版本，改为按 `[version]` 排序。
- **修复 `Pad()` 负数崩溃**：填充空间不足时显式失败而非 `' ' * -1` 抛异常。
- **补丁未命中不再假成功**：汇总未命中项并以非零退出码失败。
- **app.asar / worker 原子写盘**：临时文件 + 替换，避免中途崩溃留下截断文件。
- **驱动器探测动态枚举**：不再硬编码 `G:\Qoder`（无 G 盘的机器上会直接抛 DriveNotFoundException）。
- **`@electron/fuses` 版本锁定**（1.3.0，`--save-exact`）。
- **移除 `tok.ps1` / `readcred.ps1`**：两个读取 Windows 凭据管理器中 GitHub token 的调试脚本与解锁功能无关，且其一将 token 明文写入 `%TEMP%` 不清理，已从仓库删除。

## 注意

- Qoder **自动更新后**（版本目录变化或 asar 重新下载）需重跑本脚本。
- 脚本只改本机安装，不碰你的账号与服务端；服务端 `allow_byok` 开关值不会变，本方案是让客户端校验与本地执行链路对齐。
- 仅供个人学习研究，请自行承担使用风险。
