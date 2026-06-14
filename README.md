# Snell Server 多版本一键管理脚本 (V5 / V6 同步共存)

一个功能强大的 Linux Snell Server 交互式一键管理脚本。支持在同一台 VPS 上同时安装并独立运行 V5 稳定版与 V6 协议，互不干扰，提供极简的快捷命令操作与全方位的系统性能优化。

---

## 📥 一键安装与运行

在您的 Linux 服务器终端复制并运行以下命令，即可直接拉取并运行：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/hann0w0/snell-install/main/snell.sh)"
```

如果您的服务器未预装 curl，也可以使用 wget :

```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/hann0w0/snell-install/main/snell.sh)"
```

> 💡 **提示**：首次成功运行一键命令后，您无需再次复制此命令。今后只需在您的服务器终端直接输入：
> ```bash
> snell
> ```
> 即可瞬间呼出管理菜单。
