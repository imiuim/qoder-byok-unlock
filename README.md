# Qoder BYOK Unlock

一键解锁 Qoder（Windows）自定义模型 / 自带 Provider（BYOK）在**全部产品面**的使用——包括普通会话与**智能体团队（多智能体）**。

适用版本：**Qoder 0.5.x**（在 0.5.6 上开发并实测通过；锚点为内容匹配，0.5.x 小版本差异大多可自适应）。

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
