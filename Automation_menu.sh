#!/bin/bash

# =================================================================
#  Linux 服务器运维工具箱
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
CURRENT_SCRIPT=$(readlink -f "$0")

# --- 0. 环境深度检测 ---
check_sys() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 请使用 sudo 或 root 权限运行此脚本！${NC}"
        exit 1
    fi

    if [ -f /etc/os-release ]; then
        source /etc/os-release
        OS_NAME=$ID
        OS_VERSION=$VERSION_ID
    else
        echo -e "${RED}无法读取 /etc/os-release。${NC}"
        exit 1
    fi

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
    if [ "$OS_TYPE" == "rhel" ]; then $CMD_INSTALL cronie; fi
    echo -e "${GREEN}√ 系统更新完成。${NC}"
}

# 2. 开启 BBR
enable_bbr() {
    echo -e "\n${YELLOW}[正在执行] 检查并开启 TCP BBR...${NC}"
    if [ "$IS_CONTAINER" -eq 1 ]; then
        echo -e "${RED}x 容器环境无法修改内核参数，跳过。${NC}"
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
    echo -e "\n> 1. 调整 Swappiness 为 10..."
    if grep -q "vm.swappiness" /etc/sysctl.conf; then
        sed -i 's/vm.swappiness.*/vm.swappiness = 10/' /etc/sysctl.conf
    else
        echo "vm.swappiness = 10" >> /etc/sysctl.conf
    fi
    sysctl -p >/dev/null 2>&1
    echo -e "${GREEN}√ 已优化。${NC}"

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

# 7. Docker 清理 (Safe模式支持)
clean_docker_garbage() {
    MODE="$1"
    echo -e "\n${YELLOW}[正在执行] Docker 垃圾清理...${NC}"
    
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}x 未安装 Docker，无法清理。${NC}"
        return
    fi
    
    # 逻辑修正：严格判断 safe 参数
    if [ "$MODE" == "safe" ]; then
        echo -e "${GREEN}>>> [安全模式] 正在清理未使用镜像、容器、网络 (保留数据卷)...${NC}"
        docker system prune -a -f
    else
        echo -e "${RED}>>> [强力模式] 正在清理所有未使用资源 (包含数据卷!)...${NC}"
        docker system prune -a --volumes -f
    fi
    
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

# --- 逻辑核心区分 (防止定时任务跑偏) ---

# 9. 手动全量优化 (Run All)
run_all() {
    echo -e "${BLUE}>>> 启动全量优化 (Run All Mode)...${NC}"
    sys_update
    enable_bbr      # 仅在此模式执行
    smart_swap      # 仅在此模式执行
    sync_time
    install_docker
    limit_docker_logs
    clean_docker_garbage # 默认强力模式
    clean_system_cache
    echo -e "${BLUE}>>> 全量优化完成。${NC}"
}

# 10. 定时任务专用 (Safe Daily Mode)
cron_tasks() {
    echo -e "\n${BLUE}=======================================${NC}"
    echo -e "${BLUE}   [Daily Maintenance] 定时维护开始    ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    date
    
    # 1. 系统更新
    sys_update           
    # 2. 时间同步
    sync_time            
    # 3. 安全清理 Docker (保留数据卷)
    clean_docker_garbage safe 
    # 4. 系统日志清理
    clean_system_cache   
    
    echo -e "${BLUE}>>> [Daily Maintenance] 维护结束。${NC}"
}

# 11. 定时任务管理 (修复版)
manage_cron() {
    echo -e "\n${YELLOW}[配置] 定时自动维护任务 (Crontab)${NC}"
    
    if [[ "$CURRENT_SCRIPT" == "/dev/fd/"* ]]; then
        echo -e "${RED}警告: 脚本路径无效，请先保存到本地再运行。${NC}"
        return
    fi
    chmod +x "$CURRENT_SCRIPT"

    echo -e "----------------------------------------"
    echo -e "当前选择的操作:"
    echo -e "1. ${GREEN}添加/重置${NC} 定时任务 (解决旧版逻辑问题)"
    echo -e "2. ${RED}删除${NC} 所有相关任务"
    echo -e "0. 返回主菜单"
    echo -e "----------------------------------------"
    read -p "请输入 [1/2/0]: " action_choice

    if [ "$action_choice" == "2" ]; then
        crontab -l > /tmp/cron_bkp 2>/dev/null
        grep -v "$CURRENT_SCRIPT" /tmp/cron_bkp > /tmp/cron_new
        crontab /tmp/cron_new
        rm /tmp/cron_bkp /tmp/cron_new
        echo -e "${GREEN}√ 已删除本脚本的所有定时任务。${NC}"
        return
    elif [ "$action_choice" == "0" ]; then
        return
    elif [ "$action_choice" != "1" ]; then
        echo -e "${RED}无效输入。${NC}"
        return
    fi

    echo -e "\n请选择执行频率:"
    echo -e "1. 每天 (Daily)"
    echo -e "2. 每周 (Weekly)"
    echo -e "3. 每月 (Monthly)"
    read -p "请输入 [1-3]: " freq_choice

    echo -e ""
    while true; do
        read -p "请输入执行的小时 (0-23): " cron_hour
        if [[ "$cron_hour" =~ ^[0-9]+$ ]] && [ "$cron_hour" -ge 0 ] && [ "$cron_hour" -le 23 ]; then break; fi
        echo -e "${RED}错误: 小时必须是 0-23 之间的数字。${NC}"
    done

    while true; do
        read -p "请输入执行的分钟 (0-59): " cron_min
        if [[ "$cron_min" =~ ^[0-9]+$ ]] && [ "$cron_min" -ge 0 ] && [ "$cron_min" -le 59 ]; then break; fi
        echo -e "${RED}错误: 分钟必须是 0-59 之间的数字。${NC}"
    done

    cron_exp=""
    desc_str=""
    cron_dom="*"
    cron_dow="*"

    case $freq_choice in
        1) desc_str="每天 $cron_hour:$cron_min" ;;
        2) 
            while true; do
                read -p "请输入星期几 (0=周日 ... 6=周六): " cron_dow
                if [[ "$cron_dow" =~ ^[0-6]$ ]]; then break; fi
                echo -e "${RED}错误: 请输入 0-6。${NC}"
            done
            desc_str="每周 (周$cron_dow) $cron_hour:$cron_min"
            ;;
        3) 
            while true; do
                read -p "请输入日期 (1-31): " cron_dom
                if [[ "$cron_dom" =~ ^[0-9]+$ ]] && [ "$cron_dom" -ge 1 ] && [ "$cron_dom" -le 31 ]; then break; fi
                echo -e "${RED}错误: 请输入 1-31。${NC}"
            done
            desc_str="每月 $cron_dom 号 $cron_hour:$cron_min"
            ;;
        *) echo -e "${RED}无效选择。${NC}"; return ;;
    esac

    cron_exp="$cron_min $cron_hour $cron_dom * $cron_dow"

    # --- 关键逻辑: 写入 Crontab ---
    crontab -l > /tmp/cron_bkp 2>/dev/null
    
    # 1. 先清理掉旧的、包含本脚本路径的所有任务 (防止 run_all 残留)
    grep -v "$CURRENT_SCRIPT" /tmp/cron_bkp > /tmp/cron_new
    
    # 2. 写入新的、明确调用 cron_daily 的任务
    # 使用 >> 追加到日志，方便排查
    echo "$cron_exp /bin/bash $CURRENT_SCRIPT cron_daily >> /var/log/automation_menu.log 2>&1" >> /tmp/cron_new
    
    crontab /tmp/cron_new
    rm /tmp/cron_bkp /tmp/cron_new

    echo -e "${GREEN}√ 定时任务设置成功！${NC}"
    echo -e "  策略: ${YELLOW}$desc_str${NC}"
    echo -e "  命令: ${CYAN}/bin/bash $CURRENT_SCRIPT cron_daily${NC}"
    echo -e "  注意: 请确保您看到了 'cron_daily' 字样，这代表安全模式。"
}

# --- 主逻辑入口 ---

check_sys

# 1. 严格匹配 cron_daily 参数 (Crontab 专用)
if [ "$1" == "cron_daily" ]; then
    cron_tasks
    exit 0
fi

# 2. 严格匹配 run_all 参数 (手动/旧版兼容)
if [ "$1" == "run_all" ]; then
    run_all
    exit 0
fi

# 3. 交互式菜单
show_menu() {
    clear
    echo -e "${BLUE}======================================================${NC}"
    echo -e "${BLUE}    🚀 Linux 全能运维工具箱${NC}"
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
    echo -e "${YELLOW}9. 手动执行所有优化 (Run All)${NC}"
    echo -e "${CYAN}10. 设置/删除 定时维护任务 (Daily Mode)${NC}"
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
        7) clean_docker_garbage; pause ;; # 手动默认强力
        8) clean_system_cache; pause ;;
        9) run_all; pause ;;
        10) manage_cron; pause ;;
        0) echo -e "\n👋 再见！"; exit 0 ;;
        *) echo -e "\n${RED}无效输入！${NC}"; sleep 1 ;;
    esac
done
