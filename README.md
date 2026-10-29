# Codex Quota Lite · 额度

Windows 上的简洁 Codex 额度插件。支持应用内面板与随 Codex 启动的置顶悬浮窗。

这是非官方社区项目，与 OpenAI 无隶属关系。

## 功能

- 查看各额度窗口的剩余百分比、重置时间和更新时间。
- 每分钟后台刷新，读取期间窗口继续响应；关闭时取消读取。
- 多额度池可切换，默认显示 Codex，并记住本次选择。
- 悬浮窗支持拖动、位置记忆和低额度颜色提示。
- 只绑定 Codex 桌面主进程；宿主退出后关闭，不转绑独立 CLI。
- 本地只读查询，无运行时第三方 npm 依赖，无额外开机启动项。

## 要求

- Windows 10/11、Windows PowerShell 5.1。
- 已安装且已登录 ChatGPT 账户的 Codex 桌面版 / CLI。
- Node.js 20 或更新版本。安装脚本也会查找 Codex 已有的 Node 运行时。
- 支持本地插件的 Codex 版本。应用内可视面板取决于宿主对 MCP Apps 的支持。

## 安装

下载并解压源码，或克隆本仓库，在仓库目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

安装脚本把部署文件复制到 `%LOCALAPPDATA%\CodexQuotaLite`，在那里写入本机 Node 路径，再通过 Codex 官方 CLI 注册本地市场与插件。仓库中的通用配置保持不变。

安装后重新打开 Codex，在新对话中输入“打开额度面板”。支持的桌面宿主也会提供插件入口，悬浮窗在插件服务加载时自动启动。

自定义 Node 路径可设置 `CODEX_QUOTA_NODE_PATH`。脚本无法找到 Node 时，请先安装 Node.js 20+。

## 数据与隐私

额度来自本机官方 `codex app-server` 的 `account/rateLimits/read`，查询不会创建模型任务。程序不直接读取或保存登录凭据，也不上传账户数据到项目服务器。

这是 Codex 订阅额度，不是 OpenAI API 或 DeepSeek 的账户余额。缺失值显示为未知；读取失败会保留旧数据并提示失败。

悬浮窗位置保存在 `%APPDATA%\CodexQuotaWidget\state.json`。插件不会修改系统安全设置、创建计划任务或添加开机启动项。

## 开发与验证

```powershell
npm test
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\plugins\quota-lite\test\widget.test.ps1
```

测试覆盖额度转换、错误与超时、子进程取消、stdio 协议、宿主身份、PID 复用、多额度池选择以及慢速读取时的 WPF 调度。真实账户和桌面点击验证不在 CI 中执行。

只准备部署文件而不注册插件：

```powershell
.\Install.ps1 -PrepareOnly -InstallRoot "$env:TEMP\quota-lite-preview"
```

## 卸载

```powershell
codex plugin remove quota-lite@quota-lite-community
codex plugin marketplace remove quota-lite-community
```

卸载后，部署文件和位置记录可以按需手动删除。

## 限制

悬浮窗目前只识别 Windows 上已确认的 Codex 桌面安装路径。多个桌面实例无法明确区分时不启动悬浮窗。其他平台可以复用 Node 后端，但不提供该 WPF 窗口。

## 许可证

[MIT](LICENSE)。
