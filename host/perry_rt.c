/*
 * perry_rt.c — 在 WAMR 上为 perry/typerry 生成的 wasm 模块提供 `rt` 导入模块。
 *
 * typerry 产出的 wasm 声明了 200+ 个 `rt.*` 导入; 本文件实现其中"纯原始值"的那部分,
 * 其余由 build/rt_symbols.inc (由 tools/gen-rt-symbols.mjs 从 wasm 导入段生成)
 * 以"调用即报错"的桩补齐, 保证模块能实例化, 但绝不静默吞掉未实现的功能。
 *
 * 宿主侧的约定 (与 typerry 自带的 JS 宿主层完全一致):
 *   - 所有值是 f64 位模式经 i64 传递的 NaN-boxed 值 (见 perry_abi.h);
 *   - 字符串表按注册顺序追加, 下标即字符串 id, 必须与 wasm 模块的计数一致;
 *   - 动态调用统一走 mem_call(nameId, argc, base): 参数以 u64 槽位写在
 *     wasm 线性内存 base 处, 结果写回 base。
 *
 * 未实现 (超出本 demo 范围): 对象/数组/闭包/类 (handle store) 相关导入。
 * 这些导入一旦被调用会抛出 wasm 异常并打印函数名, 而不是返回假数据。
 */
#include <math.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "wasm_export.h"

#include "perry_abi.h"

/* mem_call 一次最多携带的参数槽数。 */
#define PERRY_MAX_ARGS 16

/* ------------------------------------------------------------------ */
/* 字符串表                                                            */
/* ------------------------------------------------------------------ */

typedef struct {
    char *bytes;        /* UTF-8, 以 NUL 结尾 */
    uint32_t len;       /* UTF-8 字节数 */
    uint32_t utf16_len; /* JS string.length: UTF-16 码元数 */
} PerryString;

static PerryString *g_strings;
static uint32_t g_string_count;
static uint32_t g_string_cap;

static char g_error[256];
static char g_unimpl[128];

static bool
failf(const char *fmt, ...)
{
    va_list ap;

    va_start(ap, fmt);
    vsnprintf(g_error, sizeof g_error, fmt, ap);
    va_end(ap);
    return false;
}

static uint32_t
utf16_len_of(const char *bytes, uint32_t len)
{
    uint32_t units = 0, i = 0;

    while (i < len) {
        unsigned char c = (unsigned char)bytes[i];

        if (c < 0x80) {
            units += 1;
            i += 1;
        }
        else if ((c & 0xE0) == 0xC0) {
            units += 1;
            i += 2;
        }
        else if ((c & 0xF0) == 0xE0) {
            units += 1;
            i += 3;
        }
        else if ((c & 0xF8) == 0xF0) {
            units += 2; /* 非 BMP 码点: 2 个 UTF-16 码元 */
            i += 4;
        }
        else {
            units += 1; /* 非法字节按单字节处理 */
            i += 1;
        }
    }
    return units;
}

/* 追加到字符串表, 返回其 id; 失败返回 UINT32_MAX。 */
static uint32_t
string_intern(const char *bytes, uint32_t len)
{
    PerryString *slot;
    char *copy;

    if (g_string_count == g_string_cap) {
        uint32_t cap = g_string_cap ? g_string_cap * 2 : 1024;
        PerryString *grown = realloc(g_strings, (size_t)cap * sizeof *grown);

        if (!grown)
            return UINT32_MAX;
        g_strings = grown;
        g_string_cap = cap;
    }
    if (!(copy = malloc((size_t)len + 1)))
        return UINT32_MAX;
    memcpy(copy, bytes, len);
    copy[len] = '\0';

    slot = &g_strings[g_string_count];
    slot->bytes = copy;
    slot->len = len;
    slot->utf16_len = utf16_len_of(copy, len);
    return g_string_count++;
}

/* ------------------------------------------------------------------ */
/* wasm 侧辅助                                                         */
/* ------------------------------------------------------------------ */

static void
set_exception(wasm_exec_env_t exec_env, const char *message)
{
    wasm_runtime_set_exception(wasm_runtime_get_module_inst(exec_env), message);
}

static void *
app_addr(wasm_exec_env_t exec_env, uint32_t offset, uint32_t size)
{
    wasm_module_inst_t inst = wasm_runtime_get_module_inst(exec_env);
    void *native;

    if (!inst) {
        failf("no module instance");
        return NULL;
    }
    if (!wasm_runtime_validate_app_addr(inst, offset, size)) {
        failf("wasm memory out of range: offset=%u size=%u", offset, size);
        return NULL;
    }
    if (!(native = wasm_runtime_addr_app_to_native(inst, offset)))
        failf("wasm address translation failed: offset=%u", offset);
    return native;
}

/* 供生成的桩函数使用: 报告未实现的 rt.* 导入。 */
uint64_t
perry_rt_unimplemented(wasm_exec_env_t exec_env, const char *name)
{
    snprintf(g_unimpl, sizeof g_unimpl,
             "perry host: rt.%s is not implemented by this native library", name);
    set_exception(exec_env, g_unimpl);
    return 0;
}

/* ------------------------------------------------------------------ */
/* 值模型 (仅原始值)                                                   */
/* ------------------------------------------------------------------ */

typedef enum {
    PV_UNDEFINED,
    PV_NULL,
    PV_BOOLEAN,
    PV_NUMBER,
    PV_STRING,
    PV_HANDLE /* 对象/数组/闭包: 本宿主不实现 */
} PvKind;

typedef struct {
    PvKind kind;
    double number;
    int boolean;
    uint32_t id;
} Pv;

static Pv
pv_decode(uint64_t bits)
{
    Pv v;

    memset(&v, 0, sizeof v);
    if (bits == PERRY_TAG_UNDEFINED)
        v.kind = PV_UNDEFINED;
    else if (bits == PERRY_TAG_NULL)
        v.kind = PV_NULL;
    else if (bits == PERRY_TAG_TRUE) {
        v.kind = PV_BOOLEAN;
        v.boolean = 1;
    }
    else if (bits == PERRY_TAG_FALSE)
        v.kind = PV_BOOLEAN;
    else {
        switch (bits >> 48) {
            case PERRY_BOX_STRING:
                v.kind = PV_STRING;
                v.id = (uint32_t)bits;
                break;
            case PERRY_BOX_INT32:
                v.kind = PV_NUMBER;
                v.number = (double)(int32_t)(uint32_t)bits;
                break;
            case PERRY_BOX_POINTER:
                v.kind = PV_HANDLE;
                v.id = (uint32_t)bits;
                break;
            default:
                v.kind = PV_NUMBER;
                v.number = perry_double_of(bits);
                break;
        }
    }
    return v;
}

static bool
pv_encode(const Pv *v, uint64_t *bits)
{
    switch (v->kind) {
        case PV_UNDEFINED:
            *bits = PERRY_TAG_UNDEFINED;
            return true;
        case PV_NULL:
            *bits = PERRY_TAG_NULL;
            return true;
        case PV_BOOLEAN:
            *bits = v->boolean ? PERRY_TAG_TRUE : PERRY_TAG_FALSE;
            return true;
        case PV_NUMBER:
            *bits = perry_bits_of(v->number);
            return true;
        case PV_STRING:
            *bits = perry_box_string(v->id);
            return true;
        default:
            return failf("objects/arrays are not supported (handle %u)", v->id);
    }
}

/* JS Number → String 的最短可往返表示。 */
static void
format_number(double value, char *out, size_t cap)
{
    int precision;

    if (isnan(value)) {
        snprintf(out, cap, "NaN");
        return;
    }
    if (isinf(value)) {
        snprintf(out, cap, value < 0 ? "-Infinity" : "Infinity");
        return;
    }
    if (value == 0) {
        snprintf(out, cap, "0");
        return;
    }
    if ((double)(long long)value == value && fabs(value) < 1e15) {
        snprintf(out, cap, "%lld", (long long)value);
        return;
    }
    for (precision = 1; precision <= 17; precision++) {
        snprintf(out, cap, "%.*g", precision, value);
        if (strtod(out, NULL) == value)
            return;
    }
}

static bool
pv_to_number(const Pv *v, double *out)
{
    switch (v->kind) {
        case PV_NUMBER:
            *out = v->number;
            return true;
        case PV_NULL:
            *out = 0;
            return true;
        case PV_BOOLEAN:
            *out = v->boolean ? 1 : 0;
            return true;
        case PV_UNDEFINED:
            *out = NAN;
            return true;
        case PV_STRING: {
            const PerryString *s = &g_strings[v->id];
            char *end;

            if (s->len == 0) {
                *out = 0;
                return true;
            }
            *out = strtod(s->bytes, &end);
            if (end != s->bytes + s->len)
                *out = NAN;
            return true;
        }
        default:
            return failf("cannot convert an object to a number");
    }
}

/* JS ToString */
static bool
pv_to_string(const Pv *v, Pv *out)
{
    char buf[32];
    uint32_t id;

    switch (v->kind) {
        case PV_STRING:
            *out = *v;
            return true;
        case PV_UNDEFINED:
            id = string_intern("undefined", 9);
            break;
        case PV_NULL:
            id = string_intern("null", 4);
            break;
        case PV_BOOLEAN:
            id = string_intern(v->boolean ? "true" : "false",
                               v->boolean ? 4 : 5);
            break;
        case PV_NUMBER:
            format_number(v->number, buf, sizeof buf);
            id = string_intern(buf, (uint32_t)strlen(buf));
            break;
        default:
            return failf("cannot convert an object to a string");
    }
    if (id == UINT32_MAX)
        return failf("string table allocation failed");

    out->kind = PV_STRING;
    out->id = id;
    return true;
}

static bool
value_truthy(const Pv *v, bool *truthy)
{
    switch (v->kind) {
        case PV_UNDEFINED:
        case PV_NULL:
            *truthy = false;
            return true;
        case PV_BOOLEAN:
            *truthy = v->boolean != 0;
            return true;
        case PV_NUMBER:
            *truthy = v->number != 0 && !isnan(v->number);
            return true;
        case PV_STRING:
            *truthy = g_strings[v->id].len > 0;
            return true;
        default:
            *truthy = true; /* JS 里对象恒为真 */
            return true;
    }
}

static bool
value_strict_eq(const Pv *a, const Pv *b, bool *equal)
{
    const PerryString *x, *y;

    *equal = false;
    if (a->kind != b->kind)
        return true; /* undefined / null 是不同 kind, 符合 === 语义 */
    switch (a->kind) {
        case PV_NUMBER:
            *equal = a->number == b->number; /* NaN !== NaN, +0 === -0 */
            return true;
        case PV_STRING:
            x = &g_strings[a->id];
            y = &g_strings[b->id];
            *equal = x->len == y->len && memcmp(x->bytes, y->bytes, x->len) == 0;
            return true;
        case PV_BOOLEAN:
            *equal = a->boolean == b->boolean;
            return true;
        default:
            *equal = true; /* undefined/null 同 kind 即相等 */
            return true;
    }
}

/* JS string + string */
static bool
value_concat(const Pv *a, const Pv *b, Pv *out)
{
    Pv sa, sb;
    const PerryString *x, *y;
    char *joined;
    uint32_t id;

    if (!pv_to_string(a, &sa) || !pv_to_string(b, &sb))
        return false;
    x = &g_strings[sa.id];
    y = &g_strings[sb.id];

    if (!(joined = malloc((size_t)x->len + y->len)))
        return failf("string allocation failed");
    memcpy(joined, x->bytes, x->len);
    memcpy(joined + x->len, y->bytes, y->len);

    id = string_intern(joined, x->len + y->len);
    free(joined);
    if (id == UINT32_MAX)
        return failf("string table allocation failed");

    out->kind = PV_STRING;
    out->id = id;
    return true;
}

/* JS `+` */
static bool
value_add(const Pv *a, const Pv *b, Pv *out)
{
    double x, y;

    if (a->kind == PV_STRING || b->kind == PV_STRING)
        return value_concat(a, b, out);
    if (!pv_to_number(a, &x) || !pv_to_number(b, &y))
        return false;

    out->kind = PV_NUMBER;
    out->number = x + y;
    return true;
}

static bool
value_print(const Pv *v, FILE *stream)
{
    Pv s;

    if (!pv_to_string(v, &s))
        return false;
    fwrite(g_strings[s.id].bytes, 1, g_strings[s.id].len, stream);
    fputc('\n', stream);
    fflush(stream);
    return true;
}

/* ------------------------------------------------------------------ */
/* rt.* 直接导入 (wasm 静态调用的那部分)                               */
/* ------------------------------------------------------------------ */

void rt_string_new(wasm_exec_env_t exec_env, uint32_t offset, uint32_t len);

void rt_console_log(wasm_exec_env_t exec_env, uint64_t value);
void rt_console_warn(wasm_exec_env_t exec_env, uint64_t value);
void rt_console_error(wasm_exec_env_t exec_env, uint64_t value);

uint64_t rt_string_concat(wasm_exec_env_t exec_env, uint64_t lhs, uint64_t rhs);
uint64_t rt_js_add(wasm_exec_env_t exec_env, uint64_t lhs, uint64_t rhs);
uint32_t rt_string_eq(wasm_exec_env_t exec_env, uint64_t lhs, uint64_t rhs);
uint64_t rt_string_len(wasm_exec_env_t exec_env, uint64_t value);
uint64_t rt_jsvalue_to_string(wasm_exec_env_t exec_env, uint64_t value);
uint32_t rt_is_truthy(wasm_exec_env_t exec_env, uint64_t value);
uint32_t rt_js_strict_eq(wasm_exec_env_t exec_env, uint64_t lhs, uint64_t rhs);

double rt_mem_call(wasm_exec_env_t exec_env, double name_id, double arg_count,
                   uint32_t base);
uint32_t rt_mem_call_i32(wasm_exec_env_t exec_env, double name_id, double arg_count,
                         uint32_t base);

/* 把宿主值编码回 i64; 失败时抛异常并返回 undefined。 */
static uint64_t
rt_return_value(wasm_exec_env_t exec_env, const Pv *out)
{
    uint64_t bits = PERRY_TAG_UNDEFINED;

    if (!pv_encode(out, &bits)) {
        set_exception(exec_env, g_error);
        return PERRY_TAG_UNDEFINED;
    }
    return bits;
}

void
rt_string_new(wasm_exec_env_t exec_env, uint32_t offset, uint32_t len)
{
    uint8_t *bytes;

    g_error[0] = '\0';
    if (!(bytes = app_addr(exec_env, offset, len))) {
        set_exception(exec_env, g_error);
        return;
    }
    if (string_intern((const char *)bytes, len) == UINT32_MAX)
        set_exception(exec_env, "perry host: string table allocation failed");
}

static void
rt_console_emit(wasm_exec_env_t exec_env, uint64_t bits, FILE *stream)
{
    Pv v = pv_decode(bits);

    g_error[0] = '\0';
    if (!value_print(&v, stream))
        set_exception(exec_env, g_error);
}

void
rt_console_log(wasm_exec_env_t exec_env, uint64_t value)
{
    rt_console_emit(exec_env, value, stdout);
}

void
rt_console_warn(wasm_exec_env_t exec_env, uint64_t value)
{
    rt_console_emit(exec_env, value, stderr);
}

void
rt_console_error(wasm_exec_env_t exec_env, uint64_t value)
{
    rt_console_emit(exec_env, value, stderr);
}

uint64_t
rt_string_concat(wasm_exec_env_t exec_env, uint64_t lhs, uint64_t rhs)
{
    Pv a = pv_decode(lhs), b = pv_decode(rhs), out;

    g_error[0] = '\0';
    if (!value_concat(&a, &b, &out)) {
        set_exception(exec_env, g_error);
        return PERRY_TAG_UNDEFINED;
    }
    return rt_return_value(exec_env, &out);
}

uint64_t
rt_js_add(wasm_exec_env_t exec_env, uint64_t lhs, uint64_t rhs)
{
    Pv a = pv_decode(lhs), b = pv_decode(rhs), out;

    g_error[0] = '\0';
    if (!value_add(&a, &b, &out)) {
        set_exception(exec_env, g_error);
        return PERRY_TAG_UNDEFINED;
    }
    return rt_return_value(exec_env, &out);
}

static uint32_t
rt_compare(wasm_exec_env_t exec_env, uint64_t lhs, uint64_t rhs)
{
    Pv a = pv_decode(lhs), b = pv_decode(rhs);
    bool equal = false;

    g_error[0] = '\0';
    if (!value_strict_eq(&a, &b, &equal)) {
        set_exception(exec_env, g_error);
        return 0;
    }
    return equal ? 1 : 0;
}

uint32_t
rt_string_eq(wasm_exec_env_t exec_env, uint64_t lhs, uint64_t rhs)
{
    return rt_compare(exec_env, lhs, rhs);
}

uint32_t
rt_js_strict_eq(wasm_exec_env_t exec_env, uint64_t lhs, uint64_t rhs)
{
    return rt_compare(exec_env, lhs, rhs);
}

uint32_t
rt_is_truthy(wasm_exec_env_t exec_env, uint64_t value)
{
    Pv v = pv_decode(value);
    bool truthy = false;

    if (!value_truthy(&v, &truthy)) {
        set_exception(exec_env, g_error);
        return 0;
    }
    return truthy ? 1 : 0;
}

uint64_t
rt_string_len(wasm_exec_env_t exec_env, uint64_t value)
{
    Pv v = pv_decode(value);

    (void)exec_env;
    return perry_bits_of(v.kind == PV_STRING ? (double)g_strings[v.id].utf16_len
                                             : 0);
}

uint64_t
rt_jsvalue_to_string(wasm_exec_env_t exec_env, uint64_t value)
{
    Pv v = pv_decode(value), out;

    g_error[0] = '\0';
    if (!pv_to_string(&v, &out)) {
        set_exception(exec_env, g_error);
        return PERRY_TAG_UNDEFINED;
    }
    return rt_return_value(exec_env, &out);
}

/* ------------------------------------------------------------------ */
/* mem_call: 动态桥接调用                                              */
/* ------------------------------------------------------------------ */

typedef bool (*PerryBridgeFn)(const Pv *args, uint32_t argc, Pv *out);

typedef struct {
    const char *name;
    PerryBridgeFn fn;
} PerryBridge;

static bool
bridge_console_log(const Pv *args, uint32_t argc, Pv *out)
{
    (void)out;
    if (argc < 1)
        return failf("console_log: missing argument");
    return value_print(&args[0], stdout);
}

static bool
bridge_console_warn(const Pv *args, uint32_t argc, Pv *out)
{
    (void)out;
    if (argc < 1)
        return failf("console_warn: missing argument");
    return value_print(&args[0], stderr);
}

static bool
bridge_console_error(const Pv *args, uint32_t argc, Pv *out)
{
    (void)out;
    if (argc < 1)
        return failf("console_error: missing argument");
    return value_print(&args[0], stderr);
}

static bool
bridge_string_concat(const Pv *args, uint32_t argc, Pv *out)
{
    if (argc < 2)
        return failf("string_concat: expected 2 arguments");
    memset(out, 0, sizeof *out);
    return value_concat(&args[0], &args[1], out);
}

static bool
bridge_js_add(const Pv *args, uint32_t argc, Pv *out)
{
    if (argc < 2)
        return failf("js_add: expected 2 arguments");
    memset(out, 0, sizeof *out);
    return value_add(&args[0], &args[1], out);
}

static bool
bridge_string_eq(const Pv *args, uint32_t argc, Pv *out)
{
    bool equal = false;

    if (argc < 2)
        return failf("string_eq: expected 2 arguments");
    if (!value_strict_eq(&args[0], &args[1], &equal))
        return false;
    memset(out, 0, sizeof *out);
    out->kind = PV_NUMBER;
    out->number = equal ? 1 : 0;
    return true;
}

static bool
bridge_js_strict_eq(const Pv *args, uint32_t argc, Pv *out)
{
    bool equal = false;

    if (argc < 2)
        return failf("js_strict_eq: expected 2 arguments");
    if (!value_strict_eq(&args[0], &args[1], &equal))
        return false;
    memset(out, 0, sizeof *out);
    out->kind = PV_NUMBER;
    out->number = equal ? 1 : 0;
    return true;
}

static bool
bridge_string_len(const Pv *args, uint32_t argc, Pv *out)
{
    if (argc < 1)
        return failf("string_len: missing argument");
    memset(out, 0, sizeof *out);
    out->kind = PV_NUMBER;
    out->number = args[0].kind == PV_STRING
                      ? (double)g_strings[args[0].id].utf16_len
                      : 0; /* perry 宿主层对非字符串/数组返回 0 */
    return true;
}

static bool
bridge_is_truthy(const Pv *args, uint32_t argc, Pv *out)
{
    bool truthy = false;

    if (argc < 1)
        return failf("is_truthy: missing argument");
    if (!value_truthy(&args[0], &truthy))
        return false;
    memset(out, 0, sizeof *out);
    out->kind = PV_NUMBER;
    out->number = truthy ? 1 : 0;
    return true;
}

static bool
bridge_jsvalue_to_string(const Pv *args, uint32_t argc, Pv *out)
{
    if (argc < 1)
        return failf("jsvalue_to_string: missing argument");
    memset(out, 0, sizeof *out);
    return pv_to_string(&args[0], out);
}

static const PerryBridge g_bridges[] = {
    { "console_log", bridge_console_log },
    { "console_warn", bridge_console_warn },
    { "console_error", bridge_console_error },
    { "string_concat", bridge_string_concat },
    { "js_add", bridge_js_add },
    { "string_eq", bridge_string_eq },
    { "string_len", bridge_string_len },
    { "jsvalue_to_string", bridge_jsvalue_to_string },
    { "is_truthy", bridge_is_truthy },
    { "js_strict_eq", bridge_js_strict_eq },
};

/*
 * 读取参数 → 按名字分派 → 返回结果。
 * 出错时设置 wasm 异常并返回 false。
 */
static bool
mem_call_invoke(wasm_exec_env_t exec_env, double name_id, double arg_count,
                uint32_t base, Pv *out)
{
    uint32_t name = (uint32_t)name_id, argc = (uint32_t)arg_count, i;
    const PerryString *symbol;
    Pv args[PERRY_MAX_ARGS];
    uint8_t *slots;

    g_error[0] = '\0';
    if (!g_strings || name >= g_string_count)
        return failf("mem_call: unknown string id %u", name);
    if (argc > PERRY_MAX_ARGS)
        return failf("mem_call: too many arguments (%u)", argc);

    symbol = &g_strings[name];
    if (!(slots = app_addr(exec_env, base, (argc ? argc : 1) * 8))) {
        set_exception(exec_env, g_error);
        return false;
    }
    for (i = 0; i < argc; i++) {
        uint64_t bits;

        memcpy(&bits, slots + (size_t)i * 8, sizeof bits);
        args[i] = pv_decode(bits);
    }

    memset(out, 0, sizeof *out);
    out->kind = PV_UNDEFINED;
    for (i = 0; i < sizeof g_bridges / sizeof g_bridges[0]; i++) {
        if (strcmp(symbol->bytes, g_bridges[i].name) == 0)
            break;
    }
    if (i == sizeof g_bridges / sizeof g_bridges[0]) {
        failf("bridge function '%s' is not implemented", symbol->bytes);
        set_exception(exec_env, g_error);
        return false;
    }
    if (!g_bridges[i].fn(args, argc, out)) {
        set_exception(exec_env, g_error);
        return false;
    }
    return true;
}

double
rt_mem_call(wasm_exec_env_t exec_env, double name_id, double arg_count,
            uint32_t base)
{
    Pv out;
    uint64_t bits;

    if (!mem_call_invoke(exec_env, name_id, arg_count, base, &out))
        return 0.0;
    if (!pv_encode(&out, &bits)) {
        set_exception(exec_env, g_error);
        return 0.0;
    }
    /* 结果写回参数起始槽位, 由 wasm 侧读取。 */
    memcpy(app_addr(exec_env, base, 8), &bits, sizeof bits);
    return 0.0;
}

uint32_t
rt_mem_call_i32(wasm_exec_env_t exec_env, double name_id, double arg_count,
                uint32_t base)
{
    Pv out;
    double result = 0;

    if (!mem_call_invoke(exec_env, name_id, arg_count, base, &out))
        return 0;
    if (!pv_to_number(&out, &result) || isnan(result))
        return 0;
    return (uint32_t)(int32_t)result;
}

/* ------------------------------------------------------------------ */
/* 原生符号表 (由 tools/gen-rt-symbols.mjs 从 wasm 导入段生成)          */
/* ------------------------------------------------------------------ */

#include "rt_symbols.inc"

uint32_t
get_native_lib(char **p_module_name, NativeSymbol **p_native_symbols)
{
    *p_module_name = (char *)"rt";
    *p_native_symbols = perry_rt_symbols;
    return (uint32_t)(sizeof perry_rt_symbols / sizeof perry_rt_symbols[0]);
}
