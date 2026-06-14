# Snell Server 多版本一键管理脚本 (V5 / V6 同步共存)

一个功能强大的 Linux Snell Server 交互式一键管理脚本。支持在同一台 VPS 上**同时安装并独立运行 V5 稳定版与 V6 协议**，互不干扰，提供极简的快捷命令操作与全方位的系统优化支持。

---

## 📥 一键安装与运行

在您的 Linux 服务器终端复制并运行以下命令，即可直接拉取并运行：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/hann0w0/snell-install/main/snell.sh)"
```

如果您的服务器未预装 curl，也可以使用 wget：

```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/hann0w0/snell-install/main/snell.sh)"
```

> 💡 **提示**：首次成功运行一键命令后，您无需再次复制此命令。今后只需在您的服务器终端直接输入：
> ```bash
> sudo snell
> ```
> 即可瞬间呼出管理菜单。

---

## 🌟 核心特性

- **🚀 终端输入 `snell` 秒开面板**：只需在终端输入 `sudo snell`，即可在 0.1 秒内直接呼出管理面板，无需每次都复制冗长的网络下载命令。
- **👥 V5 与 V6 完美双版本共存**：首创双版本独立运行架构！彻底隔离并解耦 V5 和 V6 的主程序路径、服务进程、配置文件与版本标记，支持在单台 VPS 上同时开启、独立管理。
- **⚡ 客户端配置直观展示**：彻底摒弃繁琐的子菜单！直接分类列出 Surge 和 Clash (Mihomo) 的节点配置格式，支持跨版本一次性拖选并批量复制。
- **🛡️ 端口碰撞与冲突自动拦截**：在安装新版本或修改现有端口时，脚本将自动检测另一版本所占用的端口。一旦检测到冲突会立即提示并拦截，防止因端口抢占导致服务启动失败。
- **🔄 凌晨定时更新与故障安全回滚**：支持每天凌晨 03:30 自动静默检测并升级主程序。在更新失败或新服务启动异常 3 秒内，自动执行静默安全回滚并恢复旧版本，确保代理服务永不断网。
- **🛠️ 一键内核 BBR 加速与时间同步**：内置一键同步中国标准时间（支持阿里云/腾讯云 NTP 高精度授时）以及一键开启系统级 TCP BBR 拥塞控制调优，大幅提升大带宽、长距离网络连接的吞吐效率。

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

## 💻 系统兼容性

| 项目 | 要求 |
|:---|:---|
| 支持系统 | Debian 9+ / Ubuntu 18.04+ / CentOS 7+ / Fedora 30+ / Arch Linux |
| CPU 架构 | amd64 (x86_64), aarch64 (arm64), i386, armv7l (V5 only) |
| 内核版本 | 4.9+（BBR 拥塞控制需要） |
| 依赖工具 | wget, unzip（脚本会自动检测并安装） |

---

## ❓ 常见问题 (FAQ)

**Q: V5 和 V6 能否使用相同端口？**

A: 不能。脚本会自动检测端口冲突并拦截，确保两个版本使用不同的端口独立运行。

**Q: 定时更新失败会怎样？**

A: 定时更新内置安全回滚机制。如果新版本服务启动异常，会在 3 秒内自动回滚并恢复旧版本，确保代理服务不中断。

**Q: V6 在 Clash 中如何工作？**

A: Clash 客户端暂未原生支持 V6 传输层协议。脚本会自动生成 `version: 5` 的配置，在 Clash 中安全降级连接 V6 服务端。

**Q: 如何卸载快捷指令 `snell`？**

A: 快捷指令位于 `/usr/local/bin/snell`，删除该文件即可：`sudo rm -f /usr/local/bin/snell`。

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 许可证开源。
