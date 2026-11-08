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

1. 自动定位 Qoder 安装（支持 `G:\Qoder` / `D:\Qoder` / `C:\Qoder` / `%LOCALAPPDATA%\Programs\Qoder`），取 `.qoder-versions` 下最新版本；
2. 结束 Qoder 进程；
3. 翻转 ASAR integrity fuse（exe 备份 `.bak-unlock`）；
4. 打 6 处补丁（P1–P4 改 app.asar，P5–P6 改 worker；全部等长/内容锚点校验、唯一性检查、`.bak-unlock` 备份、幂等可重跑）；
5. 提示启动 Qoder 实测。

补丁清单：

- **P1** 渲染层模型目录不再删除 BYOK/外部 provider 模型
- **P2** 渲染层 provider 过滤门放行
- **P3** 主进程模型吞没门恒放行（`R7x`/`zXe` 两种形态自动识别）
- **P4** 智能体团队表单 `E=V==="cloud"` 恒假（成员模型可选）
- **P5** worker `allow_byok` 阈值 `>=2 → >=1`（团队 turn 的服务端开关校验降级）
- **P6** worker SE 路由函数注入**同步回退**：团队 daemon 的 registry 未注册 provider 时，现场从 `~/.qoder/settings.json` 读取 providers 重建注册表再解析 route（这是「系统发生异常」的根因修复）

## 回滚

所有被改文件都有同目录 `.bak-unlock` 备份，`-Rollback` 一键还原（fuse + asar + worker）。也可以手动把备份复制回原名。

## 注意

- Qoder **自动更新后**（版本目录变化或 asar 重新下载）需重跑本脚本。
- 脚本只改本机安装，不碰你的账号与服务端；服务端 `allow_byok` 开关值不会变，本方案是让客户端校验与本地执行链路对齐。
- 仅供个人学习研究，请自行承担使用风险。
