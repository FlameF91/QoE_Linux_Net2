#!/bin/bash
# ============================================================
#  TC 网络条件切换工具
#  从 "Network Condition Profiles.txt" 读取网络条件,
#  以随机顺序逐个应用, 并记录所有操作日志。
#  需要 root 权限运行。
# ============================================================

# ======================== 配置 ========================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE_FILE="${SCRIPT_DIR}/Network Condition Profiles.txt"
LOG_FILE="${SCRIPT_DIR}/tc_experiment.log"

# ======================== 颜色 ========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ======================== 函数 ========================

# 写入日志（追加模式）
log_msg() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] $1" >> "${LOG_FILE}"
}

# 分隔线
print_separator() {
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
}

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[错误] 此脚本需要 root 权限运行，请使用 sudo 执行。${NC}"
        echo -e "${YELLOW}用法: sudo bash $0${NC}"
        exit 1
    fi
}

# 从文件读取网络条件
read_profiles() {
    if [[ ! -f "${PROFILE_FILE}" ]]; then
        echo -e "${RED}[错误] 找不到网络条件文件: ${PROFILE_FILE}${NC}"
        exit 1
    fi

    PROFILE_IDS=()
    declare -gA PROFILE_RTT
    declare -gA PROFILE_JITTER
    declare -gA PROFILE_LOSS

    while IFS= read -r line || [[ -n "$line" ]]; do
        # 去除 Windows 换行符中的 \r
        line=$(echo "$line" | tr -d '\r')

        # 跳过注释行和空行
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$(echo "$line" | tr -d '[:space:]')" ]] && continue

        # 解析: ID  RTT  JITTER  PACKET_LOSS
        local id rtt jitter loss
        id=$(echo "$line" | awk '{print $1}')
        rtt=$(echo "$line" | awk '{print $2}' | sed 's/ms//g')
        jitter=$(echo "$line" | awk '{print $3}' | sed 's/ms//g')
        loss=$(echo "$line" | awk '{print $4}' | sed 's/%//g')

        if [[ -n "$id" && -n "$rtt" && -n "$jitter" && -n "$loss" ]]; then
            PROFILE_IDS+=("$id")
            PROFILE_RTT["$id"]="$rtt"
            PROFILE_JITTER["$id"]="$jitter"
            PROFILE_LOSS["$id"]="$loss"
        fi
    done < "${PROFILE_FILE}"

    if [[ ${#PROFILE_IDS[@]} -eq 0 ]]; then
        echo -e "${RED}[错误] 未从文件中读取到任何网络条件配置。${NC}"
        exit 1
    fi

    echo -e "${GREEN}[信息] 成功读取 ${#PROFILE_IDS[@]} 个网络条件配置。${NC}"
}

# 从日志文件读取已完成的组数, 确定当前组号
get_group_number() {
    if [[ -f "${LOG_FILE}" ]]; then
        local count
        count=$(grep -c '\[实验组完成\]' "${LOG_FILE}" 2>/dev/null || echo "0")
        echo $((count + 1))
    else
        echo 1
    fi
}

# Fisher-Yates 洗牌算法, 随机打乱数组
shuffle_array() {
    local -n arr=$1
    local i j tmp
    for ((i=${#arr[@]}-1; i>0; i--)); do
        j=$((RANDOM % (i + 1)))
        tmp="${arr[$i]}"
        arr[$i]="${arr[$j]}"
        arr[$j]="$tmp"
    done
}

# 清除 TC 规则
clear_tc() {
    tc qdisc del dev "${IFACE}" root 2>/dev/null
    return 0
}

# 应用 TC 网络条件
apply_tc() {
    local id="$1"
    local rtt="${PROFILE_RTT[$id]}"
    local jitter="${PROFILE_JITTER[$id]}"
    local loss="${PROFILE_LOSS[$id]}"

    # RTT 是往返延迟, tc netem delay 是单向延迟, 所以除以 2
    local delay
    delay=$(awk "BEGIN {printf \"%.1f\", ${rtt} / 2}")

    # 先清除已有规则
    clear_tc

    # C01 等全零条件: 只需清除规则即可
    if [[ "$rtt" == "0" && "$jitter" == "0" && "$loss" == "0" ]]; then
        log_msg "  执行: 清除所有 TC 规则 (恢复正常网络)"
        log_msg "  结果: 成功"
        echo -e "${GREEN}  [TC] 已清除所有规则 (正常网络)${NC}"
        return 0
    fi

    # 构建 tc 命令
    local tc_cmd="tc qdisc add dev ${IFACE} root netem"

    # 添加延迟和抖动
    if [[ "$rtt" != "0" || "$jitter" != "0" ]]; then
        tc_cmd+=" delay ${delay}ms"
        if [[ "$jitter" != "0" ]]; then
            tc_cmd+=" ${jitter}ms distribution normal"
        fi
    fi

    # 添加丢包率
    if [[ "$loss" != "0" ]]; then
        tc_cmd+=" loss ${loss}%"
    fi

    log_msg "  执行: ${tc_cmd}"

    # 执行 tc 命令
    local output
    output=$(eval "${tc_cmd}" 2>&1)
    local result=$?

    if [[ $result -eq 0 ]]; then
        log_msg "  结果: 成功"
        echo -e "${GREEN}  [TC] 命令执行成功${NC}"
    else
        log_msg "  结果: 失败 (返回码: ${result}, 输出: ${output})"
        echo -e "${RED}  [TC] 命令执行失败！(返回码: ${result})${NC}"
        echo -e "${RED}  输出: ${output}${NC}"
    fi

    return $result
}

# 格式化网络条件为可读字符串
format_condition() {
    local id="$1"
    echo "${id} (RTT: ${PROFILE_RTT[$id]}ms, Jitter: ${PROFILE_JITTER[$id]}ms, 丢包率: ${PROFILE_LOSS[$id]}%)"
}

# 信号处理: Ctrl+C 时清除 TC 规则
cleanup_on_exit() {
    echo ""
    echo -e "${YELLOW}[警告] 检测到中断信号, 正在清除 TC 规则...${NC}"
    clear_tc
    log_msg "[中断] 用户手动中断实验, 已清除 TC 规则"
    log_msg "========================================================"
    echo -e "${GREEN}[信息] TC 规则已清除, 网络已恢复正常。${NC}"
    exit 1
}

# ======================== 主程序 ========================

# 捕获 Ctrl+C
trap cleanup_on_exit SIGINT SIGTERM

# 1. 检查权限
check_root

echo ""
print_separator
echo -e "${BOLD}        TC 网络条件切换工具${NC}"
echo -e "${BOLD}        QoE 实验网络模拟${NC}"
print_separator
echo ""

# 2. 获取网络接口名称
echo -e "${CYAN}可用的网络接口:${NC}"
ip -br link show | awk '{printf "  %-20s %s\n", $1, $2}'
echo ""
read -rp "请输入要使用的网络接口名称: " IFACE

if [[ -z "$IFACE" ]]; then
    echo -e "${RED}[错误] 网络接口名称不能为空。${NC}"
    exit 1
fi

# 验证接口是否存在
if ! ip link show "$IFACE" &>/dev/null; then
    echo -e "${RED}[错误] 网络接口 '${IFACE}' 不存在, 请检查后重试。${NC}"
    exit 1
fi

echo -e "${GREEN}[信息] 使用网络接口: ${IFACE}${NC}"

# 3. 读取网络条件配置文件
read_profiles

# 4. 确定当前组号
GROUP_NUM=$(get_group_number)

echo ""
print_separator
echo -e "${BOLD}    第 ${GROUP_NUM} 组实验${NC}"
echo -e "${BOLD}    日期: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BOLD}    网络接口: ${IFACE}${NC}"
echo -e "${BOLD}    实验总数: ${#PROFILE_IDS[@]}${NC}"
print_separator
echo ""

# 5. 记录日志 - 实验开始
log_msg "========================================================"
log_msg "第 ${GROUP_NUM} 组实验开始"
log_msg "日期时间: $(date '+%Y-%m-%d %H:%M:%S')"
log_msg "网络接口: ${IFACE}"
log_msg "网络条件文件: ${PROFILE_FILE}"
log_msg "========================================================"

# 6. 随机打乱条件顺序
SHUFFLED=("${PROFILE_IDS[@]}")
shuffle_array SHUFFLED

log_msg "随机顺序: ${SHUFFLED[*]}"

# 保存实验顺序用于最终汇总
EXPERIMENT_ORDER=("${SHUFFLED[@]}")

TOTAL=${#SHUFFLED[@]}

# 7. 逐个进行实验
for ((i=0; i<TOTAL; i++)); do
    current_id="${SHUFFLED[$i]}"
    exp_num=$((i + 1))

    echo ""
    print_separator

    # 揭示上一个实验的网络条件 (从第 2 个实验开始)
    if [[ $i -gt 0 ]]; then
        prev_id="${SHUFFLED[$((i - 1))]}"
        prev_num=$i
        echo ""
        echo -e "${YELLOW}  ╔══════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}  ║  [揭示] 第 ${prev_num}/${TOTAL} 个实验的网络条件:${NC}"
        echo -e "${YELLOW}  ║  $(format_condition "$prev_id")${NC}"
        echo -e "${YELLOW}  ╚══════════════════════════════════════════════════╝${NC}"
        echo ""
        log_msg "[揭示] 第 ${prev_num}/${TOTAL} 个实验条件: $(format_condition "$prev_id")"
    fi

    echo -e "${BOLD}  ▶ 即将进行第 ${exp_num}/${TOTAL} 个实验 （第 ${GROUP_NUM} 组）${NC}"
    print_separator
    echo ""

    read -rp "  按回车键应用第 ${exp_num} 个实验的网络条件..."

    # 记录日志
    log_msg "--- 第 ${exp_num}/${TOTAL} 个实验 ---"
    log_msg "  应用条件 ID: ${current_id}"
    log_msg "  RTT: ${PROFILE_RTT[$current_id]}ms (单向延迟: $(awk "BEGIN {printf \"%.1f\", ${PROFILE_RTT[$current_id]} / 2}")ms)"
    log_msg "  Jitter: ${PROFILE_JITTER[$current_id]}ms"
    log_msg "  丢包率: ${PROFILE_LOSS[$current_id]}%"

    # 应用 TC 条件
    apply_tc "$current_id"

    echo ""
    echo -e "${GREEN}  ✔ 第 ${exp_num}/${TOTAL} 个实验条件已应用, 请开始测试。${NC}"
    echo ""
done

# 8. 最后一个实验完成后, 揭示其条件
echo ""
print_separator
echo ""
read -rp "  第 ${TOTAL}/${TOTAL} 个实验测试完成后, 按回车键查看结果并结束..."
echo ""

last_id="${SHUFFLED[$((TOTAL - 1))]}"
echo -e "${YELLOW}  ╔══════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}  ║  [揭示] 第 ${TOTAL}/${TOTAL} 个实验的网络条件:${NC}"
echo -e "${YELLOW}  ║  $(format_condition "$last_id")${NC}"
echo -e "${YELLOW}  ╚══════════════════════════════════════════════════╝${NC}"
echo ""
log_msg "[揭示] 第 ${TOTAL}/${TOTAL} 个实验条件: $(format_condition "$last_id")"

# 9. 清除 TC 规则, 恢复正常网络
echo -e "${CYAN}[信息] 正在清除 TC 规则, 恢复正常网络...${NC}"
clear_tc
log_msg "已清除所有 TC 规则, 网络恢复正常"
echo -e "${GREEN}[信息] 网络已恢复正常。${NC}"

# 10. 显示实验汇总表
echo ""
print_separator
echo -e "${BOLD}        第 ${GROUP_NUM} 组实验汇总${NC}"
print_separator
echo ""
printf "  ${BOLD}%-10s %-8s %-12s %-14s %-10s${NC}\n" "实验序号" "条件ID" "RTT(往返)" "Jitter(抖动)" "丢包率"
echo "  ──────── ────── ────────── ──────────── ────────"

for ((i=0; i<TOTAL; i++)); do
    id="${EXPERIMENT_ORDER[$i]}"
    exp_num=$((i + 1))
    printf "  %-10s %-8s %-12s %-14s %-10s\n" \
        "${exp_num}/${TOTAL}" \
        "${id}" \
        "${PROFILE_RTT[$id]}ms" \
        "${PROFILE_JITTER[$id]}ms" \
        "${PROFILE_LOSS[$id]}%"
done

echo ""
print_separator
echo ""

# 11. 写入汇总日志
log_msg "--- 第 ${GROUP_NUM} 组实验汇总 ---"
for ((i=0; i<TOTAL; i++)); do
    id="${EXPERIMENT_ORDER[$i]}"
    log_msg "  实验 $((i + 1))/${TOTAL}: $(format_condition "$id")"
done
log_msg "[实验组完成] 第 ${GROUP_NUM} 组实验已全部完成"
log_msg "结束时间: $(date '+%Y-%m-%d %H:%M:%S')"
log_msg "========================================================"

echo -e "${GREEN}${BOLD}  ✔ 第 ${GROUP_NUM} 组实验已全部完成！${NC}"
echo -e "  日志文件: ${LOG_FILE}"
echo ""
