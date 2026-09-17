/*
 * perry_link.c — 把 perry 产出的业务模块和它需要的运行时模块链接起来执行。
 *
 * 与上一版 demo 的区别：这里没有"用 C 重写的 rt.* 实现"，也没有 --native-lib。
 * rt.* 由另一个 wasm 模块提供 —— 那个模块是 runtime-wasm/ 里的 Rust 源码用
 * wasm32-unknown-unknown 编出来的。宿主只做两件事：
 *   1. 把运行时模块用名字 "rt" 注册进 WAMR 的全局模块表 (业务模块 import 的就是它);
 *   2. 给运行时模块配上 WASI (它用 fd_write 写 stdout/stderr)。
 * 内存只有一块: 运行时模块导出 memory, 业务模块 import 它 (tools/patch-app-memory.mjs)。
 *
 * 用法: perry_link <app.wasm> <rt.wasm>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "wasm_export.h"

static uint8_t *
read_file(const char *path, uint32_t *out_size)
{
    FILE *file = fopen(path, "rb");
    long size;
    uint8_t *buffer;

    if (!file) {
        fprintf(stderr, "cannot open %s\n", path);
        return NULL;
    }
    fseek(file, 0, SEEK_END);
    size = ftell(file);
    fseek(file, 0, SEEK_SET);
    if (size <= 0) {
        fclose(file);
        fprintf(stderr, "%s: empty\n", path);
        return NULL;
    }
    buffer = malloc((size_t)size);
    if (!buffer || fread(buffer, 1, (size_t)size, file) != (size_t)size) {
        fclose(file);
        free(buffer);
        fprintf(stderr, "%s: read failed\n", path);
        return NULL;
    }
    fclose(file);
    *out_size = (uint32_t)size;
    return buffer;
}

static int
fail(const char *what, const char *detail)
{
    fprintf(stderr, "%s: %s\n", what, detail ? detail : "(no message)");
    return 1;
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
    const char *exception;

    if (argc != 3) {
        fprintf(stderr, "usage: %s <app.wasm> <rt.wasm>\n", argv[0]);
        return 2;
    }

    memset(&init_args, 0, sizeof init_args);
    init_args.mem_alloc_type = Alloc_With_System_Allocator;
    if (!wasm_runtime_full_init(&init_args))
        return fail("wasm_runtime_full_init", NULL);

    if (!(rt_buf = read_file(argv[2], &rt_size)) || !(app_buf = read_file(argv[1], &app_size)))
        return 1;

    /* 1. 运行时模块先加载并注册成 "rt" —— 业务模块的 212 个导入 (211 个函数 + memory)
     *    都在加载时按这个名字解析。 */
    rt = wasm_runtime_load(rt_buf, rt_size, error_buf, sizeof error_buf);
    if (!rt)
        return fail("load runtime module", error_buf);
    if (!wasm_runtime_register_module("rt", rt, error_buf, sizeof error_buf))
        return fail("register runtime module", error_buf);

    /* 2. 运行时用 WASI 的 fd_write 打日志 (默认 stdio)。 */
    wasm_runtime_set_wasi_args(rt, NULL, 0, NULL, 0, NULL, 0, NULL, 0);

    app = wasm_runtime_load(app_buf, app_size, error_buf, sizeof error_buf);
    if (!app)
        return fail("load app module", error_buf);

    /* 3. 实例化业务模块 —— WAMR 会一并实例化它依赖的 "rt" 模块并完成符号/内存链接。 */
    app_inst = wasm_runtime_instantiate(app, 64 * 1024, 0, error_buf, sizeof error_buf);
    if (!app_inst)
        return fail("instantiate app module", error_buf);

    /* 4. 跑入口。 */
    if (!wasm_application_execute_main(app_inst, 0, NULL)) {
        exception = wasm_runtime_get_exception(app_inst);
        return fail("execute _start", exception);
    }
    if ((exception = wasm_runtime_get_exception(app_inst)))
        return fail("app raised", exception);

    wasm_runtime_destroy();
    return 0;
}
