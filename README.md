# Agent Pet

一个运行在 Mac 桌面上的悬浮小桌宠。鼠标移入桌宠时，展开任务族面板，查看正在运行、等待处理和本轮已结束的 agent 会话。

## 启动

需要 macOS 与 Command Line Tools 中的 Swift 编译器；收集器使用系统自带的 Python 3，不需要 API 密钥。

在仓库根目录执行：

```sh
cd native
./build.sh
open "dist/Agent Pet.app"
```

启动后桌宠显示在屏幕右下角，可拖动；鼠标移入显示面板。面板右上角有刷新、收起和退出按钮。应用退出时会停止它启动的本机收集器。当前版本不会自动添加开机启动项。

面板顶部可在 `GPT`、`Claude`、`Claude Code` 三个分类间切换。`GPT` 汇集 Codex 与 ChatGPT，`Claude` 展示 Claude 网页及 Claude 桌面 Code，`Claude Code` 展示 CLI 会话。每个分类单独显示任务族、状态计数和最近完成。首次打开时默认选择活跃对话最多的分类，数量相同则选择 `GPT`；手动切换后保留所选分类。

## 覆盖范围

| 来源 | 当前可显示的内容 | 边界 |
| --- | --- | --- |
| Codex 桌面任务 | 最近活动的任务、子 agent、回合运行状态、项目分组 | 读取本机 Codex 数据库；旧的残留 `inProgress` 会被时间阈值排除。本轮结束不表示整个目标完成。 |
| Claude Code CLI 与 Claude 桌面 Code | 仍在运行的进程、`busy/idle` 状态、桌面 Code 标题、近期子 agent 活动 | 子 agent 缺少可靠的完成信号；没有证据时标为未知。 |
| ChatGPT 与 Claude 网页聊天 | 安装浏览器伴侣后，已打开的 Chrome/Edge 对话标签的标题、链接和可观察状态 | 只覆盖打开的标签。页面改版或浏览器后台节流可能使状态变成未知。 |
| 普通 ChatGPT/Claude 桌面聊天 | 暂无实时状态接入 | 目前找到的本机缓存不能可靠反映当前运行状态；这些聊天不会被伪装成自动追踪。 |

浏览器伴侣安装方法见 `browser-extension/README.md`。安装时在 Chrome 的 `chrome://extensions` 或 Edge 的 `edge://extensions` 开启开发者模式，选择“加载已解压的扩展程序”，然后选择本项目的 `browser-extension` 文件夹。桌宠运行时，扩展会向本机 `127.0.0.1:56987` 发送已打开对话的观察结果。

## 状态与进度的含义

- **进行中**：Codex 最近启动且仍标为运行中的回合、Claude Code 的活跃进程，或网页上可见的停止生成按钮。
- **等待中**：网页出现明确的允许/拒绝决策框。
- **待后续**：本轮回复结束或会话空闲；不代表用户交给 agent 的整个目标已完成。
- **未知**：本地状态太旧、子 agent 没有明确状态，或浏览器观察过期。
- **需处理**：Codex 最近一轮失败。

若 Claude Code 在当前会话使用了明确的 Task 清单，收集器从 `TaskCreate` 与 `TaskUpdate` 记录计算已完成项/总项；清单长时间没有更新后不再显示这个数字。其他会话没有可信的分母时只显示状态，不生成百分比。

## 本地数据

收集器只读本机 Codex/Claude Code 的任务数据；为提取 `TaskCreate` 与 `TaskUpdate` 的完成数，它会扫描 Claude Code 的 transcript JSONL，其中可能包含消息正文，但不会把正文写入汇总文件或发送到网络。浏览器伴侣只发送对话 ID、标题、无查询参数的网址和可见状态，不发送消息正文。汇总写入 `~/.agent-pet/tasks.json`，目录和文件仅供当前用户访问；HTTP 接收器只绑定 `127.0.0.1`，且只接受浏览器扩展来源。项目不会修改 Codex 或 Claude 的设置，也不会安装 Hooks。

如需删除，退出桌宠，移除浏览器扩展，再删除 `native/dist/Agent Pet.app` 和 `~/.agent-pet`。源码仍保留在本项目中。

## 开发验证

```sh
python3 -m unittest discover -s collector -p 'test_*.py' -v
python3 collector/collector.py --once
```

Codex 和 Claude 的本地文件格式是应用内部实现，升级后可能变化。当前采集器遇到读库或文件错误时会跳过该来源，界面通过数据生成时间提示采集是否过期。

## 许可证

MIT，见仓库根目录的 `LICENSE`。
