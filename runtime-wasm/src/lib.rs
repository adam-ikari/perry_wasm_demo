//! perry-rt-wasm — perry 的 `rt.*` 运行时，用 Rust 写成、编译成 wasm 模块。
//!
//! 与 host/perry_rt.c (探针版宿主) 实现同一套 ABI，但形态完全不同：
//! 不是宿主进程里的共享库，而是一个独立的 wasm 模块，import 业务模块的内存，
//! export 业务模块需要的 211 个 `rt.*` 函数。合并成一个模块之后，宿主只剩 WASI。
//!
//! ABI 事实来源：perry-runtime/src/value.rs 的 NaN-boxing 编码 + 业务 wasm 的导入段。
#![no_std]
#![allow(static_mut_refs)]
#![allow(non_snake_case)] // 生成的桩函数名直接照搬 wasm 导入名 (如 stub_string_padStart)

use core::panic::PanicInfo;

// ---------------------------------------------------------------- 基础

#[panic_handler]
fn on_panic(_info: &PanicInfo) -> ! {
    trap()
}

#[inline(never)]
fn trap() -> ! {
    core::arch::wasm32::unreachable()
}

/// 线性内存的绝对地址 -> 指针。wasm32 里指针就是内存偏移，所以地址即指针。
#[inline]
fn mem_ptr<T>(addr: u32) -> *mut T {
    core::ptr::with_exposed_provenance_mut::<T>(addr as usize)
}

#[inline]
fn mem_bytes(addr: u32, len: u32) -> &'static [u8] {
    unsafe { core::slice::from_raw_parts(mem_ptr::<u8>(addr), len as usize) }
}

// ---------------------------------------------------------------- WASI 输出

#[repr(C)]
struct Iovec {
    buf: *const u8,
    buf_len: u32,
}

// 运行时模块自己不带 libc：标准输出/错误只用到 fd_write 这一个 WASI 调用。
#[link(wasm_import_module = "wasi_snapshot_preview1")]
extern "C" {
    fn fd_write(fd: i32, iovs: *const Iovec, iovs_len: usize, nwritten: *mut usize) -> i32;
}

fn write_fd(fd: i32, bytes: &[u8]) {
    let iov = Iovec { buf: bytes.as_ptr(), buf_len: bytes.len() as u32 };
    let mut written: usize = 0;
    unsafe { fd_write(fd, &iov, 1, &mut written) };
}

fn fatal(msg: &[u8]) -> ! {
    write_fd(2, b"Exception: ");
    write_fd(2, msg);
    write_fd(2, b"\n");
    trap()
}

/// 供生成的桩函数使用：报告未实现的 `rt.*` 导入。
#[no_mangle]
pub extern "C" fn perry_rt_unimplemented(name: *const u8, len: u32) -> ! {
    write_fd(2, b"Exception: bridge function '");
    write_fd(2, unsafe { core::slice::from_raw_parts(name, len as usize) });
    write_fd(2, b"' is not implemented\n");
    trap()
}

macro_rules! not_implemented {
    ($name:literal) => {
        $crate::perry_rt_unimplemented($name.as_ptr(), $name.len() as u32)
    };
}

// ---------------------------------------------------------------- 值模型

const TAG_UNDEFINED: u64 = 0x7FFC_0000_0000_0001;
const TAG_NULL: u64 = 0x7FFC_0000_0000_0002;
const TAG_FALSE: u64 = 0x7FFC_0000_0000_0003;
const TAG_TRUE: u64 = 0x7FFC_0000_0000_0004;
const BOX_POINTER: u64 = 0x7FFD;
const BOX_INT32: u64 = 0x7FFE;
const BOX_STRING: u64 = 0x7FFF;

#[derive(Clone, Copy, PartialEq)]
enum V {
    Undefined,
    Null,
    Bool(bool),
    Num(f64),
    Str(u32),
    Handle(u32),
}

fn decode(bits: u64) -> V {
    match bits {
        TAG_UNDEFINED => V::Undefined,
        TAG_NULL => V::Null,
        TAG_TRUE => V::Bool(true),
        TAG_FALSE => V::Bool(false),
        _ => match bits >> 48 {
            BOX_STRING => V::Str(bits as u32),
            BOX_INT32 => V::Num((bits as u32 as i32) as f64),
            BOX_POINTER => V::Handle(bits as u32),
            _ => V::Num(f64::from_bits(bits)),
        },
    }
}

fn encode(v: V) -> u64 {
    match v {
        V::Undefined => TAG_UNDEFINED,
        V::Null => TAG_NULL,
        V::Bool(true) => TAG_TRUE,
        V::Bool(false) => TAG_FALSE,
        V::Num(n) => n.to_bits(),
        V::Str(id) => (BOX_STRING << 48) | id as u64,
        V::Handle(id) => (BOX_POINTER << 48) | id as u64,
    }
}

// ---------------------------------------------------------------- 字符串表

const MAX_STRINGS: usize = 1024;
const ARENA_SIZE: usize = 64 * 1024;

#[derive(Clone, Copy)]
struct Entry {
    ptr: u32,
    len: u32,
    utf16: u32,
}

static mut STRINGS: [Entry; MAX_STRINGS] = [Entry { ptr: 0, len: 0, utf16: 0 }; MAX_STRINGS];
static mut COUNT: usize = 0;
static mut ARENA: [u8; ARENA_SIZE] = [0; ARENA_SIZE];
static mut USED: usize = 0;

/// JS `String.prototype.length`：UTF-8 字节数 → UTF-16 码元数。
fn utf16_len(bytes: &[u8]) -> u32 {
    let mut units = 0u32;
    let mut i = 0usize;
    while i < bytes.len() {
        let c = bytes[i];
        if c < 0x80 {
            units += 1;
            i += 1;
        } else if c & 0xE0 == 0xC0 {
            units += 1;
            i += 2;
        } else if c & 0xF0 == 0xE0 {
            units += 1;
            i += 3;
        } else if c & 0xF8 == 0xF0 {
            units += 2; // 非 BMP 码点占两个 UTF-16 码元
            i += 4;
        } else {
            units += 1; // 非法字节按单字节处理
            i += 1;
        }
    }
    units
}

/// 把 [src, src+len) 的字节拷进 arena 并登记到字符串表，返回其 id。
fn intern_bytes(src: *const u8, len: u32) -> u32 {
    let arena = core::ptr::addr_of_mut!(ARENA).cast::<u8>();
    let used = unsafe { USED };
    let count = unsafe { COUNT };
    if count >= MAX_STRINGS {
        fatal(b"string table overflow");
    }
    if used + len as usize > ARENA_SIZE {
        fatal(b"string arena overflow");
    }
    unsafe {
        let dst = arena.add(used);
        core::ptr::copy_nonoverlapping(src, dst, len as usize);
        USED = used + len as usize;
        let slice = core::slice::from_raw_parts(dst, len as usize);
        let entries = core::ptr::addr_of_mut!(STRINGS).cast::<Entry>();
        *entries.add(count) = Entry { ptr: dst as usize as u32, len, utf16: utf16_len(slice) };
        COUNT = count + 1;
    }
    count as u32
}

fn intern(bytes: &[u8]) -> u32 {
    intern_bytes(bytes.as_ptr(), bytes.len() as u32)
}

fn str_bytes(id: u32) -> &'static [u8] {
    let entries = core::ptr::addr_of!(STRINGS).cast::<Entry>();
    let count = unsafe { COUNT };
    if id as usize >= count {
        fatal(b"unknown string id");
    }
    let entry = unsafe { *entries.add(id as usize) };
    mem_bytes(entry.ptr, entry.len)
}

fn str_utf16(id: u32) -> u32 {
    let entries = core::ptr::addr_of!(STRINGS).cast::<Entry>();
    let count = unsafe { COUNT };
    if id as usize >= count {
        return 0;
    }
    unsafe { (*entries.add(id as usize)).utf16 }
}

// ---------------------------------------------------------------- 数字格式化

struct Num {
    bytes: [u8; 48],
    len: usize,
}

impl Num {
    fn new() -> Self {
        Num { bytes: [0; 48], len: 0 }
    }

    fn push(&mut self, byte: u8) {
        if self.len < self.bytes.len() {
            self.bytes[self.len] = byte;
            self.len += 1;
        }
    }

    fn push_bytes(&mut self, raw: &[u8]) {
        for &byte in raw {
            self.push(byte);
        }
    }

    fn push_digits(&mut self, mut value: u64) {
        let mut tmp = [0u8; 24];
        let mut count = 0;
        if value == 0 {
            self.push(b'0');
            return;
        }
        while value > 0 {
            tmp[count] = b'0' + (value % 10) as u8;
            value /= 10;
            count += 1;
        }
        while count > 0 {
            count -= 1;
            self.push(tmp[count]);
        }
    }

    fn as_slice(&self) -> &[u8] {
        &self.bytes[..self.len]
    }
}

/// JS Number → String。整数与 0/NaN/Infinity 与 JS 一致；
/// 小数最多保留 6 位并去掉尾随 0 —— 不是 JS 的最短往返表示（本 demo 不涉及）。
fn format_number(v: f64) -> Num {
    let mut out = Num::new();
    if v.is_nan() {
        out.push_bytes(b"NaN");
    } else if v.is_infinite() {
        out.push_bytes(if v < 0.0 { b"-Infinity" } else { b"Infinity" });
    } else if v == 0.0 {
        out.push(b'0');
    } else if v == (v as i64) as f64 {
        if v < 0.0 {
            out.push(b'-');
        }
        out.push_digits((v as i64).unsigned_abs());
    } else {
        let negative = v < 0.0;
        let magnitude = if negative { -v } else { v };
        let whole = magnitude as u64;
        let mut frac = magnitude - whole as f64;
        if negative {
            out.push(b'-');
        }
        out.push_digits(whole);
        out.push(b'.');
        let mut digits = [0u8; 6];
        let mut count = 0usize;
        for slot in digits.iter_mut() {
            frac *= 10.0;
            let digit = frac as u8;
            *slot = digit;
            frac -= digit as f64;
            count += 1;
        }
        while count > 0 && digits[count - 1] == 0 {
            count -= 1;
        }
        for &digit in &digits[..count] {
            out.push(b'0' + digit);
        }
    }
    out
}

/// JS ToNumber 的整数/小数子集（不含指数记法）。
fn parse_number(bytes: &[u8]) -> f64 {
    let mut i = 0usize;
    let mut sign = 1.0;
    if i < bytes.len() && (bytes[i] == b'+' || bytes[i] == b'-') {
        if bytes[i] == b'-' {
            sign = -1.0;
        }
        i += 1;
    }
    let mut value = 0.0f64;
    let mut digits = 0;
    while i < bytes.len() && bytes[i].is_ascii_digit() {
        value = value * 10.0 + (bytes[i] - b'0') as f64;
        i += 1;
        digits += 1;
    }
    if i < bytes.len() && bytes[i] == b'.' {
        i += 1;
        let mut scale = 0.1;
        while i < bytes.len() && bytes[i].is_ascii_digit() {
            value += (bytes[i] - b'0') as f64 * scale;
            scale *= 0.1;
            i += 1;
            digits += 1;
        }
    }
    if digits == 0 || i != bytes.len() {
        return f64::NAN;
    }
    sign * value
}

// ---------------------------------------------------------------- 值操作

/// JS ToString。本运行时只支持原始值。
fn to_string(v: V) -> V {
    match v {
        V::Str(_) => v,
        V::Undefined => V::Str(intern(b"undefined")),
        V::Null => V::Str(intern(b"null")),
        V::Bool(true) => V::Str(intern(b"true")),
        V::Bool(false) => V::Str(intern(b"false")),
        V::Num(n) => V::Str(intern(format_number(n).as_slice())),
        V::Handle(_) => fatal(b"objects/arrays are not supported"),
    }
}

fn to_number(v: V) -> f64 {
    match v {
        V::Num(n) => n,
        V::Null => 0.0,
        V::Bool(b) => {
            if b {
                1.0
            } else {
                0.0
            }
        }
        V::Undefined => f64::NAN,
        V::Str(id) => parse_number(str_bytes(id)),
        V::Handle(_) => fatal(b"cannot convert an object to a number"),
    }
}

fn truthy(v: V) -> bool {
    match v {
        V::Undefined | V::Null => false,
        V::Bool(b) => b,
        V::Num(n) => n != 0.0 && !n.is_nan(),
        V::Str(id) => !str_bytes(id).is_empty(),
        V::Handle(_) => true, // JS 里对象恒为真
    }
}

fn strict_eq(a: V, b: V) -> bool {
    match (a, b) {
        (V::Num(x), V::Num(y)) => x == y, // NaN !== NaN, +0 === -0
        (V::Str(x), V::Str(y)) => str_bytes(x) == str_bytes(y),
        (V::Bool(x), V::Bool(y)) => x == y,
        (V::Undefined, V::Undefined) | (V::Null, V::Null) => true,
        (V::Handle(_), V::Handle(_)) => true,
        _ => false,
    }
}

/// JS `+`：任一侧是字符串就拼接，否则数值相加。
fn add(a: V, b: V) -> V {
    if matches!(a, V::Str(_)) || matches!(b, V::Str(_)) {
        return concat(a, b);
    }
    V::Num(to_number(a) + to_number(b))
}

fn concat(a: V, b: V) -> V {
    let (x, y) = (to_string(a), to_string(b));
    let (V::Str(x), V::Str(y)) = (x, y) else {
        fatal(b"string concat failed");
    };
    let (xb, yb) = (str_bytes(x), str_bytes(y));
    let arena = core::ptr::addr_of_mut!(ARENA).cast::<u8>();
    let used = unsafe { USED };
    if used + xb.len() + yb.len() > ARENA_SIZE {
        fatal(b"string arena overflow");
    }
    unsafe {
        let dst = arena.add(used);
        core::ptr::copy_nonoverlapping(xb.as_ptr(), dst, xb.len());
        core::ptr::copy_nonoverlapping(yb.as_ptr(), dst.add(xb.len()), yb.len());
    }
    V::Str(intern_bytes(
        unsafe { arena.add(used) },
        (xb.len() + yb.len()) as u32,
    ))
}

fn print_value(v: V, fd: i32) {
    let s = to_string(v);
    if let V::Str(id) = s {
        write_fd(fd, str_bytes(id));
        write_fd(fd, b"\n");
    }
}

// ---------------------------------------------------------------- 直接导入的 rt.*

#[export_name = "string_new"]
pub extern "C" fn rt_string_new(offset: u32, len: u32) {
    intern_bytes(mem_ptr::<u8>(offset), len);
}

#[export_name = "console_log"]
pub extern "C" fn rt_console_log(value: i64) {
    print_value(decode(value as u64), 1);
}

#[export_name = "console_warn"]
pub extern "C" fn rt_console_warn(value: i64) {
    print_value(decode(value as u64), 2);
}

#[export_name = "console_error"]
pub extern "C" fn rt_console_error(value: i64) {
    print_value(decode(value as u64), 2);
}

#[export_name = "string_concat"]
pub extern "C" fn rt_string_concat(lhs: i64, rhs: i64) -> i64 {
    encode(concat(decode(lhs as u64), decode(rhs as u64))) as i64
}

#[export_name = "js_add"]
pub extern "C" fn rt_js_add(lhs: i64, rhs: i64) -> i64 {
    encode(add(decode(lhs as u64), decode(rhs as u64))) as i64
}

#[export_name = "string_eq"]
pub extern "C" fn rt_string_eq(lhs: i64, rhs: i64) -> i32 {
    strict_eq(decode(lhs as u64), decode(rhs as u64)) as i32
}

#[export_name = "js_strict_eq"]
pub extern "C" fn rt_js_strict_eq(lhs: i64, rhs: i64) -> i32 {
    strict_eq(decode(lhs as u64), decode(rhs as u64)) as i32
}

#[export_name = "is_truthy"]
pub extern "C" fn rt_is_truthy(value: i64) -> i32 {
    truthy(decode(value as u64)) as i32
}

#[export_name = "string_len"]
pub extern "C" fn rt_string_len(value: i64) -> i64 {
    let len = match decode(value as u64) {
        V::Str(id) => str_utf16(id) as f64,
        _ => 0.0, // perry 宿主层对非字符串返回 0
    };
    encode(V::Num(len)) as i64
}

#[export_name = "jsvalue_to_string"]
pub extern "C" fn rt_jsvalue_to_string(value: i64) -> i64 {
    encode(to_string(decode(value as u64))) as i64
}

// ---------------------------------------------------------------- mem_call 桥接

const MAX_ARGS: usize = 16;

const BRIDGES: [&[u8]; 10] = [
    b"console_log",
    b"console_warn",
    b"console_error",
    b"string_concat",
    b"js_add",
    b"string_eq",
    b"string_len",
    b"jsvalue_to_string",
    b"is_truthy",
    b"js_strict_eq",
];

fn bridge(index: usize, args: &[V], argc: usize) -> V {
    let need = |n: usize, what: &[u8]| {
        if argc < n {
            fatal(what);
        }
    };
    match index {
        0 => {
            need(1, b"console_log: missing argument");
            print_value(args[0], 1);
            V::Undefined
        }
        1 => {
            need(1, b"console_warn: missing argument");
            print_value(args[0], 2);
            V::Undefined
        }
        2 => {
            need(1, b"console_error: missing argument");
            print_value(args[0], 2);
            V::Undefined
        }
        3 => {
            need(2, b"string_concat: expected 2 arguments");
            concat(args[0], args[1])
        }
        4 => {
            need(2, b"js_add: expected 2 arguments");
            add(args[0], args[1])
        }
        5 => {
            need(2, b"string_eq: expected 2 arguments");
            V::Num(strict_eq(args[0], args[1]) as u8 as f64)
        }
        6 => {
            need(1, b"string_len: missing argument");
            let len = match args[0] {
                V::Str(id) => str_utf16(id) as f64,
                _ => 0.0,
            };
            V::Num(len)
        }
        7 => {
            need(1, b"jsvalue_to_string: missing argument");
            to_string(args[0])
        }
        8 => {
            need(1, b"is_truthy: missing argument");
            V::Num(truthy(args[0]) as u8 as f64)
        }
        9 => {
            need(2, b"js_strict_eq: expected 2 arguments");
            V::Num(strict_eq(args[0], args[1]) as u8 as f64)
        }
        _ => unreachable!(),
    }
}

/// 读取参数槽位 → 按名字分派 → 返回结果。
fn invoke(name_id: f64, arg_count: f64, base: u32) -> V {
    let name = name_id as u32;
    let argc = arg_count as u32 as usize;
    if argc > MAX_ARGS {
        fatal(b"mem_call: too many arguments");
    }
    let symbol = str_bytes(name);
    let mut args = [V::Undefined; MAX_ARGS];
    for (i, slot) in args.iter_mut().enumerate().take(argc) {
        let bits = u64::from_le(unsafe {
            core::ptr::read_unaligned(mem_ptr::<u64>(base + (i as u32) * 8))
        });
        *slot = decode(bits);
    }
    for (index, candidate) in BRIDGES.iter().enumerate() {
        if *candidate == symbol {
            return bridge(index, &args, argc);
        }
    }
    write_fd(2, b"Exception: bridge function '");
    write_fd(2, symbol);
    write_fd(2, b"' is not implemented\n");
    trap()
}

#[export_name = "mem_call"]
pub extern "C" fn rt_mem_call(name_id: f64, arg_count: f64, base: u32) -> f64 {
    let out = invoke(name_id, arg_count, base);
    unsafe {
        core::ptr::write_unaligned(mem_ptr::<u64>(base), encode(out));
    }
    0.0
}

#[export_name = "mem_call_i32"]
pub extern "C" fn rt_mem_call_i32(name_id: f64, arg_count: f64, base: u32) -> i32 {
    match invoke(name_id, arg_count, base) {
        V::Num(n) if !n.is_nan() => n as i32,
        V::Num(_) | V::Undefined | V::Null | V::Handle(_) => 0,
        V::Bool(b) => b as i32,
        V::Str(id) => parse_number(str_bytes(id)) as i32,
    }
}

/// WAMR 把带 WASI 导入的模块分成 command / reactor 两类，reactor 需要导出
/// `_initialize`。这个运行时是 reactor：静态数据由数据段初始化，这里无事可做。
#[export_name = "_initialize"]
pub extern "C" fn initialize() {}

// ---------------------------------------------------------------- 未实现的导入

// 由 tools/gen-rt-symbols.mjs 从 build/app.wasm 的导入段生成 (198 个桩)。
include!("../../build/rt_symbols.rs");
