#!/bin/bash

# Default build command if none provided
BUILD_CMD="${@:-npm run compile}"
LOG_FILE="vmstat_build.log"

# Function to get total memory in KB
get_total_mem() {
    grep MemTotal /proc/meminfo | awk '{print $2}'
}

MEM_TOTAL_KB=$(get_total_mem)
echo "Total System Memory: $((MEM_TOTAL_KB / 1024)) MB"

# Start vmstat monitoring
echo "Starting resource monitoring (vmstat)..."
# -n: one header, -t: timestamp, -w: wide output
vmstat -n -t -w 1 > "$LOG_FILE" &
VMSTAT_PID=$!

# Run the build command
echo "----------------------------------------"
echo "Starting Build: $BUILD_CMD"
echo "----------------------------------------"
START_TIME=$(date +%s)

# Execute the build command
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
kill $VMSTAT_PID
wait $VMSTAT_PID 2>/dev/null

echo "Analyzing resource usage from $LOG_FILE..."

# Analyze log with awk
awk -v mem_total="$MEM_TOTAL_KB" '
BEGIN {
    max_cpu = 0; sum_cpu = 0; count = 0;
    max_mem_used = 0; sum_mem_used = 0;
    max_swap = 0;
    
    # Initialize column indices to -1
    us_idx = -1; sy_idx = -1;
    swpd_idx = -1; free_idx = -1; buff_idx = -1; cache_idx = -1;
}

# Header detection
/swpd/ { 
    for (i=1; i<=NF; i++) {
        if ($i == "us") us_idx = i;
        if ($i == "sy") sy_idx = i;
        if ($i == "swpd") swpd_idx = i;
        if ($i == "free") free_idx = i;
        if ($i == "buff") buff_idx = i;
        if ($i == "cache") cache_idx = i;
    }
    next 
}

# Skip other header lines
/procs/ { next }
/memory/ { next }
/timestamp/ { next }

{
    # Skip lines if we haven"t found headers yet
    if (us_idx == -1) next;
    
    # Skip short lines (e.g. startup artifacts)
    if (NF < 15) next;

    # Parse CPU (us + sy)
    us = $us_idx;
    sy = $sy_idx;
    cpu_usage = us + sy;
    
    if (cpu_usage > max_cpu) max_cpu = cpu_usage;
    sum_cpu += cpu_usage;
    
    # Parse Memory Usage
    # Used = Total - Free - Buff - Cache
    free = $free_idx;
    buff = $buff_idx;
    cache = $cache_idx;
    
    used_kb = mem_total - free - buff - cache;
    # Ensure non-negative (just in case of weird accounting)
    if (used_kb < 0) used_kb = 0;
    
    used_mb = used_kb / 1024;
    
    if (used_mb > max_mem_used) max_mem_used = used_mb;
    sum_mem_used += used_mb;

    # Parse Swap
    swap = $swpd_idx;
    if (swap > max_swap) max_swap = swap;

    count++;
}

END {
    if (count > 0) {
        printf "\n=== Resource Usage Analysis ===\n";
        printf "Duration: %d seconds\n", count;
        printf "\n[CPU Usage]\n";
        printf "  Max: %.1f%%\n", max_cpu;
        printf "  Avg: %.1f%%\n", sum_cpu / count;
        
        printf "\n[Memory Usage]\n";
        printf "  Max Used: %.1f MB (%.1f%% of Total)\n", max_mem_used, (max_mem_used / (mem_total/1024)) * 100;
        printf "  Avg Used: %.1f MB\n", sum_mem_used / count;
        
        printf "\n[Swap Usage]\n";
        printf "  Max Swap: %.1f KB\n", max_swap;
        
        # Recommendations
        printf "\n[Recommendations]\n";
        if (max_cpu > 90) printf "- CPU saturation detected (Max > 90%%). Consider checking parallelism settings.\n";
        if ((max_mem_used / (mem_total/1024)) > 0.9) printf "- High Memory Usage (>90%%). Risk of OOM.\n";
        if (max_swap > 0) printf "- Swap usage detected! Performance may degrade significantly.\n";
        if (max_cpu < 50) printf "- CPU underutilized (< 50%% Max). Build might be I/O bound or single-threaded.\n";
        
    } else {
        print "No valid data collected in log file.";
    }
}
' "$LOG_FILE" | tee "resource_summary.txt"
