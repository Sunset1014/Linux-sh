#!/bin/bash

# 磁盘性能测试脚本（终极修复版）
# 解决读取测试失败和进度条显示异常问题

# 颜色与样式
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BAR_LENGTH=50

# ASCII 艺术字
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
    TEST_SIZE="4G"
    RUNTIME="60"
    DISK="/dev/sda"
}

# 打印优雅进度条（修复版）
print_progress() {
    local percent=$1; local max=$2; local status=$3
    local filled=$((percent * BAR_LENGTH / max))
    local empty=$((BAR_LENGTH - filled))
    
    local bar="${BLUE}[${GREEN}$(printf "%-${filled}s" "" | tr ' ' '#')${BLUE}$(printf "%-${empty}s" "" | tr ' ' '-')${BLUE}]${NC}"
    
    if [ $percent -eq $max ]; then
        percent="${GREEN}${percent}${NC}"
    else
        percent="${BLUE}${percent}${NC}"
    fi
    
    echo -ne "${bar} ${percent}% ${status}...${NC}\r"
}

# 执行测试并显示进度（修复版）
run_test() {
    local name=$1; shift
    local params="$*"
    local log_file="$LOG_DIR/${name}.json"
    local err_file="$LOG_DIR/${name}.err"
    
    echo -e "${BLUE}开始 ${name} 测试...${NC}"
    
    # 清理缓存并重建测试文件
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    rm -f "$TEST_FILE"
    
    # 执行测试
    fio --name="${name}" --filename="$TEST_FILE" --size="$TEST_SIZE" --runtime="$RUNTIME" \
        --output-format=json $params > "$log_file" 2>"$err_file" &
    
    local pid=$!
    local start_time=$(date +%s)
    
    while kill -0 $pid 2>/dev/null; do
        local elapsed=$(( $(date +%s) - start_time ))
        local percent=$(( elapsed * 100 / RUNTIME ))
        
        # 确保百分比不超过100
        if [ $percent -gt 100 ]; then
            percent=100
        fi
        
        print_progress $percent 100 "$name"
        sleep 1
    done
    
    # 确保最终显示100%完成
    print_progress 100 100 "$name ${GREEN}完成${NC}"
    echo
    
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
    
    # 检查JSON文件是否有效
    if ! jq empty "$log_file" >/dev/null 2>&1; then
        echo -e "${RED}${name} 结果文件格式错误！${NC}"
        echo -e "${YELLOW}错误详情:${NC}"
        jq "$log_file" 2>&1 | sed 's/^/  /'
        return 1
    fi
    
    local bw=$(jq -r ".jobs[0].write.bw // .jobs[0].read.bw" "$log_file")
    local iops=$(jq -r ".jobs[0].write.iops // .jobs[0].read.iops" "$log_file")
    local lat=$(jq -r ".jobs[0].write.lat.nsec.mean // .jobs[0].read.lat.nsec.mean" "$log_file")
    
    local bw_mb=$(echo "scale=2; $bw / 1024" | bc -l)
    local lat_ms=$(echo "scale=2; $lat / 1000000" | bc -l)
    
    echo -e "${BLUE}→ ${name} 测试结果:${NC}"
    echo -e "  ${GREEN}带宽: ${bw_mb} MB/s${NC}"
    echo -e "  ${GREEN}IOPS: ${iops}${NC}"
    echo -e "  ${GREEN}平均延迟: ${lat_ms} ms${NC}"
    
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
    
    mkdir -p "$TEST_DIR" "$LOG_DIR" || { echo -e "${RED}无法创建测试目录！${NC}"; exit 1; }
    rm -f "$TEST_FILE"
    
    # 优化的测试参数（针对虚拟机环境）
    local test_names=("顺序写入" "顺序读取" "随机写入" "随机读取" "混合读写")
    local test_params=(
        "--rw=write --bs=1M --iodepth=1 --numjobs=1 --ioengine=sync --direct=1"  # 直接IO
        "--rw=read --bs=1M --iodepth=16 --numjobs=1 --ioengine=libaio --direct=1"  # 读取使用libaio
        "--rw=randwrite --bs=4k --iodepth=8 --numjobs=1 --ioengine=libaio --direct=1"
        "--rw=randread --bs=4k --iodepth=8 --numjobs=1 --ioengine=libaio --direct=1"
        "--rw=randrw --bs=4k --iodepth=8 --numjobs=1 --ioengine=libaio --direct=1 --rwmixread=70"
    )
    
    local failed=0
    for ((i=0; i<${#test_names[@]}; i++)); do
        run_test "${test_names[$i]}" "${test_params[$i]}" || ((failed++))
    done
    
    echo -e "\n${BLUE}================= 测试报告 ================${NC}"
    echo -e "${GREEN}磁盘: ${DISK} (类型: $(lsblk -d -o ROTA "$DISK" | tail -n1 | sed 's/0/SSD/;s/1/HDD/'))${NC}"
    echo -e "${GREEN}测试文件: ${TEST_SIZE} | 运行时间: ${RUNTIME}秒/测试${NC}"
    echo -e "${BLUE}==========================================${NC}\n"
    
    for ((i=0; i<${#test_names[@]}; i++)); do
        parse_result "${test_names[$i]}" "$LOG_DIR/${test_names[$i]}.json"
    done
    
    # 改进的性能评分
    if [ $failed -eq 0 ]; then
        local all_valid=1
        for name in "${test_names[@]}"; do
            local log="$LOG_DIR/${name}.json"
            if [ ! -s "$log" ] || ! jq empty "$log" >/dev/null 2>&1; then
                all_valid=0
                break
            fi
        done
        
        if [ $all_valid -eq 1 ]; then
            # 检查关键指标是否为0
            local has_zero=0
            for name in "${test_names[@]}"; do
                local log="$LOG_DIR/${name}.json"
                local bw=$(jq -r ".jobs[0].write.bw // .jobs[0].read.bw" "$log")
                if [ "$bw" = "0" ]; then
                    has_zero=1
                    echo -e "${YELLOW}警告: ${name} 带宽为0，结果可能异常${NC}"
                fi
            done
            
            if [ $has_zero -eq 0 ]; then
                echo -e "${BLUE}\n性能评分: ${GREEN}PASS${NC} (所有测试成功完成)"
            else
                echo -e "${BLUE}\n性能评分: ${YELLOW}WARNING${NC} (部分测试结果异常但无错误)"
            fi
        else
            echo -e "${BLUE}\n性能评分: ${RED}FAIL${NC} (部分测试结果无效)"
        fi
    else
        echo -e "${BLUE}\n性能评分: ${RED}FAIL${NC} (${failed}项测试失败)"
    fi
    
    rm -f "$TEST_FILE"
    echo -e "${BLUE}\n测试完成！详细日志保存在: ${LOG_DIR}${NC}"
}

main
