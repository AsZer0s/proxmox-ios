<div align="center">
  <img src="ProxmoxManager/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="128" height="128" alt="Proxmox Manager App 图标">

# Proxmox Manager

**把 Proxmox VE 装进口袋。**

一款为 iPhone 与 iPad 打造的原生 Proxmox VE 管理客户端。<br>
随时查看集群状态、管理虚拟机与容器，并安全地处理日常运维任务。

[English](README.md) · 简体中文

![iOS 16+](https://img.shields.io/badge/iOS-16.0%2B-0A84FF?style=flat-square&logo=apple)
![SwiftUI](https://img.shields.io/badge/Interface-SwiftUI-0A84FF?style=flat-square)
![Proxmox VE 6+](https://img.shields.io/badge/Proxmox%20VE-6.0%2B-E57000?style=flat-square)
![License](https://img.shields.io/badge/License-MIT-34C759?style=flat-square)
</div>

---

## 随时掌控你的 Proxmox 集群

Proxmox Manager 直接连接你的 Proxmox VE 服务器，以符合 iOS 使用习惯的方式呈现节点、虚拟机、LXC 容器、存储与任务状态。无需在手机浏览器中操作桌面网页，也无需经过第三方中转服务。

无论是快速巡检、处理异常实例，还是创建与调整工作负载，都可以在一个清晰、原生的界面中完成。

## 核心功能

| | |
|---|---|
| **集群与节点** | 查看多节点状态、在线时间、负载以及 CPU、内存和磁盘使用情况。 |
| **虚拟机与容器** | 集中浏览 QEMU 虚拟机与 LXC 容器，支持按名称、VMID、节点和状态搜索筛选。 |
| **生命周期管理** | 启动、重启、正常关机或强制停止实例，并通过确认提示降低误操作风险。 |
| **创建与配置** | 创建、编辑、删除及完整克隆虚拟机和容器，调整 CPU、内存、启动选项等配置。 |
| **硬件管理** | 添加、扩容、迁移、分离和删除磁盘，并管理 CD/DVD、启动顺序、EFI、TPM、PCI、USB、串口及高级网络参数。 |
| **Cloud-Init** | 添加 Cloud-Init Drive，并管理用户、SSH 公钥、DNS、软件包升级以及 IPv4 / IPv6 网络配置。 |
| **快照** | 创建、回滚和删除快照，可选择是否保存虚拟机运行状态。 |
| **存储与备份** | 查看存储内容，管理备份计划、保留与清理策略、备份归档、恢复及保护状态。 |
| **迁移** | 在兼容的集群节点之间迁移虚拟机与容器，支持本地磁盘迁移和目标存储映射。 |
| **防火墙** | 管理实例防火墙选项、规则、安全组引用、IPSet、IPSet 条目与防火墙日志。 |
| **控制台** | 使用密码、TOTP 或 API Token 连接时，可打开内置 noVNC、LXC 终端与节点 Shell。 |
| **安装介质** | 从 URL 导入 ISO，或浏览并下载 Proxmox LXC Appliance Templates。 |
| **性能图表** | 查看节点或实例的 CPU、内存、网络和磁盘历史数据，支持小时、天、周视图。 |
| **任务中心** | 跨节点查看持久化的服务器任务历史、结果与日志，并可取消仍在执行的任务。 |
| **节点维护** | 管理节点服务、刷新软件包索引、查看可用更新，并安全地重启或关闭节点。 |

## 安全连接

- 支持用户名密码、API Token 与 TOTP 双重验证
- 密码、Token Secret 与证书指纹保存在 iOS Keychain
- 支持由可信 CA 签发的证书
- 自签名证书首次连接时显示 SHA-256 指纹并要求确认
- 已固定的证书发生变化时自动拒绝连接
- 可使用 Face ID 锁定 App，进入后台时自动遮挡敏感界面
- 会话失效后自动重新认证，减少重复登录
- 所有连接均由设备直接发往你的 Proxmox VE，不依赖云端中转

## 原生移动体验

- 为 iPhone 与 iPad 设计的 SwiftUI 界面
- 支持简体中文与英文
- 前台自动刷新，支持下拉手动刷新
- 根据当前 Proxmox 账户权限显示可用操作
- 对强制停止、删除、快照回滚等高风险操作提供明确确认
- 深色模式、动态字体与系统原生交互

## 兼容性

- iOS / iPadOS 16.0 或更高版本
- Proxmox VE 6.0 或更高版本
- 支持单节点及多节点集群
- 可使用密码或 API Token 连接

部分管理功能需要对应的 Proxmox VE 权限；权限不足时，App 会隐藏相关操作或给出提示。

## 隐私

Proxmox Manager 不包含广告或用户追踪，不收集个人数据。服务器信息与凭据保存在设备本地，运行数据直接从你配置的 Proxmox VE 获取。

## 声明

Proxmox Manager 是独立开发的第三方客户端，与 Proxmox Server Solutions GmbH 无隶属或官方合作关系。Proxmox 及 Proxmox VE 是其各自所有者的商标。

## 许可

本项目采用 [MIT License](LICENSE)。
