# diff+

diff+ 是一个轻量的 macOS Git 审阅工具，适合在一个窗口里检查多个仓库的改动。打开包含 Git 仓库和 worktree 的父目录，就可以逐个查看 AI 或其他工具改过的文件。

diff+ 使用 SwiftUI 和 AppKit，直接调用本机 Git。在 macOS 27 上，仓库导航、三栏和工具栏采用系统原生样式。

## 能做什么

- **多仓库浏览**：自动发现 Git 仓库和 linked worktree，分批显示状态。可按仓库名称、分支或路径模糊搜索，也可以只看有变更的工作树。「文件」菜单可重新打开最近使用的工作区。
- **变更文件树**：在同一栏展开目录。可按文件名或路径模糊搜索，也可筛选未提交或已提交未合入的改动。
- **代码对比**：在并排、行内和完整文件之间切换。文本对比显示增删行数、改动位置和行内字符高亮，并排模式支持同步滚动。勾选「忽略行内空白」可略过缩进、空格和制表符差异。
- **文件内搜索**：输入文本后显示匹配数量、高亮并跳转。并排模式可选择左侧或右侧，行内模式搜索当前展示的增删行和上下文，完整文件模式搜索当前版本或编辑中的内容。
- **文件大纲**：点击「大纲」查找 Markdown 标题或 Swift、JavaScript、TypeScript、Python、Rust、Go 的常见声明，点击一项跳到对应行。对比时可切换大纲版本。文本区域右缘的缩略图显示可见范围与改动位置，可点击或拖动跳转。
- **文件预览**：支持图片、PDF 和系统可播放的音视频。Office 文档等其他格式由 macOS 快速查看处理，支持范围取决于系统。
- **Git 操作**：编辑并保存工作区文件、按文件暂存和取消暂存、提交暂存区，以及更新远端引用。

「已提交未合入」显示从所选基准与当前分支的共同祖先到 `HEAD` 的净改动。基准来自本地 Git 引用，可在仓库菜单中更改。使用 squash merge 的仓库中，显示的分支差异可能和 GitHub 的 PR 合入状态不同。

## 从源码运行

运行需要 macOS 14 或更高版本以及本机 Git。重新构建需要含 macOS 27 SDK 的 Xcode 或 Command Line Tools。

```sh
git clone https://github.com/fantasticit/diffdesk.git
cd diffdesk
./scripts/build-app.sh
open 'dist/diff+.app'
```

应用构建为当前 Mac 的架构，默认使用临时签名。打开应用后，按 `⌘O` 选择工作区父目录，或用下面的命令直接打开指定目录。

```sh
open 'dist/diff+.app' --args --workspace "$HOME/Documents/code"
```

| 快捷键 | 操作 |
| --- | --- |
| `⌘O` | 打开工作区 |
| `⌘R` | 刷新工作区 |
| `⌘S` | 保存正在编辑的文件 |
| `⌘F` | 在当前文件中搜索 |
| `⌘G` / `⇧⌘G` | 下一个 / 上一个搜索匹配 |
| `Esc` | 在搜索框内关闭搜索 |
| `⇧⌘F` | 筛选变更文件 |
| `⇧⌘O` | 显示或隐藏文件大纲 |
| `⌥⌘↑` / `⌥⌘↓` | 跳到上一处 / 下一处改动 |

## 分发签名

如果钥匙串中已有有效的 Developer ID Application 签名身份，可以使用该身份构建。脚本会启用 Hardened Runtime、添加安全时间戳并验证签名。Apple 公证需要另行提交。

```sh
./scripts/build-app.sh --developer-id "Developer ID Application: Your Name (TEAMID)"
```
