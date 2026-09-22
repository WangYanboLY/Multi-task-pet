# Agent Pet 原生桌宠

这是 Agent Pet 的 macOS 悬浮界面。桌宠可拖动，并停留在普通窗口上方。光标移到桌宠上时会展开任务面板，移出桌宠与面板后自动收起。面板可手动刷新、打开带链接的对话，也可退出应用。

面板顶部有 `GPT`、`Claude`、`Claude Code` 三个分类。`GPT` 汇集 Codex 和 ChatGPT；`Claude` 展示 Claude 网页及 Claude 桌面 Code；`Claude Code` 展示 CLI 会话。每个分类单独显示活跃任务族、待后续任务族、最近完成和计数。首次打开时默认选择活跃对话最多的分类，数量相同则优先选择 `GPT`；手动切换后保留所选分类。

## 构建与运行

需要 macOS 13 或更新版本、Swift Command Line Tools 和系统自带的 `/usr/bin/python3`。无需 Xcode 工程或第三方依赖。

在本目录执行：

```sh
./build.sh
open 'dist/Agent Pet.app'
```

脚本将相邻的 `collector/collector.py` 放入应用的 `Contents/Resources`。启动应用时会启动采集器；退出应用时会结束它启动的采集器进程。应用不会设置开机自启。

## 数据展示

界面每 3 秒读取一次 `~/.agent-pet/tasks.json`。任务族依据 `family_id` 分组，每条对话保留来源、状态、更新时间及可选的实际完成数。含有 `working` 或 `waiting` 对话的任务族出现在“活跃任务族”，其中也展示该族的其他状态；仅有 `idle`、`failed`、`unknown` 等未完成状态的任务族出现在“待后续与需处理”。只有明确的 `done` 对话出现在“最近完成”。界面不推测完成百分比。

Claude 和 ChatGPT 网页聊天仅覆盖已打开且安装浏览器伴侣的标签页。普通 Claude / ChatGPT 桌面聊天目前没有可靠的实时状态来源；界面不会将缺失数据解释成已完成。

时间同时显示数据生成时间、界面上次检查时间，以及每条对话的更新时间，按电脑本地时区显示。没有数据文件、空数据及读取错误都有明确提示。关闭悬停面板不会退出应用；面板右上角电源按钮会退出应用。
