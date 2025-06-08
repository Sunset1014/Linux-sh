#!/bin/bash

# 终极版磁盘性能测试脚本
# 智能环境检测、优雅进度显示、完整结果分析
# 作者：Sunset1014

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # 恢复默认颜色

# 样式函数
print_header() {
    echo -e "${BLUE}
   _____            __  __            _       _     
  / ____|          |  \/  |          (_)     | |    
 | |     ___  _ __ | \  / | __ _ _ __ _  __ _| |___ 
 | |    / _ \| '_ \| |\/| |/ _\` | '__| |/ _\` | / __|
 | |___| (_) | | | | |  | | (_| | |  | | (_| | \__ \\
  \_____\___/|_| |_|_|  |_|\__,_|_|  |_|\__,_|_|___/
${NC}"
}

# 检查命令是否存在
check_command() {
    command -v "$1" >/dev/null 2>&1
}

# 检查并安装依赖
check_dependencies() {
    echo -e "${BLUE}正在检查系统依赖...${NC}"
    local dependencies=("fio" "jq")
    local missing=()
    
    for dep in "${dependencies[@]}"; do
        if ! check_command "$dep"; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}缺少依赖: ${missing[*]}${NC}"
        
        # 检测包管理器
        if check_command "apt-get"; then
            echo -e "${BLUE}使用 apt-get 安装依赖...${NC}"
            sudo apt-get update && sudo apt-get install -y "${missing[@]}"
        elif check_command "yum"; then
            echo -e "${BLUE}使用 yum 安装依赖...${NC}"
            sudo yum install -y "${missing[@]}"
        else
            echo -e "${RED}无法自动安装依赖，请手动安装: ${missing[*]}${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}所有依赖已安装${NC}"
    fi
}

# 智能检测磁盘类型
detect_disk_type() {
    local disk_path="/dev/sda"  # 默认检测系统盘
    if [ -n "$1" ]; then
        disk_path="$1"  # 使用用户指定的磁盘
    fi
    
    if ! [ -e "$disk_path" ]; then
        echo -e "${RED}错误: 磁盘 $disk_path 不存在${NC}"
        return 1
    fi
    
    # 尝试检测 SSD/HDD
    if check_command "lsblk"; then
        local rotational=$(lsblk -d -o "ROTA" "$disk_path" | tail -n 1 | tr -d '[:space:]')
        if [ "$rotational" = "0" ]; then
            DISK_TYPE="SSD"
        else
            DISK_TYPE="HDD"
        fi
    else
        # 回退方案：检查 SMART 信息
        if check_command "smartctl"; then
            local ssd_info=$(smartctl -i "$disk_path" 2>/dev/null | grep -i "solid state device")
            if [ -n "$ssd_info" ]; then
                DISK_TYPE="SSD"
            else
                DISK_TYPE="HDD"
            fi
        else
            DISK_TYPE="未知"
        fi
    fi
    
    # 获取磁盘容量
    if check_command "lsblk"; then
        DISK_SIZE=$(lsblk -d -o "SIZE" "$disk_path" | tail -n 1 | tr -d '[:space:]')
    else
        DISK_SIZE="未知"
    fi
    
    echo -e "${BLUE}检测到磁盘: $disk_path (类型: $DISK_TYPE, 容量: $DISK_SIZE)${NC}"
    return 0
}

# 智能确定测试文件大小
determine_test_size() {
    local total_ram=$(free -g | awk '/^Mem:/{print $2}')
    local disk_available=$(df -BG "$TEST_DIR" | awk 'NR==2{print $4}' | tr -d 'G')
    
    # 默认测试文件大小为 RAM 的 1/2，但不超过可用磁盘空间的 10%
    local default_size=$((total_ram > 1 ? total_ram / 2 : 1))
    
    # 确保测试文件不会填满磁盘
    if [ $((default_size * 10)) -gt $disk_available ]; then
        default_size=$((disk_available / 10))
        if [ $default_size -lt 1 ]; then
            default_size=1
        fi
    fi
    
    TEST_SIZE="${default_size}G"
    echo -e "${BLUE}自动确定测试文件大小: $TEST_SIZE${NC}"
}

# 进度条显示
show_progress() {
    local pid=$1
    local msg=$2
    local duration=$3
    local start_time=$(date +%s)
    local end_time=$((start_time + duration))
    local width=50
    
    while kill -0 $pid 2>/dev/null; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        local percent=$((elapsed * 100 / duration))
        local filled=$((percent * width / 100))
        local empty=$((width - filled))
        
        # 构建进度条
        local bar="["
        for ((i=0; i<filled; i++)); do
            bar="${bar}█"
        done
        for ((i=0; i<empty; i++)); do
            bar="${bar} "
        done
        bar="${bar}]"
        
        # 计算剩余时间
        local remaining=$((end_time - current_time))
        local minutes=$((remaining / 60))
        local seconds=$((remaining % 60))
        
        echo -ne "${BLUE}${bar} ${percent}% (剩余: ${minutes}m${seconds}s) ${msg}...${NC}\r"
        sleep 1
    done
    
    # 完成后显示100%
    echo -e "${BLUE}[${GREEN}$(printf "%${width}s" | tr ' ' '█')${BLUE}] 100% ${msg} 完成${NC}"
}

# 执行测试
run_test() {
    local test_name=$1
    local params=$2
    local log_file="$LOG_DIR/${test_name}.json"
    
    echo -e "${BLUE}开始 ${test_name} 测试...${NC}"
    fio --name="${test_name}" --output-format=json --filename="$TEST_FILE" \
        --size="$TEST_SIZE" --runtime="$RUNTIME" --group_reporting \
        ${params} > "$log_file" 2>/dev/null &
    
    local test_pid=$!
    show_progress $test_pid "${test_name}" "$RUNTIME"
    wait $test_pid
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}${test_name} 测试失败${NC}"
        return 1
    fi
    
    return 0
}

# 解析测试结果
parse_result() {
    local test_type=$1
    local log_file="$2"
    
    # 提取基本指标
    local bw=$(jq -r ".jobs[0].read.bw // .jobs[0].write.bw // .jobs[0].total.bw" "$log_file")
    local iops=$(jq -r ".jobs[0].read.iops // .jobs[0].write.iops // .jobs[0].total.iops" "$log_file")
    local lat=$(jq -r ".jobs[0].read.lat.nsec.mean // .jobs[0].write.lat.nsec.mean // .jobs[0].total.lat.nsec.mean" "$log_file")
    
    # 转换单位
    local bw_mb=$(echo "scale=2; $bw / 1024" | bc)
    local lat_ms=$(echo "scale=2; $lat / 1000000" | bc)
    
    # 输出结果
    echo -e "${BLUE}→ ${test_type} 测试结果:${NC}"
    echo -e "  ${GREEN}带宽: ${bw_mb} MB/s${NC}"
    echo -e "  ${GREEN}IOPS: ${iops}${NC}"
    echo -e "  ${GREEN}平均延迟: ${lat_ms} ms${NC}"
    
    # 根据磁盘类型提供参考值
    if [ "$DISK_TYPE" = "SSD" ]; then
        echo -e "  ${YELLOW}SSD 参考: 顺序读写 > 300 MB/s, 随机 4K 读写 > 10,000 IOPS${NC}"
    elif [ "$DISK_TYPE" = "HDD" ]; then
        echo -e "  ${YELLOW}HDD 参考: 顺序读写 > 100 MB/s, 随机 4K 读写 > 100 IOPS${NC}"
    fi
    
    echo
}

# 主函数
main() {
    # 初始化
    print_header
    TEST_DIR="${TEST_DIR:-/home/sunset1014/test_dir}"
    mkdir -p "$TEST_DIR" || { echo -e "${RED}无法创建测试目录！${NC}"; exit 1; }
    LOG_DIR="$TEST_DIR/logs"
    mkdir -p "$LOG_DIR"
    TEST_FILE="$TEST_DIR/fio.test"
    RUNTIME="${RUNTIME:-30}"  # 默认每个测试运行30秒
    
    # 检查依赖
    check_dependencies
    
    # 检测磁盘类型
    detect_disk_type || exit 1
    
    # 确定测试文件大小
    determine_test_size
    
    # 清理旧文件
    rm -f "$TEST_FILE"
    
    # 测试参数
    local tests=(
        "顺序写入测试" "--ioengine=libaio --iodepth=1 --rw=write --bs=1M --numjobs=1"
        "顺序读取测试" "--ioengine=libaio --iodepth=1 --rw=read --bs=1M --numjobs=1"
        "随机写入测试" "--ioengine=libaio --iodepth=32 --rw=randwrite --bs=4k --numjobs=4"
        "随机读取测试" "--ioengine=libaio --iodepth=32 --rw=randread --bs=4k --numjobs=4"
        "混合读写测试" "--ioengine=libaio --iodepth=32 --rw=randrw --bs=4k --numjobs=4 --rwmixread=70"
    )
    
    # 执行所有测试
    local failed_tests=0
    for ((i=0; i<${#tests[@]}; i+=2)); do
        local test_name="${tests[$i]}"
        local test_params="${tests[$((i+1))]}"
        
        run_test "$test_name" "$test_params"
        if [ $? -ne 0 ]; then
            ((failed_tests++))
        fi
    done
    
    # 输出结果
    echo -e "${BLUE}\n\n==================== 测试结果汇总 ====================${NC}"
    echo -e "${GREEN}测试目录: ${TEST_DIR}${NC}"
    echo -e "${GREEN}测试文件大小: ${TEST_SIZE}${NC}"
    echo -e "${GREEN}磁盘类型: ${DISK_TYPE}${NC}"
    echo -e "${BLUE}=====================================================${NC}\n"
    
    # 解析每个测试结果
    for ((i=0; i<${#tests[@]}; i+=2)); do
        local test_name="${tests[$i]}"
        local log_file="$LOG_DIR/${test_name}.json"
        
        if [ -f "$log_file" ]; then
            parse_result "$test_name" "$log_file"
        else
            echo -e "${RED}无法找到 ${test_name} 的结果文件！${NC}"
        fi
    done
    
    # 性能评分
    echo -e "${BLUE}\n==================== 性能评分 ====================${NC}"
    if [ "$DISK_TYPE" = "SSD" ]; then
        local seq_write=$(jq -r ".jobs[0].write.bw" "$LOG_DIR/顺序写入测试.json")
        local rand_read=$(jq -r ".jobs[0].read.iops" "$LOG_DIR/随机读取测试.json")
        
        local score_seq=$((seq_write / 3000))  # 每300MB/s得1分
        local score_rand=$((rand_read / 10000))  # 每10000IOPS得1分
        local total_score=$(((score_seq + score_rand) * 5))
        
        if [ $total_score -gt 100 ]; then
            total_score=100
        fi
        
        echo -e "${GREEN}总评分: ${total_score}/100${NC}"
        echo -e "${YELLOW}评分说明: SSD 性能优异(80-100), 良好(60-79), 一般(40-59), 较差(<40)${NC}"
    elif [ "$DISK_TYPE" = "HDD" ]; then
        local seq_write=$(jq -r ".jobs[0].write.bw" "$LOG_DIR/顺序写入测试.json")
        local rand_read=$(jq -r ".jobs[0].read.iops" "$LOG_DIR/随机读取测试.json")
        
        local score_seq=$((seq_write / 1000))  # 每100MB/s得1分
        local score_rand=$((rand_read / 100))  # 每100IOPS得1分
        local total_score=$(((score_seq + score_rand) * 5))
        
        if [ $total_score -gt 100 ]; then
            total_score=100
        fi
        
        echo -e "${GREEN}总评分: ${total_score}/100${NC}"
        echo -e "${YELLOW}评分说明: HDD 性能优异(80-100), 良好(60-79), 一般(40-59), 较差(<40)${NC}"
    fi
    
    # 清理测试文件
    rm -f "$TEST_FILE"
    echo -e "${BLUE}\n测试完成！临时文件已清理${NC}"
    echo -e "${BLUE}详细日志保存在: ${LOG_DIR}${NC}"
}

# 执行主函数
main    
