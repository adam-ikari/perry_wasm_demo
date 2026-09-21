/*
 * bench_time.c — 基准专用计时包装 (只用于性能测量, 不改 host/perry_link.c)。
 *
 * 复用 perry_link 的 load/register/instantiate/execute_main 流程, 增加计时:
 *   INIT_MS  <ms>   进程 main 入口 -> 模块加载/注册/实例化完成 ("启动到开始计算")
 *   RUN <i>  <ms>   第 i 次 execute_main 耗时 (i 从 1 起; 前 WARMUP 次为预热)
 *
 * 用法: bench_time <app.wasm> <rt.wasm> <runs>
 * 时钟: CLOCK_MONOTONIC, 单位毫秒, 输出到 stdout (供 bench.sh 解析)。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "wasm_export.h"

#define WARMUP 1

static uint8_t *
read_file(const char *path, uint32_t *out_size)
{
    FILE *file = fopen(path, "rb");
    long size;
    uint8_t *buffer;

    if (!file)
        return NULL;
    fseek(file, 0, SEEK_END);
    size = ftell(file);
    fseek(file, 0, SEEK_SET);
    if (size <= 0) {
        fclose(file);
        return NULL;
    }
    buffer = malloc((size_t)size);
    if (!buffer || fread(buffer, 1, (size_t)size, file) != (size_t)size) {
        fclose(file);
        free(buffer);
        return NULL;
    }
    fclose(file);
    *out_size = (uint32_t)size;
    return buffer;
}

static double
now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

int
main(int argc, char *argv[])
{
    RuntimeInitArgs init_args;
    char error_buf[256] = { 0 };
    uint32_t app_size = 0, rt_size = 0;
    uint8_t *app_buf, *rt_buf;
    wasm_module_t app, rt;
    wasm_module_inst_t app_inst;
    int runs, i;
    double t_start, t_ready;

    if (argc != 4) {
        fprintf(stderr, "usage: %s <app.wasm> <rt.wasm> <runs>\n", argv[0]);
        return 2;
    }
    runs = atoi(argv[3]);
    if (runs < 1)
        runs = 1;

    t_start = now_ms();
    memset(&init_args, 0, sizeof init_args);
    init_args.mem_alloc_type = Alloc_With_System_Allocator;
    if (!wasm_runtime_full_init(&init_args)) {
        fprintf(stderr, "wasm_runtime_full_init failed\n");
        return 1;
    }

    if (!(rt_buf = read_file(argv[2], &rt_size)) || !(app_buf = read_file(argv[1], &app_size)))
        return 1;

    rt = wasm_runtime_load(rt_buf, rt_size, error_buf, sizeof error_buf);
    if (!rt) {
        fprintf(stderr, "load runtime module: %s\n", error_buf);
        return 1;
    }
    if (!wasm_runtime_register_module("rt", rt, error_buf, sizeof error_buf)) {
        fprintf(stderr, "register runtime module: %s\n", error_buf);
        return 1;
    }
    wasm_runtime_set_wasi_args(rt, NULL, 0, NULL, 0, NULL, 0, NULL, 0);

    app = wasm_runtime_load(app_buf, app_size, error_buf, sizeof error_buf);
    if (!app) {
        fprintf(stderr, "load app module: %s\n", error_buf);
        return 1;
    }
    app_inst = wasm_runtime_instantiate(app, 64 * 1024, 0, error_buf, sizeof error_buf);
    if (!app_inst) {
        fprintf(stderr, "instantiate app module: %s\n", error_buf);
        return 1;
    }
    t_ready = now_ms();
    printf("INIT_MS %.3f\n", t_ready - t_start);
    fflush(stdout);

    /* 预热: 首次执行含模块内运行时初始化 (字符串表/堆), 不计时 */
    if (!wasm_application_execute_main(app_inst, 0, NULL)) {
        fprintf(stderr, "warmup execute failed: %s\n",
                wasm_runtime_get_exception(app_inst));
        return 1;
    }

    for (i = 1; i <= runs; i++) {
        double t0 = now_ms();
        if (!wasm_application_execute_main(app_inst, 0, NULL)) {
            fprintf(stderr, "run %d failed: %s\n", i,
                    wasm_runtime_get_exception(app_inst));
            return 1;
        }
        printf("RUN %d %.3f\n", i, now_ms() - t0);
        fflush(stdout);
    }
    return 0;
}
