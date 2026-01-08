#!/bin/bash

# =================================================================
#  Linux 服务器运维工具箱 (定时任务增强版)
#  新增: 命令行参数支持 (实现无人值守运行)
#  新增: Crontab 定时任务一键配置
# =================================================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局变量
OS_TYPE=""
OS_NAME=""
OS_VERSION=""
VIRT_TYPE=""
IS_CONTAINER=0
CMD_INSTALL=""
CMD_UPDATE=""
SVC_CHRONY=""
CURRENT_SCRIPT=$(readlink -f "$0") # 获取当前脚本绝对路径

# --- 0. 环境深度检测 ---
check_sys() {
    # 1. 检查 Root 权限
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 请使用 sudo 或 root 权限运行此脚本！${NC}"
        exit 1
    fi

    # 2. 检测发行版
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        OS_NAME=$ID
        OS_VERSION=$VERSION_ID
    else
        echo -e "${RED}无法读取 /etc/os-release，无法判断系统类型。${NC}"
        exit 1
    fi

    # 识别包管理器
    if [[ "$OS_NAME" =~ (debian|ubuntu|kali|linuxmint) ]]; then
        OS_TYPE="debian"
        CMD_INSTALL="apt install -y"
        CMD_UPDATE="apt update -y && apt upgrade -y"
        SVC_CHRONY="chrony"
    elif [[ "$OS_NAME" =~ (centos|rhel|almalinux|rocky|fedora) ]]; then
        OS_TYPE="rhel"
        CMD_INSTALL="yum install -y"
        CMD_UPDATE="yum makecache && yum update -y"
        SVC_CHRONY="chronyd"
    else
        echo -e "${RED}❌ 不支持的发行版: $OS_NAME${NC}"
        exit 1
    fi

    # 3. 检测虚拟化
    if command -v systemd-detect-virt &> /dev/null; then
        VIRT_TYPE=$(systemd-detect-virt)
    else
        VIRT_TYPE="Unknown"
    fi
    
    if [[ "$VIRT_TYPE" =~ (kvm|qemu|vmware|oracle) ]]; then
        VIRT_DISPLAY="${GREEN}虚拟机 ($VIRT_TYPE)${NC}"
        IS_CONTAINER=0
    elif [[ "$VIRT_TYPE" =~ (lxc|openvz|docker) ]]; then
        VIRT_DISPLAY="${YELLOW}容器 ($VIRT_TYPE)${NC}"
        IS_CONTAINER=1
    elif [[ "$VIRT_TYPE" == "none" ]]; then
        VIRT_DISPLAY="${GREEN}物理机 (Bare Metal)${NC}"
        IS_CONTAINER=0
    else
        VIRT_DISPLAY="${RED}未知 ($VIRT_TYPE)${NC}"
        IS_CONTAINER=0
    fi
}

pause() {
    echo -e "\n${CYAN}>>> 功能执行完毕，按回车键返回主菜单...${NC}"
    read -r
}

# --- 功能函数区 ---

# 1. 系统更新
sys_update() {
    echo -e "\n${YELLOW}[正在执行] 系统软件包更新 ($OS_TYPE)...${NC}"
    eval $CMD_UPDATE
    $CMD_INSTALL curl wget git jq bc cron
    # 注意：Debian下叫cron, CentOS下可能叫crontabs或cronie，这里简单尝试安装
    if [ "$OS_TYPE" == "rhel" ]; then $CMD_INSTALL cronie; fi
    echo -e "${GREEN}√ 系统更新完成。${NC}"
}

# 2. 开启 BBR
enable_bbr() {
    echo -e "\n${YELLOW}[正在执行] 检查并开启 TCP BBR...${NC}"
    if [ "$IS_CONTAINER" -eq 1 ]; then
        echo -e "${RED}x 容器环境 ($VIRT_TYPE) 无法修改内核参数，跳过。${NC}"
        return
    fi
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${GREEN}√ BBR 已经是开启状态。${NC}"
    else
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        echo -e "${GREEN}√ BBR 已成功开启。${NC}"
    fi
}

# 3. 智能 Swap
smart_swap() {
    echo -e "\n${YELLOW}[正在执行] 智能 Swap 与 ZRAM 优化...${NC}"
    # A. Swappiness
    echo -e "\n> 1. 调整 Swappiness 为 10..."
    if grep -q "vm.swappiness" /etc/sysctl.conf; then
        sed -i 's/vm.swappiness.*/vm.swappiness = 10/' /etc/sysctl.conf
    else
        echo "vm.swappiness = 10" >> /etc/sysctl.conf
    fi
    sysctl -p >/dev/null 2>&1
    echo -e "${GREEN}√ 已优化。${NC}"

    # B. 物理 Swap
    echo -e "\n> 2. 检查物理 Swap 文件..."
    if [ "$IS_CONTAINER" -eq 1 ]; then
        echo -e "${YELLOW}  容器环境跳过物理 Swap。${NC}"
    elif swapon --show | grep -qE "file|partition"; then
        echo -e "${GREEN}√ 已存在 Swap，跳过。${NC}"
    else
        if ! command -v bc &> /dev/null; then $CMD_INSTALL bc; fi
        MEM_TOTAL_MB=$(free -m | awk '/Mem:/ {print $2}')
        DISK_AVAIL_MB=$(df -m / | awk 'NR==2 {print $4}')
        
        if [ "$MEM_TOTAL_MB" -lt 2048 ]; then TARGET_GB=2
        elif [ "$MEM_TOTAL_MB" -lt 8192 ]; then TARGET_GB=4
        else TARGET_GB=8; fi
        TARGET_MB=$((TARGET_GB * 1024))
        
        if [ "$DISK_AVAIL_MB" -gt "$((TARGET_MB + 2048))" ]; then
            echo -e "${YELLOW}正在创建 ${TARGET_GB}GB Swap 文件...${NC}"
            dd if=/dev/zero of=/swapfile bs=1M count=$TARGET_MB status=progress
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            if ! grep -q "/swapfile" /etc/fstab; then echo "/swapfile none swap sw 0 0" >> /etc/fstab; fi
            echo -e "${GREEN}√ 创建成功。${NC}"
        else
            echo -e "${RED}x 磁盘空间不足，跳过。${NC}"
        fi
    fi

    # C. ZRAM
    echo -e "\n> 3. ZRAM 内存压缩配置..."
    if [[ "$IS_CONTAINER" -eq 1 || "$OS_TYPE" == "rhel" ]]; then
        echo -e "${YELLOW}  容器环境或 RHEL 系统跳过 ZRAM。${NC}"
    else
        if ! command -v zramctl &> /dev/null; then
            $CMD_INSTALL linux-modules-extra-$(uname -r) 2>/dev/null || true
            $CMD_INSTALL zram-tools
            echo "ALGO=lz4" > /etc/default/zramswap
            echo "PERCENT=50" >> /etc/default/zramswap
            systemctl daemon-reload
            systemctl restart zramswap
            echo -e "${GREEN}√ ZRAM 安装成功。${NC}"
        else
            echo -e "${GREEN}√ ZRAM 已安装。${NC}"
        fi
        zramctl
    fi
}

# 4. 时间同步
sync_time() {
    echo -e "\n${YELLOW}[正在执行] 配置 Chrony 时间同步...${NC}"
    if systemctl is-active --quiet $SVC_CHRONY; then
        echo -e "${GREEN}√ Chrony 正在运行。${NC}"
    else
        $CMD_INSTALL chrony
        systemctl enable --now $SVC_CHRONY
        echo -e "${GREEN}√ Chrony 已启动。${NC}"
    fi
    chronyc makestep
    echo -e "${GREEN}√ 时间已校准。${NC}"
}

# 5. Docker 安装
install_docker() {
    echo -e "\n${YELLOW}[正在执行] 检测 Docker 环境...${NC}"
    if command -v docker &> /dev/null; then
        echo -e "${GREEN}√ Docker 已安装。${NC}"
    else
        echo -e "${YELLOW}未检测到 Docker，开始自动安装...${NC}"
        curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun
        systemctl enable --now docker
        if command -v docker &> /dev/null; then
            echo -e "${GREEN}√ Docker 安装成功！${NC}"
        else
            echo -e "${RED}x Docker 安装失败。${NC}"
        fi
    fi
}

# 6. Docker 日志限制
limit_docker_logs() {
    echo -e "\n${YELLOW}[正在执行] 配置 Docker 日志限制...${NC}"
    if ! command -v docker &> /dev/null; then install_docker; fi
    if command -v docker &> /dev/null; then
        if [ ! -f /etc/docker/daemon.json ]; then
            mkdir -p /etc/docker
            cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "3"
  }
}
EOF
            systemctl daemon-reload
            systemctl restart docker
            echo -e "${GREEN}√ Docker 配置已更新并重启。${NC}"
        else
            echo -e "${RED}! /etc/docker/daemon.json 已存在，跳过。${NC}"
        fi
    fi
}

# 7. Docker 强力清理
clean_docker_garbage() {
    echo -e "\n${YELLOW}[正在执行] Docker 强力清理...${NC}"
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}x 未安装 Docker，无法清理。${NC}"
        return
    fi
    docker system prune -a --volumes -f
    echo -e "${GREEN}√ Docker 清理完毕。${NC}"
}

# 8. 系统缓存清理
clean_system_cache() {
    echo -e "\n${YELLOW}[正在执行] 操作系统缓存清理...${NC}"
    if [ "$OS_TYPE" == "debian" ]; then
        apt autoremove -y && apt clean
    elif [ "$OS_TYPE" == "rhel" ]; then
        yum autoremove -y && yum clean all
    fi
    journalctl --vacuum-size=100M > /dev/null 2>&1
    echo -e "${GREEN}√ 系统清理完毕。${NC}"
    df -h / | awk 'NR==2 {print $5 " used"}'
}

# 9. 执行所有
run_all() {
    sys_update
    enable_bbr
    smart_swap
    sync_time
    install_docker
    limit_docker_logs
    clean_docker_garbage
    clean_system_cache
}

# 10. 管理定时任务 (新增功能)
manage_cron() {
    echo -e "\n${YELLOW}[正在配置] 自动维护任务 (Crontab)...${NC}"
    
    # 检查脚本路径是否合法
    if [[ "$CURRENT_SCRIPT" == "/dev/fd/"* ]]; then
        echo -e "${RED}警告: 您似乎是直接通过 curl/wget 运行的脚本。${NC}"
        echo -e "请先将脚本下载并保存到本地（例如 /root/menu.sh），然后给它赋予执行权限，再运行添加定时任务。"
        return
    fi
    
    # 确保有执行权限
    chmod +x "$CURRENT_SCRIPT"

    echo -e "请选择操作:"
    echo -e "1. 添加: 每天凌晨 3:00 自动执行全套优化"
    echo -e "2. 删除: 取消本脚本的所有定时任务"
    read -p "请输入 [1/2]: " cron_choice

    if [ "$cron_choice" == "1" ]; then
        # 备份现有 crontab
        crontab -l > /tmp/cron_bkp 2>/dev/null
        
        # 删除可能存在的旧任务，防止重复
        grep -v "$CURRENT_SCRIPT" /tmp/cron_bkp > /tmp/cron_new
        
        # 添加新任务 (追加日志到 /var/log/automation_menu.log)
        echo "0 3 * * * /bin/bash $CURRENT_SCRIPT run_all >> /var/log/automation_menu.log 2>&1" >> /tmp/cron_new
        
        # 应用新 crontab
        crontab /tmp/cron_new
        rm /tmp/cron_bkp /tmp/cron_new
        echo -e "${GREEN}√ 定时任务已添加！每天 03:00 自动运行。${NC}"
        echo -e "  日志文件位置: /var/log/automation_menu.log"
        
    elif [ "$cron_choice" == "2" ]; then
        crontab -l > /tmp/cron_bkp 2>/dev/null
        # 反向查找并保存
        grep -v "$CURRENT_SCRIPT" /tmp/cron_bkp > /tmp/cron_new
        crontab /tmp/cron_new
        rm /tmp/cron_bkp /tmp/cron_new
        echo -e "${GREEN}√ 已移除本脚本的所有定时任务。${NC}"
    else
        echo -e "${RED}无效选择。${NC}"
    fi
}

# --- 主逻辑入口 ---

# 0. 优先执行环境检查
check_sys

# 逻辑分支: 判断是否有命令行参数
# 如果运行 ./menu.sh run_all，则直接执行 run_all 函数并退出，不显示菜单
if [ "$1" == "run_all" ]; then
    echo -e "${BLUE}>>> 检测到自动运行参数，开始执行全套维护任务...${NC}"
    date
    run_all
    echo -e "${BLUE}>>> 所有自动任务执行完毕。${NC}"
    exit 0
fi

# 如果没有参数，则显示交互式菜单
show_menu() {
    clear
    echo -e "${BLUE}======================================================${NC}"
    echo -e "${BLUE}    🚀 Linux 全能运维工具箱 (定时任务增强版)   ${NC}"
    echo -e "${BLUE}======================================================${NC}"
    echo -e " 💻  系统:  ${GREEN}${OS_NAME} ${OS_VERSION}${NC} (${OS_TYPE})"
    echo -e " 📦  环境:  ${VIRT_DISPLAY}"
    echo -e "${BLUE}======================================================${NC}"
    echo -e "${GREEN}1.${NC} 更新系统软件包"
    echo -e "${GREEN}2.${NC} 开启 TCP BBR 加速"
    echo -e "${GREEN}3.${NC} 智能 Swap/ZRAM 优化"
    echo -e "${GREEN}4.${NC} 配置 Chrony 时间同步"
    echo -e "${GREEN}5.${NC} 安装/检测 Docker 环境"
    echo -e "${GREEN}6.${NC} 限制 Docker 日志大小"
    echo -e "${GREEN}7.${NC} Docker 强力清理 (镜像/容器/卷)"
    echo -e "${GREEN}8.${NC} 系统垃圾清理 (缓存/日志)"
    echo -e "${YELLOW}9. 执行以上所有优化 (Run All)${NC}"
    echo -e "${CYAN}10. 设置定时自动运行 (Crontab)${NC}"
    echo -e "${BLUE}======================================================${NC}"
    echo -e "${RED}0. 退出脚本${NC}"
    echo -e "${BLUE}======================================================${NC}"
}

while true; do
    show_menu
    read -p "请输入数字选择功能 [0-10]: " choice
    
    case $choice in
        1) sys_update; pause ;;
        2) enable_bbr; pause ;;
        3) smart_swap; pause ;;
        4) sync_time; pause ;;
        5) install_docker; pause ;;
        6) limit_docker_logs; pause ;;
        7) clean_docker_garbage; pause ;;
        8) clean_system_cache; pause ;;
        9) run_all; pause ;;
        10) manage_cron; pause ;;
        0) echo -e "\n👋 再见！"; exit 0 ;;
        *) echo -e "\n${RED}无效输入！${NC}"; sleep 1 ;;
    esac
done
