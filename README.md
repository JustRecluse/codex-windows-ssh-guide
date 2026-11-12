# Codex / ChatGPT 桌面端 SSH 连接 Windows 远端

一份基于真实排查整理的实战手册。

- **正文**：[codex-windows-ssh-guide.md](codex-windows-ssh-guide.md)
- **脚本**：[shims/](shims) — 与线上实际部署版本哈希一致

## 一句话结论

Codex 桌面端的 SSH 远端并非不支持 Windows，而是它的引导脚本假设 POSIX shell，
且默认假设远端能长期驻留后台进程。补齐四件事即可跑通：Git Bash 默认 shell、
`SHELL` 环境变量、可脱离会话的 app-server 启动方式、正确的 socket 目录属主。
