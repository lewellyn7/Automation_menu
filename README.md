# 🚀 Linux 服务器全能运维工具箱 (Universal Edition)

这是一个专为 Linux 服务器设计的**一键式自动化运维与优化脚本**。它集成了系统更新、内核优化、Docker 管理、垃圾清理等多项功能，并具备强大的**环境感知能力**，能够根据不同的发行版和虚拟化环境执行差异化的策略。

## 核心特性

* **🌐 全发行版兼容**：自动识别并适配 **Debian / Ubuntu / Kali** (apt系) 和 **CentOS / RHEL / AlmaLinux** (yum/dnf系)。
* **🧠 智能环境感知**：
    * **物理机/虚拟机 (KVM/VMware)**：执行完整内核优化、ZRAM 内存压缩。
    * **容器 (LXC/Docker/OpenVZ)**：自动跳过内核修改、Swap 创建等不安全操作，防止报错。
* **🐳 Docker 深度管理**：集成了安装、日志限制配置以及强力清理功能。
* **⚡ 性能优化**：BBR 加速、智能 Swap 策略、ZRAM 内存压缩。

---

## 📋 功能菜单详解

### 0. 启动自检 (自动运行)
脚本启动时会自动检测以下信息并展示在顶部面板：
* **操作系统**：发行版名称及版本（如 Debian 12, CentOS 7）。
* **包管理器**：自动切换 `apt` 或 `yum` 命令。
* **虚拟化类型**：判断是 KVM（全虚拟化）还是 LXC/Docker（容器化），决定后续功能的执行逻辑。

### 1. 更新系统软件包
* **功能**：刷新软件源缓存，并将所有已安装的软件包更新到最新版本。
* **适配**：
    * Debian系：`apt update && apt upgrade`
    * RHEL系：`yum makecache && yum update`
* **附加**：自动安装常用必备工具 (`curl`, `wget`, `git`, `jq`, `bc`)。

### 2. 开启 TCP BBR 加速
* **功能**：修改内核参数，启用 Google BBR 拥塞控制算法，显著提升网络吞吐量和降低延迟。
* **智能逻辑**：
    * 若检测到环境为 **容器 (LXC/Docker)**，则自动跳过（容器无法独立修改内核参数）。
    * 若 BBR 已开启，则提示无需重复操作。

### 3. 智能 Swap 与 ZRAM 优化
这是本脚本最复杂的逻辑模块，包含三步操作：
1.  **调整 Swappiness**：将 `vm.swappiness` 设置为 `10`，让系统尽可能使用物理内存，减少硬盘 I/O，防止卡顿。
2.  **创建物理 Swap (交换分区)**：
    * **逻辑**：根据物理内存大小自动计算 Swap 大小。
        * 内存 < 2GB → 创建 2GB Swap
        * 内存 2GB ~ 8GB → 创建 4GB Swap
        * 内存 > 8GB → 创建 8GB Swap
    * **保护**：检测磁盘剩余空间，若空间不足（需预留 2GB 安全空间）则跳过创建。
    * **避坑**：若检测到是 **容器环境**，自动跳过（防止权限错误）。
3.  **配置 ZRAM (内存压缩)**：
    * **功能**：划出 50% 物理内存作为压缩交换区（算法 lz4），变相增加内存容量。
    * **兼容性**：仅在 Debian/Ubuntu 且非容器环境下启用。RHEL 系因配置复杂性暂时跳过以保稳定。

### 4. 配置 Chrony 时间同步
* **功能**：安装并启用业界最精准的 `chrony` 服务，强制同步一次时间。
* **适配**：自动识别服务名为 `chrony` (Debian) 或 `chronyd` (CentOS)。

### 5. 安装/检测 Docker 环境
* **功能**：一键安装 Docker Engine。
* **优化**：使用官方脚本并指定 **Aliyun (阿里云)** 镜像源，解决国内服务器下载慢或超时的问题。

### 6. 限制 Docker 日志大小
* **痛点解决**：防止 Docker 容器日志无限增长占满磁盘。
* **操作**：自动创建或修改 `/etc/docker/daemon.json`，设置全局日志策略：
    ```json
    {
      "log-driver": "json-file",
      "log-opts": { "max-size": "20m", "max-file": "3" }
    }
    ```
* **生效**：配置完成后会自动重启 Docker 服务。

### 7. Docker 强力清理
* **警告**：这是一个**破坏性**清理功能，用于极致释放空间。
* **执行命令**：`docker system prune -a --volumes -f`
* **清理内容**：
    * 🛑 所有已停止的容器 (Stopped Containers)
    * 🕸️ 所有未使用的网络 (Unused Networks)
    * 🖼️ **所有未被使用的镜像** (不仅是悬空镜像，凡是没跑起来的都删)
    * 🧱 所有构建缓存 (Build Cache)
    * 💾 **所有未使用的挂载卷** (Unused Volumes - **慎用！**)

### 8. 系统垃圾清理
* **功能**：清理操作系统层面的缓存，与 Docker 清理分离。
* **清理内容**：
    * 包管理器缓存 (`apt clean` / `yum clean all`)。
    * 自动移除不再需要的依赖包 (`autoremove`)。
    * 清理 Systemd 日志 (`journalctl`)，只保留最近 100MB 日志。

### 9. 执行以上所有优化
* **逻辑**：按顺序自动执行功能 1 到 8。
* **流程**：更新系统 -> BBR -> Swap/ZRAM -> 时间同步 -> 安装 Docker -> 限制日志 -> Docker 清理 -> 系统清理。

---

## 💻 使用方法

1. **国内加速一键运行命令**：
    ```bash
    bash <(curl -sL https://ghproxy.net/https://raw.githubusercontent.com/lewellyn7/Automation_menu/main/Automation_menu.sh)
    ```
2. **国内加速一键运行命令（备用）**：
    ```bash
    wget -qO- https://ghproxy.net/https://raw.githubusercontent.com/lewellyn7/Automation_menu/main/Automation_menu.sh | bash
    ```
  
    


## ⚠️ 注意事项
* 该脚本需要 **Root** 权限运行。
* **CentOS 7** 用户请注意内核版本，开启 BBR 可能需要先手动升级内核。
* **LXC 容器** 用户：脚本会跳过 Swap 和 BBR，这是正常现象，请在宿主机（PVE）层面进行优化。
