// route-4 实验版运行时: 值语义全部复用 perry-runtime (wasm32-wasip1 cdylib)。
// rt.* ABI 不变 (字符串载荷仍是 codegen 的编译期 table index);
// 适配层 = 一张 index -> *mut StringHeader 表, 桥内把 perry 指针翻进翻出。
use perry_runtime::builtins::{js_mod, js_parse_float, js_parse_int, js_value_typeof};
use perry_runtime::date::js_date_now;
use perry_runtime::math::{js_math_log, js_math_max2, js_math_min2, js_math_pow, js_math_random, js_math_round};
use perry_runtime::string::{js_string_concat, js_string_equals, js_string_from_bytes, js_string_length, StringHeader};
use perry_runtime::value::{js_dynamic_add, js_is_truthy, js_jsvalue_to_string};

const TAG_UNDEFINED: u64 = 0x7FFC_0000_0000_0001;
const TAG_NULL: u64 = 0x7FFC_0000_0000_0002;
const TAG_TRUE: u64 = 0x7FFC_0000_0000_0003;
const TAG_FALSE: u64 = 0x7FFC_0000_0000_0004;
const BOX_POINTER: u64 = 0x7FFD;
const BOX_INT32: u64 = 0x7FFE;
const BOX_STRING: u64 = 0x7FFF;

#[repr(C)] struct Iovec { buf: *const u8, buf_len: u32 }
#[link(wasm_import_module = "wasi_snapshot_preview1")]
extern "C" { fn fd_write(fd: i32, iovs: *const Iovec, n: usize, w: *mut usize) -> i32; }
fn write_fd(fd: i32, b: &[u8]) {
    let iov = Iovec { buf: b.as_ptr(), buf_len: b.len() as u32 };
    let mut w: usize = 0;
    unsafe { fd_write(fd, &iov, 1, &mut w) };
}
fn fatal(m: &[u8]) -> ! { write_fd(2, b"Exception: "); write_fd(2, m); write_fd(2, b"\n"); trap() }
fn trap() -> ! { loop { core::arch::wasm32::unreachable() } }
#[no_mangle] pub extern "C" fn perry_rt_unimplemented(n: *const u8, l: u32) -> ! {
    write_fd(2, b"Exception: bridge function '");
    write_fd(2, unsafe { core::slice::from_raw_parts(n, l as usize) });
    write_fd(2, b"' is not implemented\n"); trap()
}
macro_rules! not_implemented { ($n:literal) => { $crate::perry_rt_unimplemented($n.as_ptr(), $n.len() as u32) }; }

#[derive(Clone, Copy, PartialEq)] enum V { Undefined, Null, Bool(bool), Num(f64), Str(u32), Handle(u32) }
fn decode(b: u64) -> V { match b {
    TAG_UNDEFINED => V::Undefined, TAG_NULL => V::Null,
    TAG_TRUE => V::Bool(true), TAG_FALSE => V::Bool(false),
    _ => match b >> 48 {
        BOX_STRING => V::Str(b as u32), BOX_INT32 => V::Num((b as u32 as i32) as f64),
        BOX_POINTER => V::Handle(b as u32), _ => V::Num(f64::from_bits(b)),
    } } }
fn encode(v: V) -> u64 { match v {
    V::Undefined => TAG_UNDEFINED, V::Null => TAG_NULL,
    V::Bool(t) => if t { TAG_TRUE } else { TAG_FALSE },
    V::Num(n) => n.to_bits(), V::Str(i) => (BOX_STRING << 48) | i as u64,
    V::Handle(i) => (BOX_POINTER << 48) | i as u64 } }

// ---- 字符串表: codegen id -> perry StringHeader* (复用 perry 堆) ----
const MAX_STRINGS: usize = 1 << 16;
static mut STR: [*mut StringHeader; MAX_STRINGS] = [core::ptr::null_mut(); MAX_STRINGS];
static mut COUNT: usize = 0;
fn push_str(p: *mut StringHeader) -> u32 { unsafe {
    let c = COUNT; if c >= MAX_STRINGS { fatal(b"string table overflow"); }
    *core::ptr::addr_of_mut!(STR).cast::<*mut StringHeader>().add(c) = p;
    COUNT = c + 1; c as u32 } }
fn get_str(id: u32) -> *mut StringHeader { unsafe {
    let s = *core::ptr::addr_of!(STR).cast::<*const StringHeader>().add(id as usize);
    if s.is_null() { fatal(b"unknown string id"); } s as *mut StringHeader } }
fn str_bytes(id: u32) -> &'static [u8] { unsafe {
    let h = &*get_str(id);
    core::slice::from_raw_parts((h as *const StringHeader).add(1) as *const u8, h.byte_len as usize) } }

// perry 指针载体 <-> codegen index 载体
fn perry_str(id: u32) -> u64 { (BOX_STRING << 48) | get_str(id) as u64 }
fn to_perry(v: V) -> f64 { match v {
    V::Str(i) => f64::from_bits(perry_str(i)),
    V::Num(n) => n, V::Bool(b) => f64::from_bits(if b { TAG_TRUE } else { TAG_FALSE }),
    V::Undefined => f64::from_bits(TAG_UNDEFINED), V::Null => f64::from_bits(TAG_NULL),
    V::Handle(_) => fatal(b"objects unsupported") } }
fn from_perry_ptr(p: *mut StringHeader) -> V { V::Str(push_str(p)) }

fn to_number(v: V) -> f64 { match v {
    V::Num(n) => n, V::Null => 0.0, V::Bool(b) => if b {1.0} else {0.0},
    V::Undefined => f64::NAN, V::Str(_) => f64::NAN, V::Handle(_) => fatal(b"obj->num") } }
fn to_string(v: V) -> V { match v {
    V::Str(_) => v,
    V::Undefined => V::Str(push_str(unsafe { js_undefined_str() })),
    V::Null => V::Str(push_str(unsafe { js_null_str() })),
    V::Bool(b) => V::Str(push_str(unsafe { js_bool_str(b) })),
    V::Num(n) => from_perry_ptr(unsafe { js_jsvalue_to_string(n) }),
    V::Handle(_) => fatal(b"obj->str") } }
fn truthy(v: V) -> bool { unsafe { js_is_truthy(to_perry(v)) != 0 } }
fn str_header(v: V) -> *mut StringHeader { match v {
    V::Str(i) => get_str(i),
    other => from_perry_ptr(unsafe { js_jsvalue_to_string(to_perry(other)) }).str_or_die() } }
impl V { fn str_or_die(self) -> *mut StringHeader {
    match self { V::Str(i) => get_str(i), _ => unreachable!() } } }

// perry 的 undefined/null/true/false 缓存串 (经 typeof 取)
unsafe fn js_undefined_str() -> *mut StringHeader { js_value_typeof(f64::from_bits(TAG_UNDEFINED)) }
unsafe fn js_null_str() -> *mut StringHeader { js_value_typeof(f64::from_bits(TAG_NULL)) }
unsafe fn js_bool_str(b: bool) -> *mut StringHeader {
    js_value_typeof(f64::from_bits(if b { TAG_TRUE } else { TAG_FALSE })) }

fn mem_ptr<T>(off: u32) -> *mut T { off as usize as *mut T }

// ---- 13 个真实桥: 语义全部来自 perry-runtime ----
#[export_name = "string_new"]
pub extern "C" fn rt_string_new(offset: u32, len: u32) {
    push_str(unsafe { js_string_from_bytes(mem_ptr::<u8>(offset), len) });
}
#[export_name = "console_log"] pub extern "C" fn rt_console_log(v: i64) { print_value(decode(v as u64), 1) }
#[export_name = "console_warn"] pub extern "C" fn rt_console_warn(v: i64) { print_value(decode(v as u64), 2) }
#[export_name = "console_error"] pub extern "C" fn rt_console_error(v: i64) { print_value(decode(v as u64), 2) }
fn print_value(v: V, fd: i32) {
    let s = to_string(v);
    if let V::Str(id) = s { write_fd(fd, str_bytes(id)); write_fd(fd, b"\n"); }
}
#[export_name = "string_concat"]
pub extern "C" fn rt_string_concat(a: i64, b: i64) -> i64 {
    let c = unsafe { js_string_concat(str_header(decode(a as u64)), str_header(decode(b as u64))) };
    encode(from_perry_ptr(c)) as i64
}
#[export_name = "js_add"]
pub extern "C" fn rt_js_add(a: i64, b: i64) -> i64 {
    let (x, y) = (decode(a as u64), decode(b as u64));
    if matches!(x, V::Str(_)) || matches!(y, V::Str(_)) {
        let c = unsafe { js_string_concat(str_header(x), str_header(y)) };
        return encode(from_perry_ptr(c)) as i64;
    }
    if let (V::Num(x), V::Num(y)) = (x, y) {
        return encode(V::Num(x + y)) as i64;
    }
    unsafe { js_dynamic_add(to_perry(x), to_perry(y)).to_bits() as i64 }
}
#[export_name = "string_eq"]
pub extern "C" fn rt_string_eq(a: i64, b: i64) -> i32 {
    unsafe { js_string_equals(str_header(decode(a as u64)), str_header(decode(b as u64))) }
}
#[export_name = "js_strict_eq"]
pub extern "C" fn rt_js_strict_eq(a: i64, b: i64) -> i32 {
    let (x, y) = (decode(a as u64), decode(b as u64));
    if matches!(x, V::Str(_)) && matches!(y, V::Str(_)) {
        return unsafe { js_string_equals(str_header(x), str_header(y)) };
    }
    (strict_eq(x, y)) as i32
}
fn strict_eq(a: V, b: V) -> bool { match (a, b) {
    (V::Num(x), V::Num(y)) => x == y, (V::Str(x), V::Str(y)) => x == y || str_bytes(x) == str_bytes(y),
    (V::Bool(x), V::Bool(y)) => x == y,
    (V::Undefined, V::Undefined) | (V::Null, V::Null) => true, _ => false } }
#[export_name = "is_truthy"] pub extern "C" fn rt_is_truthy(v: i64) -> i32 { truthy(decode(v as u64)) as i32 }
#[export_name = "string_len"]
pub extern "C" fn rt_string_len(v: i64) -> i64 {
    match decode(v as u64) { V::Str(i) => unsafe { js_string_length(get_str(i)) as f64 },
        _ => 0.0 }.to_bits() as i64 }
#[export_name = "jsvalue_to_string"]
pub extern "C" fn rt_jsvalue_to_string(v: i64) -> i64 {
    encode(to_string(decode(v as u64))) as i64 }

// 数学: perry 有 C 导出的走 perry; floor/ceil/abs/sqrt 与 perry native codegen 一样内联
fn num1(v: i64, f: fn(f64) -> f64) -> i64 { f(to_number(decode(v as u64))).to_bits() as i64 }
#[export_name = "math_floor"] pub extern "C" fn rt_math_floor(v: i64) -> i64 { num1(v, f64::floor) }
#[export_name = "math_ceil"]  pub extern "C" fn rt_math_ceil(v: i64)  -> i64 { num1(v, f64::ceil) }
#[export_name = "math_abs"]   pub extern "C" fn rt_math_abs(v: i64)   -> i64 { num1(v, f64::abs) }
#[export_name = "math_sqrt"]  pub extern "C" fn rt_math_sqrt(v: i64)  -> i64 { num1(v, f64::sqrt) }
#[export_name = "math_round"] pub extern "C" fn rt_math_round(v: i64) -> i64 {
    unsafe { js_math_round(to_number(decode(v as u64))).to_bits() as i64 } }
#[export_name = "math_log"]   pub extern "C" fn rt_math_log(v: i64) -> i64 {
    unsafe { js_math_log(to_number(decode(v as u64))).to_bits() as i64 } }
#[export_name = "math_pow"]
pub extern "C" fn rt_math_pow(a: i64, b: i64) -> i64 {
    unsafe { js_math_pow(to_number(decode(a as u64)), to_number(decode(b as u64))).to_bits() as i64 } }
#[export_name = "math_random"] pub extern "C" fn rt_math_random() -> i64 {
    unsafe { js_math_random().to_bits() as i64 } }
#[export_name = "math_min"]
pub extern "C" fn rt_math_min(a: i64, b: i64) -> i64 {
    unsafe { js_math_min2(to_number(decode(a as u64)), to_number(decode(b as u64))).to_bits() as i64 } }
#[export_name = "math_max"]
pub extern "C" fn rt_math_max(a: i64, b: i64) -> i64 {
    unsafe { js_math_max2(to_number(decode(a as u64)), to_number(decode(b as u64))).to_bits() as i64 } }
#[export_name = "date_now"] pub extern "C" fn rt_date_now() -> i64 {
    unsafe { perry_runtime::date::js_date_now().to_bits() as i64 } }
#[export_name = "js_typeof"]
pub extern "C" fn rt_js_typeof(v: i64) -> i64 {
    encode(from_perry_ptr(unsafe { js_value_typeof(to_perry(decode(v as u64))) })) as i64 }
#[export_name = "parse_int"]
pub extern "C" fn rt_parse_int(v: i64) -> i64 {
    unsafe { js_parse_int(str_header(decode(v as u64)), f64::NAN).to_bits() as i64 } }
#[export_name = "parse_float"]
pub extern "C" fn rt_parse_float(v: i64) -> i64 {
    unsafe { js_parse_float(str_header(decode(v as u64))).to_bits() as i64 } }
#[export_name = "js_mod"] pub extern "C" fn rt_js_mod(a: i64, b: i64) -> i64 {
    let (x, y) = (to_number(decode(a as u64)), to_number(decode(b as u64)));
    if y == 0.0 { return f64::NAN.to_bits() as i64; }
    (x % y).to_bits() as i64 }
#[export_name = "is_null_or_undefined"] pub extern "C" fn rt_is_null_or_undefined(v: i64) -> i32 {
    matches!(decode(v as u64), V::Null | V::Undefined) as i32 }

// ---- mem_call 分派 (route-3 结构不变, 桥语义已换成 perry) ----
const MAX_ARGS: usize = 16;
const BRIDGES: [&[u8]; 10] = [b"console_log", b"console_warn", b"console_error", b"string_concat",
    b"js_add", b"string_eq", b"string_len", b"jsvalue_to_string", b"is_truthy", b"js_strict_eq"];
static mut NAME_CACHE: [u8; 64] = [0xFF; 64];
fn invoke(name_id: f64, arg_count: f64, base: u32) -> V {
    let name = name_id as u32; let argc = arg_count as u32 as usize;
    if argc > MAX_ARGS { fatal(b"mem_call: too many arguments"); }
    let mut args = [V::Undefined; MAX_ARGS];
    for (i, s) in args.iter_mut().enumerate().take(argc) {
        *s = decode(u64::from_le(unsafe { core::ptr::read_unaligned(mem_ptr::<u64>(base + i as u32 * 8)) }));
    }
    if name < 64 { let c = unsafe { *core::ptr::addr_of!(NAME_CACHE).cast::<u8>().add(name as usize) };
        if c != 0xFF { return bridge(c as usize, &args, argc); } }
    let sym = str_bytes(name);
    for (i, c) in BRIDGES.iter().enumerate() {
        if *c == sym { if name < 64 { unsafe {
            *core::ptr::addr_of_mut!(NAME_CACHE).cast::<u8>().add(name as usize) = i as u8; } }
            return bridge(i, &args, argc); } }
    write_fd(2, b"Exception: bridge function '"); write_fd(2, sym);
    write_fd(2, b"' is not implemented\n"); trap()
}
fn bridge(i: usize, a: &[V], n: usize) -> V { let need = |k: usize| { if n < k { fatal(b"arity") } };
    match i { 0 => { need(1); print_value(a[0], 1); V::Undefined }
        1 => { need(1); print_value(a[0], 2); V::Undefined }
        2 => { need(1); print_value(a[0], 2); V::Undefined }
        3 => { need(2); concat_v(a[0], a[1]) }
        4 => { need(2); if matches!(a[0], V::Str(_)) || matches!(a[1], V::Str(_)) { concat_v(a[0], a[1]) }
               else { V::Num(to_number(a[0]) + to_number(a[1])) } }
        5 => V::Num(strict_eq(a[0], a[1]) as u8 as f64),
        6 => V::Num(match a[0] { V::Str(i) => unsafe { js_string_length(get_str(i)) as f64 }, _ => 0.0 }),
        7 => to_string(a[0]), 8 => V::Num(truthy(a[0]) as u8 as f64),
        _ => V::Num(strict_eq(a[0], a[1]) as u8 as f64) } }
fn concat_v(a: V, b: V) -> V {
    from_perry_ptr(unsafe { js_string_concat(str_header(a), str_header(b)) }) }
#[export_name = "mem_call"]
pub extern "C" fn rt_mem_call(name_id: f64, arg_count: f64, base: u32) -> f64 {
    let out = invoke(name_id, arg_count, base);
    unsafe { core::ptr::write_unaligned(mem_ptr::<u64>(base), encode(out)) }; 0.0 }
#[export_name = "mem_call_i32"]
pub extern "C" fn rt_mem_call_i32(name_id: f64, arg_count: f64, base: u32) -> i32 {
    match invoke(name_id, arg_count, base) {
        V::Num(n) if !n.is_nan() => n as i32, V::Bool(b) => b as i32,
        V::Str(i) => parse_num(str_bytes(i)) as i32, _ => 0 } }
fn parse_num(b: &[u8]) -> f64 {
    let s = core::str::from_utf8(b).unwrap_or(""); s.trim().parse::<f64>().unwrap_or(f64::NAN) }
#[export_name = "_initialize"] pub extern "C" fn initialize() {}

// EH 桩: wasm 上 try/catch 走宿主导入, _Unwind_* 是链接期残留
#[no_mangle] pub extern "C" fn setjmp(_e: *mut i32) -> i32 { 0 }
#[no_mangle] pub extern "C" fn longjmp(_e: *mut i32, _v: i32) -> ! { core::arch::wasm32::unreachable() }
#[no_mangle] pub extern "C" fn perry_sjlj_try(_a: i32, _b: i32, _c: i32) -> i32 { 0 }
#[no_mangle] pub extern "C" fn _Unwind_GetLanguageSpecificData(_c: *mut u8) -> *const u8 { core::ptr::null() }
#[no_mangle] pub extern "C" fn _Unwind_GetIPInfo(_c: *mut u8, _p: *mut i32) -> usize { 0 }
#[no_mangle] pub extern "C" fn _Unwind_GetRegionStart(_c: *mut u8) -> usize { 0 }
#[no_mangle] pub extern "C" fn _Unwind_GetCFA(_c: *mut u8) -> usize { 0 }
#[no_mangle] pub extern "C" fn _Unwind_SetGR(_c: *mut u8, _r: i32, _v: usize) {}
#[no_mangle] pub extern "C" fn _Unwind_SetIP(_c: *mut u8, _v: usize) {}
#[no_mangle] pub extern "C" fn _Unwind_Backtrace(_f: *mut u8, _a: *mut u8) -> i32 { 5 }
#[no_mangle] pub extern "C" fn _Unwind_RaiseException(_e: *mut u8) -> i32 { 5 }

include!("../build/rt_symbols.rs");
