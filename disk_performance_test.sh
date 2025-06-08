#!/bin/bash

# 磁盘性能测试脚本（修复版）
# 修复ASCII艺术字显示问题

# 颜色与样式
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'  # 恢复默认
BAR_LENGTH=50  # 进度条长度

# 修复后的艺术字（使用双反斜杠转义）
print_header() {
    echo -e "${BLUE}
   _____            __  __            _       _     
  / ____|          |  \\\/  |          (_)     | |    
 | |     ___  _ __ | \\\\  / | __ _ _ __ _  __ _| |___ 
 | |    / _ \\| '_ \\| |\\/| |/ _\` | '__| |/ _\` | / __|
 | |___| (_) | | | | |  | | (_| | |  | | (_| | \\\__ \\
  \\_____\\___/|_| |_|_|  |_|\\__,_|_|  |_|\\__,_|_|___/
${NC}"
}

# 检查依赖
check_dependencies() {
    local deps=("fio" "jq" "dmidecode" "lsblk")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo -e "${YELLOW}安装依赖: $dep...${NC}"
            sudo apt-get install -y "$dep" || { echo -e "${RED}无法安装依赖！${NC}"; exit 1; }
        fi
    done
}

# 检测虚拟机环境
detect_vm() {
    if dmidecode -s system-product-name | grep -qi "virtual"; then
        echo -e "${YELLOW}警告: 检测到虚拟机环境！${NC}"
        echo -e "${YELLOW}测试结果受虚拟化层影响，可能低于物理磁盘${NC}"
    fi
}

# 设置测试参数
setup_params() {
    TEST_DIR="${TEST_DIR:-/home/sunset1014/test_dir}"
    LOG_DIR="$TEST_DIR/logs"
    TEST_FILE="$TEST_DIR/fio.test"
    TEST_SIZE="4G"         # 虚拟机环境增大测试文件
    RUNTIME="60"          # 每项测试运行时间（秒）
    IOENGINE="sync"       # 虚拟机环境使用 sync IO
    DISK="/dev/sda"       # 默认测试磁盘
}

# 打印优雅进度条
print_progress() {
    local current=$1; local total=$2; local status=$3
    local percent=$((current * 100 / total))
    local filled=$((percent * BAR_LENGTH / 100))
    local empty=$((BAR_LENGTH - filled))
    
    # 构建进度条
    local bar="${BLUE}[${GREEN}$(printf "%-${filled}s" "" | tr ' ' '#')${BLUE}$(printf "%-${empty}s" "" | tr ' ' '-')${BLUE}]${NC}"
    
    # 彩色百分比
    if [ $percent -eq 100 ]; then
        percent="${GREEN}100${NC}"
    else
        percent="${BLUE}${percent}${NC}"
    fi
    
    echo -ne "${bar} ${percent}% ${status}...${NC}\r"
}

# 执行测试并显示进度
run_test() {
    local name=$1; shift
    local params="$*"
    local log_file="$LOG_DIR/${name}.json"
    local err_file="$LOG_DIR/${name}.err"
    
    echo -e "${BLUE}开始 ${name} 测试...${NC}"
    
    # 执行测试并捕获PID
    fio --name="${name}" --filename="$TEST_FILE" --size="$TEST_SIZE" --runtime="$RUNTIME" \
        --ioengine="$IOENGINE" $params --output-format=json > "$log_file" 2>"$err_file" &
    local pid=$!
    
    # 实时更新进度
    local start_time=$(date +%s)
    while kill -0 $pid 2>/dev/null; do
        local elapsed=$(( $(date +%s) - start_time ))
        local percent=$(( elapsed * 100 / RUNTIME ))
        if [ $percent -gt 100 ]; then percent=100; fi
        print_progress $elapsed $RUNTIME "$name"
        sleep 1
    done
    
    # 确保显示100%完成
    print_progress $RUNTIME $RUNTIME "$name ${GREEN}完成${NC}"
    echo
    
    # 检查测试状态
    if [ $? -ne 0 ] || [ ! -s "$log_file" ]; then
        echo -e "${RED}${name} 测试失败！错误日志: ${err_file}${NC}"
        return 1
    else
        echo -e "${GREEN}${name} 测试成功！${NC}"
        return 0
    fi
}

# 解析测试结果
parse_result() {
    local name=$1; local log_file=$2
    
    if [ ! -s "$log_file" ]; then
        echo -e "${RED}无法解析 ${name} 结果：文件不存在或为空！${NC}"
        return 1
    fi
    
    # 提取关键指标
    local bw=$(jq -r ".jobs[0].write.bw // .jobs[0].read.bw" "$log_file")
    local iops=$(jq -r ".jobs[0].write.iops // .jobs[0].read.iops" "$log_file")
    local lat=$(jq -r ".jobs[0].write.lat.nsec.mean // .jobs[0].read.lat.nsec.mean" "$log_file")
    
    # 转换单位
    local bw_mb=$(echo "scale=2; $bw / 1024" | bc -l)
    local lat_ms=$(echo "scale=2; $lat / 1000000" | bc -l)
    
    # 输出结果
    echo -e "${BLUE}→ ${name} 测试结果:${NC}"
    echo -e "  ${GREEN}带宽: ${bw_mb} MB/s${NC}"
    echo -e "  ${GREEN}IOPS: ${iops}${NC}"
    echo -e "  ${GREEN}平均延迟: ${lat_ms} ms${NC}"
    
    # 提供性能参考
    local disk_type=$(lsblk -d -o ROTA "$DISK" | tail -n1 | sed 's/0/SSD/;s/1/HDD/')
    if [ "$disk_type" = "SSD" ]; then
        echo -e "  ${YELLOW}SSD 参考: 顺序读写 > 300 MB/s, 随机 4K 读写 > 10,000 IOPS${NC}"
    else
        echo -e "  ${YELLOW}HDD 参考: 顺序读写 > 100 MB/s, 随机 4K 读写 > 100 IOPS${NC}"
    fi
    echo
}

# 主函数
main() {
    print_header
    check_dependencies
    detect_vm
    setup_params
    
    # 创建目录
    mkdir -p "$TEST_DIR" "$LOG_DIR" || { echo -e "${RED}无法创建测试目录！${NC}"; exit 1; }
    rm -f "$TEST_FILE"
    
    # 定义测试场景
    local test_names=("顺序写入" "顺序读取" "随机写入" "随机读取" "混合读写")
    local test_params=(
        "--rw=write --bs=1M --iodepth=1 --numjobs=1"
        "--rw=read --bs=1M --iodepth=1 --numjobs=1"
        "--rw=randwrite --bs=4k --iodepth=4 --numjobs=2"
        "--rw=randread --bs=4k --iodepth=4 --numjobs=2"
        "--rw=randrw --bs=4k --iodepth=4 --numjobs=2 --rwmixread=70"
    )
    
    # 执行所有测试
    local failed=0
    for ((i=0; i<${#test_names[@]}; i++)); do
        run_test "${test_names[$i]}" "${test_params[$i]}" || ((failed++))
    done
    
    # 输出测试报告
    echo -e "\n${BLUE}================= 测试报告 ================${NC}"
    echo -e "${GREEN}磁盘: ${DISK} (类型: $(lsblk -d -o ROTA "$DISK" | tail -n1 | sed 's/0/SSD/;s/1/HDD/'))${NC}"
    echo -e "${GREEN}测试文件: ${TEST_SIZE} | 运行时间: ${RUNTIME}秒/测试${NC}"
    echo -e "${BLUE}==========================================${NC}\n"
    
    # 解析每个测试结果
    for ((i=0; i<${#test_names[@]}; i++)); do
        local log_file="$LOG_DIR/${test_names[$i]}.json"
        parse_result "${test_names[$i]}" "$log_file"
    done
    
    # 性能评分
    if [ $failed -eq 0 ]; then
        echo -e "${BLUE}\n性能评分: ${GREEN}PASS${NC} (所有测试成功完成)"
    else
        echo -e "${BLUE}\n性能评分: ${RED}FAIL${NC} (${failed}项测试失败)"
    fi
    
    # 清理临时文件
    rm -f "$TEST_FILE"
    echo -e "${BLUE}\n测试完成！详细日志保存在: ${LOG_DIR}${NC}"
}

# 执行主函数
main
