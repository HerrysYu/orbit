# 文档

[English](README.md) | **简体中文**

从[项目介绍与部署指南](../README.zh-CN.md)开始。各份公开文档的标题附近都有语言切换链接；默认 README 和技术文档入口使用英文，中文版通过对应链接保留。

## 部署与使用

- [Mac Host](../host/README.zh-CN.md)：安装、启动／关闭／重启、Android 手机准备、通知、上下文管理和清除聊天记录。
- [Relay](../relay/README.zh-CN.md)：Cloudflare 部署、APNs 配置、路由、限制与实验性 ADB 隧道。
- [MCP 服务](mcp-services.zh-CN.md)：内置服务、已连接的办公工具、本地配置与 ModelScope 导入。
- [Skills](../skills/README.zh-CN.md)：技能目录和安装方法。各技能都有英文阅读版；运行时仍加载现有的中文 `SKILL.md`。

## 架构与实现参考

- [技术方案 v0.1](方案.md)：系统架构、连接方案、Host、iOS App 和拟定的实施阶段。
- [线协议](protocol.zh-CN.md)：身份、配对、加密、传输、请求、事件和数据结构。
- [手机 UI 自动化迁移](手机UI自动化-执行步骤.md)：交给实施 agent 的迁移步骤与当时确认的决策。
- [iOS 加密测试向量](../ios/OPATests/VECTORS.zh-CN.md)：共用的互通向量及其使用方式。

## App 设计参考

- [Orbit App 设计简报](design/orbit-app-design.zh-CN.md)
- [iOS 重设计实施计划](design/implementation-plan.zh-CN.md)
- [Wave 2 实施简报](design/wave2-briefs.zh-CN.md)
- [新方向 v2](design/v2-direction.zh-CN.md)

设计和迁移文档记录了项目的不同阶段。请先查看各文档中的状态说明，再判断其中的提案或计划步骤是否已实现。
