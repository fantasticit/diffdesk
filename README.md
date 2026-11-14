# Diffdesk

Diffdesk 是一个轻量的 macOS Git 审阅工具，适合在一个窗口里检查多个仓库的改动。打开包含 Git 仓库和 worktree 的父目录，就可以逐个查看 AI 或其他工具改过的文件。

Diffdesk 使用 SwiftUI 和 AppKit，直接调用本机 Git。

## 能做什么

- **多仓库浏览**：自动发现 Git 仓库和 linked worktree，分批显示状态。可按仓库名称、分支或路径模糊搜索。
- **变更文件树**：在同一栏展开目录。可按文件名或路径模糊搜索，也可筛选未提交或已提交未合入的改动。
- **代码对比**：查看完整文件或左右对比。文本对比支持同步滚动、高亮增删行，以及跳到上一处或下一处改动。
- **文件预览**：支持图片、PDF 和系统可播放的音视频。Office 文档等其他格式由 macOS 快速查看处理，支持范围取决于系统。
- **Git 操作**：编辑并保存工作区文件、按文件暂存和取消暂存、提交暂存区，以及更新远端引用。

「已提交未合入」显示从所选基准与当前分支的共同祖先到 `HEAD` 的净改动。基准来自本地 Git 引用，可在仓库菜单中更改。使用 squash merge 的仓库中，显示的分支差异可能和 GitHub 的 PR 合入状态不同。

## 从源码运行

需要 macOS 14 或更高版本、Swift 6 工具链，以及本机 Git。可通过 Xcode 或 Xcode Command Line Tools 安装工具链。

```sh
git clone https://github.com/fantasticit/diffdesk.git
cd diffdesk
./scripts/build-app.sh
open dist/Diffdesk.app
```

应用构建为当前 Mac 的架构，默认使用临时签名。打开应用后，按 `⌘O` 选择工作区父目录，或用下面的命令直接打开指定目录。

```sh
open dist/Diffdesk.app --args --workspace "$HOME/Documents/code"
```

| 快捷键 | 操作 |
| --- | --- |
| `⌘O` | 打开工作区 |
| `⌘R` | 刷新工作区 |
| `⌘S` | 保存正在编辑的文件 |

## 分发签名

如果钥匙串中已有有效的 Developer ID Application 签名身份，可以使用该身份构建。脚本会启用 Hardened Runtime、添加安全时间戳并验证签名。Apple 公证需要另行提交。

```sh
./scripts/build-app.sh --developer-id "Developer ID Application: Your Name (TEAMID)"
```
