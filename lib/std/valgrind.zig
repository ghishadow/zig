const builtin = @import("builtin");
const std = @import("std.zig");
const math = std.math;

pub fn doClientRequest(default: usize, request: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize) usize {
    if (!builtin.valgrind_support) {
        return default;
    }

    const args = &[_]usize{ request, a1, a2, a3, a4, a5 };

    return switch (builtin.cpu.arch) {
        .arm, .armeb, .thumb, .thumbeb => asm volatile (
            \\ mov r12, r12, ror #3  ; mov r12, r12, ror #13
            \\ mov r12, r12, ror #29 ; mov r12, r12, ror #19
            \\ orr r10, r10, r10
            : [_] "={r3}" (-> usize),
            : [_] "{r4}" (args),
              [_] "{r3}" (default),
            : .{ .memory = true }),
        .aarch64, .aarch64_be => asm volatile (
            \\ ror x12, x12, #3  ; ror x12, x12, #13
            \\ ror x12, x12, #51 ; ror x12, x12, #61
            \\ orr x10, x10, x10
            : [_] "={x3}" (-> usize),
            : [_] "{x4}" (args),
              [_] "{x3}" (default),
            : .{ .memory = true }),
        .mips, .mipsel => asm volatile (
            \\ srl $0,  $0,  13
            \\ srl $0,  $0,  29
            \\ srl $0,  $0,  3
            \\ srl $0,  $0,  19
            \\ or  $13, $13, $13
            : [_] "={$11}" (-> usize),
            : [_] "{$12}" (args),
              [_] "{$11}" (default),
            : .{ .memory = true }),
        .mips64, .mips64el => asm volatile (
            \\ dsll $0,  $0,  3   ; dsll $0, $0, 13
            \\ dsll $0,  $0,  29  ; dsll $0, $0, 19
            \\ or   $13, $13, $13
            : [_] "={$11}" (-> usize),
            : [_] "{$12}" (args),
              [_] "{$11}" (default),
            : .{ .memory = true }),
        .powerpc, .powerpcle => asm volatile (
            \\ rlwinm 0, 0, 3,  0, 31 ; rlwinm 0, 0, 13, 0, 31
            \\ rlwinm 0, 0, 29, 0, 31 ; rlwinm 0, 0, 19, 0, 31
            \\ or     1, 1, 1
            : [_] "={r3}" (-> usize),
            : [_] "{r4}" (args),
              [_] "{r3}" (default),
            : .{ .memory = true }),
        .powerpc64, .powerpc64le => asm volatile (
            \\ rotldi 0, 0, 3  ; rotldi 0, 0, 13
            \\ rotldi 0, 0, 61 ; rotldi 0, 0, 51
            \\ or     1, 1, 1
            : [_] "={r3}" (-> usize),
            : [_] "{r4}" (args),
              [_] "{r3}" (default),
            : .{ .memory = true }),
        .riscv64 => asm volatile (
            \\ .option push
            \\ .option norvc
            \\ srli zero, zero, 3
            \\ srli zero, zero, 13
            \\ srli zero, zero, 51
            \\ srli zero, zero, 61
            \\ or   a0,   a0,   a0
            \\ .option pop
            : [_] "={a3}" (-> usize),
            : [_] "{a4}" (args),
              [_] "{a3}" (default),
            : .{ .memory = true }),
        .s390x => asm volatile (
            \\ lr %%r15, %%r15
            \\ lr %%r1,  %%r1
            \\ lr %%r2,  %%r2
            \\ lr %%r3,  %%r3
            \\ lr %%r2,  %%r2
            : [_] "={r3}" (-> usize),
            : [_] "{r2}" (args),
              [_] "{r3}" (default),
            : .{ .memory = true }),
        .x86 => asm volatile (
            \\ roll  $3,    %%edi ; roll $13, %%edi
            \\ roll  $29,   %%edi ; roll $19, %%edi
            \\ xchgl %%ebx, %%ebx
            : [_] "={edx}" (-> usize),
            : [_] "{eax}" (args),
              [_] "{edx}" (default),
            : .{ .memory = true }),
        .x86_64 => asm volatile (
            \\ rolq  $3,    %%rdi ; rolq $13, %%rdi
            \\ rolq  $61,   %%rdi ; rolq $51, %%rdi
            \\ xchgq %%rbx, %%rbx
            : [_] "={rdx}" (-> usize),
            : [_] "{rax}" (args),
              [_] "{rdx}" (default),
            : .{ .memory = true }),
        else => default,
    };
}

pub const ClientRequest = enum(u32) {
    RunningOnValgrind = 4097,
    DiscardTranslations = 4098,
    ClientCall0 = 4353,
    ClientCall1 = 4354,
    ClientCall2 = 4355,
    ClientCall3 = 4356,
    CountErrors = 4609,
    GdbMonitorCommand = 4610,
    MalloclikeBlock = 4865,
    ResizeinplaceBlock = 4875,
    FreelikeBlock = 4866,
    CreateMempool = 4867,
    DestroyMempool = 4868,
    MempoolAlloc = 4869,
    MempoolFree = 4870,
    MempoolTrim = 4871,
    MoveMempool = 4872,
    MempoolChange = 4873,
    MempoolExists = 4874,
    Printf = 5121,
    PrintfBacktrace = 5122,
    PrintfValistByRef = 5123,
    PrintfBacktraceValistByRef = 5124,
    StackRegister = 5377,
    StackDeregister = 5378,
    StackChange = 5379,
    LoadPdbDebuginfo = 5633,
    MapIpToSrcloc = 5889,
    ChangeErrDisablement = 6145,
    VexInitForIri = 6401,
    InnerThreads = 6402,
};
pub fn ToolBase(base: [2]u8) u32 {
    return (@as(u32, base[0] & 0xff) << 24) | (@as(u32, base[1] & 0xff) << 16);
}
pub fn IsTool(base: [2]u8, code: usize) bool {
    return ToolBase(base) == (code & 0xffff0000);
}

fn doClientRequestExpr(default: usize, request: ClientRequest, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize) usize {
    return doClientRequest(default, @as(usize, @intCast(@intFromEnum(request))), a1, a2, a3, a4, a5);
}

fn doClientRequestStmt(request: ClientRequest, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize) void {
    _ = doClientRequestExpr(0, request, a1, a2, a3, a4, a5);
}

/// Returns the number of Valgrinds this code is running under.  That
/// is, 0 if running natively, 1 if running under Valgrind, 2 if
/// running under Valgrind which is running under another Valgrind,
/// etc.
pub fn runningOnValgrind() usize {
    return doClientRequestExpr(0, .RunningOnValgrind, 0, 0, 0, 0, 0);
}

test "works whether running on valgrind or not" {
    _ = runningOnValgrind();
}

/// Discard translation of code in the slice qzz.  Useful if you are debugging
/// a JITter or some such, since it provides a way to make sure valgrind will
/// retranslate the invalidated area.  Returns no value.
pub fn discardTranslations(qzz: []const u8) void {
    doClientRequestStmt(.DiscardTranslations, @intFromPtr(qzz.ptr), qzz.len, 0, 0, 0);
}

pub fn innerThreads(qzz: [*]u8) void {
    doClientRequestStmt(.InnerThreads, @intFromPtr(qzz), 0, 0, 0, 0);
}

pub fn nonSimdCall0(func: fn (usize) usize) usize {
    return doClientRequestExpr(0, .ClientCall0, @intFromPtr(func), 0, 0, 0, 0);
}

pub fn nonSimdCall1(func: fn (usize, usize) usize, a1: usize) usize {
    return doClientRequestExpr(0, .ClientCall1, @intFromPtr(func), a1, 0, 0, 0);
}

pub fn nonSimdCall2(func: fn (usize, usize, usize) usize, a1: usize, a2: usize) usize {
    return doClientRequestExpr(0, .ClientCall2, @intFromPtr(func), a1, a2, 0, 0);
}

pub fn nonSimdCall3(func: fn (usize, usize, usize, usize) usize, a1: usize, a2: usize, a3: usize) usize {
    return doClientRequestExpr(0, .ClientCall3, @intFromPtr(func), a1, a2, a3, 0);
}

/// Counts the number of errors that have been recorded by a tool.  Nb:
/// the tool must record the errors with VG_(maybe_record_error)() or
/// VG_(unique_error)() for them to be counted.
pub fn countErrors() usize {
    return doClientRequestExpr(0, // default return
        .CountErrors, 0, 0, 0, 0, 0);
}

pub fn mallocLikeBlock(mem: []u8, rzB: usize, is_zeroed: bool) void {
    doClientRequestStmt(.MalloclikeBlock, @intFromPtr(mem.ptr), mem.len, rzB, @intFromBool(is_zeroed), 0);
}

pub fn resizeInPlaceBlock(oldmem: []u8, newsize: usize, rzB: usize) void {
    doClientRequestStmt(.ResizeinplaceBlock, @intFromPtr(oldmem.ptr), oldmem.len, newsize, rzB, 0);
}

pub fn freeLikeBlock(addr: [*]u8, rzB: usize) void {
    doClientRequestStmt(.FreelikeBlock, @intFromPtr(addr), rzB, 0, 0, 0);
}

/// Create a memory pool.
pub const MempoolFlags = struct {
    pub const AutoFree = 1;
    pub const MetaPool = 2;
};
pub fn createMempool(pool: [*]u8, rzB: usize, is_zeroed: bool, flags: usize) void {
    doClientRequestStmt(.CreateMempool, @intFromPtr(pool), rzB, @intFromBool(is_zeroed), flags, 0);
}

/// Destroy a memory pool.
pub fn destroyMempool(pool: [*]u8) void {
    doClientRequestStmt(.DestroyMempool, @intFromPtr(pool), 0, 0, 0, 0);
}

/// Associate a piece of memory with a memory pool.
pub fn mempoolAlloc(pool: [*]u8, mem: []u8) void {
    doClientRequestStmt(.MempoolAlloc, @intFromPtr(pool), @intFromPtr(mem.ptr), mem.len, 0, 0);
}

/// Disassociate a piece of memory from a memory pool.
pub fn mempoolFree(pool: [*]u8, addr: [*]u8) void {
    doClientRequestStmt(.MempoolFree, @intFromPtr(pool), @intFromPtr(addr), 0, 0, 0);
}

/// Disassociate any pieces outside a particular range.
pub fn mempoolTrim(pool: [*]u8, mem: []u8) void {
    doClientRequestStmt(.MempoolTrim, @intFromPtr(pool), @intFromPtr(mem.ptr), mem.len, 0, 0);
}

/// Resize and/or move a piece associated with a memory pool.
pub fn moveMempool(poolA: [*]u8, poolB: [*]u8) void {
    doClientRequestStmt(.MoveMempool, @intFromPtr(poolA), @intFromPtr(poolB), 0, 0, 0);
}

/// Resize and/or move a piece associated with a memory pool.
pub fn mempoolChange(pool: [*]u8, addrA: [*]u8, mem: []u8) void {
    doClientRequestStmt(.MempoolChange, @intFromPtr(pool), @intFromPtr(addrA), @intFromPtr(mem.ptr), mem.len, 0);
}

/// Return if a mempool exists.
pub fn mempoolExists(pool: [*]u8) bool {
    return doClientRequestExpr(0, .MempoolExists, @intFromPtr(pool), 0, 0, 0, 0) != 0;
}

/// Mark a piece of memory as being a stack. Returns a stack id.
/// start is the lowest addressable stack byte, end is the highest
/// addressable stack byte.
pub fn stackRegister(stack: []u8) usize {
    return doClientRequestExpr(0, .StackRegister, @intFromPtr(stack.ptr), @intFromPtr(stack.ptr) + stack.len, 0, 0, 0);
}

/// Unmark the piece of memory associated with a stack id as being a stack.
pub fn stackDeregister(id: usize) void {
    doClientRequestStmt(.StackDeregister, id, 0, 0, 0, 0);
}

/// Change the start and end address of the stack id.
/// start is the new lowest addressable stack byte, end is the new highest
/// addressable stack byte.
pub fn stackChange(id: usize, newstack: []u8) void {
    doClientRequestStmt(.StackChange, id, @intFromPtr(newstack.ptr), @intFromPtr(newstack.ptr) + newstack.len, 0, 0);
}

// Load PDB debug info for Wine PE image_map.
// pub fn loadPdbDebuginfo(fd, ptr, total_size, delta) void {
//     doClientRequestStmt(.LoadPdbDebuginfo,
//         fd, ptr, total_size, delta,
//         0);
// }

/// Map a code address to a source file name and line number.  buf64
/// must point to a 64-byte buffer in the caller's address space. The
/// result will be dumped in there and is guaranteed to be zero
/// terminated.  If no info is found, the first byte is set to zero.
pub fn mapIpToSrcloc(addr: *const u8, buf64: [64]u8) usize {
    return doClientRequestExpr(0, .MapIpToSrcloc, @intFromPtr(addr), @intFromPtr(&buf64[0]), 0, 0, 0);
}

/// Disable error reporting for this thread.  Behaves in a stack like
/// way, so you can safely call this multiple times provided that
/// enableErrorReporting() is called the same number of times
/// to re-enable reporting.  The first call of this macro disables
/// reporting.  Subsequent calls have no effect except to increase the
/// number of enableErrorReporting() calls needed to re-enable
/// reporting.  Child threads do not inherit this setting from their
/// parents -- they are always created with reporting enabled.
pub fn disableErrorReporting() void {
    doClientRequestStmt(.ChangeErrDisablement, 1, 0, 0, 0, 0);
}

/// Re-enable error reporting. (see disableErrorReporting())
pub fn enableErrorReporting() void {
    doClientRequestStmt(.ChangeErrDisablement, math.maxInt(usize), 0, 0, 0, 0);
}

/// Execute a monitor command from the client program.
/// If a connection is opened with GDB, the output will be sent
/// according to the output mode set for vgdb.
/// If no connection is opened, output will go to the log output.
/// Returns 1 if command not recognised, 0 otherwise.
pub fn monitorCommand(command: [*]u8) bool {
    return doClientRequestExpr(0, .GdbMonitorCommand, @intFromPtr(command), 0, 0, 0, 0) != 0;
}

pub const memcheck = @import("valgrind/memcheck.zig");
pub const callgrind = @import("valgrind/callgrind.zig");
pub const cachegrind = @import("valgrind/cachegrind.zig");

test {
    _ = memcheck;
    _ = callgrind;
    _ = cachegrind;
}
