/*
 * xmod_time.c — 归因对照计时器 2: 双模块 (app 导入 triv) 跨模块调用开销测量。
 * triv 模块由 wat 现场给出 (两个平凡 wasm 函数), app 每层 fib 递归做 2 次跨模块调用,
 * 与 perry fib 的 mem_call* 调用图相同但被调方无任何分派/装箱成本。
 *
 * 用法: xmod_time <app.wasm> <triv.wasm> <runs>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "wasm_export.h"

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
    uint32_t app_size = 0, triv_size = 0;
    uint8_t *app_buf, *triv_buf;
    wasm_module_t app, triv;
    wasm_module_inst_t app_inst;
    int runs, i;
    double t0, t1;

    if (argc != 4) {
        fprintf(stderr, "usage: %s <app.wasm> <triv.wasm> <runs>\n", argv[0]);
        return 2;
    }
    runs = atoi(argv[3]);

    memset(&init_args, 0, sizeof init_args);
    init_args.mem_alloc_type = Alloc_With_System_Allocator;
    if (!wasm_runtime_full_init(&init_args)) {
        fprintf(stderr, "init failed\n");
        return 1;
    }
    if (!(triv_buf = read_file(argv[2], &triv_size)) ||
        !(app_buf = read_file(argv[1], &app_size)))
        return 1;
    triv = wasm_runtime_load(triv_buf, triv_size, error_buf, sizeof error_buf);
    if (!triv) {
        fprintf(stderr, "load triv: %s\n", error_buf);
        return 1;
    }
    if (!wasm_runtime_register_module("triv", triv, error_buf, sizeof error_buf)) {
        fprintf(stderr, "register triv: %s\n", error_buf);
        return 1;
    }
    app = wasm_runtime_load(app_buf, app_size, error_buf, sizeof error_buf);
    if (!app) {
        fprintf(stderr, "load app: %s\n", error_buf);
        return 1;
    }
    app_inst = wasm_runtime_instantiate(app, 64 * 1024, 0, error_buf, sizeof error_buf);
    if (!app_inst) {
        fprintf(stderr, "instantiate: %s\n", error_buf);
        return 1;
    }

    /* 预热 + 验证 */
    if (!wasm_application_execute_main(app_inst, 0, NULL)) {
        fprintf(stderr, "warmup failed: %s\n", wasm_runtime_get_exception(app_inst));
        return 1;
    }
    for (i = 0; i < runs; i++) {
        t0 = now_ms();
        if (!wasm_application_execute_main(app_inst, 0, NULL)) {
            fprintf(stderr, "run %d failed: %s\n", i,
                    wasm_runtime_get_exception(app_inst));
            return 1;
        }
        t1 = now_ms();
        printf("RUN %d %.3f\n", i + 1, t1 - t0);
    }
    wasm_runtime_destroy();
    return 0;
}
