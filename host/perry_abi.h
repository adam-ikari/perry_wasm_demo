/*
 * perry_abi.h — Perry 的 NaN-boxing 值编码。
 *
 * 与 perry-runtime/src/value.rs 及 typerry 自带的 JS 宿主层 (wasmBoot) 保持一致:
 *   - wasm 模块内部所有值都是 f64;
 *   - 调用宿主 (rt.*) 时按 i64 传"位模式", 宿主返回时同样按 i64 返回位模式;
 *   - 非 NaN 的普通 f64 就是 number 本身。
 */
#ifndef PERRY_ABI_H
#define PERRY_ABI_H

#include <stdint.h>
#include <string.h>

#define PERRY_TAG_UNDEFINED 0x7FFC000000000001ULL
#define PERRY_TAG_NULL 0x7FFC000000000002ULL
#define PERRY_TAG_FALSE 0x7FFC000000000003ULL
#define PERRY_TAG_TRUE 0x7FFC000000000004ULL

/* 高 16 位为 tag, 低 32 位为编号 */
#define PERRY_BOX_POINTER 0x7FFDULL
#define PERRY_BOX_INT32 0x7FFEULL
#define PERRY_BOX_STRING 0x7FFFULL

static inline uint64_t
perry_bits_of(double value)
{
    uint64_t bits;
    memcpy(&bits, &value, sizeof bits);
    return bits;
}

static inline double
perry_double_of(uint64_t bits)
{
    double value;
    memcpy(&value, &bits, sizeof value);
    return value;
}

static inline uint64_t
perry_box_string(uint32_t id)
{
    return (PERRY_BOX_STRING << 48) | (uint64_t)id;
}

static inline uint64_t
perry_box_int32(int32_t value)
{
    return (PERRY_BOX_INT32 << 48) | (uint32_t)value;
}

#endif /* PERRY_ABI_H */
