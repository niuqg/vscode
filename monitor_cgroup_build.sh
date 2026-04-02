#!/bin/bash

# Output file
LOG_FILE="cgroup_stats.csv"
SUMMARY_FILE="cgroup_summary.txt"
BUILD_CMD="${@:-npm run compile}"

# CGroup v2 paths
CGROUP_ROOT="/sys/fs/cgroup"
CPU_STAT="$CGROUP_ROOT/cpu.stat"
MEM_CURRENT="$CGROUP_ROOT/memory.current"
SWAP_CURRENT="$CGROUP_ROOT/memory.swap.current"

# Check if CGroup v2 is available
if [ ! -f "$CPU_STAT" ]; then
    echo "Error: CGroup v2 not detected at $CGROUP_ROOT. This script requires CGroup v2."
    exit 1
fi

# Function to get current time in microseconds
get_time_us() {
    date +%s%6N
}

# Function to get CPU usage in microseconds from cpu.stat
get_cpu_usage_us() {
    grep "usage_usec" "$CPU_STAT" | awk '{print $2}'
}

# Function to get memory in bytes
get_mem_bytes() {
    cat "$MEM_CURRENT" 2>/dev/null || echo 0
}

# Function to get swap in bytes
get_swap_bytes() {
    cat "$SWAP_CURRENT" 2>/dev/null || echo 0
}

echo "Timestamp,CPU_Cores,Memory_MB,Swap_MB" > "$LOG_FILE"

# Start monitoring in background
monitor() {
    local prev_cpu_us=$(get_cpu_usage_us)
    local prev_time_us=$(get_time_us)
    
    while true; do
        sleep 1
        
        local curr_cpu_us=$(get_cpu_usage_us)
        local curr_time_us=$(get_time_us)
        local mem_bytes=$(get_mem_bytes)
        local swap_bytes=$(get_swap_bytes)
        
        # Calculate deltas
        local delta_cpu_us=$((curr_cpu_us - prev_cpu_us))
        local delta_time_us=$((curr_time_us - prev_time_us))
        
        # Avoid division by zero
        if [ $delta_time_us -eq 0 ]; then delta_time_us=1; fi
        
        # Calculate CPU cores used (float)
        # usage_us / time_us = cores
        # We use awk for floating point arithmetic
        local cpu_cores=$(awk -v cpu="$delta_cpu_us" -v time="$delta_time_us" 'BEGIN { printf "%.2f", cpu / time }')
        
        # Calculate Memory in MB
        local mem_mb=$(awk -v mem="$mem_bytes" 'BEGIN { printf "%.2f", mem / 1024 / 1024 }')
        local swap_mb=$(awk -v swap="$swap_bytes" 'BEGIN { printf "%.2f", swap / 1024 / 1024 }')
        
        local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
        
        echo "$timestamp,$cpu_cores,$mem_mb,$swap_mb" >> "$LOG_FILE"
        
        prev_cpu_us=$curr_cpu_us
        prev_time_us=$curr_time_us
    done
}

echo "Starting CGroup resource monitoring..."
monitor &
MONITOR_PID=$!

# Execute Build
echo "----------------------------------------"
echo "Starting Build Command: $BUILD_CMD"
echo "----------------------------------------"
START_TIME=$(date +%s)

eval "$BUILD_CMD"
BUILD_EXIT_CODE=$?

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "----------------------------------------"
if [ $BUILD_EXIT_CODE -eq 0 ]; then
    echo "Build Finished Successfully in ${DURATION} seconds."
else
    echo "Build Failed with exit code $BUILD_EXIT_CODE after ${DURATION} seconds."
fi
echo "----------------------------------------"

# Stop monitoring
kill $MONITOR_PID
wait $MONITOR_PID 2>/dev/null

echo "Analyzing CGroup resource usage..."

# Analyze CSV
awk -F',' '
BEGIN {
    max_cpu = 0; sum_cpu = 0; count = 0;
    max_mem = 0; sum_mem = 0;
    max_swap = 0;
}
NR > 1 {
    cpu = $2;
    mem = $3;
    swap = $4;
    
    if (cpu > max_cpu) max_cpu = cpu;
    sum_cpu += cpu;
    
    if (mem > max_mem) max_mem = mem;
    sum_mem += mem;
    
    if (swap > max_swap) max_swap = swap;
    
    count++;
}
END {
    if (count > 0) {
        printf "\n=== Container Resource Analysis (CGroup) ===\n";
        printf "Duration: %d seconds\n", count;
        printf "\n[CPU Usage]\n";
        printf "  Max Cores Used: %.2f\n", max_cpu;
        printf "  Avg Cores Used: %.2f\n", sum_cpu / count;
        
        printf "\n[Memory Usage]\n";
        printf "  Max Memory: %.2f MB\n", max_mem;
        printf "  Avg Memory: %.2f MB\n", sum_mem / count;
        
        printf "\n[Swap Usage]\n";
        printf "  Max Swap: %.2f MB\n", max_swap;
        
        # Recommendations
        printf "\n[Recommendations]\n";
        if (max_swap > 0) printf "- Swap usage detected! Increase container memory limit.\n";
        if (max_cpu < 0.5) printf "- CPU usage very low (< 0.5 cores). Build might be I/O bound or single-threaded.\n";
    } else {
        print "No data collected.";
    }
}
' "$LOG_FILE" | tee "$SUMMARY_FILE"
