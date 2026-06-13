# Snell Server 多版本一键管理脚本 (V5 / V6 同步共存)

[![License](https://img.shields.io/github/license/github/docs.svg?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu%20%7C%20CentOS%20%7C%20Fedora%20%7C%20Arch-blue.svg?style=flat-square)](https://github.com)

一个功能强大的 Linux Snell Server 交互式一键管理脚本。支持在同一台 VPS 上**同时安装并独立运行 V5 稳定版与 V6 协议**，互不干扰，提供极简的快捷命令操作与全方位的系统优化支持。

---

## 🌟 核心特性

- **🚀 快捷指令开机秒开**：通过一键命令运行后，脚本会自动持久化到系统并注册 `/usr/local/bin/snell`。后续只需在终端敲入 `snell` 即可在 **0.1 秒内秒开管理面板**。
- **👥 双版本无缝共存**：完美隔离并解耦 V5 与 V6 的二进制路径、配置文件、Systemd 服务和版本记录。
- **⚡ 客户端配置聚合提取**：无需繁琐的子菜单切换！选择“查看配置”一键以 Surge / Clash 两个客户端分类直观列出所有已配置的节点，方便跨版本一次性拖选复制。
- **🛡️ 端口碰撞智能拦截**：在安装和修改端口时，脚本将自动探测另一版本占用的端口。发生冲突时予以提示并拦截，规避端口被抢占导致的服务启动失败。
- **🔄 定时升级与安全回滚**：支持自动定时更新（中国时间每天凌晨 03:30）。在更新失败 3 秒后，脚本将自动进行静默回滚并恢复旧版本，确保服务稳定不中断。
- **🛠️ 系统级辅助优化**：内置一键系统时区强制同步（阿里/腾讯 NTP 授时）及一键 TCP BBR 拥塞控制深度加速。

---

## 📥 一键安装与运行

您可以使用以下任意一条命令在您的 Linux 服务器上直接拉取并运行：

### 推荐命令 (使用 curl)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/您的用户名/您的仓库名/main/snell.sh)
```

### 备用命令 (使用 wget)
```bash
wget -qO- https://raw.githubusercontent.com/您的用户名/您的仓库名/main/snell.sh | bash
```

> 💡 **提示**：首次成功运行一键命令后，您无需再次复制此命令。今后只需在您的服务器终端直接输入：
> ```bash
> snell
> ```
> 即可瞬间呼出管理菜单。

---

## 🖥️ 菜单功能预览

运行后您将看到以下精美的交互面板：

```text
  ────────────────────────────────────────────────
   Snell Server 管理脚本
   支持 V5 / V6 同步共存
  ────────────────────────────────────────────────

  V5 状态: ● 运行中   版本: v5.0.1       自启: 是
  V6 状态: ○ 已停止   版本: v6.0.0b2     自启: 否

  ────────────────────────────────────────────────

  1.  安装 Snell
  2.  更新 Snell
  3.  卸载 Snell
  4.  修改配置
  5.  查看配置
  6.  重启服务
  7.  运行日志
  8.  BBR 优化
  9.  时间同步
  10. 定时更新

  0.  退出

  ────────────────────────────────────────────────
```

---

## 📋 客户端支持规范

### 1. Surge 客户端
脚本直接生成对应 V5 / V6 的 `Snell` 节点格式，直接复制粘贴至配置中的 `[Proxy]` 段落使用：
```ini
[Proxy]
Snell-V5 = snell, 您的IP, 端口, psk=您的密钥, version=5, udp-relay=true
Snell-V6 = snell, 您的IP, 端口, psk=您的密钥, version=6, udp-relay=true
```

### 2. Clash 客户端 (Mihomo / Clash.Meta)
由于 Clash 客户端暂未原生支持 V6 的传输层，脚本将自动为您生成对齐的 `version: 5` 格式，在 Clash 中安全降级连接 V6 服务端使用：
```yaml
proxies:
  - name: Snell V5
    type: snell
    server: 您的IP
    port: V5端口
    psk: 您的密钥
    version: 5
    udp: true

  - name: Snell V6
    type: snell
    server: 您的IP
    port: V6端口
    psk: 您的密钥
    version: 5 # 自动降级配置
    udp: true
```

---

## 🔒 卸载与清理

如果您需要卸载：
- 进入菜单输入 `3`。
- 脚本会智能提示您选择：`1. 卸载 V5` / `2. 卸载 V6` / `3. 同时卸载 V5 和 V6`。
- 您可以选择是否彻底清除配置文件。若选择同时卸载且清理配置，脚本将深度清洗 `/etc/snell` 配置目录，实现 100% 干净无残留卸载。

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 许可证开源。
