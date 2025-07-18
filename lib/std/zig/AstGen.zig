//! Ingests an AST and produces ZIR code.
const AstGen = @This();

const std = @import("std");
const Ast = std.zig.Ast;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const StringIndexAdapter = std.hash_map.StringIndexAdapter;
const StringIndexContext = std.hash_map.StringIndexContext;

const isPrimitive = std.zig.primitives.isPrimitive;

const Zir = std.zig.Zir;
const BuiltinFn = std.zig.BuiltinFn;
const AstRlAnnotate = std.zig.AstRlAnnotate;

gpa: Allocator,
tree: *const Ast,
/// The set of nodes which, given the choice, must expose a result pointer to
/// sub-expressions. See `AstRlAnnotate` for details.
nodes_need_rl: *const AstRlAnnotate.RlNeededSet,
instructions: std.MultiArrayList(Zir.Inst) = .{},
extra: ArrayListUnmanaged(u32) = .empty,
string_bytes: ArrayListUnmanaged(u8) = .empty,
/// Tracks the current byte offset within the source file.
/// Used to populate line deltas in the ZIR. AstGen maintains
/// this "cursor" throughout the entire AST lowering process in order
/// to avoid starting over the line/column scan for every declaration, which
/// would be O(N^2).
source_offset: u32 = 0,
/// Tracks the corresponding line of `source_offset`.
/// This value is absolute.
source_line: u32 = 0,
/// Tracks the corresponding column of `source_offset`.
/// This value is absolute.
source_column: u32 = 0,
/// Used for temporary allocations; freed after AstGen is complete.
/// The resulting ZIR code has no references to anything in this arena.
arena: Allocator,
string_table: std.HashMapUnmanaged(u32, void, StringIndexContext, std.hash_map.default_max_load_percentage) = .empty,
compile_errors: ArrayListUnmanaged(Zir.Inst.CompileErrors.Item) = .empty,
/// The topmost block of the current function.
fn_block: ?*GenZir = null,
fn_var_args: bool = false,
/// Whether we are somewhere within a function. If `true`, any container decls may be
/// generic and thus must be tunneled through closure.
within_fn: bool = false,
/// The return type of the current function. This may be a trivial `Ref`, or
/// otherwise it refers to a `ret_type` instruction.
fn_ret_ty: Zir.Inst.Ref = .none,
/// Maps string table indexes to the first `@import` ZIR instruction
/// that uses this string as the operand.
imports: std.AutoArrayHashMapUnmanaged(Zir.NullTerminatedString, Ast.TokenIndex) = .empty,
/// Used for temporary storage when building payloads.
scratch: std.ArrayListUnmanaged(u32) = .empty,
/// Whenever a `ref` instruction is needed, it is created and saved in this
/// table instead of being immediately appended to the current block body.
/// Then, when the instruction is being added to the parent block (typically from
/// setBlockBody), if it has a ref_table entry, then the ref instruction is added
/// there. This makes sure two properties are upheld:
/// 1. All pointers to the same locals return the same address. This is required
///    to be compliant with the language specification.
/// 2. `ref` instructions will dominate their uses. This is a required property
///    of ZIR.
/// The key is the ref operand; the value is the ref instruction.
ref_table: std.AutoHashMapUnmanaged(Zir.Inst.Index, Zir.Inst.Index) = .empty,
/// Any information which should trigger invalidation of incremental compilation
/// data should be used to update this hasher. The result is the final source
/// hash of the enclosing declaration/etc.
src_hasher: std.zig.SrcHasher,

const InnerError = error{ OutOfMemory, AnalysisFail };

fn addExtra(astgen: *AstGen, extra: anytype) Allocator.Error!u32 {
    const fields = std.meta.fields(@TypeOf(extra));
    try astgen.extra.ensureUnusedCapacity(astgen.gpa, fields.len);
    return addExtraAssumeCapacity(astgen, extra);
}

fn addExtraAssumeCapacity(astgen: *AstGen, extra: anytype) u32 {
    const fields = std.meta.fields(@TypeOf(extra));
    const extra_index: u32 = @intCast(astgen.extra.items.len);
    astgen.extra.items.len += fields.len;
    setExtra(astgen, extra_index, extra);
    return extra_index;
}

fn setExtra(astgen: *AstGen, index: usize, extra: anytype) void {
    const fields = std.meta.fields(@TypeOf(extra));
    var i = index;
    inline for (fields) |field| {
        astgen.extra.items[i] = switch (field.type) {
            u32 => @field(extra, field.name),

            Zir.Inst.Ref,
            Zir.Inst.Index,
            Zir.Inst.Declaration.Name,
            std.zig.SimpleComptimeReason,
            Zir.NullTerminatedString,
            // Ast.TokenIndex is missing because it is a u32.
            Ast.OptionalTokenIndex,
            Ast.Node.Index,
            Ast.Node.OptionalIndex,
            => @intFromEnum(@field(extra, field.name)),

            Ast.TokenOffset,
            Ast.OptionalTokenOffset,
            Ast.Node.Offset,
            Ast.Node.OptionalOffset,
            => @bitCast(@intFromEnum(@field(extra, field.name))),

            i32,
            Zir.Inst.Call.Flags,
            Zir.Inst.BuiltinCall.Flags,
            Zir.Inst.SwitchBlock.Bits,
            Zir.Inst.SwitchBlockErrUnion.Bits,
            Zir.Inst.FuncFancy.Bits,
            Zir.Inst.Param.Type,
            Zir.Inst.Func.RetTy,
            => @bitCast(@field(extra, field.name)),

            else => @compileError("bad field type"),
        };
        i += 1;
    }
}

fn reserveExtra(astgen: *AstGen, size: usize) Allocator.Error!u32 {
    const extra_index: u32 = @intCast(astgen.extra.items.len);
    try astgen.extra.resize(astgen.gpa, extra_index + size);
    return extra_index;
}

fn appendRefs(astgen: *AstGen, refs: []const Zir.Inst.Ref) !void {
    return astgen.extra.appendSlice(astgen.gpa, @ptrCast(refs));
}

fn appendRefsAssumeCapacity(astgen: *AstGen, refs: []const Zir.Inst.Ref) void {
    astgen.extra.appendSliceAssumeCapacity(@ptrCast(refs));
}

pub fn generate(gpa: Allocator, tree: Ast) Allocator.Error!Zir {
    assert(tree.mode == .zig);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var nodes_need_rl = try AstRlAnnotate.annotate(gpa, arena.allocator(), tree);
    defer nodes_need_rl.deinit(gpa);

    var astgen: AstGen = .{
        .gpa = gpa,
        .arena = arena.allocator(),
        .tree = &tree,
        .nodes_need_rl = &nodes_need_rl,
        .src_hasher = undefined, // `structDeclInner` for the root struct will set this
    };
    defer astgen.deinit(gpa);

    // String table index 0 is reserved for `NullTerminatedString.empty`.
    try astgen.string_bytes.append(gpa, 0);

    // We expect at least as many ZIR instructions and extra data items
    // as AST nodes.
    try astgen.instructions.ensureTotalCapacity(gpa, tree.nodes.len);

    // First few indexes of extra are reserved and set at the end.
    const reserved_count = @typeInfo(Zir.ExtraIndex).@"enum".fields.len;
    try astgen.extra.ensureTotalCapacity(gpa, tree.nodes.len + reserved_count);
    astgen.extra.items.len += reserved_count;

    var top_scope: Scope.Top = .{};

    var gz_instructions: std.ArrayListUnmanaged(Zir.Inst.Index) = .empty;
    var gen_scope: GenZir = .{
        .is_comptime = true,
        .parent = &top_scope.base,
        .decl_node_index = .root,
        .decl_line = 0,
        .astgen = &astgen,
        .instructions = &gz_instructions,
        .instructions_top = 0,
    };
    defer gz_instructions.deinit(gpa);

    // The AST -> ZIR lowering process assumes an AST that does not have any parse errors.
    // Parse errors, or AstGen errors in the root struct, are considered "fatal", so we emit no ZIR.
    const fatal = if (tree.errors.len == 0) fatal: {
        if (AstGen.structDeclInner(
            &gen_scope,
            &gen_scope.base,
            .root,
            tree.containerDeclRoot(),
            .auto,
            .none,
            .parent,
        )) |struct_decl_ref| {
            assert(struct_decl_ref.toIndex().? == .main_struct_inst);
            break :fatal false;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AnalysisFail => break :fatal true, // Handled via compile_errors below.
        }
    } else fatal: {
        try lowerAstErrors(&astgen);
        break :fatal true;
    };

    const err_index = @intFromEnum(Zir.ExtraIndex.compile_errors);
    if (astgen.compile_errors.items.len == 0) {
        astgen.extra.items[err_index] = 0;
    } else {
        try astgen.extra.ensureUnusedCapacity(gpa, 1 + astgen.compile_errors.items.len *
            @typeInfo(Zir.Inst.CompileErrors.Item).@"struct".fields.len);

        astgen.extra.items[err_index] = astgen.addExtraAssumeCapacity(Zir.Inst.CompileErrors{
            .items_len = @intCast(astgen.compile_errors.items.len),
        });

        for (astgen.compile_errors.items) |item| {
            _ = astgen.addExtraAssumeCapacity(item);
        }
    }

    const imports_index = @intFromEnum(Zir.ExtraIndex.imports);
    if (astgen.imports.count() == 0) {
        astgen.extra.items[imports_index] = 0;
    } else {
        try astgen.extra.ensureUnusedCapacity(gpa, @typeInfo(Zir.Inst.Imports).@"struct".fields.len +
            astgen.imports.count() * @typeInfo(Zir.Inst.Imports.Item).@"struct".fields.len);

        astgen.extra.items[imports_index] = astgen.addExtraAssumeCapacity(Zir.Inst.Imports{
            .imports_len = @intCast(astgen.imports.count()),
        });

        var it = astgen.imports.iterator();
        while (it.next()) |entry| {
            _ = astgen.addExtraAssumeCapacity(Zir.Inst.Imports.Item{
                .name = entry.key_ptr.*,
                .token = entry.value_ptr.*,
            });
        }
    }

    return .{
        .instructions = if (fatal) .empty else astgen.instructions.toOwnedSlice(),
        .string_bytes = try astgen.string_bytes.toOwnedSlice(gpa),
        .extra = try astgen.extra.toOwnedSlice(gpa),
    };
}

fn deinit(astgen: *AstGen, gpa: Allocator) void {
    astgen.instructions.deinit(gpa);
    astgen.extra.deinit(gpa);
    astgen.string_table.deinit(gpa);
    astgen.string_bytes.deinit(gpa);
    astgen.compile_errors.deinit(gpa);
    astgen.imports.deinit(gpa);
    astgen.scratch.deinit(gpa);
    astgen.ref_table.deinit(gpa);
}

const ResultInfo = struct {
    /// The semantics requested for the result location
    rl: Loc,

    /// The "operator" consuming the result location
    ctx: Context = .none,

    /// Turns a `coerced_ty` back into a `ty`. Should be called at branch points
    /// such as if and switch expressions.
    fn br(ri: ResultInfo) ResultInfo {
        return switch (ri.rl) {
            .coerced_ty => |ty| .{
                .rl = .{ .ty = ty },
                .ctx = ri.ctx,
            },
            else => ri,
        };
    }

    fn zirTag(ri: ResultInfo) Zir.Inst.Tag {
        switch (ri.rl) {
            .ty => return switch (ri.ctx) {
                .shift_op => .as_shift_operand,
                else => .as_node,
            },
            else => unreachable,
        }
    }

    const Loc = union(enum) {
        /// The expression is the right-hand side of assignment to `_`. Only the side-effects of the
        /// expression should be generated. The result instruction from the expression must
        /// be ignored.
        discard,
        /// The expression has an inferred type, and it will be evaluated as an rvalue.
        none,
        /// The expression will be coerced into this type, but it will be evaluated as an rvalue.
        ty: Zir.Inst.Ref,
        /// Same as `ty` but it is guaranteed that Sema will additionally perform the coercion,
        /// so no `as` instruction needs to be emitted.
        coerced_ty: Zir.Inst.Ref,
        /// The expression must generate a pointer rather than a value. For example, the left hand side
        /// of an assignment uses this kind of result location.
        ref,
        /// The expression must generate a pointer rather than a value, and the pointer will be coerced
        /// by other code to this type, which is guaranteed by earlier instructions to be a pointer type.
        ref_coerced_ty: Zir.Inst.Ref,
        /// The expression must store its result into this typed pointer. The result instruction
        /// from the expression must be ignored.
        ptr: PtrResultLoc,
        /// The expression must store its result into this allocation, which has an inferred type.
        /// The result instruction from the expression must be ignored.
        /// Always an instruction with tag `alloc_inferred`.
        inferred_ptr: Zir.Inst.Ref,
        /// The expression has a sequence of pointers to store its results into due to a destructure
        /// operation. Each of these pointers may or may not have an inferred type.
        destructure: struct {
            /// The AST node of the destructure operation itself.
            src_node: Ast.Node.Index,
            /// The pointers to store results into.
            components: []const DestructureComponent,
        },

        const DestructureComponent = union(enum) {
            typed_ptr: PtrResultLoc,
            inferred_ptr: Zir.Inst.Ref,
            discard,
        };

        const PtrResultLoc = struct {
            inst: Zir.Inst.Ref,
            src_node: ?Ast.Node.Index = null,
        };

        /// Find the result type for a cast builtin given the result location.
        /// If the location does not have a known result type, returns `null`.
        fn resultType(rl: Loc, gz: *GenZir, node: Ast.Node.Index) !?Zir.Inst.Ref {
            return switch (rl) {
                .discard, .none, .ref, .inferred_ptr, .destructure => null,
                .ty, .coerced_ty => |ty_ref| ty_ref,
                .ref_coerced_ty => |ptr_ty| try gz.addUnNode(.elem_type, ptr_ty, node),
                .ptr => |ptr| {
                    const ptr_ty = try gz.addUnNode(.typeof, ptr.inst, node);
                    return try gz.addUnNode(.elem_type, ptr_ty, node);
                },
            };
        }

        /// Find the result type for a cast builtin given the result location.
        /// If the location does not have a known result type, emits an error on
        /// the given node.
        fn resultTypeForCast(rl: Loc, gz: *GenZir, node: Ast.Node.Index, builtin_name: []const u8) !Zir.Inst.Ref {
            const astgen = gz.astgen;
            if (try rl.resultType(gz, node)) |ty| return ty;
            switch (rl) {
                .destructure => |destructure| return astgen.failNodeNotes(node, "{s} must have a known result type", .{builtin_name}, &.{
                    try astgen.errNoteNode(destructure.src_node, "destructure expressions do not provide a single result type", .{}),
                    try astgen.errNoteNode(node, "use @as to provide explicit result type", .{}),
                }),
                else => return astgen.failNodeNotes(node, "{s} must have a known result type", .{builtin_name}, &.{
                    try astgen.errNoteNode(node, "use @as to provide explicit result type", .{}),
                }),
            }
        }
    };

    const Context = enum {
        /// The expression is the operand to a return expression.
        @"return",
        /// The expression is the input to an error-handling operator (if-else, try, or catch).
        error_handling_expr,
        /// The expression is the right-hand side of a shift operation.
        shift_op,
        /// The expression is an argument in a function call.
        fn_arg,
        /// The expression is the right-hand side of an initializer for a `const` variable
        const_init,
        /// The expression is the right-hand side of an assignment expression.
        assignment,
        /// No specific operator in particular.
        none,
    };
};

const coerced_align_ri: ResultInfo = .{ .rl = .{ .coerced_ty = .u29_type } };
const coerced_linksection_ri: ResultInfo = .{ .rl = .{ .coerced_ty = .slice_const_u8_type } };
const coerced_type_ri: ResultInfo = .{ .rl = .{ .coerced_ty = .type_type } };
const coerced_bool_ri: ResultInfo = .{ .rl = .{ .coerced_ty = .bool_type } };

fn typeExpr(gz: *GenZir, scope: *Scope, type_node: Ast.Node.Index) InnerError!Zir.Inst.Ref {
    return comptimeExpr(gz, scope, coerced_type_ri, type_node, .type);
}

fn reachableTypeExpr(
    gz: *GenZir,
    scope: *Scope,
    type_node: Ast.Node.Index,
    reachable_node: Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    return reachableExprComptime(gz, scope, coerced_type_ri, type_node, reachable_node, .type);
}

/// Same as `expr` but fails with a compile error if the result type is `noreturn`.
fn reachableExpr(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    reachable_node: Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    return reachableExprComptime(gz, scope, ri, node, reachable_node, null);
}

fn reachableExprComptime(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    reachable_node: Ast.Node.Index,
    /// If `null`, the expression is not evaluated in a comptime context.
    comptime_reason: ?std.zig.SimpleComptimeReason,
) InnerError!Zir.Inst.Ref {
    const result_inst = if (comptime_reason) |r|
        try comptimeExpr(gz, scope, ri, node, r)
    else
        try expr(gz, scope, ri, node);

    if (gz.refIsNoReturn(result_inst)) {
        try gz.astgen.appendErrorNodeNotes(reachable_node, "unreachable code", .{}, &[_]u32{
            try gz.astgen.errNoteNode(node, "control flow is diverted here", .{}),
        });
    }
    return result_inst;
}

fn lvalExpr(gz: *GenZir, scope: *Scope, node: Ast.Node.Index) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    switch (tree.nodeTag(node)) {
        .root => unreachable,
        .test_decl => unreachable,
        .global_var_decl => unreachable,
        .local_var_decl => unreachable,
        .simple_var_decl => unreachable,
        .aligned_var_decl => unreachable,
        .switch_case => unreachable,
        .switch_case_inline => unreachable,
        .switch_case_one => unreachable,
        .switch_case_inline_one => unreachable,
        .container_field_init => unreachable,
        .container_field_align => unreachable,
        .container_field => unreachable,
        .asm_output => unreachable,
        .asm_input => unreachable,

        .assign,
        .assign_destructure,
        .assign_bit_and,
        .assign_bit_or,
        .assign_shl,
        .assign_shl_sat,
        .assign_shr,
        .assign_bit_xor,
        .assign_div,
        .assign_sub,
        .assign_sub_wrap,
        .assign_sub_sat,
        .assign_mod,
        .assign_add,
        .assign_add_wrap,
        .assign_add_sat,
        .assign_mul,
        .assign_mul_wrap,
        .assign_mul_sat,
        .add,
        .add_wrap,
        .add_sat,
        .sub,
        .sub_wrap,
        .sub_sat,
        .mul,
        .mul_wrap,
        .mul_sat,
        .div,
        .mod,
        .bit_and,
        .bit_or,
        .shl,
        .shl_sat,
        .shr,
        .bit_xor,
        .bang_equal,
        .equal_equal,
        .greater_than,
        .greater_or_equal,
        .less_than,
        .less_or_equal,
        .array_cat,
        .array_mult,
        .bool_and,
        .bool_or,
        .@"asm",
        .asm_simple,
        .asm_legacy,
        .string_literal,
        .number_literal,
        .call,
        .call_comma,
        .call_one,
        .call_one_comma,
        .unreachable_literal,
        .@"return",
        .@"if",
        .if_simple,
        .@"while",
        .while_simple,
        .while_cont,
        .bool_not,
        .address_of,
        .optional_type,
        .block,
        .block_semicolon,
        .block_two,
        .block_two_semicolon,
        .@"break",
        .ptr_type_aligned,
        .ptr_type_sentinel,
        .ptr_type,
        .ptr_type_bit_range,
        .array_type,
        .array_type_sentinel,
        .enum_literal,
        .multiline_string_literal,
        .char_literal,
        .@"defer",
        .@"errdefer",
        .@"catch",
        .error_union,
        .merge_error_sets,
        .switch_range,
        .for_range,
        .bit_not,
        .negation,
        .negation_wrap,
        .@"resume",
        .@"try",
        .slice,
        .slice_open,
        .slice_sentinel,
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        .struct_init_one,
        .struct_init_one_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init,
        .struct_init_comma,
        .@"switch",
        .switch_comma,
        .@"for",
        .for_simple,
        .@"suspend",
        .@"continue",
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto,
        .fn_decl,
        .anyframe_type,
        .anyframe_literal,
        .error_set_decl,
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        .@"comptime",
        .@"nosuspend",
        .error_value,
        => return astgen.failNode(node, "invalid left-hand side to assignment", .{}),

        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            const builtin_token = tree.nodeMainToken(node);
            const builtin_name = tree.tokenSlice(builtin_token);
            // If the builtin is an invalid name, we don't cause an error here; instead
            // let it pass, and the error will be "invalid builtin function" later.
            if (BuiltinFn.list.get(builtin_name)) |info| {
                if (!info.allows_lvalue) {
                    return astgen.failNode(node, "invalid left-hand side to assignment", .{});
                }
            }
        },

        // These can be assigned to.
        .unwrap_optional,
        .deref,
        .field_access,
        .array_access,
        .identifier,
        .grouped_expression,
        .@"orelse",
        => {},
    }
    return expr(gz, scope, .{ .rl = .ref }, node);
}

/// Turn Zig AST into untyped ZIR instructions.
/// When `rl` is discard, ptr, inferred_ptr, or inferred_ptr, the
/// result instruction can be used to inspect whether it is isNoReturn() but that is it,
/// it must otherwise not be used.
fn expr(gz: *GenZir, scope: *Scope, ri: ResultInfo, node: Ast.Node.Index) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    switch (tree.nodeTag(node)) {
        .root => unreachable, // Top-level declaration.
        .test_decl => unreachable, // Top-level declaration.
        .container_field_init => unreachable, // Top-level declaration.
        .container_field_align => unreachable, // Top-level declaration.
        .container_field => unreachable, // Top-level declaration.
        .fn_decl => unreachable, // Top-level declaration.

        .global_var_decl => unreachable, // Handled in `blockExpr`.
        .local_var_decl => unreachable, // Handled in `blockExpr`.
        .simple_var_decl => unreachable, // Handled in `blockExpr`.
        .aligned_var_decl => unreachable, // Handled in `blockExpr`.
        .@"defer" => unreachable, // Handled in `blockExpr`.
        .@"errdefer" => unreachable, // Handled in `blockExpr`.

        .switch_case => unreachable, // Handled in `switchExpr`.
        .switch_case_inline => unreachable, // Handled in `switchExpr`.
        .switch_case_one => unreachable, // Handled in `switchExpr`.
        .switch_case_inline_one => unreachable, // Handled in `switchExpr`.
        .switch_range => unreachable, // Handled in `switchExpr`.

        .asm_output => unreachable, // Handled in `asmExpr`.
        .asm_input => unreachable, // Handled in `asmExpr`.

        .for_range => unreachable, // Handled in `forExpr`.

        .assign => {
            try assign(gz, scope, node);
            return rvalue(gz, ri, .void_value, node);
        },

        .assign_destructure => {
            // Note that this variant does not declare any new var/const: that
            // variant is handled by `blockExprStmts`.
            try assignDestructure(gz, scope, node);
            return rvalue(gz, ri, .void_value, node);
        },

        .assign_shl => {
            try assignShift(gz, scope, node, .shl);
            return rvalue(gz, ri, .void_value, node);
        },
        .assign_shl_sat => {
            try assignShiftSat(gz, scope, node);
            return rvalue(gz, ri, .void_value, node);
        },
        .assign_shr => {
            try assignShift(gz, scope, node, .shr);
            return rvalue(gz, ri, .void_value, node);
        },

        .assign_bit_and => {
            try assignOp(gz, scope, node, .bit_and);
            return rvalue(gz, ri, .void_value, node);
        },
        .assign_bit_or => {
            try assignOp(gz, scope, node, .bit_or);
            return rvalue(gz, ri, .void_value, node);
        },
        .assign_bit_xor => {
            try assignOp(gz, scope, node, .xor);
            return rvalue(gz, ri, .void_value, node);
        },
        .assign_div => {
            try assignOp(gz, scope, node, .div);
            return rvalue(gz, ri, .void_value, node);
        },
        .assign_sub => {
            try assignOp(gz, scope, node, .sub);
            return rvalue(gz, ri, .void_value, node);
        },
        .assign_sub_wrap => {
            try assignOp(gz, scope, node, .subwrap);
            return rvalue(gz, ri, .void_value, node);
        },
        .assign_sub_sat => {
            try assignOp(gz, scope, node, .sub_sat);
            return rvalue(gz, ri, .void_value, node);
        },
        .assign_mod => {
            try assignOp(gz, scope, node, .mod_rem);
            return rvalue(gz, ri, .void_value, node);
        },
        .assign_add => {
            try assignOp(gz, scope, node, .add);
            return rvalue(gz, ri, .void_value, node);
        },
        .assign_add_wrap => {
            try assignOp(gz, scope, node, .addwrap);
            return rvalue(gz, ri, .void_value, node);
        },
        .assign_add_sat => {
            try assignOp(gz, scope, node, .add_sat);
            return rvalue(gz, ri, .void_value, node);
        },
        .assign_mul => {
            try assignOp(gz, scope, node, .mul);
            return rvalue(gz, ri, .void_value, node);
        },
        .assign_mul_wrap => {
            try assignOp(gz, scope, node, .mulwrap);
            return rvalue(gz, ri, .void_value, node);
        },
        .assign_mul_sat => {
            try assignOp(gz, scope, node, .mul_sat);
            return rvalue(gz, ri, .void_value, node);
        },

        // zig fmt: off
        .shl => return shiftOp(gz, scope, ri, node, tree.nodeData(node).node_and_node[0], tree.nodeData(node).node_and_node[1], .shl),
        .shr => return shiftOp(gz, scope, ri, node, tree.nodeData(node).node_and_node[0], tree.nodeData(node).node_and_node[1], .shr),

        .add      => return simpleBinOp(gz, scope, ri, node, .add),
        .add_wrap => return simpleBinOp(gz, scope, ri, node, .addwrap),
        .add_sat  => return simpleBinOp(gz, scope, ri, node, .add_sat),
        .sub      => return simpleBinOp(gz, scope, ri, node, .sub),
        .sub_wrap => return simpleBinOp(gz, scope, ri, node, .subwrap),
        .sub_sat  => return simpleBinOp(gz, scope, ri, node, .sub_sat),
        .mul      => return simpleBinOp(gz, scope, ri, node, .mul),
        .mul_wrap => return simpleBinOp(gz, scope, ri, node, .mulwrap),
        .mul_sat  => return simpleBinOp(gz, scope, ri, node, .mul_sat),
        .div      => return simpleBinOp(gz, scope, ri, node, .div),
        .mod      => return simpleBinOp(gz, scope, ri, node, .mod_rem),
        .shl_sat  => return simpleBinOp(gz, scope, ri, node, .shl_sat),

        .bit_and          => return simpleBinOp(gz, scope, ri, node, .bit_and),
        .bit_or           => return simpleBinOp(gz, scope, ri, node, .bit_or),
        .bit_xor          => return simpleBinOp(gz, scope, ri, node, .xor),
        .bang_equal       => return simpleBinOp(gz, scope, ri, node, .cmp_neq),
        .equal_equal      => return simpleBinOp(gz, scope, ri, node, .cmp_eq),
        .greater_than     => return simpleBinOp(gz, scope, ri, node, .cmp_gt),
        .greater_or_equal => return simpleBinOp(gz, scope, ri, node, .cmp_gte),
        .less_than        => return simpleBinOp(gz, scope, ri, node, .cmp_lt),
        .less_or_equal    => return simpleBinOp(gz, scope, ri, node, .cmp_lte),
        .array_cat        => return simpleBinOp(gz, scope, ri, node, .array_cat),

        .array_mult => {
            // This syntax form does not currently use the result type in the language specification.
            // However, the result type can be used to emit more optimal code for large multiplications by
            // having Sema perform a coercion before the multiplication operation.
            const lhs_node, const rhs_node = tree.nodeData(node).node_and_node;
            const result = try gz.addPlNode(.array_mul, node, Zir.Inst.ArrayMul{
                .res_ty = if (try ri.rl.resultType(gz, node)) |t| t else .none,
                .lhs = try expr(gz, scope, .{ .rl = .none }, lhs_node),
                .rhs = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = .usize_type } }, rhs_node, .array_mul_factor),
            });
            return rvalue(gz, ri, result, node);
        },

        .error_union, .merge_error_sets => |tag| {
            const inst_tag: Zir.Inst.Tag = switch (tag) {
                .error_union => .error_union_type,
                .merge_error_sets => .merge_error_sets,
                else => unreachable,
            };
            const lhs_node, const rhs_node = tree.nodeData(node).node_and_node;
            const lhs = try reachableTypeExpr(gz, scope, lhs_node, node);
            const rhs = try reachableTypeExpr(gz, scope, rhs_node, node);
            const result = try gz.addPlNode(inst_tag, node, Zir.Inst.Bin{ .lhs = lhs, .rhs = rhs });
            return rvalue(gz, ri, result, node);
        },

        .bool_and => return boolBinOp(gz, scope, ri, node, .bool_br_and),
        .bool_or  => return boolBinOp(gz, scope, ri, node, .bool_br_or),

        .bool_not => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none }, tree.nodeData(node).node, .bool_not),
        .bit_not  => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none }, tree.nodeData(node).node, .bit_not),

        .negation      => return   negation(gz, scope, ri, node),
        .negation_wrap => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none }, tree.nodeData(node).node, .negate_wrap),

        .identifier => return identifier(gz, scope, ri, node, null),

        .asm_simple,
        .@"asm",
        => return asmExpr(gz, scope, ri, node, tree.fullAsm(node).?),

        .asm_legacy => {
            return astgen.failNodeNotes(node, "legacy asm clobbers syntax", .{}, &[_]u32{
                try astgen.errNoteNode(node, "use 'zig fmt' to auto-upgrade", .{}),
            });
        },

        .string_literal           => return stringLiteral(gz, ri, node),
        .multiline_string_literal => return multilineStringLiteral(gz, ri, node),

        .number_literal => return numberLiteral(gz, ri, node, node, .positive),
        // zig fmt: on

        .builtin_call_two,
        .builtin_call_two_comma,
        .builtin_call,
        .builtin_call_comma,
        => {
            var buf: [2]Ast.Node.Index = undefined;
            const params = tree.builtinCallParams(&buf, node).?;
            return builtinCall(gz, scope, ri, node, params, false);
        },

        .call_one,
        .call_one_comma,
        .call,
        .call_comma,
        => {
            var buf: [1]Ast.Node.Index = undefined;
            return callExpr(gz, scope, ri, .none, node, tree.fullCall(&buf, node).?);
        },

        .unreachable_literal => {
            try emitDbgNode(gz, node);
            _ = try gz.addAsIndex(.{
                .tag = .@"unreachable",
                .data = .{ .@"unreachable" = .{
                    .src_node = gz.nodeIndexToRelative(node),
                } },
            });
            return Zir.Inst.Ref.unreachable_value;
        },
        .@"return" => return ret(gz, scope, node),
        .field_access => return fieldAccess(gz, scope, ri, node),

        .if_simple,
        .@"if",
        => {
            const if_full = tree.fullIf(node).?;
            no_switch_on_err: {
                const error_token = if_full.error_token orelse break :no_switch_on_err;
                const else_node = if_full.ast.else_expr.unwrap() orelse break :no_switch_on_err;
                const full_switch = tree.fullSwitch(else_node) orelse break :no_switch_on_err;
                if (full_switch.label_token != null) break :no_switch_on_err;
                if (tree.nodeTag(full_switch.ast.condition) != .identifier) break :no_switch_on_err;
                if (!mem.eql(u8, tree.tokenSlice(error_token), tree.tokenSlice(tree.nodeMainToken(full_switch.ast.condition)))) break :no_switch_on_err;
                return switchExprErrUnion(gz, scope, ri.br(), node, .@"if");
            }
            return ifExpr(gz, scope, ri.br(), node, if_full);
        },

        .while_simple,
        .while_cont,
        .@"while",
        => return whileExpr(gz, scope, ri.br(), node, tree.fullWhile(node).?, false),

        .for_simple, .@"for" => return forExpr(gz, scope, ri.br(), node, tree.fullFor(node).?, false),

        .slice_open,
        .slice,
        .slice_sentinel,
        => {
            const full = tree.fullSlice(node).?;
            if (full.ast.end != .none and
                tree.nodeTag(full.ast.sliced) == .slice_open and
                nodeIsTriviallyZero(tree, full.ast.start))
            {
                const lhs_extra = tree.sliceOpen(full.ast.sliced).ast;

                const lhs = try expr(gz, scope, .{ .rl = .ref }, lhs_extra.sliced);
                const start = try expr(gz, scope, .{ .rl = .{ .coerced_ty = .usize_type } }, lhs_extra.start);
                const cursor = maybeAdvanceSourceCursorToMainToken(gz, node);
                const len = try expr(gz, scope, .{ .rl = .{ .coerced_ty = .usize_type } }, full.ast.end.unwrap().?);
                const sentinel = if (full.ast.sentinel.unwrap()) |sentinel| try expr(gz, scope, .{ .rl = .none }, sentinel) else .none;
                try emitDbgStmt(gz, cursor);
                const result = try gz.addPlNode(.slice_length, node, Zir.Inst.SliceLength{
                    .lhs = lhs,
                    .start = start,
                    .len = len,
                    .start_src_node_offset = gz.nodeIndexToRelative(full.ast.sliced),
                    .sentinel = sentinel,
                });
                return rvalue(gz, ri, result, node);
            }
            const lhs = try expr(gz, scope, .{ .rl = .ref }, full.ast.sliced);

            const cursor = maybeAdvanceSourceCursorToMainToken(gz, node);
            const start = try expr(gz, scope, .{ .rl = .{ .coerced_ty = .usize_type } }, full.ast.start);
            const end = if (full.ast.end.unwrap()) |end| try expr(gz, scope, .{ .rl = .{ .coerced_ty = .usize_type } }, end) else .none;
            const sentinel = if (full.ast.sentinel.unwrap()) |sentinel| s: {
                const sentinel_ty = try gz.addUnNode(.slice_sentinel_ty, lhs, node);
                break :s try expr(gz, scope, .{ .rl = .{ .coerced_ty = sentinel_ty } }, sentinel);
            } else .none;
            try emitDbgStmt(gz, cursor);
            if (sentinel != .none) {
                const result = try gz.addPlNode(.slice_sentinel, node, Zir.Inst.SliceSentinel{
                    .lhs = lhs,
                    .start = start,
                    .end = end,
                    .sentinel = sentinel,
                });
                return rvalue(gz, ri, result, node);
            } else if (end != .none) {
                const result = try gz.addPlNode(.slice_end, node, Zir.Inst.SliceEnd{
                    .lhs = lhs,
                    .start = start,
                    .end = end,
                });
                return rvalue(gz, ri, result, node);
            } else {
                const result = try gz.addPlNode(.slice_start, node, Zir.Inst.SliceStart{
                    .lhs = lhs,
                    .start = start,
                });
                return rvalue(gz, ri, result, node);
            }
        },

        .deref => {
            const lhs = try expr(gz, scope, .{ .rl = .none }, tree.nodeData(node).node);
            _ = try gz.addUnNode(.validate_deref, lhs, node);
            switch (ri.rl) {
                .ref, .ref_coerced_ty => return lhs,
                else => {
                    const result = try gz.addUnNode(.load, lhs, node);
                    return rvalue(gz, ri, result, node);
                },
            }
        },
        .address_of => {
            const operand_rl: ResultInfo.Loc = if (try ri.rl.resultType(gz, node)) |res_ty_inst| rl: {
                _ = try gz.addUnTok(.validate_ref_ty, res_ty_inst, tree.firstToken(node));
                break :rl .{ .ref_coerced_ty = res_ty_inst };
            } else .ref;
            const result = try expr(gz, scope, .{ .rl = operand_rl }, tree.nodeData(node).node);
            return rvalue(gz, ri, result, node);
        },
        .optional_type => {
            const operand = try typeExpr(gz, scope, tree.nodeData(node).node);
            const result = try gz.addUnNode(.optional_type, operand, node);
            return rvalue(gz, ri, result, node);
        },
        .unwrap_optional => switch (ri.rl) {
            .ref, .ref_coerced_ty => {
                const lhs = try expr(gz, scope, .{ .rl = .ref }, tree.nodeData(node).node_and_token[0]);

                const cursor = maybeAdvanceSourceCursorToMainToken(gz, node);
                try emitDbgStmt(gz, cursor);

                return gz.addUnNode(.optional_payload_safe_ptr, lhs, node);
            },
            else => {
                const lhs = try expr(gz, scope, .{ .rl = .none }, tree.nodeData(node).node_and_token[0]);

                const cursor = maybeAdvanceSourceCursorToMainToken(gz, node);
                try emitDbgStmt(gz, cursor);

                return rvalue(gz, ri, try gz.addUnNode(.optional_payload_safe, lhs, node), node);
            },
        },
        .block_two,
        .block_two_semicolon,
        .block,
        .block_semicolon,
        => {
            var buf: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buf, node).?;
            return blockExpr(gz, scope, ri, node, statements, .normal);
        },
        .enum_literal => if (try ri.rl.resultType(gz, node)) |res_ty| {
            const str_index = try astgen.identAsString(tree.nodeMainToken(node));
            const res = try gz.addPlNode(.decl_literal, node, Zir.Inst.Field{
                .lhs = res_ty,
                .field_name_start = str_index,
            });
            switch (ri.rl) {
                .discard, .none, .ref => unreachable, // no result type
                .ty, .coerced_ty => return res, // `decl_literal` does the coercion for us
                .ref_coerced_ty, .ptr, .inferred_ptr, .destructure => return rvalue(gz, ri, res, node),
            }
        } else return simpleStrTok(gz, ri, tree.nodeMainToken(node), node, .enum_literal),
        .error_value => return simpleStrTok(gz, ri, tree.nodeMainToken(node) + 2, node, .error_value),
        // TODO restore this when implementing https://github.com/ziglang/zig/issues/6025
        // .anyframe_literal => return rvalue(gz, ri, .anyframe_type, node),
        .anyframe_literal => {
            const result = try gz.addUnNode(.anyframe_type, .void_type, node);
            return rvalue(gz, ri, result, node);
        },
        .anyframe_type => {
            const return_type = try typeExpr(gz, scope, tree.nodeData(node).token_and_node[1]);
            const result = try gz.addUnNode(.anyframe_type, return_type, node);
            return rvalue(gz, ri, result, node);
        },
        .@"catch" => {
            const catch_token = tree.nodeMainToken(node);
            const payload_token: ?Ast.TokenIndex = if (tree.tokenTag(catch_token + 1) == .pipe)
                catch_token + 2
            else
                null;
            no_switch_on_err: {
                const capture_token = payload_token orelse break :no_switch_on_err;
                const full_switch = tree.fullSwitch(tree.nodeData(node).node_and_node[1]) orelse break :no_switch_on_err;
                if (full_switch.label_token != null) break :no_switch_on_err;
                if (tree.nodeTag(full_switch.ast.condition) != .identifier) break :no_switch_on_err;
                if (!mem.eql(u8, tree.tokenSlice(capture_token), tree.tokenSlice(tree.nodeMainToken(full_switch.ast.condition)))) break :no_switch_on_err;
                return switchExprErrUnion(gz, scope, ri.br(), node, .@"catch");
            }
            switch (ri.rl) {
                .ref, .ref_coerced_ty => return orelseCatchExpr(
                    gz,
                    scope,
                    ri,
                    node,
                    .is_non_err_ptr,
                    .err_union_payload_unsafe_ptr,
                    .err_union_code_ptr,
                    payload_token,
                ),
                else => return orelseCatchExpr(
                    gz,
                    scope,
                    ri,
                    node,
                    .is_non_err,
                    .err_union_payload_unsafe,
                    .err_union_code,
                    payload_token,
                ),
            }
        },
        .@"orelse" => switch (ri.rl) {
            .ref, .ref_coerced_ty => return orelseCatchExpr(
                gz,
                scope,
                ri,
                node,
                .is_non_null_ptr,
                .optional_payload_unsafe_ptr,
                undefined,
                null,
            ),
            else => return orelseCatchExpr(
                gz,
                scope,
                ri,
                node,
                .is_non_null,
                .optional_payload_unsafe,
                undefined,
                null,
            ),
        },

        .ptr_type_aligned,
        .ptr_type_sentinel,
        .ptr_type,
        .ptr_type_bit_range,
        => return ptrType(gz, scope, ri, node, tree.fullPtrType(node).?),

        .container_decl,
        .container_decl_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        => {
            var buf: [2]Ast.Node.Index = undefined;
            return containerDecl(gz, scope, ri, node, tree.fullContainerDecl(&buf, node).?, .anon);
        },

        .@"break" => return breakExpr(gz, scope, node),
        .@"continue" => return continueExpr(gz, scope, node),
        .grouped_expression => return expr(gz, scope, ri, tree.nodeData(node).node_and_token[0]),
        .array_type => return arrayType(gz, scope, ri, node),
        .array_type_sentinel => return arrayTypeSentinel(gz, scope, ri, node),
        .char_literal => return charLiteral(gz, ri, node),
        .error_set_decl => return errorSetDecl(gz, ri, node),
        .array_access => return arrayAccess(gz, scope, ri, node),
        .@"comptime" => return comptimeExprAst(gz, scope, ri, node),
        .@"switch", .switch_comma => return switchExpr(gz, scope, ri.br(), node, tree.fullSwitch(node).?),

        .@"nosuspend" => return nosuspendExpr(gz, scope, ri, node),
        .@"suspend" => return suspendExpr(gz, scope, node),
        .@"resume" => return resumeExpr(gz, scope, ri, node),

        .@"try" => return tryExpr(gz, scope, ri, node, tree.nodeData(node).node),

        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        => {
            var buf: [2]Ast.Node.Index = undefined;
            return arrayInitExpr(gz, scope, ri, node, tree.fullArrayInit(&buf, node).?);
        },

        .struct_init_one,
        .struct_init_one_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init,
        .struct_init_comma,
        => {
            var buf: [2]Ast.Node.Index = undefined;
            return structInitExpr(gz, scope, ri, node, tree.fullStructInit(&buf, node).?);
        },

        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto,
        => {
            var buf: [1]Ast.Node.Index = undefined;
            return fnProtoExpr(gz, scope, ri, node, tree.fullFnProto(&buf, node).?);
        },
    }
}

/// When a name strategy other than `.anon` is available, for instance when analyzing the init expr
/// of a variable declaration, try this function before `expr`/`comptimeExpr`/etc, so that the name
/// strategy can be applied if necessary. If `null` is returned, then `node` does not consume a name
/// strategy, and a normal evaluation function like `expr` should be used instead. Otherwise, `node`
/// does consume a name strategy; the expression has been evaluated like `expr`, but using the given
/// name strategy.
fn nameStratExpr(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    name_strat: Zir.Inst.NameStrategy,
) InnerError!?Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    switch (tree.nodeTag(node)) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => {
            var buf: [2]Ast.Node.Index = undefined;
            return try containerDecl(gz, scope, ri, node, tree.fullContainerDecl(&buf, node).?, name_strat);
        },
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            const builtin_token = tree.nodeMainToken(node);
            const builtin_name = tree.tokenSlice(builtin_token);
            if (!std.mem.eql(u8, builtin_name, "@Type")) return null;
            var buf: [2]Ast.Node.Index = undefined;
            const params = tree.builtinCallParams(&buf, node).?;
            if (params.len != 1) return null; // let `builtinCall` error
            return try builtinReify(gz, scope, ri, node, params[0], name_strat);
        },
        else => return null,
    }
}

fn nosuspendExpr(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const body_node = tree.nodeData(node).node;
    if (gz.nosuspend_node.unwrap()) |nosuspend_node| {
        try astgen.appendErrorNodeNotes(node, "redundant nosuspend block", .{}, &[_]u32{
            try astgen.errNoteNode(nosuspend_node, "other nosuspend block here", .{}),
        });
    }
    gz.nosuspend_node = node.toOptional();
    defer gz.nosuspend_node = .none;
    return expr(gz, scope, ri, body_node);
}

fn suspendExpr(
    gz: *GenZir,
    scope: *Scope,
    node: Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const gpa = astgen.gpa;
    const tree = astgen.tree;
    const body_node = tree.nodeData(node).node;

    if (gz.nosuspend_node.unwrap()) |nosuspend_node| {
        return astgen.failNodeNotes(node, "suspend inside nosuspend block", .{}, &[_]u32{
            try astgen.errNoteNode(nosuspend_node, "nosuspend block here", .{}),
        });
    }
    if (gz.suspend_node.unwrap()) |suspend_node| {
        return astgen.failNodeNotes(node, "cannot suspend inside suspend block", .{}, &[_]u32{
            try astgen.errNoteNode(suspend_node, "other suspend block here", .{}),
        });
    }

    const suspend_inst = try gz.makeBlockInst(.suspend_block, node);
    try gz.instructions.append(gpa, suspend_inst);

    var suspend_scope = gz.makeSubBlock(scope);
    suspend_scope.suspend_node = node.toOptional();
    defer suspend_scope.unstack();

    const body_result = try fullBodyExpr(&suspend_scope, &suspend_scope.base, .{ .rl = .none }, body_node, .normal);
    if (!gz.refIsNoReturn(body_result)) {
        _ = try suspend_scope.addBreak(.break_inline, suspend_inst, .void_value);
    }
    try suspend_scope.setBlockBody(suspend_inst);

    return suspend_inst.toRef();
}

fn resumeExpr(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const rhs_node = tree.nodeData(node).node;
    const operand = try expr(gz, scope, .{ .rl = .ref }, rhs_node);
    const result = try gz.addUnNode(.@"resume", operand, node);
    return rvalue(gz, ri, result, node);
}

fn fnProtoExpr(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    fn_proto: Ast.full.FnProto,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    if (fn_proto.name_token) |some| {
        return astgen.failTok(some, "function type cannot have a name", .{});
    }

    if (fn_proto.ast.align_expr.unwrap()) |align_expr| {
        return astgen.failNode(align_expr, "function type cannot have an alignment", .{});
    }

    if (fn_proto.ast.addrspace_expr.unwrap()) |addrspace_expr| {
        return astgen.failNode(addrspace_expr, "function type cannot have an addrspace", .{});
    }

    if (fn_proto.ast.section_expr.unwrap()) |section_expr| {
        return astgen.failNode(section_expr, "function type cannot have a linksection", .{});
    }

    const return_type = fn_proto.ast.return_type.unwrap().?;
    const maybe_bang = tree.firstToken(return_type) - 1;
    const is_inferred_error = tree.tokenTag(maybe_bang) == .bang;
    if (is_inferred_error) {
        return astgen.failTok(maybe_bang, "function type cannot have an inferred error set", .{});
    }

    const is_extern = blk: {
        const maybe_extern_token = fn_proto.extern_export_inline_token orelse break :blk false;
        break :blk tree.tokenTag(maybe_extern_token) == .keyword_extern;
    };
    assert(!is_extern);

    return fnProtoExprInner(gz, scope, ri, node, fn_proto, false);
}

fn fnProtoExprInner(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    fn_proto: Ast.full.FnProto,
    implicit_ccc: bool,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    var block_scope = gz.makeSubBlock(scope);
    defer block_scope.unstack();

    const block_inst = try gz.makeBlockInst(.block_inline, node);

    var noalias_bits: u32 = 0;
    const is_var_args = is_var_args: {
        var param_type_i: usize = 0;
        var it = fn_proto.iterate(tree);
        while (it.next()) |param| : (param_type_i += 1) {
            const is_comptime = if (param.comptime_noalias) |token| switch (tree.tokenTag(token)) {
                .keyword_noalias => is_comptime: {
                    noalias_bits |= @as(u32, 1) << (std.math.cast(u5, param_type_i) orelse
                        return astgen.failTok(token, "this compiler implementation only supports 'noalias' on the first 32 parameters", .{}));
                    break :is_comptime false;
                },
                .keyword_comptime => true,
                else => false,
            } else false;

            const is_anytype = if (param.anytype_ellipsis3) |token| blk: {
                switch (tree.tokenTag(token)) {
                    .keyword_anytype => break :blk true,
                    .ellipsis3 => break :is_var_args true,
                    else => unreachable,
                }
            } else false;

            const param_name = if (param.name_token) |name_token| blk: {
                if (mem.eql(u8, "_", tree.tokenSlice(name_token)))
                    break :blk .empty;

                break :blk try astgen.identAsString(name_token);
            } else .empty;

            if (is_anytype) {
                const name_token = param.name_token orelse param.anytype_ellipsis3.?;

                const tag: Zir.Inst.Tag = if (is_comptime)
                    .param_anytype_comptime
                else
                    .param_anytype;
                _ = try block_scope.addStrTok(tag, param_name, name_token);
            } else {
                const param_type_node = param.type_expr.?;
                var param_gz = block_scope.makeSubBlock(scope);
                defer param_gz.unstack();
                param_gz.is_comptime = true;
                const param_type = try fullBodyExpr(&param_gz, scope, coerced_type_ri, param_type_node, .normal);
                const param_inst_expected: Zir.Inst.Index = @enumFromInt(astgen.instructions.len + 1);
                _ = try param_gz.addBreakWithSrcNode(.break_inline, param_inst_expected, param_type, param_type_node);
                const name_token = param.name_token orelse tree.nodeMainToken(param_type_node);
                const tag: Zir.Inst.Tag = if (is_comptime) .param_comptime else .param;
                // We pass `prev_param_insts` as `&.{}` here because a function prototype can't refer to previous
                // arguments (we haven't set up scopes here).
                const param_inst = try block_scope.addParam(&param_gz, &.{}, false, tag, name_token, param_name);
                assert(param_inst_expected == param_inst);
            }
        }
        break :is_var_args false;
    };

    const cc: Zir.Inst.Ref = if (fn_proto.ast.callconv_expr.unwrap()) |callconv_expr|
        try comptimeExpr(
            &block_scope,
            scope,
            .{ .rl = .{ .coerced_ty = try block_scope.addBuiltinValue(callconv_expr, .calling_convention) } },
            callconv_expr,
            .@"callconv",
        )
    else if (implicit_ccc)
        try block_scope.addBuiltinValue(node, .calling_convention_c)
    else
        .none;

    const ret_ty_node = fn_proto.ast.return_type.unwrap().?;
    const ret_ty = try comptimeExpr(&block_scope, scope, coerced_type_ri, ret_ty_node, .function_ret_ty);

    const result = try block_scope.addFunc(.{
        .src_node = fn_proto.ast.proto_node,

        .cc_ref = cc,
        .cc_gz = null,
        .ret_ref = ret_ty,
        .ret_gz = null,

        .ret_param_refs = &.{},
        .param_insts = &.{},
        .ret_ty_is_generic = false,

        .param_block = block_inst,
        .body_gz = null,
        .is_var_args = is_var_args,
        .is_inferred_error = false,
        .is_noinline = false,
        .noalias_bits = noalias_bits,

        .proto_hash = undefined, // ignored for `body_gz == null`
    });

    _ = try block_scope.addBreak(.break_inline, block_inst, result);
    try block_scope.setBlockBody(block_inst);
    try gz.instructions.append(astgen.gpa, block_inst);

    return rvalue(gz, ri, block_inst.toRef(), fn_proto.ast.proto_node);
}

fn arrayInitExpr(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    array_init: Ast.full.ArrayInit,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    assert(array_init.ast.elements.len != 0); // Otherwise it would be struct init.

    const array_ty: Zir.Inst.Ref, const elem_ty: Zir.Inst.Ref = inst: {
        const type_expr = array_init.ast.type_expr.unwrap() orelse break :inst .{ .none, .none };

        infer: {
            const array_type: Ast.full.ArrayType = tree.fullArrayType(type_expr) orelse break :infer;
            // This intentionally does not support `@"_"` syntax.
            if (tree.nodeTag(array_type.ast.elem_count) == .identifier and
                mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(array_type.ast.elem_count)), "_"))
            {
                const len_inst = try gz.addInt(array_init.ast.elements.len);
                const elem_type = try typeExpr(gz, scope, array_type.ast.elem_type);
                if (array_type.ast.sentinel == .none) {
                    const array_type_inst = try gz.addPlNode(.array_type, type_expr, Zir.Inst.Bin{
                        .lhs = len_inst,
                        .rhs = elem_type,
                    });
                    break :inst .{ array_type_inst, elem_type };
                } else {
                    const sentinel_node = array_type.ast.sentinel.unwrap().?;
                    const sentinel = try comptimeExpr(gz, scope, .{ .rl = .{ .ty = elem_type } }, sentinel_node, .array_sentinel);
                    const array_type_inst = try gz.addPlNode(
                        .array_type_sentinel,
                        type_expr,
                        Zir.Inst.ArrayTypeSentinel{
                            .len = len_inst,
                            .elem_type = elem_type,
                            .sentinel = sentinel,
                        },
                    );
                    break :inst .{ array_type_inst, elem_type };
                }
            }
        }
        const array_type_inst = try typeExpr(gz, scope, type_expr);
        _ = try gz.addPlNode(.validate_array_init_ty, node, Zir.Inst.ArrayInit{
            .ty = array_type_inst,
            .init_count = @intCast(array_init.ast.elements.len),
        });
        break :inst .{ array_type_inst, .none };
    };

    if (array_ty != .none) {
        // Typed inits do not use RLS for language simplicity.
        switch (ri.rl) {
            .discard => {
                if (elem_ty != .none) {
                    const elem_ri: ResultInfo = .{ .rl = .{ .ty = elem_ty } };
                    for (array_init.ast.elements) |elem_init| {
                        _ = try expr(gz, scope, elem_ri, elem_init);
                    }
                } else {
                    for (array_init.ast.elements, 0..) |elem_init, i| {
                        const this_elem_ty = try gz.add(.{
                            .tag = .array_init_elem_type,
                            .data = .{ .bin = .{
                                .lhs = array_ty,
                                .rhs = @enumFromInt(i),
                            } },
                        });
                        _ = try expr(gz, scope, .{ .rl = .{ .ty = this_elem_ty } }, elem_init);
                    }
                }
                return .void_value;
            },
            .ref => return arrayInitExprTyped(gz, scope, node, array_init.ast.elements, array_ty, elem_ty, true),
            else => {
                const array_inst = try arrayInitExprTyped(gz, scope, node, array_init.ast.elements, array_ty, elem_ty, false);
                return rvalue(gz, ri, array_inst, node);
            },
        }
    }

    switch (ri.rl) {
        .none => return arrayInitExprAnon(gz, scope, node, array_init.ast.elements),
        .discard => {
            for (array_init.ast.elements) |elem_init| {
                _ = try expr(gz, scope, .{ .rl = .discard }, elem_init);
            }
            return Zir.Inst.Ref.void_value;
        },
        .ref => {
            const result = try arrayInitExprAnon(gz, scope, node, array_init.ast.elements);
            return gz.addUnTok(.ref, result, tree.firstToken(node));
        },
        .ref_coerced_ty => |ptr_ty_inst| {
            const dest_arr_ty_inst = try gz.addPlNode(.validate_array_init_ref_ty, node, Zir.Inst.ArrayInitRefTy{
                .ptr_ty = ptr_ty_inst,
                .elem_count = @intCast(array_init.ast.elements.len),
            });
            return arrayInitExprTyped(gz, scope, node, array_init.ast.elements, dest_arr_ty_inst, .none, true);
        },
        .ty, .coerced_ty => |result_ty_inst| {
            _ = try gz.addPlNode(.validate_array_init_result_ty, node, Zir.Inst.ArrayInit{
                .ty = result_ty_inst,
                .init_count = @intCast(array_init.ast.elements.len),
            });
            return arrayInitExprTyped(gz, scope, node, array_init.ast.elements, result_ty_inst, .none, false);
        },
        .ptr => |ptr| {
            try arrayInitExprPtr(gz, scope, node, array_init.ast.elements, ptr.inst);
            return .void_value;
        },
        .inferred_ptr => {
            // We can't get elem pointers of an untyped inferred alloc, so must perform a
            // standard anonymous initialization followed by an rvalue store.
            // See corresponding logic in structInitExpr.
            const result = try arrayInitExprAnon(gz, scope, node, array_init.ast.elements);
            return rvalue(gz, ri, result, node);
        },
        .destructure => |destructure| {
            // Untyped init - destructure directly into result pointers
            if (array_init.ast.elements.len != destructure.components.len) {
                return astgen.failNodeNotes(node, "expected {} elements for destructure, found {}", .{
                    destructure.components.len,
                    array_init.ast.elements.len,
                }, &.{
                    try astgen.errNoteNode(destructure.src_node, "result destructured here", .{}),
                });
            }
            for (array_init.ast.elements, destructure.components) |elem_init, ds_comp| {
                const elem_ri: ResultInfo = .{ .rl = switch (ds_comp) {
                    .typed_ptr => |ptr_rl| .{ .ptr = ptr_rl },
                    .inferred_ptr => |ptr_inst| .{ .inferred_ptr = ptr_inst },
                    .discard => .discard,
                } };
                _ = try expr(gz, scope, elem_ri, elem_init);
            }
            return .void_value;
        },
    }
}

/// An array initialization expression using an `array_init_anon` instruction.
fn arrayInitExprAnon(
    gz: *GenZir,
    scope: *Scope,
    node: Ast.Node.Index,
    elements: []const Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;

    const payload_index = try addExtra(astgen, Zir.Inst.MultiOp{
        .operands_len = @intCast(elements.len),
    });
    var extra_index = try reserveExtra(astgen, elements.len);

    for (elements) |elem_init| {
        const elem_ref = try expr(gz, scope, .{ .rl = .none }, elem_init);
        astgen.extra.items[extra_index] = @intFromEnum(elem_ref);
        extra_index += 1;
    }
    return try gz.addPlNodePayloadIndex(.array_init_anon, node, payload_index);
}

/// An array initialization expression using an `array_init` or `array_init_ref` instruction.
fn arrayInitExprTyped(
    gz: *GenZir,
    scope: *Scope,
    node: Ast.Node.Index,
    elements: []const Ast.Node.Index,
    ty_inst: Zir.Inst.Ref,
    maybe_elem_ty_inst: Zir.Inst.Ref,
    is_ref: bool,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;

    const len = elements.len + 1; // +1 for type
    const payload_index = try addExtra(astgen, Zir.Inst.MultiOp{
        .operands_len = @intCast(len),
    });
    var extra_index = try reserveExtra(astgen, len);
    astgen.extra.items[extra_index] = @intFromEnum(ty_inst);
    extra_index += 1;

    if (maybe_elem_ty_inst != .none) {
        const elem_ri: ResultInfo = .{ .rl = .{ .coerced_ty = maybe_elem_ty_inst } };
        for (elements) |elem_init| {
            const elem_inst = try expr(gz, scope, elem_ri, elem_init);
            astgen.extra.items[extra_index] = @intFromEnum(elem_inst);
            extra_index += 1;
        }
    } else {
        for (elements, 0..) |elem_init, i| {
            const ri: ResultInfo = .{ .rl = .{ .coerced_ty = try gz.add(.{
                .tag = .array_init_elem_type,
                .data = .{ .bin = .{
                    .lhs = ty_inst,
                    .rhs = @enumFromInt(i),
                } },
            }) } };

            const elem_inst = try expr(gz, scope, ri, elem_init);
            astgen.extra.items[extra_index] = @intFromEnum(elem_inst);
            extra_index += 1;
        }
    }

    const tag: Zir.Inst.Tag = if (is_ref) .array_init_ref else .array_init;
    return try gz.addPlNodePayloadIndex(tag, node, payload_index);
}

/// An array initialization expression using element pointers.
fn arrayInitExprPtr(
    gz: *GenZir,
    scope: *Scope,
    node: Ast.Node.Index,
    elements: []const Ast.Node.Index,
    ptr_inst: Zir.Inst.Ref,
) InnerError!void {
    const astgen = gz.astgen;

    const array_ptr_inst = try gz.addUnNode(.opt_eu_base_ptr_init, ptr_inst, node);

    const payload_index = try addExtra(astgen, Zir.Inst.Block{
        .body_len = @intCast(elements.len),
    });
    var extra_index = try reserveExtra(astgen, elements.len);

    for (elements, 0..) |elem_init, i| {
        const elem_ptr_inst = try gz.addPlNode(.array_init_elem_ptr, elem_init, Zir.Inst.ElemPtrImm{
            .ptr = array_ptr_inst,
            .index = @intCast(i),
        });
        astgen.extra.items[extra_index] = @intFromEnum(elem_ptr_inst.toIndex().?);
        extra_index += 1;
        _ = try expr(gz, scope, .{ .rl = .{ .ptr = .{ .inst = elem_ptr_inst } } }, elem_init);
    }

    _ = try gz.addPlNodePayloadIndex(.validate_ptr_array_init, node, payload_index);
}

fn structInitExpr(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    struct_init: Ast.full.StructInit,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    if (struct_init.ast.type_expr == .none) {
        if (struct_init.ast.fields.len == 0) {
            // Anonymous init with no fields.
            switch (ri.rl) {
                .discard => return .void_value,
                .ref_coerced_ty => |ptr_ty_inst| return gz.addUnNode(.struct_init_empty_ref_result, ptr_ty_inst, node),
                .ty, .coerced_ty => |ty_inst| return gz.addUnNode(.struct_init_empty_result, ty_inst, node),
                .ptr => {
                    // TODO: should we modify this to use RLS for the field stores here?
                    const ty_inst = (try ri.rl.resultType(gz, node)).?;
                    const val = try gz.addUnNode(.struct_init_empty_result, ty_inst, node);
                    return rvalue(gz, ri, val, node);
                },
                .none, .ref, .inferred_ptr => {
                    return rvalue(gz, ri, .empty_tuple, node);
                },
                .destructure => |destructure| {
                    return astgen.failNodeNotes(node, "empty initializer cannot be destructured", .{}, &.{
                        try astgen.errNoteNode(destructure.src_node, "result destructured here", .{}),
                    });
                },
            }
        }
    } else array: {
        const type_expr = struct_init.ast.type_expr.unwrap().?;
        const array_type: Ast.full.ArrayType = tree.fullArrayType(type_expr) orelse {
            if (struct_init.ast.fields.len == 0) {
                const ty_inst = try typeExpr(gz, scope, type_expr);
                const result = try gz.addUnNode(.struct_init_empty, ty_inst, node);
                return rvalue(gz, ri, result, node);
            }
            break :array;
        };
        const is_inferred_array_len = tree.nodeTag(array_type.ast.elem_count) == .identifier and
            // This intentionally does not support `@"_"` syntax.
            mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(array_type.ast.elem_count)), "_");
        if (struct_init.ast.fields.len == 0) {
            if (is_inferred_array_len) {
                const elem_type = try typeExpr(gz, scope, array_type.ast.elem_type);
                const array_type_inst = if (array_type.ast.sentinel == .none) blk: {
                    break :blk try gz.addPlNode(.array_type, type_expr, Zir.Inst.Bin{
                        .lhs = .zero_usize,
                        .rhs = elem_type,
                    });
                } else blk: {
                    const sentinel_node = array_type.ast.sentinel.unwrap().?;
                    const sentinel = try comptimeExpr(gz, scope, .{ .rl = .{ .ty = elem_type } }, sentinel_node, .array_sentinel);
                    break :blk try gz.addPlNode(
                        .array_type_sentinel,
                        type_expr,
                        Zir.Inst.ArrayTypeSentinel{
                            .len = .zero_usize,
                            .elem_type = elem_type,
                            .sentinel = sentinel,
                        },
                    );
                };
                const result = try gz.addUnNode(.struct_init_empty, array_type_inst, node);
                return rvalue(gz, ri, result, node);
            }
            const ty_inst = try typeExpr(gz, scope, type_expr);
            const result = try gz.addUnNode(.struct_init_empty, ty_inst, node);
            return rvalue(gz, ri, result, node);
        } else {
            return astgen.failNode(
                type_expr,
                "initializing array with struct syntax",
                .{},
            );
        }
    }

    {
        var sfba = std.heap.stackFallback(256, astgen.arena);
        const sfba_allocator = sfba.get();

        var duplicate_names = std.AutoArrayHashMap(Zir.NullTerminatedString, ArrayListUnmanaged(Ast.TokenIndex)).init(sfba_allocator);
        try duplicate_names.ensureTotalCapacity(@intCast(struct_init.ast.fields.len));

        // When there aren't errors, use this to avoid a second iteration.
        var any_duplicate = false;

        for (struct_init.ast.fields) |field| {
            const name_token = tree.firstToken(field) - 2;
            const name_index = try astgen.identAsString(name_token);

            const gop = try duplicate_names.getOrPut(name_index);

            if (gop.found_existing) {
                try gop.value_ptr.append(sfba_allocator, name_token);
                any_duplicate = true;
            } else {
                gop.value_ptr.* = .{};
                try gop.value_ptr.append(sfba_allocator, name_token);
            }
        }

        if (any_duplicate) {
            var it = duplicate_names.iterator();

            while (it.next()) |entry| {
                const record = entry.value_ptr.*;
                if (record.items.len > 1) {
                    var error_notes = std.ArrayList(u32).init(astgen.arena);

                    for (record.items[1..]) |duplicate| {
                        try error_notes.append(try astgen.errNoteTok(duplicate, "duplicate name here", .{}));
                    }

                    try error_notes.append(try astgen.errNoteNode(node, "struct declared here", .{}));

                    try astgen.appendErrorTokNotes(
                        record.items[0],
                        "duplicate struct field name",
                        .{},
                        error_notes.items,
                    );
                }
            }

            return error.AnalysisFail;
        }
    }

    if (struct_init.ast.type_expr.unwrap()) |type_expr| {
        // Typed inits do not use RLS for language simplicity.
        const ty_inst = try typeExpr(gz, scope, type_expr);
        _ = try gz.addUnNode(.validate_struct_init_ty, ty_inst, node);
        switch (ri.rl) {
            .ref => return structInitExprTyped(gz, scope, node, struct_init, ty_inst, true),
            else => {
                const struct_inst = try structInitExprTyped(gz, scope, node, struct_init, ty_inst, false);
                return rvalue(gz, ri, struct_inst, node);
            },
        }
    }

    switch (ri.rl) {
        .none => return structInitExprAnon(gz, scope, node, struct_init),
        .discard => {
            // Even if discarding we must perform side-effects.
            for (struct_init.ast.fields) |field_init| {
                _ = try expr(gz, scope, .{ .rl = .discard }, field_init);
            }
            return .void_value;
        },
        .ref => {
            const result = try structInitExprAnon(gz, scope, node, struct_init);
            return gz.addUnTok(.ref, result, tree.firstToken(node));
        },
        .ref_coerced_ty => |ptr_ty_inst| {
            const result_ty_inst = try gz.addUnNode(.elem_type, ptr_ty_inst, node);
            _ = try gz.addUnNode(.validate_struct_init_result_ty, result_ty_inst, node);
            return structInitExprTyped(gz, scope, node, struct_init, result_ty_inst, true);
        },
        .ty, .coerced_ty => |result_ty_inst| {
            _ = try gz.addUnNode(.validate_struct_init_result_ty, result_ty_inst, node);
            return structInitExprTyped(gz, scope, node, struct_init, result_ty_inst, false);
        },
        .ptr => |ptr| {
            try structInitExprPtr(gz, scope, node, struct_init, ptr.inst);
            return .void_value;
        },
        .inferred_ptr => {
            // We can't get field pointers of an untyped inferred alloc, so must perform a
            // standard anonymous initialization followed by an rvalue store.
            // See corresponding logic in arrayInitExpr.
            const struct_inst = try structInitExprAnon(gz, scope, node, struct_init);
            return rvalue(gz, ri, struct_inst, node);
        },
        .destructure => |destructure| {
            // This is an untyped init, so is an actual struct, which does
            // not support destructuring.
            return astgen.failNodeNotes(node, "struct value cannot be destructured", .{}, &.{
                try astgen.errNoteNode(destructure.src_node, "result destructured here", .{}),
            });
        },
    }
}

/// A struct initialization expression using a `struct_init_anon` instruction.
fn structInitExprAnon(
    gz: *GenZir,
    scope: *Scope,
    node: Ast.Node.Index,
    struct_init: Ast.full.StructInit,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const payload_index = try addExtra(astgen, Zir.Inst.StructInitAnon{
        .abs_node = node,
        .abs_line = astgen.source_line,
        .fields_len = @intCast(struct_init.ast.fields.len),
    });
    const field_size = @typeInfo(Zir.Inst.StructInitAnon.Item).@"struct".fields.len;
    var extra_index: usize = try reserveExtra(astgen, struct_init.ast.fields.len * field_size);

    for (struct_init.ast.fields) |field_init| {
        const name_token = tree.firstToken(field_init) - 2;
        const str_index = try astgen.identAsString(name_token);
        setExtra(astgen, extra_index, Zir.Inst.StructInitAnon.Item{
            .field_name = str_index,
            .init = try expr(gz, scope, .{ .rl = .none }, field_init),
        });
        extra_index += field_size;
    }

    return gz.addPlNodePayloadIndex(.struct_init_anon, node, payload_index);
}

/// A struct initialization expression using a `struct_init` or `struct_init_ref` instruction.
fn structInitExprTyped(
    gz: *GenZir,
    scope: *Scope,
    node: Ast.Node.Index,
    struct_init: Ast.full.StructInit,
    ty_inst: Zir.Inst.Ref,
    is_ref: bool,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const payload_index = try addExtra(astgen, Zir.Inst.StructInit{
        .abs_node = node,
        .abs_line = astgen.source_line,
        .fields_len = @intCast(struct_init.ast.fields.len),
    });
    const field_size = @typeInfo(Zir.Inst.StructInit.Item).@"struct".fields.len;
    var extra_index: usize = try reserveExtra(astgen, struct_init.ast.fields.len * field_size);

    for (struct_init.ast.fields) |field_init| {
        const name_token = tree.firstToken(field_init) - 2;
        const str_index = try astgen.identAsString(name_token);
        const field_ty_inst = try gz.addPlNode(.struct_init_field_type, field_init, Zir.Inst.FieldType{
            .container_type = ty_inst,
            .name_start = str_index,
        });
        setExtra(astgen, extra_index, Zir.Inst.StructInit.Item{
            .field_type = field_ty_inst.toIndex().?,
            .init = try expr(gz, scope, .{ .rl = .{ .coerced_ty = field_ty_inst } }, field_init),
        });
        extra_index += field_size;
    }

    const tag: Zir.Inst.Tag = if (is_ref) .struct_init_ref else .struct_init;
    return gz.addPlNodePayloadIndex(tag, node, payload_index);
}

/// A struct initialization expression using field pointers.
fn structInitExprPtr(
    gz: *GenZir,
    scope: *Scope,
    node: Ast.Node.Index,
    struct_init: Ast.full.StructInit,
    ptr_inst: Zir.Inst.Ref,
) InnerError!void {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const struct_ptr_inst = try gz.addUnNode(.opt_eu_base_ptr_init, ptr_inst, node);

    const payload_index = try addExtra(astgen, Zir.Inst.Block{
        .body_len = @intCast(struct_init.ast.fields.len),
    });
    var extra_index = try reserveExtra(astgen, struct_init.ast.fields.len);

    for (struct_init.ast.fields) |field_init| {
        const name_token = tree.firstToken(field_init) - 2;
        const str_index = try astgen.identAsString(name_token);
        const field_ptr = try gz.addPlNode(.struct_init_field_ptr, field_init, Zir.Inst.Field{
            .lhs = struct_ptr_inst,
            .field_name_start = str_index,
        });
        astgen.extra.items[extra_index] = @intFromEnum(field_ptr.toIndex().?);
        extra_index += 1;
        _ = try expr(gz, scope, .{ .rl = .{ .ptr = .{ .inst = field_ptr } } }, field_init);
    }

    _ = try gz.addPlNodePayloadIndex(.validate_ptr_struct_init, node, payload_index);
}

/// This explicitly calls expr in a comptime scope by wrapping it in a `block_comptime` if
/// necessary. It should be used whenever we need to force compile-time evaluation of something,
/// such as a type.
/// The function corresponding to `comptime` expression syntax is `comptimeExprAst`.
fn comptimeExpr(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    reason: std.zig.SimpleComptimeReason,
) InnerError!Zir.Inst.Ref {
    return comptimeExpr2(gz, scope, ri, node, node, reason);
}

/// Like `comptimeExpr`, but draws a distinction between `node`, the expression to evaluate at comptime,
/// and `src_node`, the node to attach to the `block_comptime`.
fn comptimeExpr2(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    src_node: Ast.Node.Index,
    reason: std.zig.SimpleComptimeReason,
) InnerError!Zir.Inst.Ref {
    if (gz.is_comptime) {
        // No need to change anything!
        return expr(gz, scope, ri, node);
    }

    // There's an optimization here: if the body will be evaluated at comptime regardless, there's
    // no need to wrap it in a block. This is hard to determine in general, but we can identify a
    // common subset of trivially comptime expressions to take down the size of the ZIR a bit.
    const tree = gz.astgen.tree;
    switch (tree.nodeTag(node)) {
        .identifier => {
            // Many identifiers can be handled without a `block_comptime`, so `AstGen.identifier` has
            // special handling for this case.
            return identifier(gz, scope, ri, node, .{ .src_node = src_node, .reason = reason });
        },

        // These are leaf nodes which are always comptime-known.
        .number_literal,
        .char_literal,
        .string_literal,
        .multiline_string_literal,
        .enum_literal,
        .error_value,
        .anyframe_literal,
        .error_set_decl,
        // These nodes are not leaves, but will force comptime evaluation of all sub-expressions, and
        // hence behave the same regardless of whether they're in a comptime scope.
        .error_union,
        .merge_error_sets,
        .optional_type,
        .anyframe_type,
        .ptr_type_aligned,
        .ptr_type_sentinel,
        .ptr_type,
        .ptr_type_bit_range,
        .array_type,
        .array_type_sentinel,
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto,
        .container_decl,
        .container_decl_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        => {
            // No need to worry about result location here, we're not creating a comptime block!
            return expr(gz, scope, ri, node);
        },

        // Lastly, for labelled blocks, avoid emitting a labelled block directly inside this
        // comptime block, because that would be silly! Note that we don't bother doing this for
        // unlabelled blocks, since they don't generate blocks at comptime anyway (see `blockExpr`).
        .block_two, .block_two_semicolon, .block, .block_semicolon => {
            const lbrace = tree.nodeMainToken(node);
            // Careful! We can't pass in the real result location here, since it may
            // refer to runtime memory. A runtime-to-comptime boundary has to remove
            // result location information, compute the result, and copy it to the true
            // result location at runtime. We do this below as well.
            const ty_only_ri: ResultInfo = .{
                .ctx = ri.ctx,
                .rl = if (try ri.rl.resultType(gz, node)) |res_ty|
                    .{ .coerced_ty = res_ty }
                else
                    .none,
            };
            if (tree.isTokenPrecededByTags(lbrace, &.{ .identifier, .colon })) {
                var buf: [2]Ast.Node.Index = undefined;
                const stmts = tree.blockStatements(&buf, node).?;

                // Replace result location and copy back later - see above.
                const block_ref = try labeledBlockExpr(gz, scope, ty_only_ri, node, stmts, true, .normal);
                return rvalue(gz, ri, block_ref, node);
            }
        },

        // In other cases, we don't optimize anything - we need a wrapper comptime block.
        else => {},
    }

    var block_scope = gz.makeSubBlock(scope);
    block_scope.is_comptime = true;
    defer block_scope.unstack();

    const block_inst = try gz.makeBlockInst(.block_comptime, src_node);
    // Replace result location and copy back later - see above.
    const ty_only_ri: ResultInfo = .{
        .ctx = ri.ctx,
        .rl = if (try ri.rl.resultType(gz, src_node)) |res_ty|
            .{ .coerced_ty = res_ty }
        else
            .none,
    };
    const block_result = try fullBodyExpr(&block_scope, scope, ty_only_ri, node, .normal);
    if (!gz.refIsNoReturn(block_result)) {
        _ = try block_scope.addBreak(.break_inline, block_inst, block_result);
    }
    try block_scope.setBlockComptimeBody(block_inst, reason);
    try gz.instructions.append(gz.astgen.gpa, block_inst);

    return rvalue(gz, ri, block_inst.toRef(), src_node);
}

/// This one is for an actual `comptime` syntax, and will emit a compile error if
/// the scope is already known to be comptime-evaluated.
/// See `comptimeExpr` for the helper function for calling expr in a comptime scope.
fn comptimeExprAst(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    if (gz.is_comptime) {
        try astgen.appendErrorNode(node, "redundant comptime keyword in already comptime scope", .{});
    }
    const tree = astgen.tree;
    const body_node = tree.nodeData(node).node;
    return comptimeExpr2(gz, scope, ri, body_node, node, .comptime_keyword);
}

/// Restore the error return trace index. Performs the restore only if the result is a non-error or
/// if the result location is a non-error-handling expression.
fn restoreErrRetIndex(
    gz: *GenZir,
    bt: GenZir.BranchTarget,
    ri: ResultInfo,
    node: Ast.Node.Index,
    result: Zir.Inst.Ref,
) !void {
    const op = switch (nodeMayEvalToError(gz.astgen.tree, node)) {
        .always => return, // never restore/pop
        .never => .none, // always restore/pop
        .maybe => switch (ri.ctx) {
            .error_handling_expr, .@"return", .fn_arg, .const_init => switch (ri.rl) {
                .ptr => |ptr_res| try gz.addUnNode(.load, ptr_res.inst, node),
                .inferred_ptr => blk: {
                    // This is a terrible workaround for Sema's inability to load from a .alloc_inferred ptr
                    // before its type has been resolved. There is no valid operand to use here, so error
                    // traces will be popped prematurely.
                    // TODO: Update this to do a proper load from the rl_ptr, once Sema can support it.
                    break :blk .none;
                },
                .destructure => return, // value must be a tuple or array, so never restore/pop
                else => result,
            },
            else => .none, // always restore/pop
        },
    };
    _ = try gz.addRestoreErrRetIndex(bt, .{ .if_non_error = op }, node);
}

fn breakExpr(parent_gz: *GenZir, parent_scope: *Scope, node: Ast.Node.Index) InnerError!Zir.Inst.Ref {
    const astgen = parent_gz.astgen;
    const tree = astgen.tree;
    const opt_break_label, const opt_rhs = tree.nodeData(node).opt_token_and_opt_node;

    // Look for the label in the scope.
    var scope = parent_scope;
    while (true) {
        switch (scope.tag) {
            .gen_zir => {
                const block_gz = scope.cast(GenZir).?;

                if (block_gz.cur_defer_node.unwrap()) |cur_defer_node| {
                    // We are breaking out of a `defer` block.
                    return astgen.failNodeNotes(node, "cannot break out of defer expression", .{}, &.{
                        try astgen.errNoteNode(
                            cur_defer_node,
                            "defer expression here",
                            .{},
                        ),
                    });
                }

                const block_inst = blk: {
                    if (opt_break_label.unwrap()) |break_label| {
                        if (block_gz.label) |*label| {
                            if (try astgen.tokenIdentEql(label.token, break_label)) {
                                label.used = true;
                                break :blk label.block_inst;
                            }
                        }
                    } else if (block_gz.break_block.unwrap()) |i| {
                        break :blk i;
                    }
                    // If not the target, start over with the parent
                    scope = block_gz.parent;
                    continue;
                };
                // If we made it here, this block is the target of the break expr

                const break_tag: Zir.Inst.Tag = if (block_gz.is_inline)
                    .break_inline
                else
                    .@"break";

                const rhs = opt_rhs.unwrap() orelse {
                    _ = try rvalue(parent_gz, block_gz.break_result_info, .void_value, node);

                    try genDefers(parent_gz, scope, parent_scope, .normal_only);

                    // As our last action before the break, "pop" the error trace if needed
                    if (!block_gz.is_comptime)
                        _ = try parent_gz.addRestoreErrRetIndex(.{ .block = block_inst }, .always, node);

                    _ = try parent_gz.addBreak(break_tag, block_inst, .void_value);
                    return Zir.Inst.Ref.unreachable_value;
                };

                const operand = try reachableExpr(parent_gz, parent_scope, block_gz.break_result_info, rhs, node);

                try genDefers(parent_gz, scope, parent_scope, .normal_only);

                // As our last action before the break, "pop" the error trace if needed
                if (!block_gz.is_comptime)
                    try restoreErrRetIndex(parent_gz, .{ .block = block_inst }, block_gz.break_result_info, rhs, operand);

                switch (block_gz.break_result_info.rl) {
                    .ptr => {
                        // In this case we don't have any mechanism to intercept it;
                        // we assume the result location is written, and we break with void.
                        _ = try parent_gz.addBreak(break_tag, block_inst, .void_value);
                    },
                    .discard => {
                        _ = try parent_gz.addBreak(break_tag, block_inst, .void_value);
                    },
                    else => {
                        _ = try parent_gz.addBreakWithSrcNode(break_tag, block_inst, operand, rhs);
                    },
                }
                return Zir.Inst.Ref.unreachable_value;
            },
            .local_val => scope = scope.cast(Scope.LocalVal).?.parent,
            .local_ptr => scope = scope.cast(Scope.LocalPtr).?.parent,
            .namespace => break,
            .defer_normal, .defer_error => scope = scope.cast(Scope.Defer).?.parent,
            .top => unreachable,
        }
    }
    if (opt_break_label.unwrap()) |break_label| {
        const label_name = try astgen.identifierTokenString(break_label);
        return astgen.failTok(break_label, "label not found: '{s}'", .{label_name});
    } else {
        return astgen.failNode(node, "break expression outside loop", .{});
    }
}

fn continueExpr(parent_gz: *GenZir, parent_scope: *Scope, node: Ast.Node.Index) InnerError!Zir.Inst.Ref {
    const astgen = parent_gz.astgen;
    const tree = astgen.tree;
    const opt_break_label, const opt_rhs = tree.nodeData(node).opt_token_and_opt_node;

    if (opt_break_label == .none and opt_rhs != .none) {
        return astgen.failNode(node, "cannot continue with operand without label", .{});
    }

    // Look for the label in the scope.
    var scope = parent_scope;
    while (true) {
        switch (scope.tag) {
            .gen_zir => {
                const gen_zir = scope.cast(GenZir).?;

                if (gen_zir.cur_defer_node.unwrap()) |cur_defer_node| {
                    return astgen.failNodeNotes(node, "cannot continue out of defer expression", .{}, &.{
                        try astgen.errNoteNode(
                            cur_defer_node,
                            "defer expression here",
                            .{},
                        ),
                    });
                }
                const continue_block = gen_zir.continue_block.unwrap() orelse {
                    scope = gen_zir.parent;
                    continue;
                };
                if (opt_break_label.unwrap()) |break_label| blk: {
                    if (gen_zir.label) |*label| {
                        if (try astgen.tokenIdentEql(label.token, break_label)) {
                            const maybe_switch_tag = astgen.instructions.items(.tag)[@intFromEnum(label.block_inst)];
                            if (opt_rhs != .none) switch (maybe_switch_tag) {
                                .switch_block, .switch_block_ref => {},
                                else => return astgen.failNode(node, "cannot continue loop with operand", .{}),
                            } else switch (maybe_switch_tag) {
                                .switch_block, .switch_block_ref => return astgen.failNode(node, "cannot continue switch without operand", .{}),
                                else => {},
                            }

                            label.used = true;
                            label.used_for_continue = true;
                            break :blk;
                        }
                    }
                    // found continue but either it has a different label, or no label
                    scope = gen_zir.parent;
                    continue;
                } else if (gen_zir.label) |label| {
                    // This `continue` is unlabeled. If the gz we've found corresponds to a labeled
                    // `switch`, ignore it and continue to parent scopes.
                    switch (astgen.instructions.items(.tag)[@intFromEnum(label.block_inst)]) {
                        .switch_block, .switch_block_ref => {
                            scope = gen_zir.parent;
                            continue;
                        },
                        else => {},
                    }
                }

                if (opt_rhs.unwrap()) |rhs| {
                    // We need to figure out the result info to use.
                    // The type should match
                    const operand = try reachableExpr(parent_gz, parent_scope, gen_zir.continue_result_info, rhs, node);

                    try genDefers(parent_gz, scope, parent_scope, .normal_only);

                    // As our last action before the continue, "pop" the error trace if needed
                    if (!gen_zir.is_comptime)
                        _ = try parent_gz.addRestoreErrRetIndex(.{ .block = continue_block }, .always, node);

                    _ = try parent_gz.addBreakWithSrcNode(.switch_continue, continue_block, operand, rhs);
                    return Zir.Inst.Ref.unreachable_value;
                }

                try genDefers(parent_gz, scope, parent_scope, .normal_only);

                const break_tag: Zir.Inst.Tag = if (gen_zir.is_inline)
                    .break_inline
                else
                    .@"break";
                if (break_tag == .break_inline) {
                    _ = try parent_gz.addUnNode(.check_comptime_control_flow, continue_block.toRef(), node);
                }

                // As our last action before the continue, "pop" the error trace if needed
                if (!gen_zir.is_comptime)
                    _ = try parent_gz.addRestoreErrRetIndex(.{ .block = continue_block }, .always, node);

                _ = try parent_gz.addBreak(break_tag, continue_block, .void_value);
                return Zir.Inst.Ref.unreachable_value;
            },
            .local_val => scope = scope.cast(Scope.LocalVal).?.parent,
            .local_ptr => scope = scope.cast(Scope.LocalPtr).?.parent,
            .defer_normal, .defer_error => scope = scope.cast(Scope.Defer).?.parent,
            .namespace => break,
            .top => unreachable,
        }
    }
    if (opt_break_label.unwrap()) |break_label| {
        const label_name = try astgen.identifierTokenString(break_label);
        return astgen.failTok(break_label, "label not found: '{s}'", .{label_name});
    } else {
        return astgen.failNode(node, "continue expression outside loop", .{});
    }
}

/// Similar to `expr`, but intended for use when `gz` corresponds to a body
/// which will contain only this node's code. Differs from `expr` in that if the
/// root expression is an unlabeled block, does not emit an actual block.
/// Instead, the block contents are emitted directly into `gz`.
fn fullBodyExpr(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    block_kind: BlockKind,
) InnerError!Zir.Inst.Ref {
    const tree = gz.astgen.tree;

    var stmt_buf: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&stmt_buf, node) orelse
        return expr(gz, scope, ri, node);

    const lbrace = tree.nodeMainToken(node);

    if (tree.isTokenPrecededByTags(lbrace, &.{ .identifier, .colon })) {
        // Labeled blocks are tricky - forwarding result location information properly is non-trivial,
        // plus if this block is exited with a `break_inline` we aren't allowed multiple breaks. This
        // case is rare, so just treat it as a normal expression and create a nested block.
        return blockExpr(gz, scope, ri, node, statements, block_kind);
    }

    var sub_gz = gz.makeSubBlock(scope);
    try blockExprStmts(&sub_gz, &sub_gz.base, statements, block_kind);

    return rvalue(gz, ri, .void_value, node);
}

const BlockKind = enum { normal, allow_branch_hint };

fn blockExpr(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    block_node: Ast.Node.Index,
    statements: []const Ast.Node.Index,
    kind: BlockKind,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const lbrace = tree.nodeMainToken(block_node);
    if (tree.isTokenPrecededByTags(lbrace, &.{ .identifier, .colon })) {
        return labeledBlockExpr(gz, scope, ri, block_node, statements, false, kind);
    }

    if (!gz.is_comptime) {
        // Since this block is unlabeled, its control flow is effectively linear and we
        // can *almost* get away with inlining the block here. However, we actually need
        // to preserve the .block for Sema, to properly pop the error return trace.

        const block_tag: Zir.Inst.Tag = .block;
        const block_inst = try gz.makeBlockInst(block_tag, block_node);
        try gz.instructions.append(astgen.gpa, block_inst);

        var block_scope = gz.makeSubBlock(scope);
        defer block_scope.unstack();

        try blockExprStmts(&block_scope, &block_scope.base, statements, kind);

        if (!block_scope.endsWithNoReturn()) {
            // As our last action before the break, "pop" the error trace if needed
            _ = try gz.addRestoreErrRetIndex(.{ .block = block_inst }, .always, block_node);
            // No `rvalue` call here, as the block result is always `void`, so we do that below.
            _ = try block_scope.addBreak(.@"break", block_inst, .void_value);
        }

        try block_scope.setBlockBody(block_inst);
    } else {
        var sub_gz = gz.makeSubBlock(scope);
        try blockExprStmts(&sub_gz, &sub_gz.base, statements, kind);
    }

    return rvalue(gz, ri, .void_value, block_node);
}

fn checkLabelRedefinition(astgen: *AstGen, parent_scope: *Scope, label: Ast.TokenIndex) !void {
    // Look for the label in the scope.
    var scope = parent_scope;
    while (true) {
        switch (scope.tag) {
            .gen_zir => {
                const gen_zir = scope.cast(GenZir).?;
                if (gen_zir.label) |prev_label| {
                    if (try astgen.tokenIdentEql(label, prev_label.token)) {
                        const label_name = try astgen.identifierTokenString(label);
                        return astgen.failTokNotes(label, "redefinition of label '{s}'", .{
                            label_name,
                        }, &[_]u32{
                            try astgen.errNoteTok(
                                prev_label.token,
                                "previous definition here",
                                .{},
                            ),
                        });
                    }
                }
                scope = gen_zir.parent;
            },
            .local_val => scope = scope.cast(Scope.LocalVal).?.parent,
            .local_ptr => scope = scope.cast(Scope.LocalPtr).?.parent,
            .defer_normal, .defer_error => scope = scope.cast(Scope.Defer).?.parent,
            .namespace => break,
            .top => unreachable,
        }
    }
}

fn labeledBlockExpr(
    gz: *GenZir,
    parent_scope: *Scope,
    ri: ResultInfo,
    block_node: Ast.Node.Index,
    statements: []const Ast.Node.Index,
    force_comptime: bool,
    block_kind: BlockKind,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const lbrace = tree.nodeMainToken(block_node);
    const label_token = lbrace - 2;
    assert(tree.tokenTag(label_token) == .identifier);

    try astgen.checkLabelRedefinition(parent_scope, label_token);

    const need_rl = astgen.nodes_need_rl.contains(block_node);
    const block_ri: ResultInfo = if (need_rl) ri else .{
        .rl = switch (ri.rl) {
            .ptr => .{ .ty = (try ri.rl.resultType(gz, block_node)).? },
            .inferred_ptr => .none,
            else => ri.rl,
        },
        .ctx = ri.ctx,
    };
    // We need to call `rvalue` to write through to the pointer only if we had a
    // result pointer and aren't forwarding it.
    const LocTag = @typeInfo(ResultInfo.Loc).@"union".tag_type.?;
    const need_result_rvalue = @as(LocTag, block_ri.rl) != @as(LocTag, ri.rl);

    // Reserve the Block ZIR instruction index so that we can put it into the GenZir struct
    // so that break statements can reference it.
    const block_inst = try gz.makeBlockInst(if (force_comptime) .block_comptime else .block, block_node);
    try gz.instructions.append(astgen.gpa, block_inst);
    var block_scope = gz.makeSubBlock(parent_scope);
    block_scope.is_inline = force_comptime;
    block_scope.label = GenZir.Label{
        .token = label_token,
        .block_inst = block_inst,
    };
    block_scope.setBreakResultInfo(block_ri);
    if (force_comptime) block_scope.is_comptime = true;
    defer block_scope.unstack();

    try blockExprStmts(&block_scope, &block_scope.base, statements, block_kind);
    if (!block_scope.endsWithNoReturn()) {
        // As our last action before the return, "pop" the error trace if needed
        _ = try gz.addRestoreErrRetIndex(.{ .block = block_inst }, .always, block_node);
        const result = try rvalue(gz, block_scope.break_result_info, .void_value, block_node);
        const break_tag: Zir.Inst.Tag = if (force_comptime) .break_inline else .@"break";
        _ = try block_scope.addBreak(break_tag, block_inst, result);
    }

    if (!block_scope.label.?.used) {
        try astgen.appendErrorTok(label_token, "unused block label", .{});
    }

    if (force_comptime) {
        try block_scope.setBlockComptimeBody(block_inst, .comptime_keyword);
    } else {
        try block_scope.setBlockBody(block_inst);
    }

    if (need_result_rvalue) {
        return rvalue(gz, ri, block_inst.toRef(), block_node);
    } else {
        return block_inst.toRef();
    }
}

fn blockExprStmts(gz: *GenZir, parent_scope: *Scope, statements: []const Ast.Node.Index, block_kind: BlockKind) !void {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    if (statements.len == 0) return;

    var block_arena = std.heap.ArenaAllocator.init(gz.astgen.gpa);
    defer block_arena.deinit();
    const block_arena_allocator = block_arena.allocator();

    var noreturn_src_node: Ast.Node.OptionalIndex = .none;
    var scope = parent_scope;
    for (statements, 0..) |statement, stmt_idx| {
        if (noreturn_src_node.unwrap()) |src_node| {
            try astgen.appendErrorNodeNotes(
                statement,
                "unreachable code",
                .{},
                &[_]u32{
                    try astgen.errNoteNode(
                        src_node,
                        "control flow is diverted here",
                        .{},
                    ),
                },
            );
        }
        const allow_branch_hint = switch (block_kind) {
            .normal => false,
            .allow_branch_hint => stmt_idx == 0,
        };
        var inner_node = statement;
        while (true) {
            switch (tree.nodeTag(inner_node)) {
                // zig fmt: off
                .global_var_decl,
                .local_var_decl,
                .simple_var_decl,
                .aligned_var_decl, => scope = try varDecl(gz, scope, statement, block_arena_allocator, tree.fullVarDecl(statement).?),

                .assign_destructure => scope = try assignDestructureMaybeDecls(gz, scope, statement, block_arena_allocator),

                .@"defer"    => scope = try deferStmt(gz, scope, statement, block_arena_allocator, .defer_normal),
                .@"errdefer" => scope = try deferStmt(gz, scope, statement, block_arena_allocator, .defer_error),

                .assign => try assign(gz, scope, statement),

                .assign_shl => try assignShift(gz, scope, statement, .shl),
                .assign_shr => try assignShift(gz, scope, statement, .shr),

                .assign_bit_and  => try assignOp(gz, scope, statement, .bit_and),
                .assign_bit_or   => try assignOp(gz, scope, statement, .bit_or),
                .assign_bit_xor  => try assignOp(gz, scope, statement, .xor),
                .assign_div      => try assignOp(gz, scope, statement, .div),
                .assign_sub      => try assignOp(gz, scope, statement, .sub),
                .assign_sub_wrap => try assignOp(gz, scope, statement, .subwrap),
                .assign_mod      => try assignOp(gz, scope, statement, .mod_rem),
                .assign_add      => try assignOp(gz, scope, statement, .add),
                .assign_add_wrap => try assignOp(gz, scope, statement, .addwrap),
                .assign_mul      => try assignOp(gz, scope, statement, .mul),
                .assign_mul_wrap => try assignOp(gz, scope, statement, .mulwrap),

                .grouped_expression => {
                    inner_node = tree.nodeData(statement).node_and_token[0];
                    continue;
                },

                .while_simple,
                .while_cont,
                .@"while", => _ = try whileExpr(gz, scope, .{ .rl = .none }, inner_node, tree.fullWhile(inner_node).?, true),

                .for_simple,
                .@"for", => _ = try forExpr(gz, scope, .{ .rl = .none }, inner_node, tree.fullFor(inner_node).?, true),
                // zig fmt: on

                // These cases are here to allow branch hints.
                .builtin_call_two,
                .builtin_call_two_comma,
                .builtin_call,
                .builtin_call_comma,
                => {
                    var buf: [2]Ast.Node.Index = undefined;
                    const params = tree.builtinCallParams(&buf, inner_node).?;

                    try emitDbgNode(gz, inner_node);
                    const result = try builtinCall(gz, scope, .{ .rl = .none }, inner_node, params, allow_branch_hint);
                    noreturn_src_node = try addEnsureResult(gz, result, inner_node);
                },

                else => noreturn_src_node = try unusedResultExpr(gz, scope, inner_node),
            }
            break;
        }
    }

    if (noreturn_src_node == .none) {
        try genDefers(gz, parent_scope, scope, .normal_only);
    }
    try checkUsed(gz, parent_scope, scope);
}

/// Returns AST source node of the thing that is noreturn if the statement is
/// definitely `noreturn`. Otherwise returns .none.
fn unusedResultExpr(gz: *GenZir, scope: *Scope, statement: Ast.Node.Index) InnerError!Ast.Node.OptionalIndex {
    try emitDbgNode(gz, statement);
    // We need to emit an error if the result is not `noreturn` or `void`, but
    // we want to avoid adding the ZIR instruction if possible for performance.
    const maybe_unused_result = try expr(gz, scope, .{ .rl = .none }, statement);
    return addEnsureResult(gz, maybe_unused_result, statement);
}

fn addEnsureResult(gz: *GenZir, maybe_unused_result: Zir.Inst.Ref, statement: Ast.Node.Index) InnerError!Ast.Node.OptionalIndex {
    var noreturn_src_node: Ast.Node.OptionalIndex = .none;
    const elide_check = if (maybe_unused_result.toIndex()) |inst| b: {
        // Note that this array becomes invalid after appending more items to it
        // in the above while loop.
        const zir_tags = gz.astgen.instructions.items(.tag);
        switch (zir_tags[@intFromEnum(inst)]) {
            // For some instructions, modify the zir data
            // so we can avoid a separate ensure_result_used instruction.
            .call, .field_call => {
                const break_extra = gz.astgen.instructions.items(.data)[@intFromEnum(inst)].pl_node.payload_index;
                comptime assert(std.meta.fieldIndex(Zir.Inst.Call, "flags") ==
                    std.meta.fieldIndex(Zir.Inst.FieldCall, "flags"));
                const flags: *Zir.Inst.Call.Flags = @ptrCast(&gz.astgen.extra.items[
                    break_extra + std.meta.fieldIndex(Zir.Inst.Call, "flags").?
                ]);
                flags.ensure_result_used = true;
                break :b true;
            },
            .builtin_call => {
                const break_extra = gz.astgen.instructions.items(.data)[@intFromEnum(inst)].pl_node.payload_index;
                const flags: *Zir.Inst.BuiltinCall.Flags = @ptrCast(&gz.astgen.extra.items[
                    break_extra + std.meta.fieldIndex(Zir.Inst.BuiltinCall, "flags").?
                ]);
                flags.ensure_result_used = true;
                break :b true;
            },

            // ZIR instructions that might be a type other than `noreturn` or `void`.
            .add,
            .addwrap,
            .add_sat,
            .add_unsafe,
            .param,
            .param_comptime,
            .param_anytype,
            .param_anytype_comptime,
            .alloc,
            .alloc_mut,
            .alloc_comptime_mut,
            .alloc_inferred,
            .alloc_inferred_mut,
            .alloc_inferred_comptime,
            .alloc_inferred_comptime_mut,
            .make_ptr_const,
            .array_cat,
            .array_mul,
            .array_type,
            .array_type_sentinel,
            .elem_type,
            .indexable_ptr_elem_type,
            .vec_arr_elem_type,
            .vector_type,
            .indexable_ptr_len,
            .anyframe_type,
            .as_node,
            .as_shift_operand,
            .bit_and,
            .bitcast,
            .bit_or,
            .block,
            .block_comptime,
            .block_inline,
            .declaration,
            .suspend_block,
            .loop,
            .bool_br_and,
            .bool_br_or,
            .bool_not,
            .cmp_lt,
            .cmp_lte,
            .cmp_eq,
            .cmp_gte,
            .cmp_gt,
            .cmp_neq,
            .decl_ref,
            .decl_val,
            .load,
            .div,
            .elem_ptr,
            .elem_val,
            .elem_ptr_node,
            .elem_val_node,
            .elem_val_imm,
            .field_ptr,
            .field_val,
            .field_ptr_named,
            .field_val_named,
            .func,
            .func_inferred,
            .func_fancy,
            .int,
            .int_big,
            .float,
            .float128,
            .int_type,
            .is_non_null,
            .is_non_null_ptr,
            .is_non_err,
            .is_non_err_ptr,
            .ret_is_non_err,
            .mod_rem,
            .mul,
            .mulwrap,
            .mul_sat,
            .ref,
            .shl,
            .shl_sat,
            .shr,
            .str,
            .sub,
            .subwrap,
            .sub_sat,
            .negate,
            .negate_wrap,
            .typeof,
            .typeof_builtin,
            .xor,
            .optional_type,
            .optional_payload_safe,
            .optional_payload_unsafe,
            .optional_payload_safe_ptr,
            .optional_payload_unsafe_ptr,
            .err_union_payload_unsafe,
            .err_union_payload_unsafe_ptr,
            .err_union_code,
            .err_union_code_ptr,
            .ptr_type,
            .enum_literal,
            .decl_literal,
            .decl_literal_no_coerce,
            .merge_error_sets,
            .error_union_type,
            .bit_not,
            .error_value,
            .slice_start,
            .slice_end,
            .slice_sentinel,
            .slice_length,
            .slice_sentinel_ty,
            .import,
            .switch_block,
            .switch_block_ref,
            .switch_block_err_union,
            .union_init,
            .field_type_ref,
            .error_set_decl,
            .enum_from_int,
            .int_from_enum,
            .type_info,
            .size_of,
            .bit_size_of,
            .typeof_log2_int_type,
            .int_from_ptr,
            .align_of,
            .int_from_bool,
            .embed_file,
            .error_name,
            .sqrt,
            .sin,
            .cos,
            .tan,
            .exp,
            .exp2,
            .log,
            .log2,
            .log10,
            .abs,
            .floor,
            .ceil,
            .trunc,
            .round,
            .tag_name,
            .type_name,
            .frame_type,
            .int_from_float,
            .float_from_int,
            .ptr_from_int,
            .float_cast,
            .int_cast,
            .ptr_cast,
            .truncate,
            .has_decl,
            .has_field,
            .clz,
            .ctz,
            .pop_count,
            .byte_swap,
            .bit_reverse,
            .div_exact,
            .div_floor,
            .div_trunc,
            .mod,
            .rem,
            .shl_exact,
            .shr_exact,
            .bit_offset_of,
            .offset_of,
            .splat,
            .reduce,
            .shuffle,
            .atomic_load,
            .atomic_rmw,
            .mul_add,
            .max,
            .min,
            .c_import,
            .@"resume",
            .ret_err_value_code,
            .ret_ptr,
            .ret_type,
            .for_len,
            .@"try",
            .try_ptr,
            .opt_eu_base_ptr_init,
            .coerce_ptr_elem_ty,
            .struct_init_empty,
            .struct_init_empty_result,
            .struct_init_empty_ref_result,
            .struct_init_anon,
            .struct_init,
            .struct_init_ref,
            .struct_init_field_type,
            .struct_init_field_ptr,
            .array_init_anon,
            .array_init,
            .array_init_ref,
            .validate_array_init_ref_ty,
            .array_init_elem_type,
            .array_init_elem_ptr,
            => break :b false,

            .extended => switch (gz.astgen.instructions.items(.data)[@intFromEnum(inst)].extended.opcode) {
                .breakpoint,
                .disable_instrumentation,
                .disable_intrinsics,
                .set_float_mode,
                .branch_hint,
                => break :b true,
                else => break :b false,
            },

            // ZIR instructions that are always `noreturn`.
            .@"break",
            .break_inline,
            .condbr,
            .condbr_inline,
            .compile_error,
            .ret_node,
            .ret_load,
            .ret_implicit,
            .ret_err_value,
            .@"unreachable",
            .repeat,
            .repeat_inline,
            .panic,
            .trap,
            .check_comptime_control_flow,
            .switch_continue,
            => {
                noreturn_src_node = statement.toOptional();
                break :b true;
            },

            // ZIR instructions that are always `void`.
            .dbg_stmt,
            .dbg_var_ptr,
            .dbg_var_val,
            .ensure_result_used,
            .ensure_result_non_error,
            .ensure_err_union_payload_void,
            .@"export",
            .set_eval_branch_quota,
            .atomic_store,
            .store_node,
            .store_to_inferred_ptr,
            .resolve_inferred_alloc,
            .set_runtime_safety,
            .memcpy,
            .memset,
            .memmove,
            .validate_deref,
            .validate_destructure,
            .save_err_ret_index,
            .restore_err_ret_index_unconditional,
            .restore_err_ret_index_fn_entry,
            .validate_struct_init_ty,
            .validate_struct_init_result_ty,
            .validate_ptr_struct_init,
            .validate_array_init_ty,
            .validate_array_init_result_ty,
            .validate_ptr_array_init,
            .validate_ref_ty,
            .validate_const,
            => break :b true,

            .@"defer" => unreachable,
            .defer_err_code => unreachable,
        }
    } else switch (maybe_unused_result) {
        .none => unreachable,

        .unreachable_value => b: {
            noreturn_src_node = statement.toOptional();
            break :b true;
        },

        .void_value => true,

        else => false,
    };
    if (!elide_check) {
        _ = try gz.addUnNode(.ensure_result_used, maybe_unused_result, statement);
    }
    return noreturn_src_node;
}

fn countDefers(outer_scope: *Scope, inner_scope: *Scope) struct {
    have_any: bool,
    have_normal: bool,
    have_err: bool,
    need_err_code: bool,
} {
    var have_normal = false;
    var have_err = false;
    var need_err_code = false;
    var scope = inner_scope;
    while (scope != outer_scope) {
        switch (scope.tag) {
            .gen_zir => scope = scope.cast(GenZir).?.parent,
            .local_val => scope = scope.cast(Scope.LocalVal).?.parent,
            .local_ptr => scope = scope.cast(Scope.LocalPtr).?.parent,
            .defer_normal => {
                const defer_scope = scope.cast(Scope.Defer).?;
                scope = defer_scope.parent;

                have_normal = true;
            },
            .defer_error => {
                const defer_scope = scope.cast(Scope.Defer).?;
                scope = defer_scope.parent;

                have_err = true;

                const have_err_payload = defer_scope.remapped_err_code != .none;
                need_err_code = need_err_code or have_err_payload;
            },
            .namespace => unreachable,
            .top => unreachable,
        }
    }
    return .{
        .have_any = have_normal or have_err,
        .have_normal = have_normal,
        .have_err = have_err,
        .need_err_code = need_err_code,
    };
}

const DefersToEmit = union(enum) {
    both: Zir.Inst.Ref, // err code
    both_sans_err,
    normal_only,
};

fn genDefers(
    gz: *GenZir,
    outer_scope: *Scope,
    inner_scope: *Scope,
    which_ones: DefersToEmit,
) InnerError!void {
    const gpa = gz.astgen.gpa;

    var scope = inner_scope;
    while (scope != outer_scope) {
        switch (scope.tag) {
            .gen_zir => scope = scope.cast(GenZir).?.parent,
            .local_val => scope = scope.cast(Scope.LocalVal).?.parent,
            .local_ptr => scope = scope.cast(Scope.LocalPtr).?.parent,
            .defer_normal => {
                const defer_scope = scope.cast(Scope.Defer).?;
                scope = defer_scope.parent;
                try gz.addDefer(defer_scope.index, defer_scope.len);
            },
            .defer_error => {
                const defer_scope = scope.cast(Scope.Defer).?;
                scope = defer_scope.parent;
                switch (which_ones) {
                    .both_sans_err => {
                        try gz.addDefer(defer_scope.index, defer_scope.len);
                    },
                    .both => |err_code| {
                        if (defer_scope.remapped_err_code.unwrap()) |remapped_err_code| {
                            try gz.instructions.ensureUnusedCapacity(gpa, 1);
                            try gz.astgen.instructions.ensureUnusedCapacity(gpa, 1);

                            const payload_index = try gz.astgen.addExtra(Zir.Inst.DeferErrCode{
                                .remapped_err_code = remapped_err_code,
                                .index = defer_scope.index,
                                .len = defer_scope.len,
                            });
                            const new_index: Zir.Inst.Index = @enumFromInt(gz.astgen.instructions.len);
                            gz.astgen.instructions.appendAssumeCapacity(.{
                                .tag = .defer_err_code,
                                .data = .{ .defer_err_code = .{
                                    .err_code = err_code,
                                    .payload_index = payload_index,
                                } },
                            });
                            gz.instructions.appendAssumeCapacity(new_index);
                        } else {
                            try gz.addDefer(defer_scope.index, defer_scope.len);
                        }
                    },
                    .normal_only => continue,
                }
            },
            .namespace => unreachable,
            .top => unreachable,
        }
    }
}

fn checkUsed(gz: *GenZir, outer_scope: *Scope, inner_scope: *Scope) InnerError!void {
    const astgen = gz.astgen;

    var scope = inner_scope;
    while (scope != outer_scope) {
        switch (scope.tag) {
            .gen_zir => scope = scope.cast(GenZir).?.parent,
            .local_val => {
                const s = scope.cast(Scope.LocalVal).?;
                if (s.used == .none and s.discarded == .none) {
                    try astgen.appendErrorTok(s.token_src, "unused {s}", .{@tagName(s.id_cat)});
                } else if (s.used != .none and s.discarded != .none) {
                    try astgen.appendErrorTokNotes(s.discarded.unwrap().?, "pointless discard of {s}", .{@tagName(s.id_cat)}, &[_]u32{
                        try gz.astgen.errNoteTok(s.used.unwrap().?, "used here", .{}),
                    });
                }
                scope = s.parent;
            },
            .local_ptr => {
                const s = scope.cast(Scope.LocalPtr).?;
                if (s.used == .none and s.discarded == .none) {
                    try astgen.appendErrorTok(s.token_src, "unused {s}", .{@tagName(s.id_cat)});
                } else {
                    if (s.used != .none and s.discarded != .none) {
                        try astgen.appendErrorTokNotes(s.discarded.unwrap().?, "pointless discard of {s}", .{@tagName(s.id_cat)}, &[_]u32{
                            try astgen.errNoteTok(s.used.unwrap().?, "used here", .{}),
                        });
                    }
                    if (s.id_cat == .@"local variable" and !s.used_as_lvalue) {
                        try astgen.appendErrorTokNotes(s.token_src, "local variable is never mutated", .{}, &.{
                            try astgen.errNoteTok(s.token_src, "consider using 'const'", .{}),
                        });
                    }
                }

                scope = s.parent;
            },
            .defer_normal, .defer_error => scope = scope.cast(Scope.Defer).?.parent,
            .namespace => unreachable,
            .top => unreachable,
        }
    }
}

fn deferStmt(
    gz: *GenZir,
    scope: *Scope,
    node: Ast.Node.Index,
    block_arena: Allocator,
    scope_tag: Scope.Tag,
) InnerError!*Scope {
    var defer_gen = gz.makeSubBlock(scope);
    defer_gen.cur_defer_node = node.toOptional();
    defer_gen.any_defer_node = node.toOptional();
    defer defer_gen.unstack();

    const tree = gz.astgen.tree;
    var local_val_scope: Scope.LocalVal = undefined;
    var opt_remapped_err_code: Zir.Inst.OptionalIndex = .none;
    const sub_scope = if (scope_tag != .defer_error) &defer_gen.base else blk: {
        const payload_token = tree.nodeData(node).opt_token_and_node[0].unwrap() orelse break :blk &defer_gen.base;
        const ident_name = try gz.astgen.identAsString(payload_token);
        if (std.mem.eql(u8, tree.tokenSlice(payload_token), "_")) {
            try gz.astgen.appendErrorTok(payload_token, "discard of error capture; omit it instead", .{});
            break :blk &defer_gen.base;
        }
        const remapped_err_code: Zir.Inst.Index = @enumFromInt(gz.astgen.instructions.len);
        opt_remapped_err_code = remapped_err_code.toOptional();
        try gz.astgen.instructions.append(gz.astgen.gpa, .{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = .value_placeholder,
                .small = undefined,
                .operand = undefined,
            } },
        });
        const remapped_err_code_ref = remapped_err_code.toRef();
        local_val_scope = .{
            .parent = &defer_gen.base,
            .gen_zir = gz,
            .name = ident_name,
            .inst = remapped_err_code_ref,
            .token_src = payload_token,
            .id_cat = .capture,
        };
        try gz.addDbgVar(.dbg_var_val, ident_name, remapped_err_code_ref);
        break :blk &local_val_scope.base;
    };
    const expr_node = switch (scope_tag) {
        .defer_normal => tree.nodeData(node).node,
        .defer_error => tree.nodeData(node).opt_token_and_node[1],
        else => unreachable,
    };
    _ = try unusedResultExpr(&defer_gen, sub_scope, expr_node);
    try checkUsed(gz, scope, sub_scope);
    _ = try defer_gen.addBreak(.break_inline, @enumFromInt(0), .void_value);

    const body = defer_gen.instructionsSlice();
    const extra_insts: []const Zir.Inst.Index = if (opt_remapped_err_code.unwrap()) |ec| &.{ec} else &.{};
    const body_len = gz.astgen.countBodyLenAfterFixupsExtraRefs(body, extra_insts);

    const index: u32 = @intCast(gz.astgen.extra.items.len);
    try gz.astgen.extra.ensureUnusedCapacity(gz.astgen.gpa, body_len);
    gz.astgen.appendBodyWithFixupsExtraRefsArrayList(&gz.astgen.extra, body, extra_insts);

    const defer_scope = try block_arena.create(Scope.Defer);

    defer_scope.* = .{
        .base = .{ .tag = scope_tag },
        .parent = scope,
        .index = index,
        .len = body_len,
        .remapped_err_code = opt_remapped_err_code,
    };
    return &defer_scope.base;
}

fn varDecl(
    gz: *GenZir,
    scope: *Scope,
    node: Ast.Node.Index,
    block_arena: Allocator,
    var_decl: Ast.full.VarDecl,
) InnerError!*Scope {
    try emitDbgNode(gz, node);
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const name_token = var_decl.ast.mut_token + 1;
    const ident_name_raw = tree.tokenSlice(name_token);
    if (mem.eql(u8, ident_name_raw, "_")) {
        return astgen.failTok(name_token, "'_' used as an identifier without @\"_\" syntax", .{});
    }
    const ident_name = try astgen.identAsString(name_token);

    try astgen.detectLocalShadowing(
        scope,
        ident_name,
        name_token,
        ident_name_raw,
        if (tree.tokenTag(var_decl.ast.mut_token) == .keyword_const) .@"local constant" else .@"local variable",
    );

    const init_node = var_decl.ast.init_node.unwrap() orelse {
        return astgen.failNode(node, "variables must be initialized", .{});
    };

    if (var_decl.ast.addrspace_node.unwrap()) |addrspace_node| {
        return astgen.failTok(tree.nodeMainToken(addrspace_node), "cannot set address space of local variable '{s}'", .{ident_name_raw});
    }

    if (var_decl.ast.section_node.unwrap()) |section_node| {
        return astgen.failTok(tree.nodeMainToken(section_node), "cannot set section of local variable '{s}'", .{ident_name_raw});
    }

    const align_inst: Zir.Inst.Ref = if (var_decl.ast.align_node.unwrap()) |align_node|
        try expr(gz, scope, coerced_align_ri, align_node)
    else
        .none;

    switch (tree.tokenTag(var_decl.ast.mut_token)) {
        .keyword_const => {
            if (var_decl.comptime_token) |comptime_token| {
                try astgen.appendErrorTok(comptime_token, "'comptime const' is redundant; instead wrap the initialization expression with 'comptime'", .{});
            }

            // `comptime const` is a non-fatal error; treat it like the init was marked `comptime`.
            const force_comptime = var_decl.comptime_token != null;

            // Depending on the type of AST the initialization expression is, we may need an lvalue
            // or an rvalue as a result location. If it is an rvalue, we can use the instruction as
            // the variable, no memory location needed.
            if (align_inst == .none and
                !astgen.nodes_need_rl.contains(node))
            {
                const result_info: ResultInfo = if (var_decl.ast.type_node.unwrap()) |type_node| .{
                    .rl = .{ .ty = try typeExpr(gz, scope, type_node) },
                    .ctx = .const_init,
                } else .{ .rl = .none, .ctx = .const_init };
                const init_inst: Zir.Inst.Ref = try nameStratExpr(gz, scope, result_info, init_node, .dbg_var) orelse
                    try reachableExprComptime(gz, scope, result_info, init_node, node, if (force_comptime) .comptime_keyword else null);

                _ = try gz.addUnNode(.validate_const, init_inst, init_node);
                try gz.addDbgVar(.dbg_var_val, ident_name, init_inst);

                // The const init expression may have modified the error return trace, so signal
                // to Sema that it should save the new index for restoring later.
                if (nodeMayAppendToErrorTrace(tree, init_node))
                    _ = try gz.addSaveErrRetIndex(.{ .if_of_error_type = init_inst });

                const sub_scope = try block_arena.create(Scope.LocalVal);
                sub_scope.* = .{
                    .parent = scope,
                    .gen_zir = gz,
                    .name = ident_name,
                    .inst = init_inst,
                    .token_src = name_token,
                    .id_cat = .@"local constant",
                };
                return &sub_scope.base;
            }

            const is_comptime = gz.is_comptime or
                tree.nodeTag(init_node) == .@"comptime";

            const init_rl: ResultInfo.Loc = if (var_decl.ast.type_node.unwrap()) |type_node| init_rl: {
                const type_inst = try typeExpr(gz, scope, type_node);
                if (align_inst == .none) {
                    break :init_rl .{ .ptr = .{ .inst = try gz.addUnNode(.alloc, type_inst, node) } };
                } else {
                    break :init_rl .{ .ptr = .{ .inst = try gz.addAllocExtended(.{
                        .node = node,
                        .type_inst = type_inst,
                        .align_inst = align_inst,
                        .is_const = true,
                        .is_comptime = is_comptime,
                    }) } };
                }
            } else init_rl: {
                const alloc_inst = if (align_inst == .none) ptr: {
                    const tag: Zir.Inst.Tag = if (is_comptime)
                        .alloc_inferred_comptime
                    else
                        .alloc_inferred;
                    break :ptr try gz.addNode(tag, node);
                } else ptr: {
                    break :ptr try gz.addAllocExtended(.{
                        .node = node,
                        .type_inst = .none,
                        .align_inst = align_inst,
                        .is_const = true,
                        .is_comptime = is_comptime,
                    });
                };
                break :init_rl .{ .inferred_ptr = alloc_inst };
            };
            const var_ptr: Zir.Inst.Ref, const resolve_inferred: bool = switch (init_rl) {
                .ptr => |ptr| .{ ptr.inst, false },
                .inferred_ptr => |inst| .{ inst, true },
                else => unreachable,
            };
            const init_result_info: ResultInfo = .{ .rl = init_rl, .ctx = .const_init };

            const init_inst: Zir.Inst.Ref = try nameStratExpr(gz, scope, init_result_info, init_node, .dbg_var) orelse
                try reachableExprComptime(gz, scope, init_result_info, init_node, node, if (force_comptime) .comptime_keyword else null);

            // The const init expression may have modified the error return trace, so signal
            // to Sema that it should save the new index for restoring later.
            if (nodeMayAppendToErrorTrace(tree, init_node))
                _ = try gz.addSaveErrRetIndex(.{ .if_of_error_type = init_inst });

            const const_ptr = if (resolve_inferred)
                try gz.addUnNode(.resolve_inferred_alloc, var_ptr, node)
            else
                try gz.addUnNode(.make_ptr_const, var_ptr, node);

            try gz.addDbgVar(.dbg_var_ptr, ident_name, const_ptr);

            const sub_scope = try block_arena.create(Scope.LocalPtr);
            sub_scope.* = .{
                .parent = scope,
                .gen_zir = gz,
                .name = ident_name,
                .ptr = const_ptr,
                .token_src = name_token,
                .maybe_comptime = true,
                .id_cat = .@"local constant",
            };
            return &sub_scope.base;
        },
        .keyword_var => {
            if (var_decl.comptime_token != null and gz.is_comptime)
                return astgen.failTok(var_decl.comptime_token.?, "'comptime var' is redundant in comptime scope", .{});
            const is_comptime = var_decl.comptime_token != null or gz.is_comptime;
            const alloc: Zir.Inst.Ref, const resolve_inferred: bool, const result_info: ResultInfo = if (var_decl.ast.type_node.unwrap()) |type_node| a: {
                const type_inst = try typeExpr(gz, scope, type_node);
                const alloc = alloc: {
                    if (align_inst == .none) {
                        const tag: Zir.Inst.Tag = if (is_comptime)
                            .alloc_comptime_mut
                        else
                            .alloc_mut;
                        break :alloc try gz.addUnNode(tag, type_inst, node);
                    } else {
                        break :alloc try gz.addAllocExtended(.{
                            .node = node,
                            .type_inst = type_inst,
                            .align_inst = align_inst,
                            .is_const = false,
                            .is_comptime = is_comptime,
                        });
                    }
                };
                break :a .{ alloc, false, .{ .rl = .{ .ptr = .{ .inst = alloc } } } };
            } else a: {
                const alloc = alloc: {
                    if (align_inst == .none) {
                        const tag: Zir.Inst.Tag = if (is_comptime)
                            .alloc_inferred_comptime_mut
                        else
                            .alloc_inferred_mut;
                        break :alloc try gz.addNode(tag, node);
                    } else {
                        break :alloc try gz.addAllocExtended(.{
                            .node = node,
                            .type_inst = .none,
                            .align_inst = align_inst,
                            .is_const = false,
                            .is_comptime = is_comptime,
                        });
                    }
                };
                break :a .{ alloc, true, .{ .rl = .{ .inferred_ptr = alloc } } };
            };
            _ = try nameStratExpr(
                gz,
                scope,
                result_info,
                init_node,
                .dbg_var,
            ) orelse try reachableExprComptime(
                gz,
                scope,
                result_info,
                init_node,
                node,
                if (var_decl.comptime_token != null) .comptime_keyword else null,
            );
            const final_ptr: Zir.Inst.Ref = if (resolve_inferred) ptr: {
                break :ptr try gz.addUnNode(.resolve_inferred_alloc, alloc, node);
            } else alloc;

            try gz.addDbgVar(.dbg_var_ptr, ident_name, final_ptr);

            const sub_scope = try block_arena.create(Scope.LocalPtr);
            sub_scope.* = .{
                .parent = scope,
                .gen_zir = gz,
                .name = ident_name,
                .ptr = final_ptr,
                .token_src = name_token,
                .maybe_comptime = is_comptime,
                .id_cat = .@"local variable",
            };
            return &sub_scope.base;
        },
        else => unreachable,
    }
}

fn emitDbgNode(gz: *GenZir, node: Ast.Node.Index) !void {
    // The instruction emitted here is for debugging runtime code.
    // If the current block will be evaluated only during semantic analysis
    // then no dbg_stmt ZIR instruction is needed.
    if (gz.is_comptime) return;
    const astgen = gz.astgen;
    astgen.advanceSourceCursorToNode(node);
    const line = astgen.source_line - gz.decl_line;
    const column = astgen.source_column;
    try emitDbgStmt(gz, .{ line, column });
}

fn assign(gz: *GenZir, scope: *Scope, infix_node: Ast.Node.Index) InnerError!void {
    try emitDbgNode(gz, infix_node);
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const lhs, const rhs = tree.nodeData(infix_node).node_and_node;
    if (tree.nodeTag(lhs) == .identifier) {
        // This intentionally does not support `@"_"` syntax.
        const ident_name = tree.tokenSlice(tree.nodeMainToken(lhs));
        if (mem.eql(u8, ident_name, "_")) {
            _ = try expr(gz, scope, .{ .rl = .discard, .ctx = .assignment }, rhs);
            return;
        }
    }
    const lvalue = try lvalExpr(gz, scope, lhs);
    _ = try expr(gz, scope, .{ .rl = .{ .ptr = .{
        .inst = lvalue,
        .src_node = infix_node,
    } } }, rhs);
}

/// Handles destructure assignments where no LHS is a `const` or `var` decl.
fn assignDestructure(gz: *GenZir, scope: *Scope, node: Ast.Node.Index) InnerError!void {
    try emitDbgNode(gz, node);
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const full = tree.assignDestructure(node);
    if (full.comptime_token != null and gz.is_comptime) {
        return astgen.appendErrorNode(node, "redundant comptime keyword in already comptime scope", .{});
    }

    // If this expression is marked comptime, we must wrap the whole thing in a comptime block.
    var gz_buf: GenZir = undefined;
    const inner_gz = if (full.comptime_token) |_| bs: {
        gz_buf = gz.makeSubBlock(scope);
        gz_buf.is_comptime = true;
        break :bs &gz_buf;
    } else gz;
    defer if (full.comptime_token) |_| inner_gz.unstack();

    const rl_components = try astgen.arena.alloc(ResultInfo.Loc.DestructureComponent, full.ast.variables.len);
    for (rl_components, full.ast.variables) |*variable_rl, variable_node| {
        if (tree.nodeTag(variable_node) == .identifier) {
            // This intentionally does not support `@"_"` syntax.
            const ident_name = tree.tokenSlice(tree.nodeMainToken(variable_node));
            if (mem.eql(u8, ident_name, "_")) {
                variable_rl.* = .discard;
                continue;
            }
        }
        variable_rl.* = .{ .typed_ptr = .{
            .inst = try lvalExpr(inner_gz, scope, variable_node),
            .src_node = variable_node,
        } };
    }

    const ri: ResultInfo = .{ .rl = .{ .destructure = .{
        .src_node = node,
        .components = rl_components,
    } } };

    _ = try expr(inner_gz, scope, ri, full.ast.value_expr);

    if (full.comptime_token) |_| {
        const comptime_block_inst = try gz.makeBlockInst(.block_comptime, node);
        _ = try inner_gz.addBreak(.break_inline, comptime_block_inst, .void_value);
        try inner_gz.setBlockComptimeBody(comptime_block_inst, .comptime_keyword);
        try gz.instructions.append(gz.astgen.gpa, comptime_block_inst);
    }
}

/// Handles destructure assignments where the LHS may contain `const` or `var` decls.
fn assignDestructureMaybeDecls(
    gz: *GenZir,
    scope: *Scope,
    node: Ast.Node.Index,
    block_arena: Allocator,
) InnerError!*Scope {
    try emitDbgNode(gz, node);
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const full = tree.assignDestructure(node);
    if (full.comptime_token != null and gz.is_comptime) {
        try astgen.appendErrorNode(node, "redundant comptime keyword in already comptime scope", .{});
    }

    const is_comptime = full.comptime_token != null or gz.is_comptime;
    const value_is_comptime = tree.nodeTag(full.ast.value_expr) == .@"comptime";

    // When declaring consts via a destructure, we always use a result pointer.
    // This avoids the need to create tuple types, and is also likely easier to
    // optimize, since it's a bit tricky for the optimizer to "split up" the
    // value into individual pointer writes down the line.

    // We know this rl information won't live past the evaluation of this
    // expression, so it may as well go in the block arena.
    const rl_components = try block_arena.alloc(ResultInfo.Loc.DestructureComponent, full.ast.variables.len);
    var any_non_const_variables = false;
    var any_lvalue_expr = false;
    for (rl_components, full.ast.variables) |*variable_rl, variable_node| {
        switch (tree.nodeTag(variable_node)) {
            .identifier => {
                // This intentionally does not support `@"_"` syntax.
                const ident_name = tree.tokenSlice(tree.nodeMainToken(variable_node));
                if (mem.eql(u8, ident_name, "_")) {
                    any_non_const_variables = true;
                    variable_rl.* = .discard;
                    continue;
                }
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                const full_var_decl = tree.fullVarDecl(variable_node).?;

                const name_token = full_var_decl.ast.mut_token + 1;
                const ident_name_raw = tree.tokenSlice(name_token);
                if (mem.eql(u8, ident_name_raw, "_")) {
                    return astgen.failTok(name_token, "'_' used as an identifier without @\"_\" syntax", .{});
                }

                // We detect shadowing in the second pass over these, while we're creating scopes.

                if (full_var_decl.ast.addrspace_node.unwrap()) |addrspace_node| {
                    return astgen.failTok(tree.nodeMainToken(addrspace_node), "cannot set address space of local variable '{s}'", .{ident_name_raw});
                }
                if (full_var_decl.ast.section_node.unwrap()) |section_node| {
                    return astgen.failTok(tree.nodeMainToken(section_node), "cannot set section of local variable '{s}'", .{ident_name_raw});
                }

                const is_const = switch (tree.tokenTag(full_var_decl.ast.mut_token)) {
                    .keyword_var => false,
                    .keyword_const => true,
                    else => unreachable,
                };
                if (!is_const) any_non_const_variables = true;

                // We also mark `const`s as comptime if the RHS is definitely comptime-known.
                const this_variable_comptime = is_comptime or (is_const and value_is_comptime);

                const align_inst: Zir.Inst.Ref = if (full_var_decl.ast.align_node.unwrap()) |align_node|
                    try expr(gz, scope, coerced_align_ri, align_node)
                else
                    .none;

                if (full_var_decl.ast.type_node.unwrap()) |type_node| {
                    // Typed alloc
                    const type_inst = try typeExpr(gz, scope, type_node);
                    const ptr = if (align_inst == .none) ptr: {
                        const tag: Zir.Inst.Tag = if (is_const)
                            .alloc
                        else if (this_variable_comptime)
                            .alloc_comptime_mut
                        else
                            .alloc_mut;
                        break :ptr try gz.addUnNode(tag, type_inst, node);
                    } else try gz.addAllocExtended(.{
                        .node = node,
                        .type_inst = type_inst,
                        .align_inst = align_inst,
                        .is_const = is_const,
                        .is_comptime = this_variable_comptime,
                    });
                    variable_rl.* = .{ .typed_ptr = .{ .inst = ptr } };
                } else {
                    // Inferred alloc
                    const ptr = if (align_inst == .none) ptr: {
                        const tag: Zir.Inst.Tag = if (is_const) tag: {
                            break :tag if (this_variable_comptime) .alloc_inferred_comptime else .alloc_inferred;
                        } else tag: {
                            break :tag if (this_variable_comptime) .alloc_inferred_comptime_mut else .alloc_inferred_mut;
                        };
                        break :ptr try gz.addNode(tag, node);
                    } else try gz.addAllocExtended(.{
                        .node = node,
                        .type_inst = .none,
                        .align_inst = align_inst,
                        .is_const = is_const,
                        .is_comptime = this_variable_comptime,
                    });
                    variable_rl.* = .{ .inferred_ptr = ptr };
                }

                continue;
            },
            else => {},
        }
        // This variable is just an lvalue expression.
        // We will fill in its result pointer later, inside a comptime block.
        any_non_const_variables = true;
        any_lvalue_expr = true;
        variable_rl.* = .{ .typed_ptr = .{
            .inst = undefined,
            .src_node = variable_node,
        } };
    }

    if (full.comptime_token != null and !any_non_const_variables) {
        try astgen.appendErrorTok(full.comptime_token.?, "'comptime const' is redundant; instead wrap the initialization expression with 'comptime'", .{});
        // Note that this is non-fatal; we will still evaluate at comptime.
    }

    // If this expression is marked comptime, we must wrap it in a comptime block.
    var gz_buf: GenZir = undefined;
    const inner_gz = if (full.comptime_token) |_| bs: {
        gz_buf = gz.makeSubBlock(scope);
        gz_buf.is_comptime = true;
        break :bs &gz_buf;
    } else gz;
    defer if (full.comptime_token) |_| inner_gz.unstack();

    if (any_lvalue_expr) {
        // At least one variable was an lvalue expr. Iterate again in order to
        // evaluate the lvalues from within the possible block_comptime.
        for (rl_components, full.ast.variables) |*variable_rl, variable_node| {
            if (variable_rl.* != .typed_ptr) continue;
            switch (tree.nodeTag(variable_node)) {
                .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => continue,
                else => {},
            }
            variable_rl.typed_ptr.inst = try lvalExpr(inner_gz, scope, variable_node);
        }
    }

    // We can't give a reasonable anon name strategy for destructured inits, so
    // leave it at its default of `.anon`.
    _ = try reachableExpr(inner_gz, scope, .{ .rl = .{ .destructure = .{
        .src_node = node,
        .components = rl_components,
    } } }, full.ast.value_expr, node);

    if (full.comptime_token) |_| {
        // Finish the block_comptime. Inferred alloc resolution etc will occur
        // in the parent block.
        const comptime_block_inst = try gz.makeBlockInst(.block_comptime, node);
        _ = try inner_gz.addBreak(.break_inline, comptime_block_inst, .void_value);
        try inner_gz.setBlockComptimeBody(comptime_block_inst, .comptime_keyword);
        try gz.instructions.append(gz.astgen.gpa, comptime_block_inst);
    }

    // Now, iterate over the variable exprs to construct any new scopes.
    // If there were any inferred allocations, resolve them.
    // If there were any `const` decls, make the pointer constant.
    var cur_scope = scope;
    for (rl_components, full.ast.variables) |variable_rl, variable_node| {
        switch (tree.nodeTag(variable_node)) {
            .local_var_decl, .simple_var_decl, .aligned_var_decl => {},
            else => continue, // We were mutating an existing lvalue - nothing to do
        }
        const full_var_decl = tree.fullVarDecl(variable_node).?;
        const raw_ptr, const resolve_inferred = switch (variable_rl) {
            .discard => unreachable,
            .typed_ptr => |typed_ptr| .{ typed_ptr.inst, false },
            .inferred_ptr => |ptr_inst| .{ ptr_inst, true },
        };
        const is_const = switch (tree.tokenTag(full_var_decl.ast.mut_token)) {
            .keyword_var => false,
            .keyword_const => true,
            else => unreachable,
        };

        // If the alloc was inferred, resolve it. If the alloc was const, make it const.
        const final_ptr = if (resolve_inferred)
            try gz.addUnNode(.resolve_inferred_alloc, raw_ptr, variable_node)
        else if (is_const)
            try gz.addUnNode(.make_ptr_const, raw_ptr, node)
        else
            raw_ptr;

        const name_token = full_var_decl.ast.mut_token + 1;
        const ident_name_raw = tree.tokenSlice(name_token);
        const ident_name = try astgen.identAsString(name_token);
        try astgen.detectLocalShadowing(
            cur_scope,
            ident_name,
            name_token,
            ident_name_raw,
            if (is_const) .@"local constant" else .@"local variable",
        );
        try gz.addDbgVar(.dbg_var_ptr, ident_name, final_ptr);
        // Finally, create the scope.
        const sub_scope = try block_arena.create(Scope.LocalPtr);
        sub_scope.* = .{
            .parent = cur_scope,
            .gen_zir = gz,
            .name = ident_name,
            .ptr = final_ptr,
            .token_src = name_token,
            .maybe_comptime = is_const or is_comptime,
            .id_cat = if (is_const) .@"local constant" else .@"local variable",
        };
        cur_scope = &sub_scope.base;
    }

    return cur_scope;
}

fn assignOp(
    gz: *GenZir,
    scope: *Scope,
    infix_node: Ast.Node.Index,
    op_inst_tag: Zir.Inst.Tag,
) InnerError!void {
    try emitDbgNode(gz, infix_node);
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const lhs_node, const rhs_node = tree.nodeData(infix_node).node_and_node;
    const lhs_ptr = try lvalExpr(gz, scope, lhs_node);

    const cursor = switch (op_inst_tag) {
        .add, .sub, .mul, .div, .mod_rem => maybeAdvanceSourceCursorToMainToken(gz, infix_node),
        else => undefined,
    };
    const lhs = try gz.addUnNode(.load, lhs_ptr, infix_node);

    const rhs_res_ty = switch (op_inst_tag) {
        .add,
        .sub,
        => try gz.add(.{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = .inplace_arith_result_ty,
                .small = @intFromEnum(@as(Zir.Inst.InplaceOp, switch (op_inst_tag) {
                    .add => .add_eq,
                    .sub => .sub_eq,
                    else => unreachable,
                })),
                .operand = @intFromEnum(lhs),
            } },
        }),
        else => try gz.addUnNode(.typeof, lhs, infix_node), // same as LHS type
    };
    // Not `coerced_ty` since `add`/etc won't coerce to this type.
    const rhs = try expr(gz, scope, .{ .rl = .{ .ty = rhs_res_ty } }, rhs_node);

    switch (op_inst_tag) {
        .add, .sub, .mul, .div, .mod_rem => {
            try emitDbgStmt(gz, cursor);
        },
        else => {},
    }
    const result = try gz.addPlNode(op_inst_tag, infix_node, Zir.Inst.Bin{
        .lhs = lhs,
        .rhs = rhs,
    });
    _ = try gz.addPlNode(.store_node, infix_node, Zir.Inst.Bin{
        .lhs = lhs_ptr,
        .rhs = result,
    });
}

fn assignShift(
    gz: *GenZir,
    scope: *Scope,
    infix_node: Ast.Node.Index,
    op_inst_tag: Zir.Inst.Tag,
) InnerError!void {
    try emitDbgNode(gz, infix_node);
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const lhs_node, const rhs_node = tree.nodeData(infix_node).node_and_node;
    const lhs_ptr = try lvalExpr(gz, scope, lhs_node);
    const lhs = try gz.addUnNode(.load, lhs_ptr, infix_node);
    const rhs_type = try gz.addUnNode(.typeof_log2_int_type, lhs, infix_node);
    const rhs = try expr(gz, scope, .{ .rl = .{ .ty = rhs_type } }, rhs_node);

    const result = try gz.addPlNode(op_inst_tag, infix_node, Zir.Inst.Bin{
        .lhs = lhs,
        .rhs = rhs,
    });
    _ = try gz.addPlNode(.store_node, infix_node, Zir.Inst.Bin{
        .lhs = lhs_ptr,
        .rhs = result,
    });
}

fn assignShiftSat(gz: *GenZir, scope: *Scope, infix_node: Ast.Node.Index) InnerError!void {
    try emitDbgNode(gz, infix_node);
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const lhs_node, const rhs_node = tree.nodeData(infix_node).node_and_node;
    const lhs_ptr = try lvalExpr(gz, scope, lhs_node);
    const lhs = try gz.addUnNode(.load, lhs_ptr, infix_node);
    // Saturating shift-left allows any integer type for both the LHS and RHS.
    const rhs = try expr(gz, scope, .{ .rl = .none }, rhs_node);

    const result = try gz.addPlNode(.shl_sat, infix_node, Zir.Inst.Bin{
        .lhs = lhs,
        .rhs = rhs,
    });
    _ = try gz.addPlNode(.store_node, infix_node, Zir.Inst.Bin{
        .lhs = lhs_ptr,
        .rhs = result,
    });
}

fn ptrType(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    ptr_info: Ast.full.PtrType,
) InnerError!Zir.Inst.Ref {
    if (ptr_info.size == .c and ptr_info.allowzero_token != null) {
        return gz.astgen.failTok(ptr_info.allowzero_token.?, "C pointers always allow address zero", .{});
    }

    const source_offset = gz.astgen.source_offset;
    const source_line = gz.astgen.source_line;
    const source_column = gz.astgen.source_column;
    const elem_type = try typeExpr(gz, scope, ptr_info.ast.child_type);

    var sentinel_ref: Zir.Inst.Ref = .none;
    var align_ref: Zir.Inst.Ref = .none;
    var addrspace_ref: Zir.Inst.Ref = .none;
    var bit_start_ref: Zir.Inst.Ref = .none;
    var bit_end_ref: Zir.Inst.Ref = .none;
    var trailing_count: u32 = 0;

    if (ptr_info.ast.sentinel.unwrap()) |sentinel| {
        // These attributes can appear in any order and they all come before the
        // element type so we need to reset the source cursor before generating them.
        gz.astgen.source_offset = source_offset;
        gz.astgen.source_line = source_line;
        gz.astgen.source_column = source_column;

        sentinel_ref = try comptimeExpr(
            gz,
            scope,
            .{ .rl = .{ .ty = elem_type } },
            sentinel,
            switch (ptr_info.size) {
                .slice => .slice_sentinel,
                else => .pointer_sentinel,
            },
        );
        trailing_count += 1;
    }
    if (ptr_info.ast.addrspace_node.unwrap()) |addrspace_node| {
        gz.astgen.source_offset = source_offset;
        gz.astgen.source_line = source_line;
        gz.astgen.source_column = source_column;

        const addrspace_ty = try gz.addBuiltinValue(addrspace_node, .address_space);
        addrspace_ref = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = addrspace_ty } }, addrspace_node, .@"addrspace");
        trailing_count += 1;
    }
    if (ptr_info.ast.align_node.unwrap()) |align_node| {
        gz.astgen.source_offset = source_offset;
        gz.astgen.source_line = source_line;
        gz.astgen.source_column = source_column;

        align_ref = try comptimeExpr(gz, scope, coerced_align_ri, align_node, .@"align");
        trailing_count += 1;
    }
    if (ptr_info.ast.bit_range_start.unwrap()) |bit_range_start| {
        const bit_range_end = ptr_info.ast.bit_range_end.unwrap().?;
        bit_start_ref = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = .u16_type } }, bit_range_start, .type);
        bit_end_ref = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = .u16_type } }, bit_range_end, .type);
        trailing_count += 2;
    }

    const gpa = gz.astgen.gpa;
    try gz.instructions.ensureUnusedCapacity(gpa, 1);
    try gz.astgen.instructions.ensureUnusedCapacity(gpa, 1);
    try gz.astgen.extra.ensureUnusedCapacity(gpa, @typeInfo(Zir.Inst.PtrType).@"struct".fields.len +
        trailing_count);

    const payload_index = gz.astgen.addExtraAssumeCapacity(Zir.Inst.PtrType{
        .elem_type = elem_type,
        .src_node = gz.nodeIndexToRelative(node),
    });
    if (sentinel_ref != .none) {
        gz.astgen.extra.appendAssumeCapacity(@intFromEnum(sentinel_ref));
    }
    if (align_ref != .none) {
        gz.astgen.extra.appendAssumeCapacity(@intFromEnum(align_ref));
    }
    if (addrspace_ref != .none) {
        gz.astgen.extra.appendAssumeCapacity(@intFromEnum(addrspace_ref));
    }
    if (bit_start_ref != .none) {
        gz.astgen.extra.appendAssumeCapacity(@intFromEnum(bit_start_ref));
        gz.astgen.extra.appendAssumeCapacity(@intFromEnum(bit_end_ref));
    }

    const new_index: Zir.Inst.Index = @enumFromInt(gz.astgen.instructions.len);
    const result = new_index.toRef();
    gz.astgen.instructions.appendAssumeCapacity(.{ .tag = .ptr_type, .data = .{
        .ptr_type = .{
            .flags = .{
                .is_allowzero = ptr_info.allowzero_token != null,
                .is_mutable = ptr_info.const_token == null,
                .is_volatile = ptr_info.volatile_token != null,
                .has_sentinel = sentinel_ref != .none,
                .has_align = align_ref != .none,
                .has_addrspace = addrspace_ref != .none,
                .has_bit_range = bit_start_ref != .none,
            },
            .size = ptr_info.size,
            .payload_index = payload_index,
        },
    } });
    gz.instructions.appendAssumeCapacity(new_index);

    return rvalue(gz, ri, result, node);
}

fn arrayType(gz: *GenZir, scope: *Scope, ri: ResultInfo, node: Ast.Node.Index) !Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const len_node, const elem_type_node = tree.nodeData(node).node_and_node;
    if (tree.nodeTag(len_node) == .identifier and
        mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(len_node)), "_"))
    {
        return astgen.failNode(len_node, "unable to infer array size", .{});
    }
    const len = try reachableExprComptime(gz, scope, .{ .rl = .{ .coerced_ty = .usize_type } }, len_node, node, .type);
    const elem_type = try typeExpr(gz, scope, elem_type_node);

    const result = try gz.addPlNode(.array_type, node, Zir.Inst.Bin{
        .lhs = len,
        .rhs = elem_type,
    });
    return rvalue(gz, ri, result, node);
}

fn arrayTypeSentinel(gz: *GenZir, scope: *Scope, ri: ResultInfo, node: Ast.Node.Index) !Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const len_node, const extra_index = tree.nodeData(node).node_and_extra;
    const extra = tree.extraData(extra_index, Ast.Node.ArrayTypeSentinel);

    if (tree.nodeTag(len_node) == .identifier and
        mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(len_node)), "_"))
    {
        return astgen.failNode(len_node, "unable to infer array size", .{});
    }
    const len = try reachableExprComptime(gz, scope, .{ .rl = .{ .coerced_ty = .usize_type } }, len_node, node, .array_length);
    const elem_type = try typeExpr(gz, scope, extra.elem_type);
    const sentinel = try reachableExprComptime(gz, scope, .{ .rl = .{ .coerced_ty = elem_type } }, extra.sentinel, node, .array_sentinel);

    const result = try gz.addPlNode(.array_type_sentinel, node, Zir.Inst.ArrayTypeSentinel{
        .len = len,
        .elem_type = elem_type,
        .sentinel = sentinel,
    });
    return rvalue(gz, ri, result, node);
}

const WipMembers = struct {
    payload: *ArrayListUnmanaged(u32),
    payload_top: usize,
    field_bits_start: u32,
    fields_start: u32,
    fields_end: u32,
    decl_index: u32 = 0,
    field_index: u32 = 0,

    const Self = @This();

    fn init(gpa: Allocator, payload: *ArrayListUnmanaged(u32), decl_count: u32, field_count: u32, comptime bits_per_field: u32, comptime max_field_size: u32) Allocator.Error!Self {
        const payload_top: u32 = @intCast(payload.items.len);
        const field_bits_start = payload_top + decl_count;
        const fields_start = field_bits_start + if (bits_per_field > 0) blk: {
            const fields_per_u32 = 32 / bits_per_field;
            break :blk (field_count + fields_per_u32 - 1) / fields_per_u32;
        } else 0;
        const payload_end = fields_start + field_count * max_field_size;
        try payload.resize(gpa, payload_end);
        return .{
            .payload = payload,
            .payload_top = payload_top,
            .field_bits_start = field_bits_start,
            .fields_start = fields_start,
            .fields_end = fields_start,
        };
    }

    fn nextDecl(self: *Self, decl_inst: Zir.Inst.Index) void {
        self.payload.items[self.payload_top + self.decl_index] = @intFromEnum(decl_inst);
        self.decl_index += 1;
    }

    fn nextField(self: *Self, comptime bits_per_field: u32, bits: [bits_per_field]bool) void {
        const fields_per_u32 = 32 / bits_per_field;
        const index = self.field_bits_start + self.field_index / fields_per_u32;
        assert(index < self.fields_start);
        var bit_bag: u32 = if (self.field_index % fields_per_u32 == 0) 0 else self.payload.items[index];
        bit_bag >>= bits_per_field;
        comptime var i = 0;
        inline while (i < bits_per_field) : (i += 1) {
            bit_bag |= @as(u32, @intFromBool(bits[i])) << (32 - bits_per_field + i);
        }
        self.payload.items[index] = bit_bag;
        self.field_index += 1;
    }

    fn appendToField(self: *Self, data: u32) void {
        assert(self.fields_end < self.payload.items.len);
        self.payload.items[self.fields_end] = data;
        self.fields_end += 1;
    }

    fn finishBits(self: *Self, comptime bits_per_field: u32) void {
        if (bits_per_field > 0) {
            const fields_per_u32 = 32 / bits_per_field;
            const empty_field_slots = fields_per_u32 - (self.field_index % fields_per_u32);
            if (self.field_index > 0 and empty_field_slots < fields_per_u32) {
                const index = self.field_bits_start + self.field_index / fields_per_u32;
                self.payload.items[index] >>= @intCast(empty_field_slots * bits_per_field);
            }
        }
    }

    fn declsSlice(self: *Self) []u32 {
        return self.payload.items[self.payload_top..][0..self.decl_index];
    }

    fn fieldsSlice(self: *Self) []u32 {
        return self.payload.items[self.field_bits_start..self.fields_end];
    }

    fn deinit(self: *Self) void {
        self.payload.items.len = self.payload_top;
    }
};

fn fnDecl(
    astgen: *AstGen,
    gz: *GenZir,
    scope: *Scope,
    wip_members: *WipMembers,
    decl_node: Ast.Node.Index,
    body_node: Ast.Node.OptionalIndex,
    fn_proto: Ast.full.FnProto,
) InnerError!void {
    const tree = astgen.tree;

    const old_hasher = astgen.src_hasher;
    defer astgen.src_hasher = old_hasher;
    astgen.src_hasher = std.zig.SrcHasher.init(.{});
    // We don't add the full source yet, because we also need the prototype hash!
    // The source slice is added towards the *end* of this function.
    astgen.src_hasher.update(std.mem.asBytes(&astgen.source_column));

    // missing function name already checked in scanContainer()
    const fn_name_token = fn_proto.name_token.?;

    // We insert this at the beginning so that its instruction index marks the
    // start of the top level declaration.
    const decl_inst = try gz.makeDeclaration(fn_proto.ast.proto_node);
    astgen.advanceSourceCursorToNode(decl_node);

    const saved_cursor = astgen.saveSourceCursor();

    const decl_column = astgen.source_column;

    // Set this now, since parameter types, return type, etc may be generic.
    const prev_within_fn = astgen.within_fn;
    defer astgen.within_fn = prev_within_fn;
    astgen.within_fn = true;

    const is_pub = fn_proto.visib_token != null;
    const is_export = blk: {
        const maybe_export_token = fn_proto.extern_export_inline_token orelse break :blk false;
        break :blk tree.tokenTag(maybe_export_token) == .keyword_export;
    };
    const is_extern = blk: {
        const maybe_extern_token = fn_proto.extern_export_inline_token orelse break :blk false;
        break :blk tree.tokenTag(maybe_extern_token) == .keyword_extern;
    };
    const has_inline_keyword = blk: {
        const maybe_inline_token = fn_proto.extern_export_inline_token orelse break :blk false;
        break :blk tree.tokenTag(maybe_inline_token) == .keyword_inline;
    };
    const lib_name = if (fn_proto.lib_name) |lib_name_token| blk: {
        const lib_name_str = try astgen.strLitAsString(lib_name_token);
        const lib_name_slice = astgen.string_bytes.items[@intFromEnum(lib_name_str.index)..][0..lib_name_str.len];
        if (mem.indexOfScalar(u8, lib_name_slice, 0) != null) {
            return astgen.failTok(lib_name_token, "library name cannot contain null bytes", .{});
        } else if (lib_name_str.len == 0) {
            return astgen.failTok(lib_name_token, "library name cannot be empty", .{});
        }
        break :blk lib_name_str.index;
    } else .empty;
    if (fn_proto.ast.callconv_expr != .none and has_inline_keyword) {
        return astgen.failNode(
            fn_proto.ast.callconv_expr.unwrap().?,
            "explicit callconv incompatible with inline keyword",
            .{},
        );
    }

    const return_type = fn_proto.ast.return_type.unwrap().?;
    const maybe_bang = tree.firstToken(return_type) - 1;
    const is_inferred_error = tree.tokenTag(maybe_bang) == .bang;
    if (body_node == .none) {
        if (!is_extern) {
            return astgen.failTok(fn_proto.ast.fn_token, "non-extern function has no body", .{});
        }
        if (is_inferred_error) {
            return astgen.failTok(maybe_bang, "function prototype may not have inferred error set", .{});
        }
    } else {
        assert(!is_extern); // validated by parser (TODO why???)
    }

    wip_members.nextDecl(decl_inst);

    var type_gz: GenZir = .{
        .is_comptime = true,
        .decl_node_index = fn_proto.ast.proto_node,
        .decl_line = astgen.source_line,
        .parent = scope,
        .astgen = astgen,
        .instructions = gz.instructions,
        .instructions_top = gz.instructions.items.len,
    };
    defer type_gz.unstack();

    if (is_extern) {
        // We include a function *type*, not a value.
        const type_inst = try fnProtoExprInner(&type_gz, &type_gz.base, .{ .rl = .none }, decl_node, fn_proto, true);
        _ = try type_gz.addBreakWithSrcNode(.break_inline, decl_inst, type_inst, decl_node);
    }

    var align_gz = type_gz.makeSubBlock(scope);
    defer align_gz.unstack();

    if (fn_proto.ast.align_expr.unwrap()) |align_expr| {
        astgen.restoreSourceCursor(saved_cursor);
        const inst = try expr(&align_gz, &align_gz.base, coerced_align_ri, align_expr);
        _ = try align_gz.addBreakWithSrcNode(.break_inline, decl_inst, inst, decl_node);
    }

    var linksection_gz = align_gz.makeSubBlock(scope);
    defer linksection_gz.unstack();

    if (fn_proto.ast.section_expr.unwrap()) |section_expr| {
        astgen.restoreSourceCursor(saved_cursor);
        const inst = try expr(&linksection_gz, &linksection_gz.base, coerced_linksection_ri, section_expr);
        _ = try linksection_gz.addBreakWithSrcNode(.break_inline, decl_inst, inst, decl_node);
    }

    var addrspace_gz = linksection_gz.makeSubBlock(scope);
    defer addrspace_gz.unstack();

    if (fn_proto.ast.addrspace_expr.unwrap()) |addrspace_expr| {
        astgen.restoreSourceCursor(saved_cursor);
        const addrspace_ty = try addrspace_gz.addBuiltinValue(addrspace_expr, .address_space);
        const inst = try expr(&addrspace_gz, &addrspace_gz.base, .{ .rl = .{ .coerced_ty = addrspace_ty } }, addrspace_expr);
        _ = try addrspace_gz.addBreakWithSrcNode(.break_inline, decl_inst, inst, decl_node);
    }

    var value_gz = addrspace_gz.makeSubBlock(scope);
    defer value_gz.unstack();

    if (!is_extern) {
        // We include a function *value*, not a type.
        astgen.restoreSourceCursor(saved_cursor);
        try astgen.fnDeclInner(&value_gz, &value_gz.base, saved_cursor, decl_inst, decl_node, body_node.unwrap().?, fn_proto);
    }

    // *Now* we can incorporate the full source code into the hasher.
    astgen.src_hasher.update(tree.getNodeSource(decl_node));

    var hash: std.zig.SrcHash = undefined;
    astgen.src_hasher.final(&hash);
    try setDeclaration(decl_inst, .{
        .src_hash = hash,
        .src_line = type_gz.decl_line,
        .src_column = decl_column,

        .kind = .@"const",
        .name = try astgen.identAsString(fn_name_token),
        .is_pub = is_pub,
        .is_threadlocal = false,
        .linkage = if (is_extern) .@"extern" else if (is_export) .@"export" else .normal,
        .lib_name = lib_name,

        .type_gz = &type_gz,
        .align_gz = &align_gz,
        .linksection_gz = &linksection_gz,
        .addrspace_gz = &addrspace_gz,
        .value_gz = &value_gz,
    });
}

fn fnDeclInner(
    astgen: *AstGen,
    decl_gz: *GenZir,
    scope: *Scope,
    saved_cursor: SourceCursor,
    decl_inst: Zir.Inst.Index,
    decl_node: Ast.Node.Index,
    body_node: Ast.Node.Index,
    fn_proto: Ast.full.FnProto,
) InnerError!void {
    const tree = astgen.tree;

    const is_noinline = blk: {
        const maybe_noinline_token = fn_proto.extern_export_inline_token orelse break :blk false;
        break :blk tree.tokenTag(maybe_noinline_token) == .keyword_noinline;
    };
    const has_inline_keyword = blk: {
        const maybe_inline_token = fn_proto.extern_export_inline_token orelse break :blk false;
        break :blk tree.tokenTag(maybe_inline_token) == .keyword_inline;
    };

    const return_type = fn_proto.ast.return_type.unwrap().?;
    const maybe_bang = tree.firstToken(return_type) - 1;
    const is_inferred_error = tree.tokenTag(maybe_bang) == .bang;

    // Note that the capacity here may not be sufficient, as this does not include `anytype` parameters.
    var param_insts: std.ArrayListUnmanaged(Zir.Inst.Index) = try .initCapacity(astgen.arena, fn_proto.ast.params.len);

    // We use this as `is_used_or_discarded` to figure out if parameters / return types are generic.
    var any_param_used = false;

    var noalias_bits: u32 = 0;
    var params_scope = scope;
    const is_var_args = is_var_args: {
        var param_type_i: usize = 0;
        var it = fn_proto.iterate(tree);
        while (it.next()) |param| : (param_type_i += 1) {
            const is_comptime = if (param.comptime_noalias) |token| switch (tree.tokenTag(token)) {
                .keyword_noalias => is_comptime: {
                    noalias_bits |= @as(u32, 1) << (std.math.cast(u5, param_type_i) orelse
                        return astgen.failTok(token, "this compiler implementation only supports 'noalias' on the first 32 parameters", .{}));
                    break :is_comptime false;
                },
                .keyword_comptime => true,
                else => false,
            } else false;

            const is_anytype = if (param.anytype_ellipsis3) |token| blk: {
                switch (tree.tokenTag(token)) {
                    .keyword_anytype => break :blk true,
                    .ellipsis3 => break :is_var_args true,
                    else => unreachable,
                }
            } else false;

            const param_name: Zir.NullTerminatedString = if (param.name_token) |name_token| blk: {
                const name_bytes = tree.tokenSlice(name_token);
                if (mem.eql(u8, "_", name_bytes))
                    break :blk .empty;

                const param_name = try astgen.identAsString(name_token);
                try astgen.detectLocalShadowing(params_scope, param_name, name_token, name_bytes, .@"function parameter");
                break :blk param_name;
            } else {
                if (param.anytype_ellipsis3) |tok| {
                    return astgen.failTok(tok, "missing parameter name", .{});
                } else {
                    const type_expr = param.type_expr.?;
                    ambiguous: {
                        if (tree.nodeTag(type_expr) != .identifier) break :ambiguous;
                        const main_token = tree.nodeMainToken(type_expr);
                        const identifier_str = tree.tokenSlice(main_token);
                        if (isPrimitive(identifier_str)) break :ambiguous;
                        return astgen.failNodeNotes(
                            type_expr,
                            "missing parameter name or type",
                            .{},
                            &[_]u32{
                                try astgen.errNoteNode(
                                    type_expr,
                                    "if this is a name, annotate its type: '{s}: T'",
                                    .{identifier_str},
                                ),
                                try astgen.errNoteNode(
                                    type_expr,
                                    "if this is a type, give it a name: 'name: {s}'",
                                    .{identifier_str},
                                ),
                            },
                        );
                    }
                    return astgen.failNode(type_expr, "missing parameter name", .{});
                }
            };

            const param_inst = if (is_anytype) param: {
                const name_token = param.name_token orelse param.anytype_ellipsis3.?;
                const tag: Zir.Inst.Tag = if (is_comptime)
                    .param_anytype_comptime
                else
                    .param_anytype;
                break :param try decl_gz.addStrTok(tag, param_name, name_token);
            } else param: {
                const param_type_node = param.type_expr.?;
                any_param_used = false; // we will check this later
                var param_gz = decl_gz.makeSubBlock(scope);
                defer param_gz.unstack();
                const param_type = try fullBodyExpr(&param_gz, params_scope, coerced_type_ri, param_type_node, .normal);
                const param_inst_expected: Zir.Inst.Index = @enumFromInt(astgen.instructions.len + 1);
                _ = try param_gz.addBreakWithSrcNode(.break_inline, param_inst_expected, param_type, param_type_node);
                const param_type_is_generic = any_param_used;

                const name_token = param.name_token orelse tree.nodeMainToken(param_type_node);
                const tag: Zir.Inst.Tag = if (is_comptime) .param_comptime else .param;
                const param_inst = try decl_gz.addParam(&param_gz, param_insts.items, param_type_is_generic, tag, name_token, param_name);
                assert(param_inst_expected == param_inst);
                break :param param_inst.toRef();
            };

            if (param_name == .empty) continue;

            const sub_scope = try astgen.arena.create(Scope.LocalVal);
            sub_scope.* = .{
                .parent = params_scope,
                .gen_zir = decl_gz,
                .name = param_name,
                .inst = param_inst,
                .token_src = param.name_token.?,
                .id_cat = .@"function parameter",
                .is_used_or_discarded = &any_param_used,
            };
            params_scope = &sub_scope.base;
            try param_insts.append(astgen.arena, param_inst.toIndex().?);
        }
        break :is_var_args false;
    };

    // After creating the function ZIR instruction, it will need to update the break
    // instructions inside the expression blocks for cc and ret_ty to use the function
    // instruction as the body to break from.

    var ret_gz = decl_gz.makeSubBlock(params_scope);
    defer ret_gz.unstack();
    any_param_used = false; // we will check this later
    const ret_ref: Zir.Inst.Ref = inst: {
        // Parameters are in scope for the return type, so we use `params_scope` here.
        // The calling convention will not have parameters in scope, so we'll just use `scope`.
        // See #22263 for a proposal to solve the inconsistency here.
        const inst = try fullBodyExpr(&ret_gz, params_scope, coerced_type_ri, fn_proto.ast.return_type.unwrap().?, .normal);
        if (ret_gz.instructionsSlice().len == 0) {
            // In this case we will send a len=0 body which can be encoded more efficiently.
            break :inst inst;
        }
        _ = try ret_gz.addBreak(.break_inline, @enumFromInt(0), inst);
        break :inst inst;
    };
    const ret_body_param_refs = try astgen.fetchRemoveRefEntries(param_insts.items);
    const ret_ty_is_generic = any_param_used;

    // We're jumping back in source, so restore the cursor.
    astgen.restoreSourceCursor(saved_cursor);

    var cc_gz = decl_gz.makeSubBlock(scope);
    defer cc_gz.unstack();
    const cc_ref: Zir.Inst.Ref = blk: {
        if (fn_proto.ast.callconv_expr.unwrap()) |callconv_expr| {
            const inst = try expr(
                &cc_gz,
                scope,
                .{ .rl = .{ .coerced_ty = try cc_gz.addBuiltinValue(callconv_expr, .calling_convention) } },
                callconv_expr,
            );
            if (cc_gz.instructionsSlice().len == 0) {
                // In this case we will send a len=0 body which can be encoded more efficiently.
                break :blk inst;
            }
            _ = try cc_gz.addBreak(.break_inline, @enumFromInt(0), inst);
            break :blk inst;
        } else if (has_inline_keyword) {
            const inst = try cc_gz.addBuiltinValue(decl_node, .calling_convention_inline);
            _ = try cc_gz.addBreak(.break_inline, @enumFromInt(0), inst);
            break :blk inst;
        } else {
            break :blk .none;
        }
    };

    var body_gz: GenZir = .{
        .is_comptime = false,
        .decl_node_index = fn_proto.ast.proto_node,
        .decl_line = decl_gz.decl_line,
        .parent = params_scope,
        .astgen = astgen,
        .instructions = decl_gz.instructions,
        .instructions_top = decl_gz.instructions.items.len,
    };
    defer body_gz.unstack();

    // The scope stack looks like this:
    //  body_gz (top)
    //  param2
    //  param1
    //  param0
    //  decl_gz (bottom)

    // Construct the prototype hash.
    // Leave `astgen.src_hasher` unmodified; this will be used for hashing
    // the *whole* function declaration, including its body.
    var proto_hasher = astgen.src_hasher;
    const proto_node = tree.nodeData(decl_node).node_and_node[0];
    proto_hasher.update(tree.getNodeSource(proto_node));
    var proto_hash: std.zig.SrcHash = undefined;
    proto_hasher.final(&proto_hash);

    const prev_fn_block = astgen.fn_block;
    const prev_fn_ret_ty = astgen.fn_ret_ty;
    defer {
        astgen.fn_block = prev_fn_block;
        astgen.fn_ret_ty = prev_fn_ret_ty;
    }
    astgen.fn_block = &body_gz;
    astgen.fn_ret_ty = if (is_inferred_error or ret_ref.toIndex() != null) r: {
        // We're essentially guaranteed to need the return type at some point,
        // since the return type is likely not `void` or `noreturn` so there
        // will probably be an explicit return requiring RLS. Fetch this
        // return type now so the rest of the function can use it.
        break :r try body_gz.addNode(.ret_type, decl_node);
    } else ret_ref;

    const prev_var_args = astgen.fn_var_args;
    astgen.fn_var_args = is_var_args;
    defer astgen.fn_var_args = prev_var_args;

    astgen.advanceSourceCursorToNode(body_node);
    const lbrace_line = astgen.source_line - decl_gz.decl_line;
    const lbrace_column = astgen.source_column;

    _ = try fullBodyExpr(&body_gz, &body_gz.base, .{ .rl = .none }, body_node, .allow_branch_hint);
    try checkUsed(decl_gz, scope, params_scope);

    if (!body_gz.endsWithNoReturn()) {
        // As our last action before the return, "pop" the error trace if needed
        _ = try body_gz.addRestoreErrRetIndex(.ret, .always, decl_node);

        // Add implicit return at end of function.
        _ = try body_gz.addUnTok(.ret_implicit, .void_value, tree.lastToken(body_node));
    }

    const func_inst = try decl_gz.addFunc(.{
        .src_node = decl_node,
        .cc_ref = cc_ref,
        .cc_gz = &cc_gz,
        .ret_ref = ret_ref,
        .ret_gz = &ret_gz,
        .ret_param_refs = ret_body_param_refs,
        .ret_ty_is_generic = ret_ty_is_generic,
        .lbrace_line = lbrace_line,
        .lbrace_column = lbrace_column,
        .param_block = decl_inst,
        .param_insts = param_insts.items,
        .body_gz = &body_gz,
        .is_var_args = is_var_args,
        .is_inferred_error = is_inferred_error,
        .is_noinline = is_noinline,
        .noalias_bits = noalias_bits,
        .proto_hash = proto_hash,
    });
    _ = try decl_gz.addBreakWithSrcNode(.break_inline, decl_inst, func_inst, decl_node);
}

fn globalVarDecl(
    astgen: *AstGen,
    gz: *GenZir,
    scope: *Scope,
    wip_members: *WipMembers,
    node: Ast.Node.Index,
    var_decl: Ast.full.VarDecl,
) InnerError!void {
    const tree = astgen.tree;

    const old_hasher = astgen.src_hasher;
    defer astgen.src_hasher = old_hasher;
    astgen.src_hasher = std.zig.SrcHasher.init(.{});
    astgen.src_hasher.update(tree.getNodeSource(node));
    astgen.src_hasher.update(std.mem.asBytes(&astgen.source_column));

    const is_mutable = tree.tokenTag(var_decl.ast.mut_token) == .keyword_var;
    const name_token = var_decl.ast.mut_token + 1;
    const is_pub = var_decl.visib_token != null;
    const is_export = blk: {
        const maybe_export_token = var_decl.extern_export_token orelse break :blk false;
        break :blk tree.tokenTag(maybe_export_token) == .keyword_export;
    };
    const is_extern = blk: {
        const maybe_extern_token = var_decl.extern_export_token orelse break :blk false;
        break :blk tree.tokenTag(maybe_extern_token) == .keyword_extern;
    };
    const is_threadlocal = if (var_decl.threadlocal_token) |tok| blk: {
        if (!is_mutable) {
            return astgen.failTok(tok, "threadlocal variable cannot be constant", .{});
        }
        break :blk true;
    } else false;
    const lib_name = if (var_decl.lib_name) |lib_name_token| blk: {
        const lib_name_str = try astgen.strLitAsString(lib_name_token);
        const lib_name_slice = astgen.string_bytes.items[@intFromEnum(lib_name_str.index)..][0..lib_name_str.len];
        if (mem.indexOfScalar(u8, lib_name_slice, 0) != null) {
            return astgen.failTok(lib_name_token, "library name cannot contain null bytes", .{});
        } else if (lib_name_str.len == 0) {
            return astgen.failTok(lib_name_token, "library name cannot be empty", .{});
        }
        break :blk lib_name_str.index;
    } else .empty;

    astgen.advanceSourceCursorToNode(node);

    const decl_column = astgen.source_column;

    const decl_inst = try gz.makeDeclaration(node);
    wip_members.nextDecl(decl_inst);

    if (var_decl.ast.init_node.unwrap()) |init_node| {
        if (is_extern) {
            return astgen.failNode(
                init_node,
                "extern variables have no initializers",
                .{},
            );
        }
    } else {
        if (!is_extern) {
            return astgen.failNode(node, "variables must be initialized", .{});
        }
    }

    if (is_extern and var_decl.ast.type_node == .none) {
        return astgen.failNode(node, "unable to infer variable type", .{});
    }

    assert(var_decl.comptime_token == null); // handled by parser

    var type_gz: GenZir = .{
        .parent = scope,
        .decl_node_index = node,
        .decl_line = astgen.source_line,
        .astgen = astgen,
        .is_comptime = true,
        .instructions = gz.instructions,
        .instructions_top = gz.instructions.items.len,
    };
    defer type_gz.unstack();

    if (var_decl.ast.type_node.unwrap()) |type_node| {
        const type_inst = try expr(&type_gz, &type_gz.base, coerced_type_ri, type_node);
        _ = try type_gz.addBreakWithSrcNode(.break_inline, decl_inst, type_inst, node);
    }

    var align_gz = type_gz.makeSubBlock(scope);
    defer align_gz.unstack();

    if (var_decl.ast.align_node.unwrap()) |align_node| {
        const align_inst = try expr(&align_gz, &align_gz.base, coerced_align_ri, align_node);
        _ = try align_gz.addBreakWithSrcNode(.break_inline, decl_inst, align_inst, node);
    }

    var linksection_gz = type_gz.makeSubBlock(scope);
    defer linksection_gz.unstack();

    if (var_decl.ast.section_node.unwrap()) |section_node| {
        const linksection_inst = try expr(&linksection_gz, &linksection_gz.base, coerced_linksection_ri, section_node);
        _ = try linksection_gz.addBreakWithSrcNode(.break_inline, decl_inst, linksection_inst, node);
    }

    var addrspace_gz = type_gz.makeSubBlock(scope);
    defer addrspace_gz.unstack();

    if (var_decl.ast.addrspace_node.unwrap()) |addrspace_node| {
        const addrspace_ty = try addrspace_gz.addBuiltinValue(addrspace_node, .address_space);
        const addrspace_inst = try expr(&addrspace_gz, &addrspace_gz.base, .{ .rl = .{ .coerced_ty = addrspace_ty } }, addrspace_node);
        _ = try addrspace_gz.addBreakWithSrcNode(.break_inline, decl_inst, addrspace_inst, node);
    }

    var init_gz = type_gz.makeSubBlock(scope);
    defer init_gz.unstack();

    if (var_decl.ast.init_node.unwrap()) |init_node| {
        const init_ri: ResultInfo = if (var_decl.ast.type_node != .none) .{
            .rl = .{ .coerced_ty = decl_inst.toRef() },
        } else .{ .rl = .none };
        const init_inst: Zir.Inst.Ref = try nameStratExpr(&init_gz, &init_gz.base, init_ri, init_node, .parent) orelse init: {
            break :init try expr(&init_gz, &init_gz.base, init_ri, init_node);
        };
        _ = try init_gz.addBreakWithSrcNode(.break_inline, decl_inst, init_inst, node);
    }

    var hash: std.zig.SrcHash = undefined;
    astgen.src_hasher.final(&hash);
    try setDeclaration(decl_inst, .{
        .src_hash = hash,
        .src_line = type_gz.decl_line,
        .src_column = decl_column,

        .kind = if (is_mutable) .@"var" else .@"const",
        .name = try astgen.identAsString(name_token),
        .is_pub = is_pub,
        .is_threadlocal = is_threadlocal,
        .linkage = if (is_extern) .@"extern" else if (is_export) .@"export" else .normal,
        .lib_name = lib_name,

        .type_gz = &type_gz,
        .align_gz = &align_gz,
        .linksection_gz = &linksection_gz,
        .addrspace_gz = &addrspace_gz,
        .value_gz = &init_gz,
    });
}

fn comptimeDecl(
    astgen: *AstGen,
    gz: *GenZir,
    scope: *Scope,
    wip_members: *WipMembers,
    node: Ast.Node.Index,
) InnerError!void {
    const tree = astgen.tree;
    const body_node = tree.nodeData(node).node;

    const old_hasher = astgen.src_hasher;
    defer astgen.src_hasher = old_hasher;
    astgen.src_hasher = std.zig.SrcHasher.init(.{});
    astgen.src_hasher.update(tree.getNodeSource(node));
    astgen.src_hasher.update(std.mem.asBytes(&astgen.source_column));

    // Up top so the ZIR instruction index marks the start range of this
    // top-level declaration.
    const decl_inst = try gz.makeDeclaration(node);
    wip_members.nextDecl(decl_inst);
    astgen.advanceSourceCursorToNode(node);

    // This is just needed for the `setDeclaration` call.
    var dummy_gz = gz.makeSubBlock(scope);
    defer dummy_gz.unstack();

    var comptime_gz: GenZir = .{
        .is_comptime = true,
        .decl_node_index = node,
        .decl_line = astgen.source_line,
        .parent = scope,
        .astgen = astgen,
        .instructions = dummy_gz.instructions,
        .instructions_top = dummy_gz.instructions.items.len,
    };
    defer comptime_gz.unstack();

    const decl_column = astgen.source_column;

    const block_result = try fullBodyExpr(&comptime_gz, &comptime_gz.base, .{ .rl = .none }, body_node, .normal);
    if (comptime_gz.isEmpty() or !comptime_gz.refIsNoReturn(block_result)) {
        _ = try comptime_gz.addBreak(.break_inline, decl_inst, .void_value);
    }

    var hash: std.zig.SrcHash = undefined;
    astgen.src_hasher.final(&hash);
    try setDeclaration(decl_inst, .{
        .src_hash = hash,
        .src_line = comptime_gz.decl_line,
        .src_column = decl_column,
        .kind = .@"comptime",
        .name = .empty,
        .is_pub = false,
        .is_threadlocal = false,
        .linkage = .normal,
        .type_gz = &dummy_gz,
        .align_gz = &dummy_gz,
        .linksection_gz = &dummy_gz,
        .addrspace_gz = &dummy_gz,
        .value_gz = &comptime_gz,
    });
}

fn testDecl(
    astgen: *AstGen,
    gz: *GenZir,
    scope: *Scope,
    wip_members: *WipMembers,
    node: Ast.Node.Index,
) InnerError!void {
    const tree = astgen.tree;
    _, const body_node = tree.nodeData(node).opt_token_and_node;

    const old_hasher = astgen.src_hasher;
    defer astgen.src_hasher = old_hasher;
    astgen.src_hasher = std.zig.SrcHasher.init(.{});
    astgen.src_hasher.update(tree.getNodeSource(node));
    astgen.src_hasher.update(std.mem.asBytes(&astgen.source_column));

    // Up top so the ZIR instruction index marks the start range of this
    // top-level declaration.
    const decl_inst = try gz.makeDeclaration(node);

    wip_members.nextDecl(decl_inst);
    astgen.advanceSourceCursorToNode(node);

    // This is just needed for the `setDeclaration` call.
    var dummy_gz: GenZir = gz.makeSubBlock(scope);
    defer dummy_gz.unstack();

    var decl_block: GenZir = .{
        .is_comptime = true,
        .decl_node_index = node,
        .decl_line = astgen.source_line,
        .parent = scope,
        .astgen = astgen,
        .instructions = dummy_gz.instructions,
        .instructions_top = dummy_gz.instructions.items.len,
    };
    defer decl_block.unstack();

    const decl_column = astgen.source_column;

    const test_token = tree.nodeMainToken(node);

    const test_name_token = test_token + 1;
    const test_name: Zir.NullTerminatedString = switch (tree.tokenTag(test_name_token)) {
        else => .empty,
        .string_literal => name: {
            const name = try astgen.strLitAsString(test_name_token);
            const slice = astgen.string_bytes.items[@intFromEnum(name.index)..][0..name.len];
            if (mem.indexOfScalar(u8, slice, 0) != null) {
                return astgen.failTok(test_name_token, "test name cannot contain null bytes", .{});
            } else if (slice.len == 0) {
                return astgen.failTok(test_name_token, "empty test name must be omitted", .{});
            }
            break :name name.index;
        },
        .identifier => name: {
            const ident_name_raw = tree.tokenSlice(test_name_token);

            if (mem.eql(u8, ident_name_raw, "_")) return astgen.failTok(test_name_token, "'_' used as an identifier without @\"_\" syntax", .{});

            // if not @"" syntax, just use raw token slice
            if (ident_name_raw[0] != '@') {
                if (isPrimitive(ident_name_raw)) return astgen.failTok(test_name_token, "cannot test a primitive", .{});
            }

            // Local variables, including function parameters.
            const name_str_index = try astgen.identAsString(test_name_token);
            var s = scope;
            var found_already: ?Ast.Node.Index = null; // we have found a decl with the same name already
            var num_namespaces_out: u32 = 0;
            var capturing_namespace: ?*Scope.Namespace = null;
            while (true) switch (s.tag) {
                .local_val => {
                    const local_val = s.cast(Scope.LocalVal).?;
                    if (local_val.name == name_str_index) {
                        local_val.used = .fromToken(test_name_token);
                        return astgen.failTokNotes(test_name_token, "cannot test a {s}", .{
                            @tagName(local_val.id_cat),
                        }, &[_]u32{
                            try astgen.errNoteTok(local_val.token_src, "{s} declared here", .{
                                @tagName(local_val.id_cat),
                            }),
                        });
                    }
                    s = local_val.parent;
                },
                .local_ptr => {
                    const local_ptr = s.cast(Scope.LocalPtr).?;
                    if (local_ptr.name == name_str_index) {
                        local_ptr.used = .fromToken(test_name_token);
                        return astgen.failTokNotes(test_name_token, "cannot test a {s}", .{
                            @tagName(local_ptr.id_cat),
                        }, &[_]u32{
                            try astgen.errNoteTok(local_ptr.token_src, "{s} declared here", .{
                                @tagName(local_ptr.id_cat),
                            }),
                        });
                    }
                    s = local_ptr.parent;
                },
                .gen_zir => s = s.cast(GenZir).?.parent,
                .defer_normal, .defer_error => s = s.cast(Scope.Defer).?.parent,
                .namespace => {
                    const ns = s.cast(Scope.Namespace).?;
                    if (ns.decls.get(name_str_index)) |i| {
                        if (found_already) |f| {
                            return astgen.failTokNotes(test_name_token, "ambiguous reference", .{}, &.{
                                try astgen.errNoteNode(f, "declared here", .{}),
                                try astgen.errNoteNode(i, "also declared here", .{}),
                            });
                        }
                        // We found a match but must continue looking for ambiguous references to decls.
                        found_already = i;
                    }
                    num_namespaces_out += 1;
                    capturing_namespace = ns;
                    s = ns.parent;
                },
                .top => break,
            };
            if (found_already == null) {
                const ident_name = try astgen.identifierTokenString(test_name_token);
                return astgen.failTok(test_name_token, "use of undeclared identifier '{s}'", .{ident_name});
            }

            break :name try astgen.identAsString(test_name_token);
        },
    };

    var fn_block: GenZir = .{
        .is_comptime = false,
        .decl_node_index = node,
        .decl_line = decl_block.decl_line,
        .parent = &decl_block.base,
        .astgen = astgen,
        .instructions = decl_block.instructions,
        .instructions_top = decl_block.instructions.items.len,
    };
    defer fn_block.unstack();

    const prev_within_fn = astgen.within_fn;
    const prev_fn_block = astgen.fn_block;
    const prev_fn_ret_ty = astgen.fn_ret_ty;
    astgen.within_fn = true;
    astgen.fn_block = &fn_block;
    astgen.fn_ret_ty = .anyerror_void_error_union_type;
    defer {
        astgen.within_fn = prev_within_fn;
        astgen.fn_block = prev_fn_block;
        astgen.fn_ret_ty = prev_fn_ret_ty;
    }

    astgen.advanceSourceCursorToNode(body_node);
    const lbrace_line = astgen.source_line - decl_block.decl_line;
    const lbrace_column = astgen.source_column;

    const block_result = try fullBodyExpr(&fn_block, &fn_block.base, .{ .rl = .none }, body_node, .normal);
    if (fn_block.isEmpty() or !fn_block.refIsNoReturn(block_result)) {

        // As our last action before the return, "pop" the error trace if needed
        _ = try fn_block.addRestoreErrRetIndex(.ret, .always, node);

        // Add implicit return at end of function.
        _ = try fn_block.addUnTok(.ret_implicit, .void_value, tree.lastToken(body_node));
    }

    const func_inst = try decl_block.addFunc(.{
        .src_node = node,

        .cc_ref = .none,
        .cc_gz = null,
        .ret_ref = .anyerror_void_error_union_type,
        .ret_gz = null,

        .ret_param_refs = &.{},
        .param_insts = &.{},
        .ret_ty_is_generic = false,

        .lbrace_line = lbrace_line,
        .lbrace_column = lbrace_column,
        .param_block = decl_inst,
        .body_gz = &fn_block,
        .is_var_args = false,
        .is_inferred_error = false,
        .is_noinline = false,
        .noalias_bits = 0,

        // Tests don't have a prototype that needs hashing
        .proto_hash = .{0} ** 16,
    });

    _ = try decl_block.addBreak(.break_inline, decl_inst, func_inst);

    var hash: std.zig.SrcHash = undefined;
    astgen.src_hasher.final(&hash);
    try setDeclaration(decl_inst, .{
        .src_hash = hash,
        .src_line = decl_block.decl_line,
        .src_column = decl_column,

        .kind = switch (tree.tokenTag(test_name_token)) {
            .string_literal => .@"test",
            .identifier => .decltest,
            else => .unnamed_test,
        },
        .name = test_name,
        .is_pub = false,
        .is_threadlocal = false,
        .linkage = .normal,

        .type_gz = &dummy_gz,
        .align_gz = &dummy_gz,
        .linksection_gz = &dummy_gz,
        .addrspace_gz = &dummy_gz,
        .value_gz = &decl_block,
    });
}

fn structDeclInner(
    gz: *GenZir,
    scope: *Scope,
    node: Ast.Node.Index,
    container_decl: Ast.full.ContainerDecl,
    layout: std.builtin.Type.ContainerLayout,
    backing_int_node: Ast.Node.OptionalIndex,
    name_strat: Zir.Inst.NameStrategy,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const gpa = astgen.gpa;
    const tree = astgen.tree;

    is_tuple: {
        const tuple_field_node = for (container_decl.ast.members) |member_node| {
            const container_field = tree.fullContainerField(member_node) orelse continue;
            if (container_field.ast.tuple_like) break member_node;
        } else break :is_tuple;

        if (node == .root) {
            return astgen.failNode(tuple_field_node, "file cannot be a tuple", .{});
        } else {
            return tupleDecl(gz, scope, node, container_decl, layout, backing_int_node);
        }
    }

    const decl_inst = try gz.reserveInstructionIndex();

    if (container_decl.ast.members.len == 0 and backing_int_node == .none) {
        try gz.setStruct(decl_inst, .{
            .src_node = node,
            .layout = layout,
            .captures_len = 0,
            .fields_len = 0,
            .decls_len = 0,
            .has_backing_int = false,
            .known_non_opv = false,
            .known_comptime_only = false,
            .any_comptime_fields = false,
            .any_default_inits = false,
            .any_aligned_fields = false,
            .fields_hash = std.zig.hashSrc(@tagName(layout)),
            .name_strat = name_strat,
        });
        return decl_inst.toRef();
    }

    var namespace: Scope.Namespace = .{
        .parent = scope,
        .node = node,
        .inst = decl_inst,
        .declaring_gz = gz,
        .maybe_generic = astgen.within_fn,
    };
    defer namespace.deinit(gpa);

    // The struct_decl instruction introduces a scope in which the decls of the struct
    // are in scope, so that field types, alignments, and default value expressions
    // can refer to decls within the struct itself.
    astgen.advanceSourceCursorToNode(node);
    var block_scope: GenZir = .{
        .parent = &namespace.base,
        .decl_node_index = node,
        .decl_line = gz.decl_line,
        .astgen = astgen,
        .is_comptime = true,
        .instructions = gz.instructions,
        .instructions_top = gz.instructions.items.len,
    };
    defer block_scope.unstack();

    const scratch_top = astgen.scratch.items.len;
    defer astgen.scratch.items.len = scratch_top;

    var backing_int_body_len: usize = 0;
    const backing_int_ref: Zir.Inst.Ref = blk: {
        if (backing_int_node.unwrap()) |arg| {
            if (layout != .@"packed") {
                return astgen.failNode(arg, "non-packed struct does not support backing integer type", .{});
            } else {
                const backing_int_ref = try typeExpr(&block_scope, &namespace.base, arg);
                if (!block_scope.isEmpty()) {
                    if (!block_scope.endsWithNoReturn()) {
                        _ = try block_scope.addBreak(.break_inline, decl_inst, backing_int_ref);
                    }

                    const body = block_scope.instructionsSlice();
                    const old_scratch_len = astgen.scratch.items.len;
                    try astgen.scratch.ensureUnusedCapacity(gpa, countBodyLenAfterFixups(astgen, body));
                    appendBodyWithFixupsArrayList(astgen, &astgen.scratch, body);
                    backing_int_body_len = astgen.scratch.items.len - old_scratch_len;
                    block_scope.instructions.items.len = block_scope.instructions_top;
                }
                break :blk backing_int_ref;
            }
        } else {
            break :blk .none;
        }
    };

    const decl_count = try astgen.scanContainer(&namespace, container_decl.ast.members, .@"struct");
    const field_count: u32 = @intCast(container_decl.ast.members.len - decl_count);

    const bits_per_field = 4;
    const max_field_size = 5;
    var wip_members = try WipMembers.init(gpa, &astgen.scratch, decl_count, field_count, bits_per_field, max_field_size);
    defer wip_members.deinit();

    // We will use the scratch buffer, starting here, for the bodies:
    //    bodies: { // for every fields_len
    //        field_type_body_inst: Inst, // for each field_type_body_len
    //        align_body_inst: Inst, // for each align_body_len
    //        init_body_inst: Inst, // for each init_body_len
    //    }
    // Note that the scratch buffer is simultaneously being used by WipMembers, however
    // it will not access any elements beyond this point in the ArrayList. It also
    // accesses via the ArrayList items field so it can handle the scratch buffer being
    // reallocated.
    // No defer needed here because it is handled by `wip_members.deinit()` above.
    const bodies_start = astgen.scratch.items.len;

    const old_hasher = astgen.src_hasher;
    defer astgen.src_hasher = old_hasher;
    astgen.src_hasher = std.zig.SrcHasher.init(.{});
    astgen.src_hasher.update(@tagName(layout));
    if (backing_int_node.unwrap()) |arg| {
        astgen.src_hasher.update(tree.getNodeSource(arg));
    }

    var known_non_opv = false;
    var known_comptime_only = false;
    var any_comptime_fields = false;
    var any_aligned_fields = false;
    var any_default_inits = false;
    for (container_decl.ast.members) |member_node| {
        var member = switch (try containerMember(&block_scope, &namespace.base, &wip_members, member_node)) {
            .decl => continue,
            .field => |field| field,
        };

        astgen.src_hasher.update(tree.getNodeSource(member_node));

        const field_name = try astgen.identAsString(member.ast.main_token);
        member.convertToNonTupleLike(astgen.tree);
        assert(!member.ast.tuple_like);
        wip_members.appendToField(@intFromEnum(field_name));

        const type_expr = member.ast.type_expr.unwrap() orelse {
            return astgen.failTok(member.ast.main_token, "struct field missing type", .{});
        };

        const field_type = try typeExpr(&block_scope, &namespace.base, type_expr);
        const have_type_body = !block_scope.isEmpty();
        const have_align = member.ast.align_expr != .none;
        const have_value = member.ast.value_expr != .none;
        const is_comptime = member.comptime_token != null;

        if (is_comptime) {
            switch (layout) {
                .@"packed", .@"extern" => return astgen.failTok(member.comptime_token.?, "{s} struct fields cannot be marked comptime", .{@tagName(layout)}),
                .auto => any_comptime_fields = true,
            }
        } else {
            known_non_opv = known_non_opv or
                nodeImpliesMoreThanOnePossibleValue(tree, type_expr);
            known_comptime_only = known_comptime_only or
                nodeImpliesComptimeOnly(tree, type_expr);
        }
        wip_members.nextField(bits_per_field, .{ have_align, have_value, is_comptime, have_type_body });

        if (have_type_body) {
            if (!block_scope.endsWithNoReturn()) {
                _ = try block_scope.addBreak(.break_inline, decl_inst, field_type);
            }
            const body = block_scope.instructionsSlice();
            const old_scratch_len = astgen.scratch.items.len;
            try astgen.scratch.ensureUnusedCapacity(gpa, countBodyLenAfterFixups(astgen, body));
            appendBodyWithFixupsArrayList(astgen, &astgen.scratch, body);
            wip_members.appendToField(@intCast(astgen.scratch.items.len - old_scratch_len));
            block_scope.instructions.items.len = block_scope.instructions_top;
        } else {
            wip_members.appendToField(@intFromEnum(field_type));
        }

        if (member.ast.align_expr.unwrap()) |align_expr| {
            if (layout == .@"packed") {
                return astgen.failNode(align_expr, "unable to override alignment of packed struct fields", .{});
            }
            any_aligned_fields = true;
            const align_ref = try expr(&block_scope, &namespace.base, coerced_align_ri, align_expr);
            if (!block_scope.endsWithNoReturn()) {
                _ = try block_scope.addBreak(.break_inline, decl_inst, align_ref);
            }
            const body = block_scope.instructionsSlice();
            const old_scratch_len = astgen.scratch.items.len;
            try astgen.scratch.ensureUnusedCapacity(gpa, countBodyLenAfterFixups(astgen, body));
            appendBodyWithFixupsArrayList(astgen, &astgen.scratch, body);
            wip_members.appendToField(@intCast(astgen.scratch.items.len - old_scratch_len));
            block_scope.instructions.items.len = block_scope.instructions_top;
        }

        if (member.ast.value_expr.unwrap()) |value_expr| {
            any_default_inits = true;

            // The decl_inst is used as here so that we can easily reconstruct a mapping
            // between it and the field type when the fields inits are analyzed.
            const ri: ResultInfo = .{ .rl = if (field_type == .none) .none else .{ .coerced_ty = decl_inst.toRef() } };

            const default_inst = try expr(&block_scope, &namespace.base, ri, value_expr);
            if (!block_scope.endsWithNoReturn()) {
                _ = try block_scope.addBreak(.break_inline, decl_inst, default_inst);
            }
            const body = block_scope.instructionsSlice();
            const old_scratch_len = astgen.scratch.items.len;
            try astgen.scratch.ensureUnusedCapacity(gpa, countBodyLenAfterFixups(astgen, body));
            appendBodyWithFixupsArrayList(astgen, &astgen.scratch, body);
            wip_members.appendToField(@intCast(astgen.scratch.items.len - old_scratch_len));
            block_scope.instructions.items.len = block_scope.instructions_top;
        } else if (member.comptime_token) |comptime_token| {
            return astgen.failTok(comptime_token, "comptime field without default initialization value", .{});
        }
    }

    var fields_hash: std.zig.SrcHash = undefined;
    astgen.src_hasher.final(&fields_hash);

    try gz.setStruct(decl_inst, .{
        .src_node = node,
        .layout = layout,
        .captures_len = @intCast(namespace.captures.count()),
        .fields_len = field_count,
        .decls_len = decl_count,
        .has_backing_int = backing_int_ref != .none,
        .known_non_opv = known_non_opv,
        .known_comptime_only = known_comptime_only,
        .any_comptime_fields = any_comptime_fields,
        .any_default_inits = any_default_inits,
        .any_aligned_fields = any_aligned_fields,
        .fields_hash = fields_hash,
        .name_strat = name_strat,
    });

    wip_members.finishBits(bits_per_field);
    const decls_slice = wip_members.declsSlice();
    const fields_slice = wip_members.fieldsSlice();
    const bodies_slice = astgen.scratch.items[bodies_start..];
    try astgen.extra.ensureUnusedCapacity(gpa, backing_int_body_len + 2 +
        decls_slice.len + namespace.captures.count() * 2 + fields_slice.len + bodies_slice.len);
    astgen.extra.appendSliceAssumeCapacity(@ptrCast(namespace.captures.keys()));
    astgen.extra.appendSliceAssumeCapacity(@ptrCast(namespace.captures.values()));
    if (backing_int_ref != .none) {
        astgen.extra.appendAssumeCapacity(@intCast(backing_int_body_len));
        if (backing_int_body_len == 0) {
            astgen.extra.appendAssumeCapacity(@intFromEnum(backing_int_ref));
        } else {
            astgen.extra.appendSliceAssumeCapacity(astgen.scratch.items[scratch_top..][0..backing_int_body_len]);
        }
    }
    astgen.extra.appendSliceAssumeCapacity(decls_slice);
    astgen.extra.appendSliceAssumeCapacity(fields_slice);
    astgen.extra.appendSliceAssumeCapacity(bodies_slice);

    block_scope.unstack();
    return decl_inst.toRef();
}

fn tupleDecl(
    gz: *GenZir,
    scope: *Scope,
    node: Ast.Node.Index,
    container_decl: Ast.full.ContainerDecl,
    layout: std.builtin.Type.ContainerLayout,
    backing_int_node: Ast.Node.OptionalIndex,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const gpa = astgen.gpa;
    const tree = astgen.tree;

    switch (layout) {
        .auto => {},
        .@"extern", .@"packed" => return astgen.failNode(node, "{s} tuples are not supported", .{@tagName(layout)}),
    }

    if (backing_int_node.unwrap()) |arg| {
        return astgen.failNode(arg, "tuple does not support backing integer type", .{});
    }

    // We will use the scratch buffer, starting here, for the field data:
    // 1. fields: { // for every `fields_len` (stored in `extended.small`)
    //        type: Inst.Ref,
    //        init: Inst.Ref, // `.none` for non-`comptime` fields
    //    }
    const fields_start = astgen.scratch.items.len;
    defer astgen.scratch.items.len = fields_start;

    try astgen.scratch.ensureUnusedCapacity(gpa, container_decl.ast.members.len * 2);

    for (container_decl.ast.members) |member_node| {
        const field = tree.fullContainerField(member_node) orelse {
            const tuple_member = for (container_decl.ast.members) |maybe_tuple| switch (tree.nodeTag(maybe_tuple)) {
                .container_field_init,
                .container_field_align,
                .container_field,
                => break maybe_tuple,
                else => {},
            } else unreachable;
            return astgen.failNodeNotes(
                member_node,
                "tuple declarations cannot contain declarations",
                .{},
                &.{try astgen.errNoteNode(tuple_member, "tuple field here", .{})},
            );
        };

        if (!field.ast.tuple_like) {
            return astgen.failTok(field.ast.main_token, "tuple field has a name", .{});
        }

        if (field.ast.align_expr != .none) {
            return astgen.failTok(field.ast.main_token, "tuple field has alignment", .{});
        }

        if (field.ast.value_expr != .none and field.comptime_token == null) {
            return astgen.failTok(field.ast.main_token, "non-comptime tuple field has default initialization value", .{});
        }

        if (field.ast.value_expr == .none and field.comptime_token != null) {
            return astgen.failTok(field.comptime_token.?, "comptime field without default initialization value", .{});
        }

        const field_type_ref = try typeExpr(gz, scope, field.ast.type_expr.unwrap().?);
        astgen.scratch.appendAssumeCapacity(@intFromEnum(field_type_ref));

        if (field.ast.value_expr.unwrap()) |value_expr| {
            const field_init_ref = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = field_type_ref } }, value_expr, .tuple_field_default_value);
            astgen.scratch.appendAssumeCapacity(@intFromEnum(field_init_ref));
        } else {
            astgen.scratch.appendAssumeCapacity(@intFromEnum(Zir.Inst.Ref.none));
        }
    }

    const fields_len = std.math.cast(u16, container_decl.ast.members.len) orelse {
        return astgen.failNode(node, "this compiler implementation only supports 65535 tuple fields", .{});
    };

    const extra_trail = astgen.scratch.items[fields_start..];
    assert(extra_trail.len == fields_len * 2);
    try astgen.extra.ensureUnusedCapacity(gpa, @typeInfo(Zir.Inst.TupleDecl).@"struct".fields.len + extra_trail.len);
    const payload_index = astgen.addExtraAssumeCapacity(Zir.Inst.TupleDecl{
        .src_node = gz.nodeIndexToRelative(node),
    });
    astgen.extra.appendSliceAssumeCapacity(extra_trail);

    return gz.add(.{
        .tag = .extended,
        .data = .{ .extended = .{
            .opcode = .tuple_decl,
            .small = fields_len,
            .operand = payload_index,
        } },
    });
}

fn unionDeclInner(
    gz: *GenZir,
    scope: *Scope,
    node: Ast.Node.Index,
    members: []const Ast.Node.Index,
    layout: std.builtin.Type.ContainerLayout,
    opt_arg_node: Ast.Node.OptionalIndex,
    auto_enum_tok: ?Ast.TokenIndex,
    name_strat: Zir.Inst.NameStrategy,
) InnerError!Zir.Inst.Ref {
    const decl_inst = try gz.reserveInstructionIndex();

    const astgen = gz.astgen;
    const gpa = astgen.gpa;

    var namespace: Scope.Namespace = .{
        .parent = scope,
        .node = node,
        .inst = decl_inst,
        .declaring_gz = gz,
        .maybe_generic = astgen.within_fn,
    };
    defer namespace.deinit(gpa);

    // The union_decl instruction introduces a scope in which the decls of the union
    // are in scope, so that field types, alignments, and default value expressions
    // can refer to decls within the union itself.
    astgen.advanceSourceCursorToNode(node);
    var block_scope: GenZir = .{
        .parent = &namespace.base,
        .decl_node_index = node,
        .decl_line = gz.decl_line,
        .astgen = astgen,
        .is_comptime = true,
        .instructions = gz.instructions,
        .instructions_top = gz.instructions.items.len,
    };
    defer block_scope.unstack();

    const decl_count = try astgen.scanContainer(&namespace, members, .@"union");
    const field_count: u32 = @intCast(members.len - decl_count);

    if (layout != .auto and (auto_enum_tok != null or opt_arg_node != .none)) {
        if (opt_arg_node.unwrap()) |arg_node| {
            return astgen.failNode(arg_node, "{s} union does not support enum tag type", .{@tagName(layout)});
        } else {
            return astgen.failTok(auto_enum_tok.?, "{s} union does not support enum tag type", .{@tagName(layout)});
        }
    }

    const arg_inst: Zir.Inst.Ref = if (opt_arg_node.unwrap()) |arg_node|
        try typeExpr(&block_scope, &namespace.base, arg_node)
    else
        .none;

    const bits_per_field = 4;
    const max_field_size = 4;
    var any_aligned_fields = false;
    var wip_members = try WipMembers.init(gpa, &astgen.scratch, decl_count, field_count, bits_per_field, max_field_size);
    defer wip_members.deinit();

    const old_hasher = astgen.src_hasher;
    defer astgen.src_hasher = old_hasher;
    astgen.src_hasher = std.zig.SrcHasher.init(.{});
    astgen.src_hasher.update(@tagName(layout));
    astgen.src_hasher.update(&.{@intFromBool(auto_enum_tok != null)});
    if (opt_arg_node.unwrap()) |arg_node| {
        astgen.src_hasher.update(astgen.tree.getNodeSource(arg_node));
    }

    for (members) |member_node| {
        var member = switch (try containerMember(&block_scope, &namespace.base, &wip_members, member_node)) {
            .decl => continue,
            .field => |field| field,
        };
        astgen.src_hasher.update(astgen.tree.getNodeSource(member_node));
        member.convertToNonTupleLike(astgen.tree);
        if (member.ast.tuple_like) {
            return astgen.failTok(member.ast.main_token, "union field missing name", .{});
        }
        if (member.comptime_token) |comptime_token| {
            return astgen.failTok(comptime_token, "union fields cannot be marked comptime", .{});
        }

        const field_name = try astgen.identAsString(member.ast.main_token);
        wip_members.appendToField(@intFromEnum(field_name));

        const have_type = member.ast.type_expr != .none;
        const have_align = member.ast.align_expr != .none;
        const have_value = member.ast.value_expr != .none;
        const unused = false;
        wip_members.nextField(bits_per_field, .{ have_type, have_align, have_value, unused });

        if (member.ast.type_expr.unwrap()) |type_expr| {
            const field_type = try typeExpr(&block_scope, &namespace.base, type_expr);
            wip_members.appendToField(@intFromEnum(field_type));
        } else if (arg_inst == .none and auto_enum_tok == null) {
            return astgen.failNode(member_node, "union field missing type", .{});
        }
        if (member.ast.align_expr.unwrap()) |align_expr| {
            const align_inst = try expr(&block_scope, &block_scope.base, coerced_align_ri, align_expr);
            wip_members.appendToField(@intFromEnum(align_inst));
            any_aligned_fields = true;
        }
        if (member.ast.value_expr.unwrap()) |value_expr| {
            if (arg_inst == .none) {
                return astgen.failNodeNotes(
                    node,
                    "explicitly valued tagged union missing integer tag type",
                    .{},
                    &[_]u32{
                        try astgen.errNoteNode(
                            value_expr,
                            "tag value specified here",
                            .{},
                        ),
                    },
                );
            }
            if (auto_enum_tok == null) {
                return astgen.failNodeNotes(
                    node,
                    "explicitly valued tagged union requires inferred enum tag type",
                    .{},
                    &[_]u32{
                        try astgen.errNoteNode(
                            value_expr,
                            "tag value specified here",
                            .{},
                        ),
                    },
                );
            }
            const tag_value = try expr(&block_scope, &block_scope.base, .{ .rl = .{ .ty = arg_inst } }, value_expr);
            wip_members.appendToField(@intFromEnum(tag_value));
        }
    }

    var fields_hash: std.zig.SrcHash = undefined;
    astgen.src_hasher.final(&fields_hash);

    if (!block_scope.isEmpty()) {
        _ = try block_scope.addBreak(.break_inline, decl_inst, .void_value);
    }

    const body = block_scope.instructionsSlice();
    const body_len = astgen.countBodyLenAfterFixups(body);

    try gz.setUnion(decl_inst, .{
        .src_node = node,
        .layout = layout,
        .tag_type = arg_inst,
        .captures_len = @intCast(namespace.captures.count()),
        .body_len = body_len,
        .fields_len = field_count,
        .decls_len = decl_count,
        .auto_enum_tag = auto_enum_tok != null,
        .any_aligned_fields = any_aligned_fields,
        .fields_hash = fields_hash,
        .name_strat = name_strat,
    });

    wip_members.finishBits(bits_per_field);
    const decls_slice = wip_members.declsSlice();
    const fields_slice = wip_members.fieldsSlice();
    try astgen.extra.ensureUnusedCapacity(gpa, namespace.captures.count() * 2 + decls_slice.len + body_len + fields_slice.len);
    astgen.extra.appendSliceAssumeCapacity(@ptrCast(namespace.captures.keys()));
    astgen.extra.appendSliceAssumeCapacity(@ptrCast(namespace.captures.values()));
    astgen.extra.appendSliceAssumeCapacity(decls_slice);
    astgen.appendBodyWithFixups(body);
    astgen.extra.appendSliceAssumeCapacity(fields_slice);

    block_scope.unstack();
    return decl_inst.toRef();
}

fn containerDecl(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    container_decl: Ast.full.ContainerDecl,
    name_strat: Zir.Inst.NameStrategy,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const gpa = astgen.gpa;
    const tree = astgen.tree;

    const prev_fn_block = astgen.fn_block;
    astgen.fn_block = null;
    defer astgen.fn_block = prev_fn_block;

    // We must not create any types until Sema. Here the goal is only to generate
    // ZIR for all the field types, alignments, and default value expressions.

    switch (tree.tokenTag(container_decl.ast.main_token)) {
        .keyword_struct => {
            const layout: std.builtin.Type.ContainerLayout = if (container_decl.layout_token) |t| switch (tree.tokenTag(t)) {
                .keyword_packed => .@"packed",
                .keyword_extern => .@"extern",
                else => unreachable,
            } else .auto;

            const result = try structDeclInner(gz, scope, node, container_decl, layout, container_decl.ast.arg, name_strat);
            return rvalue(gz, ri, result, node);
        },
        .keyword_union => {
            const layout: std.builtin.Type.ContainerLayout = if (container_decl.layout_token) |t| switch (tree.tokenTag(t)) {
                .keyword_packed => .@"packed",
                .keyword_extern => .@"extern",
                else => unreachable,
            } else .auto;

            const result = try unionDeclInner(gz, scope, node, container_decl.ast.members, layout, container_decl.ast.arg, container_decl.ast.enum_token, name_strat);
            return rvalue(gz, ri, result, node);
        },
        .keyword_enum => {
            if (container_decl.layout_token) |t| {
                return astgen.failTok(t, "enums do not support 'packed' or 'extern'; instead provide an explicit integer tag type", .{});
            }
            // Count total fields as well as how many have explicitly provided tag values.
            const counts = blk: {
                var values: usize = 0;
                var total_fields: usize = 0;
                var decls: usize = 0;
                var opt_nonexhaustive_node: Ast.Node.OptionalIndex = .none;
                var nonfinal_nonexhaustive = false;
                for (container_decl.ast.members) |member_node| {
                    var member = tree.fullContainerField(member_node) orelse {
                        decls += 1;
                        continue;
                    };
                    member.convertToNonTupleLike(astgen.tree);
                    if (member.ast.tuple_like) {
                        return astgen.failTok(member.ast.main_token, "enum field missing name", .{});
                    }
                    if (member.comptime_token) |comptime_token| {
                        return astgen.failTok(comptime_token, "enum fields cannot be marked comptime", .{});
                    }
                    if (member.ast.type_expr.unwrap()) |type_expr| {
                        return astgen.failNodeNotes(
                            type_expr,
                            "enum fields do not have types",
                            .{},
                            &[_]u32{
                                try astgen.errNoteNode(
                                    node,
                                    "consider 'union(enum)' here to make it a tagged union",
                                    .{},
                                ),
                            },
                        );
                    }
                    if (member.ast.align_expr.unwrap()) |align_expr| {
                        return astgen.failNode(align_expr, "enum fields cannot be aligned", .{});
                    }

                    const name_token = member.ast.main_token;
                    if (mem.eql(u8, tree.tokenSlice(name_token), "_")) {
                        if (opt_nonexhaustive_node.unwrap()) |nonexhaustive_node| {
                            return astgen.failNodeNotes(
                                member_node,
                                "redundant non-exhaustive enum mark",
                                .{},
                                &[_]u32{
                                    try astgen.errNoteNode(
                                        nonexhaustive_node,
                                        "other mark here",
                                        .{},
                                    ),
                                },
                            );
                        }
                        opt_nonexhaustive_node = member_node.toOptional();
                        if (member.ast.value_expr.unwrap()) |value_expr| {
                            return astgen.failNode(value_expr, "'_' is used to mark an enum as non-exhaustive and cannot be assigned a value", .{});
                        }
                        continue;
                    } else if (opt_nonexhaustive_node != .none) {
                        nonfinal_nonexhaustive = true;
                    }
                    total_fields += 1;
                    if (member.ast.value_expr.unwrap()) |value_expr| {
                        if (container_decl.ast.arg == .none) {
                            return astgen.failNode(value_expr, "value assigned to enum tag with inferred tag type", .{});
                        }
                        values += 1;
                    }
                }
                if (nonfinal_nonexhaustive) {
                    return astgen.failNode(opt_nonexhaustive_node.unwrap().?, "'_' field of non-exhaustive enum must be last", .{});
                }
                break :blk .{
                    .total_fields = total_fields,
                    .values = values,
                    .decls = decls,
                    .nonexhaustive_node = opt_nonexhaustive_node,
                };
            };
            if (counts.nonexhaustive_node != .none and container_decl.ast.arg == .none) {
                const nonexhaustive_node = counts.nonexhaustive_node.unwrap().?;
                return astgen.failNodeNotes(
                    node,
                    "non-exhaustive enum missing integer tag type",
                    .{},
                    &[_]u32{
                        try astgen.errNoteNode(
                            nonexhaustive_node,
                            "marked non-exhaustive here",
                            .{},
                        ),
                    },
                );
            }
            // In this case we must generate ZIR code for the tag values, similar to
            // how structs are handled above.
            const nonexhaustive = counts.nonexhaustive_node != .none;

            const decl_inst = try gz.reserveInstructionIndex();

            var namespace: Scope.Namespace = .{
                .parent = scope,
                .node = node,
                .inst = decl_inst,
                .declaring_gz = gz,
                .maybe_generic = astgen.within_fn,
            };
            defer namespace.deinit(gpa);

            // The enum_decl instruction introduces a scope in which the decls of the enum
            // are in scope, so that tag values can refer to decls within the enum itself.
            astgen.advanceSourceCursorToNode(node);
            var block_scope: GenZir = .{
                .parent = &namespace.base,
                .decl_node_index = node,
                .decl_line = gz.decl_line,
                .astgen = astgen,
                .is_comptime = true,
                .instructions = gz.instructions,
                .instructions_top = gz.instructions.items.len,
            };
            defer block_scope.unstack();

            _ = try astgen.scanContainer(&namespace, container_decl.ast.members, .@"enum");
            namespace.base.tag = .namespace;

            const arg_inst: Zir.Inst.Ref = if (container_decl.ast.arg.unwrap()) |arg|
                try comptimeExpr(&block_scope, &namespace.base, coerced_type_ri, arg, .type)
            else
                .none;

            const bits_per_field = 1;
            const max_field_size = 2;
            var wip_members = try WipMembers.init(gpa, &astgen.scratch, @intCast(counts.decls), @intCast(counts.total_fields), bits_per_field, max_field_size);
            defer wip_members.deinit();

            const old_hasher = astgen.src_hasher;
            defer astgen.src_hasher = old_hasher;
            astgen.src_hasher = std.zig.SrcHasher.init(.{});
            if (container_decl.ast.arg.unwrap()) |arg| {
                astgen.src_hasher.update(tree.getNodeSource(arg));
            }
            astgen.src_hasher.update(&.{@intFromBool(nonexhaustive)});

            for (container_decl.ast.members) |member_node| {
                if (member_node.toOptional() == counts.nonexhaustive_node)
                    continue;
                astgen.src_hasher.update(tree.getNodeSource(member_node));
                var member = switch (try containerMember(&block_scope, &namespace.base, &wip_members, member_node)) {
                    .decl => continue,
                    .field => |field| field,
                };
                member.convertToNonTupleLike(astgen.tree);
                assert(member.comptime_token == null);
                assert(member.ast.type_expr == .none);
                assert(member.ast.align_expr == .none);

                const field_name = try astgen.identAsString(member.ast.main_token);
                wip_members.appendToField(@intFromEnum(field_name));

                const have_value = member.ast.value_expr != .none;
                wip_members.nextField(bits_per_field, .{have_value});

                if (member.ast.value_expr.unwrap()) |value_expr| {
                    if (arg_inst == .none) {
                        return astgen.failNodeNotes(
                            node,
                            "explicitly valued enum missing integer tag type",
                            .{},
                            &[_]u32{
                                try astgen.errNoteNode(
                                    value_expr,
                                    "tag value specified here",
                                    .{},
                                ),
                            },
                        );
                    }
                    const tag_value_inst = try expr(&block_scope, &namespace.base, .{ .rl = .{ .ty = arg_inst } }, value_expr);
                    wip_members.appendToField(@intFromEnum(tag_value_inst));
                }
            }

            if (!block_scope.isEmpty()) {
                _ = try block_scope.addBreak(.break_inline, decl_inst, .void_value);
            }

            var fields_hash: std.zig.SrcHash = undefined;
            astgen.src_hasher.final(&fields_hash);

            const body = block_scope.instructionsSlice();
            const body_len = astgen.countBodyLenAfterFixups(body);

            try gz.setEnum(decl_inst, .{
                .src_node = node,
                .nonexhaustive = nonexhaustive,
                .tag_type = arg_inst,
                .captures_len = @intCast(namespace.captures.count()),
                .body_len = body_len,
                .fields_len = @intCast(counts.total_fields),
                .decls_len = @intCast(counts.decls),
                .fields_hash = fields_hash,
                .name_strat = name_strat,
            });

            wip_members.finishBits(bits_per_field);
            const decls_slice = wip_members.declsSlice();
            const fields_slice = wip_members.fieldsSlice();
            try astgen.extra.ensureUnusedCapacity(gpa, namespace.captures.count() * 2 + decls_slice.len + body_len + fields_slice.len);
            astgen.extra.appendSliceAssumeCapacity(@ptrCast(namespace.captures.keys()));
            astgen.extra.appendSliceAssumeCapacity(@ptrCast(namespace.captures.values()));
            astgen.extra.appendSliceAssumeCapacity(decls_slice);
            astgen.appendBodyWithFixups(body);
            astgen.extra.appendSliceAssumeCapacity(fields_slice);

            block_scope.unstack();
            return rvalue(gz, ri, decl_inst.toRef(), node);
        },
        .keyword_opaque => {
            assert(container_decl.ast.arg == .none);

            const decl_inst = try gz.reserveInstructionIndex();

            var namespace: Scope.Namespace = .{
                .parent = scope,
                .node = node,
                .inst = decl_inst,
                .declaring_gz = gz,
                .maybe_generic = astgen.within_fn,
            };
            defer namespace.deinit(gpa);

            astgen.advanceSourceCursorToNode(node);
            var block_scope: GenZir = .{
                .parent = &namespace.base,
                .decl_node_index = node,
                .decl_line = gz.decl_line,
                .astgen = astgen,
                .is_comptime = true,
                .instructions = gz.instructions,
                .instructions_top = gz.instructions.items.len,
            };
            defer block_scope.unstack();

            const decl_count = try astgen.scanContainer(&namespace, container_decl.ast.members, .@"opaque");

            var wip_members = try WipMembers.init(gpa, &astgen.scratch, decl_count, 0, 0, 0);
            defer wip_members.deinit();

            if (container_decl.layout_token) |layout_token| {
                return astgen.failTok(layout_token, "opaque types do not support 'packed' or 'extern'", .{});
            }

            for (container_decl.ast.members) |member_node| {
                const res = try containerMember(&block_scope, &namespace.base, &wip_members, member_node);
                if (res == .field) {
                    return astgen.failNode(member_node, "opaque types cannot have fields", .{});
                }
            }

            try gz.setOpaque(decl_inst, .{
                .src_node = node,
                .captures_len = @intCast(namespace.captures.count()),
                .decls_len = decl_count,
                .name_strat = name_strat,
            });

            wip_members.finishBits(0);
            const decls_slice = wip_members.declsSlice();
            try astgen.extra.ensureUnusedCapacity(gpa, namespace.captures.count() * 2 + decls_slice.len);
            astgen.extra.appendSliceAssumeCapacity(@ptrCast(namespace.captures.keys()));
            astgen.extra.appendSliceAssumeCapacity(@ptrCast(namespace.captures.values()));
            astgen.extra.appendSliceAssumeCapacity(decls_slice);

            block_scope.unstack();
            return rvalue(gz, ri, decl_inst.toRef(), node);
        },
        else => unreachable,
    }
}

const ContainerMemberResult = union(enum) { decl, field: Ast.full.ContainerField };

fn containerMember(
    gz: *GenZir,
    scope: *Scope,
    wip_members: *WipMembers,
    member_node: Ast.Node.Index,
) InnerError!ContainerMemberResult {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    switch (tree.nodeTag(member_node)) {
        .container_field_init,
        .container_field_align,
        .container_field,
        => return ContainerMemberResult{ .field = tree.fullContainerField(member_node).? },

        .fn_proto,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_decl,
        => {
            var buf: [1]Ast.Node.Index = undefined;
            const full = tree.fullFnProto(&buf, member_node).?;

            const body: Ast.Node.OptionalIndex = if (tree.nodeTag(member_node) == .fn_decl)
                tree.nodeData(member_node).node_and_node[1].toOptional()
            else
                .none;

            const prev_decl_index = wip_members.decl_index;
            astgen.fnDecl(gz, scope, wip_members, member_node, body, full) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.AnalysisFail => {
                    wip_members.decl_index = prev_decl_index;
                    try addFailedDeclaration(
                        wip_members,
                        gz,
                        .@"const",
                        try astgen.identAsString(full.name_token.?),
                        full.ast.proto_node,
                        full.visib_token != null,
                    );
                },
            };
        },

        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => {
            const full = tree.fullVarDecl(member_node).?;
            const prev_decl_index = wip_members.decl_index;
            astgen.globalVarDecl(gz, scope, wip_members, member_node, full) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.AnalysisFail => {
                    wip_members.decl_index = prev_decl_index;
                    try addFailedDeclaration(
                        wip_members,
                        gz,
                        .@"const", // doesn't really matter
                        try astgen.identAsString(full.ast.mut_token + 1),
                        member_node,
                        full.visib_token != null,
                    );
                },
            };
        },

        .@"comptime" => {
            const prev_decl_index = wip_members.decl_index;
            astgen.comptimeDecl(gz, scope, wip_members, member_node) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.AnalysisFail => {
                    wip_members.decl_index = prev_decl_index;
                    try addFailedDeclaration(
                        wip_members,
                        gz,
                        .@"comptime",
                        .empty,
                        member_node,
                        false,
                    );
                },
            };
        },
        .test_decl => {
            const prev_decl_index = wip_members.decl_index;
            // We need to have *some* decl here so that the decl count matches what's expected.
            // Since it doesn't strictly matter *what* this is, let's save ourselves the trouble
            // of duplicating the test name logic, and just assume this is an unnamed test.
            astgen.testDecl(gz, scope, wip_members, member_node) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.AnalysisFail => {
                    wip_members.decl_index = prev_decl_index;
                    try addFailedDeclaration(
                        wip_members,
                        gz,
                        .unnamed_test,
                        .empty,
                        member_node,
                        false,
                    );
                },
            };
        },
        else => unreachable,
    }
    return .decl;
}

fn errorSetDecl(gz: *GenZir, ri: ResultInfo, node: Ast.Node.Index) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const gpa = astgen.gpa;
    const tree = astgen.tree;

    const payload_index = try reserveExtra(astgen, @typeInfo(Zir.Inst.ErrorSetDecl).@"struct".fields.len);
    var fields_len: usize = 0;
    {
        var idents: std.AutoHashMapUnmanaged(Zir.NullTerminatedString, Ast.TokenIndex) = .empty;
        defer idents.deinit(gpa);

        const lbrace, const rbrace = tree.nodeData(node).token_and_token;
        for (lbrace + 1..rbrace) |i| {
            const tok_i: Ast.TokenIndex = @intCast(i);
            switch (tree.tokenTag(tok_i)) {
                .doc_comment, .comma => {},
                .identifier => {
                    const str_index = try astgen.identAsString(tok_i);
                    const gop = try idents.getOrPut(gpa, str_index);
                    if (gop.found_existing) {
                        const name = try gpa.dupe(u8, mem.span(astgen.nullTerminatedString(str_index)));
                        defer gpa.free(name);
                        return astgen.failTokNotes(
                            tok_i,
                            "duplicate error set field '{s}'",
                            .{name},
                            &[_]u32{
                                try astgen.errNoteTok(
                                    gop.value_ptr.*,
                                    "previous declaration here",
                                    .{},
                                ),
                            },
                        );
                    }
                    gop.value_ptr.* = tok_i;

                    try astgen.extra.append(gpa, @intFromEnum(str_index));
                    fields_len += 1;
                },
                else => unreachable,
            }
        }
    }

    setExtra(astgen, payload_index, Zir.Inst.ErrorSetDecl{
        .fields_len = @intCast(fields_len),
    });
    const result = try gz.addPlNodePayloadIndex(.error_set_decl, node, payload_index);
    return rvalue(gz, ri, result, node);
}

fn tryExpr(
    parent_gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    operand_node: Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = parent_gz.astgen;

    const fn_block = astgen.fn_block orelse {
        return astgen.failNode(node, "'try' outside function scope", .{});
    };

    if (parent_gz.any_defer_node.unwrap()) |any_defer_node| {
        return astgen.failNodeNotes(node, "'try' not allowed inside defer expression", .{}, &.{
            try astgen.errNoteNode(
                any_defer_node,
                "defer expression here",
                .{},
            ),
        });
    }

    // Ensure debug line/column information is emitted for this try expression.
    // Then we will save the line/column so that we can emit another one that goes
    // "backwards" because we want to evaluate the operand, but then put the debug
    // info back at the try keyword for error return tracing.
    if (!parent_gz.is_comptime) {
        try emitDbgNode(parent_gz, node);
    }
    const try_lc: LineColumn = .{ astgen.source_line - parent_gz.decl_line, astgen.source_column };

    const operand_rl: ResultInfo.Loc, const block_tag: Zir.Inst.Tag = switch (ri.rl) {
        .ref, .ref_coerced_ty => .{ .ref, .try_ptr },
        else => .{ .none, .@"try" },
    };
    const operand_ri: ResultInfo = .{ .rl = operand_rl, .ctx = .error_handling_expr };
    const operand = operand: {
        // As a special case, we need to detect this form:
        // `try .foo(...)`
        // This is a decl literal form, even though we don't propagate a result type through `try`.
        var buf: [1]Ast.Node.Index = undefined;
        if (astgen.tree.fullCall(&buf, operand_node)) |full_call| {
            const res_ty: Zir.Inst.Ref = try ri.rl.resultType(parent_gz, operand_node) orelse .none;
            break :operand try callExpr(parent_gz, scope, operand_ri, res_ty, operand_node, full_call);
        }

        // This could be a pointer or value depending on the `ri` parameter.
        break :operand try reachableExpr(parent_gz, scope, operand_ri, operand_node, node);
    };

    const try_inst = try parent_gz.makeBlockInst(block_tag, node);
    try parent_gz.instructions.append(astgen.gpa, try_inst);

    var else_scope = parent_gz.makeSubBlock(scope);
    defer else_scope.unstack();

    const err_tag = switch (ri.rl) {
        .ref, .ref_coerced_ty => Zir.Inst.Tag.err_union_code_ptr,
        else => Zir.Inst.Tag.err_union_code,
    };
    const err_code = try else_scope.addUnNode(err_tag, operand, node);
    try genDefers(&else_scope, &fn_block.base, scope, .{ .both = err_code });
    try emitDbgStmt(&else_scope, try_lc);
    _ = try else_scope.addUnNode(.ret_node, err_code, node);

    try else_scope.setTryBody(try_inst, operand);
    const result = try_inst.toRef();
    switch (ri.rl) {
        .ref, .ref_coerced_ty => return result,
        else => return rvalue(parent_gz, ri, result, node),
    }
}

fn orelseCatchExpr(
    parent_gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    cond_op: Zir.Inst.Tag,
    unwrap_op: Zir.Inst.Tag,
    unwrap_code_op: Zir.Inst.Tag,
    payload_token: ?Ast.TokenIndex,
) InnerError!Zir.Inst.Ref {
    const astgen = parent_gz.astgen;
    const tree = astgen.tree;

    const lhs, const rhs = tree.nodeData(node).node_and_node;

    const need_rl = astgen.nodes_need_rl.contains(node);
    const block_ri: ResultInfo = if (need_rl) ri else .{
        .rl = switch (ri.rl) {
            .ptr => .{ .ty = (try ri.rl.resultType(parent_gz, node)).? },
            .inferred_ptr => .none,
            else => ri.rl,
        },
        .ctx = ri.ctx,
    };
    // We need to call `rvalue` to write through to the pointer only if we had a
    // result pointer and aren't forwarding it.
    const LocTag = @typeInfo(ResultInfo.Loc).@"union".tag_type.?;
    const need_result_rvalue = @as(LocTag, block_ri.rl) != @as(LocTag, ri.rl);

    const do_err_trace = astgen.fn_block != null and (cond_op == .is_non_err or cond_op == .is_non_err_ptr);

    var block_scope = parent_gz.makeSubBlock(scope);
    block_scope.setBreakResultInfo(block_ri);
    defer block_scope.unstack();

    const operand_ri: ResultInfo = switch (block_scope.break_result_info.rl) {
        .ref, .ref_coerced_ty => .{ .rl = .ref, .ctx = if (do_err_trace) .error_handling_expr else .none },
        else => .{ .rl = .none, .ctx = if (do_err_trace) .error_handling_expr else .none },
    };
    // This could be a pointer or value depending on the `operand_ri` parameter.
    // We cannot use `block_scope.break_result_info` because that has the bare
    // type, whereas this expression has the optional type. Later we make
    // up for this fact by calling rvalue on the else branch.
    const operand = try reachableExpr(&block_scope, &block_scope.base, operand_ri, lhs, rhs);
    const cond = try block_scope.addUnNode(cond_op, operand, node);
    const condbr = try block_scope.addCondBr(.condbr, node);

    const block = try parent_gz.makeBlockInst(.block, node);
    try block_scope.setBlockBody(block);
    // block_scope unstacked now, can add new instructions to parent_gz
    try parent_gz.instructions.append(astgen.gpa, block);

    var then_scope = block_scope.makeSubBlock(scope);
    defer then_scope.unstack();

    // This could be a pointer or value depending on `unwrap_op`.
    const unwrapped_payload = try then_scope.addUnNode(unwrap_op, operand, node);
    const then_result = switch (ri.rl) {
        .ref, .ref_coerced_ty => unwrapped_payload,
        else => try rvalue(&then_scope, block_scope.break_result_info, unwrapped_payload, node),
    };
    _ = try then_scope.addBreakWithSrcNode(.@"break", block, then_result, node);

    var else_scope = block_scope.makeSubBlock(scope);
    defer else_scope.unstack();

    // We know that the operand (almost certainly) modified the error return trace,
    // so signal to Sema that it should save the new index for restoring later.
    if (do_err_trace and nodeMayAppendToErrorTrace(tree, lhs))
        _ = try else_scope.addSaveErrRetIndex(.always);

    var err_val_scope: Scope.LocalVal = undefined;
    const else_sub_scope = blk: {
        const payload = payload_token orelse break :blk &else_scope.base;
        const err_str = tree.tokenSlice(payload);
        if (mem.eql(u8, err_str, "_")) {
            try astgen.appendErrorTok(payload, "discard of error capture; omit it instead", .{});
            break :blk &else_scope.base;
        }
        const err_name = try astgen.identAsString(payload);

        try astgen.detectLocalShadowing(scope, err_name, payload, err_str, .capture);

        err_val_scope = .{
            .parent = &else_scope.base,
            .gen_zir = &else_scope,
            .name = err_name,
            .inst = try else_scope.addUnNode(unwrap_code_op, operand, node),
            .token_src = payload,
            .id_cat = .capture,
        };
        break :blk &err_val_scope.base;
    };

    const else_result = try fullBodyExpr(&else_scope, else_sub_scope, block_scope.break_result_info, rhs, .allow_branch_hint);
    if (!else_scope.endsWithNoReturn()) {
        // As our last action before the break, "pop" the error trace if needed
        if (do_err_trace)
            try restoreErrRetIndex(&else_scope, .{ .block = block }, block_scope.break_result_info, rhs, else_result);

        _ = try else_scope.addBreakWithSrcNode(.@"break", block, else_result, rhs);
    }
    try checkUsed(parent_gz, &else_scope.base, else_sub_scope);

    try setCondBrPayload(condbr, cond, &then_scope, &else_scope);

    if (need_result_rvalue) {
        return rvalue(parent_gz, ri, block.toRef(), node);
    } else {
        return block.toRef();
    }
}

/// Return whether the identifier names of two tokens are equal. Resolves @""
/// tokens without allocating.
/// OK in theory it could do it without allocating. This implementation
/// allocates when the @"" form is used.
fn tokenIdentEql(astgen: *AstGen, token1: Ast.TokenIndex, token2: Ast.TokenIndex) !bool {
    const ident_name_1 = try astgen.identifierTokenString(token1);
    const ident_name_2 = try astgen.identifierTokenString(token2);
    return mem.eql(u8, ident_name_1, ident_name_2);
}

fn fieldAccess(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    switch (ri.rl) {
        .ref, .ref_coerced_ty => return addFieldAccess(.field_ptr, gz, scope, .{ .rl = .ref }, node),
        else => {
            const access = try addFieldAccess(.field_val, gz, scope, .{ .rl = .none }, node);
            return rvalue(gz, ri, access, node);
        },
    }
}

fn addFieldAccess(
    tag: Zir.Inst.Tag,
    gz: *GenZir,
    scope: *Scope,
    lhs_ri: ResultInfo,
    node: Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const object_node, const field_ident = tree.nodeData(node).node_and_token;
    const str_index = try astgen.identAsString(field_ident);
    const lhs = try expr(gz, scope, lhs_ri, object_node);

    const cursor = maybeAdvanceSourceCursorToMainToken(gz, node);
    try emitDbgStmt(gz, cursor);

    return gz.addPlNode(tag, node, Zir.Inst.Field{
        .lhs = lhs,
        .field_name_start = str_index,
    });
}

fn arrayAccess(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const tree = gz.astgen.tree;
    switch (ri.rl) {
        .ref, .ref_coerced_ty => {
            const lhs_node, const rhs_node = tree.nodeData(node).node_and_node;
            const lhs = try expr(gz, scope, .{ .rl = .ref }, lhs_node);

            const cursor = maybeAdvanceSourceCursorToMainToken(gz, node);

            const rhs = try expr(gz, scope, .{ .rl = .{ .coerced_ty = .usize_type } }, rhs_node);
            try emitDbgStmt(gz, cursor);

            return gz.addPlNode(.elem_ptr_node, node, Zir.Inst.Bin{ .lhs = lhs, .rhs = rhs });
        },
        else => {
            const lhs_node, const rhs_node = tree.nodeData(node).node_and_node;
            const lhs = try expr(gz, scope, .{ .rl = .none }, lhs_node);

            const cursor = maybeAdvanceSourceCursorToMainToken(gz, node);

            const rhs = try expr(gz, scope, .{ .rl = .{ .coerced_ty = .usize_type } }, rhs_node);
            try emitDbgStmt(gz, cursor);

            return rvalue(gz, ri, try gz.addPlNode(.elem_val_node, node, Zir.Inst.Bin{ .lhs = lhs, .rhs = rhs }), node);
        },
    }
}

fn simpleBinOp(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    op_inst_tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const lhs_node, const rhs_node = tree.nodeData(node).node_and_node;

    if (op_inst_tag == .cmp_neq or op_inst_tag == .cmp_eq) {
        const str = if (op_inst_tag == .cmp_eq) "==" else "!=";
        if (tree.nodeTag(lhs_node) == .string_literal or
            tree.nodeTag(rhs_node) == .string_literal)
            return astgen.failNode(node, "cannot compare strings with {s}", .{str});
    }

    const lhs = try reachableExpr(gz, scope, .{ .rl = .none }, lhs_node, node);
    const cursor = switch (op_inst_tag) {
        .add, .sub, .mul, .div, .mod_rem => maybeAdvanceSourceCursorToMainToken(gz, node),
        else => undefined,
    };
    const rhs = try reachableExpr(gz, scope, .{ .rl = .none }, rhs_node, node);

    switch (op_inst_tag) {
        .add, .sub, .mul, .div, .mod_rem => {
            try emitDbgStmt(gz, cursor);
        },
        else => {},
    }
    const result = try gz.addPlNode(op_inst_tag, node, Zir.Inst.Bin{ .lhs = lhs, .rhs = rhs });
    return rvalue(gz, ri, result, node);
}

fn simpleStrTok(
    gz: *GenZir,
    ri: ResultInfo,
    ident_token: Ast.TokenIndex,
    node: Ast.Node.Index,
    op_inst_tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const str_index = try astgen.identAsString(ident_token);
    const result = try gz.addStrTok(op_inst_tag, str_index, ident_token);
    return rvalue(gz, ri, result, node);
}

fn boolBinOp(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    zir_tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const lhs_node, const rhs_node = tree.nodeData(node).node_and_node;
    const lhs = try expr(gz, scope, coerced_bool_ri, lhs_node);
    const bool_br = (try gz.addPlNodePayloadIndex(zir_tag, node, undefined)).toIndex().?;

    var rhs_scope = gz.makeSubBlock(scope);
    defer rhs_scope.unstack();
    const rhs = try fullBodyExpr(&rhs_scope, &rhs_scope.base, coerced_bool_ri, rhs_node, .allow_branch_hint);
    if (!gz.refIsNoReturn(rhs)) {
        _ = try rhs_scope.addBreakWithSrcNode(.break_inline, bool_br, rhs, rhs_node);
    }
    try rhs_scope.setBoolBrBody(bool_br, lhs);

    const block_ref = bool_br.toRef();
    return rvalue(gz, ri, block_ref, node);
}

fn ifExpr(
    parent_gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    if_full: Ast.full.If,
) InnerError!Zir.Inst.Ref {
    const astgen = parent_gz.astgen;
    const tree = astgen.tree;

    const do_err_trace = astgen.fn_block != null and if_full.error_token != null;

    const need_rl = astgen.nodes_need_rl.contains(node);
    const block_ri: ResultInfo = if (need_rl) ri else .{
        .rl = switch (ri.rl) {
            .ptr => .{ .ty = (try ri.rl.resultType(parent_gz, node)).? },
            .inferred_ptr => .none,
            else => ri.rl,
        },
        .ctx = ri.ctx,
    };
    // We need to call `rvalue` to write through to the pointer only if we had a
    // result pointer and aren't forwarding it.
    const LocTag = @typeInfo(ResultInfo.Loc).@"union".tag_type.?;
    const need_result_rvalue = @as(LocTag, block_ri.rl) != @as(LocTag, ri.rl);

    var block_scope = parent_gz.makeSubBlock(scope);
    block_scope.setBreakResultInfo(block_ri);
    defer block_scope.unstack();

    const payload_is_ref = if (if_full.payload_token) |payload_token|
        tree.tokenTag(payload_token) == .asterisk
    else
        false;

    try emitDbgNode(parent_gz, if_full.ast.cond_expr);
    const cond: struct {
        inst: Zir.Inst.Ref,
        bool_bit: Zir.Inst.Ref,
    } = c: {
        if (if_full.error_token) |_| {
            const cond_ri: ResultInfo = .{ .rl = if (payload_is_ref) .ref else .none, .ctx = .error_handling_expr };
            const err_union = try expr(&block_scope, &block_scope.base, cond_ri, if_full.ast.cond_expr);
            const tag: Zir.Inst.Tag = if (payload_is_ref) .is_non_err_ptr else .is_non_err;
            break :c .{
                .inst = err_union,
                .bool_bit = try block_scope.addUnNode(tag, err_union, if_full.ast.cond_expr),
            };
        } else if (if_full.payload_token) |_| {
            const cond_ri: ResultInfo = .{ .rl = if (payload_is_ref) .ref else .none };
            const optional = try expr(&block_scope, &block_scope.base, cond_ri, if_full.ast.cond_expr);
            const tag: Zir.Inst.Tag = if (payload_is_ref) .is_non_null_ptr else .is_non_null;
            break :c .{
                .inst = optional,
                .bool_bit = try block_scope.addUnNode(tag, optional, if_full.ast.cond_expr),
            };
        } else {
            const cond = try expr(&block_scope, &block_scope.base, coerced_bool_ri, if_full.ast.cond_expr);
            break :c .{
                .inst = cond,
                .bool_bit = cond,
            };
        }
    };

    const condbr = try block_scope.addCondBr(.condbr, node);

    const block = try parent_gz.makeBlockInst(.block, node);
    try block_scope.setBlockBody(block);
    // block_scope unstacked now, can add new instructions to parent_gz
    try parent_gz.instructions.append(astgen.gpa, block);

    var then_scope = parent_gz.makeSubBlock(scope);
    defer then_scope.unstack();

    var payload_val_scope: Scope.LocalVal = undefined;

    const then_node = if_full.ast.then_expr;
    const then_sub_scope = s: {
        if (if_full.error_token != null) {
            if (if_full.payload_token) |payload_token| {
                const tag: Zir.Inst.Tag = if (payload_is_ref)
                    .err_union_payload_unsafe_ptr
                else
                    .err_union_payload_unsafe;
                const payload_inst = try then_scope.addUnNode(tag, cond.inst, then_node);
                const token_name_index = payload_token + @intFromBool(payload_is_ref);
                const ident_name = try astgen.identAsString(token_name_index);
                const token_name_str = tree.tokenSlice(token_name_index);
                if (mem.eql(u8, "_", token_name_str)) {
                    if (payload_is_ref) return astgen.failTok(payload_token, "pointer modifier invalid on discard", .{});
                    break :s &then_scope.base;
                }
                try astgen.detectLocalShadowing(&then_scope.base, ident_name, token_name_index, token_name_str, .capture);
                payload_val_scope = .{
                    .parent = &then_scope.base,
                    .gen_zir = &then_scope,
                    .name = ident_name,
                    .inst = payload_inst,
                    .token_src = token_name_index,
                    .id_cat = .capture,
                };
                try then_scope.addDbgVar(.dbg_var_val, ident_name, payload_inst);
                break :s &payload_val_scope.base;
            } else {
                _ = try then_scope.addUnNode(.ensure_err_union_payload_void, cond.inst, node);
                break :s &then_scope.base;
            }
        } else if (if_full.payload_token) |payload_token| {
            const ident_token = payload_token + @intFromBool(payload_is_ref);
            const tag: Zir.Inst.Tag = if (payload_is_ref)
                .optional_payload_unsafe_ptr
            else
                .optional_payload_unsafe;
            const ident_bytes = tree.tokenSlice(ident_token);
            if (mem.eql(u8, "_", ident_bytes)) {
                if (payload_is_ref) return astgen.failTok(payload_token, "pointer modifier invalid on discard", .{});
                break :s &then_scope.base;
            }
            const payload_inst = try then_scope.addUnNode(tag, cond.inst, then_node);
            const ident_name = try astgen.identAsString(ident_token);
            try astgen.detectLocalShadowing(&then_scope.base, ident_name, ident_token, ident_bytes, .capture);
            payload_val_scope = .{
                .parent = &then_scope.base,
                .gen_zir = &then_scope,
                .name = ident_name,
                .inst = payload_inst,
                .token_src = ident_token,
                .id_cat = .capture,
            };
            try then_scope.addDbgVar(.dbg_var_val, ident_name, payload_inst);
            break :s &payload_val_scope.base;
        } else {
            break :s &then_scope.base;
        }
    };

    const then_result = try fullBodyExpr(&then_scope, then_sub_scope, block_scope.break_result_info, then_node, .allow_branch_hint);
    try checkUsed(parent_gz, &then_scope.base, then_sub_scope);
    if (!then_scope.endsWithNoReturn()) {
        _ = try then_scope.addBreakWithSrcNode(.@"break", block, then_result, then_node);
    }

    var else_scope = parent_gz.makeSubBlock(scope);
    defer else_scope.unstack();

    // We know that the operand (almost certainly) modified the error return trace,
    // so signal to Sema that it should save the new index for restoring later.
    if (do_err_trace and nodeMayAppendToErrorTrace(tree, if_full.ast.cond_expr))
        _ = try else_scope.addSaveErrRetIndex(.always);

    if (if_full.ast.else_expr.unwrap()) |else_node| {
        const sub_scope = s: {
            if (if_full.error_token) |error_token| {
                const tag: Zir.Inst.Tag = if (payload_is_ref)
                    .err_union_code_ptr
                else
                    .err_union_code;
                const payload_inst = try else_scope.addUnNode(tag, cond.inst, if_full.ast.cond_expr);
                const ident_name = try astgen.identAsString(error_token);
                const error_token_str = tree.tokenSlice(error_token);
                if (mem.eql(u8, "_", error_token_str))
                    break :s &else_scope.base;
                try astgen.detectLocalShadowing(&else_scope.base, ident_name, error_token, error_token_str, .capture);
                payload_val_scope = .{
                    .parent = &else_scope.base,
                    .gen_zir = &else_scope,
                    .name = ident_name,
                    .inst = payload_inst,
                    .token_src = error_token,
                    .id_cat = .capture,
                };
                try else_scope.addDbgVar(.dbg_var_val, ident_name, payload_inst);
                break :s &payload_val_scope.base;
            } else {
                break :s &else_scope.base;
            }
        };
        const else_result = try fullBodyExpr(&else_scope, sub_scope, block_scope.break_result_info, else_node, .allow_branch_hint);
        if (!else_scope.endsWithNoReturn()) {
            // As our last action before the break, "pop" the error trace if needed
            if (do_err_trace)
                try restoreErrRetIndex(&else_scope, .{ .block = block }, block_scope.break_result_info, else_node, else_result);
            _ = try else_scope.addBreakWithSrcNode(.@"break", block, else_result, else_node);
        }
        try checkUsed(parent_gz, &else_scope.base, sub_scope);
    } else {
        const result = try rvalue(&else_scope, ri, .void_value, node);
        _ = try else_scope.addBreak(.@"break", block, result);
    }

    try setCondBrPayload(condbr, cond.bool_bit, &then_scope, &else_scope);

    if (need_result_rvalue) {
        return rvalue(parent_gz, ri, block.toRef(), node);
    } else {
        return block.toRef();
    }
}

/// Supports `else_scope` stacked on `then_scope`. Unstacks `else_scope` then `then_scope`.
fn setCondBrPayload(
    condbr: Zir.Inst.Index,
    cond: Zir.Inst.Ref,
    then_scope: *GenZir,
    else_scope: *GenZir,
) !void {
    defer then_scope.unstack();
    defer else_scope.unstack();
    const astgen = then_scope.astgen;
    const then_body = then_scope.instructionsSliceUpto(else_scope);
    const else_body = else_scope.instructionsSlice();
    const then_body_len = astgen.countBodyLenAfterFixups(then_body);
    const else_body_len = astgen.countBodyLenAfterFixups(else_body);
    try astgen.extra.ensureUnusedCapacity(
        astgen.gpa,
        @typeInfo(Zir.Inst.CondBr).@"struct".fields.len + then_body_len + else_body_len,
    );

    const zir_datas = astgen.instructions.items(.data);
    zir_datas[@intFromEnum(condbr)].pl_node.payload_index = astgen.addExtraAssumeCapacity(Zir.Inst.CondBr{
        .condition = cond,
        .then_body_len = then_body_len,
        .else_body_len = else_body_len,
    });
    astgen.appendBodyWithFixups(then_body);
    astgen.appendBodyWithFixups(else_body);
}

fn whileExpr(
    parent_gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    while_full: Ast.full.While,
    is_statement: bool,
) InnerError!Zir.Inst.Ref {
    const astgen = parent_gz.astgen;
    const tree = astgen.tree;

    const need_rl = astgen.nodes_need_rl.contains(node);
    const block_ri: ResultInfo = if (need_rl) ri else .{
        .rl = switch (ri.rl) {
            .ptr => .{ .ty = (try ri.rl.resultType(parent_gz, node)).? },
            .inferred_ptr => .none,
            else => ri.rl,
        },
        .ctx = ri.ctx,
    };
    // We need to call `rvalue` to write through to the pointer only if we had a
    // result pointer and aren't forwarding it.
    const LocTag = @typeInfo(ResultInfo.Loc).@"union".tag_type.?;
    const need_result_rvalue = @as(LocTag, block_ri.rl) != @as(LocTag, ri.rl);

    if (while_full.label_token) |label_token| {
        try astgen.checkLabelRedefinition(scope, label_token);
    }

    const is_inline = while_full.inline_token != null;
    if (parent_gz.is_comptime and is_inline) {
        try astgen.appendErrorTok(while_full.inline_token.?, "redundant inline keyword in comptime scope", .{});
    }
    const loop_tag: Zir.Inst.Tag = if (is_inline) .block_inline else .loop;
    const loop_block = try parent_gz.makeBlockInst(loop_tag, node);
    try parent_gz.instructions.append(astgen.gpa, loop_block);

    var loop_scope = parent_gz.makeSubBlock(scope);
    loop_scope.is_inline = is_inline;
    loop_scope.setBreakResultInfo(block_ri);
    defer loop_scope.unstack();

    var cond_scope = parent_gz.makeSubBlock(&loop_scope.base);
    defer cond_scope.unstack();

    const payload_is_ref = if (while_full.payload_token) |payload_token|
        tree.tokenTag(payload_token) == .asterisk
    else
        false;

    try emitDbgNode(parent_gz, while_full.ast.cond_expr);
    const cond: struct {
        inst: Zir.Inst.Ref,
        bool_bit: Zir.Inst.Ref,
    } = c: {
        if (while_full.error_token) |_| {
            const cond_ri: ResultInfo = .{ .rl = if (payload_is_ref) .ref else .none };
            const err_union = try fullBodyExpr(&cond_scope, &cond_scope.base, cond_ri, while_full.ast.cond_expr, .normal);
            const tag: Zir.Inst.Tag = if (payload_is_ref) .is_non_err_ptr else .is_non_err;
            break :c .{
                .inst = err_union,
                .bool_bit = try cond_scope.addUnNode(tag, err_union, while_full.ast.cond_expr),
            };
        } else if (while_full.payload_token) |_| {
            const cond_ri: ResultInfo = .{ .rl = if (payload_is_ref) .ref else .none };
            const optional = try fullBodyExpr(&cond_scope, &cond_scope.base, cond_ri, while_full.ast.cond_expr, .normal);
            const tag: Zir.Inst.Tag = if (payload_is_ref) .is_non_null_ptr else .is_non_null;
            break :c .{
                .inst = optional,
                .bool_bit = try cond_scope.addUnNode(tag, optional, while_full.ast.cond_expr),
            };
        } else {
            const cond = try fullBodyExpr(&cond_scope, &cond_scope.base, coerced_bool_ri, while_full.ast.cond_expr, .normal);
            break :c .{
                .inst = cond,
                .bool_bit = cond,
            };
        }
    };

    const condbr_tag: Zir.Inst.Tag = if (is_inline) .condbr_inline else .condbr;
    const condbr = try cond_scope.addCondBr(condbr_tag, node);
    const block_tag: Zir.Inst.Tag = if (is_inline) .block_inline else .block;
    const cond_block = try loop_scope.makeBlockInst(block_tag, node);
    try cond_scope.setBlockBody(cond_block);
    // cond_scope unstacked now, can add new instructions to loop_scope
    try loop_scope.instructions.append(astgen.gpa, cond_block);

    // make scope now but don't stack on parent_gz until loop_scope
    // gets unstacked after cont_expr is emitted and added below
    var then_scope = parent_gz.makeSubBlock(&cond_scope.base);
    then_scope.instructions_top = GenZir.unstacked_top;
    defer then_scope.unstack();

    var dbg_var_name: Zir.NullTerminatedString = .empty;
    var dbg_var_inst: Zir.Inst.Ref = undefined;
    var opt_payload_inst: Zir.Inst.OptionalIndex = .none;
    var payload_val_scope: Scope.LocalVal = undefined;
    const then_sub_scope = s: {
        if (while_full.error_token != null) {
            if (while_full.payload_token) |payload_token| {
                const tag: Zir.Inst.Tag = if (payload_is_ref)
                    .err_union_payload_unsafe_ptr
                else
                    .err_union_payload_unsafe;
                // will add this instruction to then_scope.instructions below
                const payload_inst = try then_scope.makeUnNode(tag, cond.inst, while_full.ast.cond_expr);
                opt_payload_inst = payload_inst.toOptional();
                const ident_token = payload_token + @intFromBool(payload_is_ref);
                const ident_bytes = tree.tokenSlice(ident_token);
                if (mem.eql(u8, "_", ident_bytes)) {
                    if (payload_is_ref) return astgen.failTok(payload_token, "pointer modifier invalid on discard", .{});
                    break :s &then_scope.base;
                }
                const ident_name = try astgen.identAsString(ident_token);
                try astgen.detectLocalShadowing(&then_scope.base, ident_name, ident_token, ident_bytes, .capture);
                payload_val_scope = .{
                    .parent = &then_scope.base,
                    .gen_zir = &then_scope,
                    .name = ident_name,
                    .inst = payload_inst.toRef(),
                    .token_src = ident_token,
                    .id_cat = .capture,
                };
                dbg_var_name = ident_name;
                dbg_var_inst = payload_inst.toRef();
                break :s &payload_val_scope.base;
            } else {
                _ = try then_scope.addUnNode(.ensure_err_union_payload_void, cond.inst, node);
                break :s &then_scope.base;
            }
        } else if (while_full.payload_token) |payload_token| {
            const tag: Zir.Inst.Tag = if (payload_is_ref)
                .optional_payload_unsafe_ptr
            else
                .optional_payload_unsafe;
            // will add this instruction to then_scope.instructions below
            const payload_inst = try then_scope.makeUnNode(tag, cond.inst, while_full.ast.cond_expr);
            opt_payload_inst = payload_inst.toOptional();
            const ident_token = payload_token + @intFromBool(payload_is_ref);
            const ident_name = try astgen.identAsString(ident_token);
            const ident_bytes = tree.tokenSlice(ident_token);
            if (mem.eql(u8, "_", ident_bytes)) {
                if (payload_is_ref) return astgen.failTok(payload_token, "pointer modifier invalid on discard", .{});
                break :s &then_scope.base;
            }
            try astgen.detectLocalShadowing(&then_scope.base, ident_name, ident_token, ident_bytes, .capture);
            payload_val_scope = .{
                .parent = &then_scope.base,
                .gen_zir = &then_scope,
                .name = ident_name,
                .inst = payload_inst.toRef(),
                .token_src = ident_token,
                .id_cat = .capture,
            };
            dbg_var_name = ident_name;
            dbg_var_inst = payload_inst.toRef();
            break :s &payload_val_scope.base;
        } else {
            break :s &then_scope.base;
        }
    };

    var continue_scope = parent_gz.makeSubBlock(then_sub_scope);
    continue_scope.instructions_top = GenZir.unstacked_top;
    defer continue_scope.unstack();
    const continue_block = try then_scope.makeBlockInst(block_tag, node);

    const repeat_tag: Zir.Inst.Tag = if (is_inline) .repeat_inline else .repeat;
    _ = try loop_scope.addNode(repeat_tag, node);

    try loop_scope.setBlockBody(loop_block);
    loop_scope.break_block = loop_block.toOptional();
    loop_scope.continue_block = continue_block.toOptional();
    if (while_full.label_token) |label_token| {
        loop_scope.label = .{
            .token = label_token,
            .block_inst = loop_block,
        };
    }

    // done adding instructions to loop_scope, can now stack then_scope
    then_scope.instructions_top = then_scope.instructions.items.len;

    const then_node = while_full.ast.then_expr;
    if (opt_payload_inst.unwrap()) |payload_inst| {
        try then_scope.instructions.append(astgen.gpa, payload_inst);
    }
    if (dbg_var_name != .empty) try then_scope.addDbgVar(.dbg_var_val, dbg_var_name, dbg_var_inst);
    try then_scope.instructions.append(astgen.gpa, continue_block);
    // This code could be improved to avoid emitting the continue expr when there
    // are no jumps to it. This happens when the last statement of a while body is noreturn
    // and there are no `continue` statements.
    // Tracking issue: https://github.com/ziglang/zig/issues/9185
    if (while_full.ast.cont_expr.unwrap()) |cont_expr| {
        _ = try unusedResultExpr(&then_scope, then_sub_scope, cont_expr);
    }

    continue_scope.instructions_top = continue_scope.instructions.items.len;
    {
        try emitDbgNode(&continue_scope, then_node);
        const unused_result = try fullBodyExpr(&continue_scope, &continue_scope.base, .{ .rl = .none }, then_node, .allow_branch_hint);
        _ = try addEnsureResult(&continue_scope, unused_result, then_node);
    }
    try checkUsed(parent_gz, &then_scope.base, then_sub_scope);
    const break_tag: Zir.Inst.Tag = if (is_inline) .break_inline else .@"break";
    if (!continue_scope.endsWithNoReturn()) {
        astgen.advanceSourceCursor(tree.tokenStart(tree.lastToken(then_node)));
        try emitDbgStmt(parent_gz, .{ astgen.source_line - parent_gz.decl_line, astgen.source_column });
        _ = try parent_gz.add(.{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = .dbg_empty_stmt,
                .small = undefined,
                .operand = undefined,
            } },
        });
        _ = try continue_scope.addBreak(break_tag, continue_block, .void_value);
    }
    try continue_scope.setBlockBody(continue_block);
    _ = try then_scope.addBreak(break_tag, cond_block, .void_value);

    var else_scope = parent_gz.makeSubBlock(&cond_scope.base);
    defer else_scope.unstack();

    if (while_full.ast.else_expr.unwrap()) |else_node| {
        const sub_scope = s: {
            if (while_full.error_token) |error_token| {
                const tag: Zir.Inst.Tag = if (payload_is_ref)
                    .err_union_code_ptr
                else
                    .err_union_code;
                const else_payload_inst = try else_scope.addUnNode(tag, cond.inst, while_full.ast.cond_expr);
                const ident_name = try astgen.identAsString(error_token);
                const ident_bytes = tree.tokenSlice(error_token);
                if (mem.eql(u8, ident_bytes, "_"))
                    break :s &else_scope.base;
                try astgen.detectLocalShadowing(&else_scope.base, ident_name, error_token, ident_bytes, .capture);
                payload_val_scope = .{
                    .parent = &else_scope.base,
                    .gen_zir = &else_scope,
                    .name = ident_name,
                    .inst = else_payload_inst,
                    .token_src = error_token,
                    .id_cat = .capture,
                };
                try else_scope.addDbgVar(.dbg_var_val, ident_name, else_payload_inst);
                break :s &payload_val_scope.base;
            } else {
                break :s &else_scope.base;
            }
        };
        // Remove the continue block and break block so that `continue` and `break`
        // control flow apply to outer loops; not this one.
        loop_scope.continue_block = .none;
        loop_scope.break_block = .none;
        const else_result = try fullBodyExpr(&else_scope, sub_scope, loop_scope.break_result_info, else_node, .allow_branch_hint);
        if (is_statement) {
            _ = try addEnsureResult(&else_scope, else_result, else_node);
        }

        try checkUsed(parent_gz, &else_scope.base, sub_scope);
        if (!else_scope.endsWithNoReturn()) {
            _ = try else_scope.addBreakWithSrcNode(break_tag, loop_block, else_result, else_node);
        }
    } else {
        const result = try rvalue(&else_scope, ri, .void_value, node);
        _ = try else_scope.addBreak(break_tag, loop_block, result);
    }

    if (loop_scope.label) |some| {
        if (!some.used) {
            try astgen.appendErrorTok(some.token, "unused while loop label", .{});
        }
    }

    try setCondBrPayload(condbr, cond.bool_bit, &then_scope, &else_scope);

    const result = if (need_result_rvalue)
        try rvalue(parent_gz, ri, loop_block.toRef(), node)
    else
        loop_block.toRef();

    if (is_statement) {
        _ = try parent_gz.addUnNode(.ensure_result_used, result, node);
    }

    return result;
}

fn forExpr(
    parent_gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    for_full: Ast.full.For,
    is_statement: bool,
) InnerError!Zir.Inst.Ref {
    const astgen = parent_gz.astgen;

    if (for_full.label_token) |label_token| {
        try astgen.checkLabelRedefinition(scope, label_token);
    }

    const need_rl = astgen.nodes_need_rl.contains(node);
    const block_ri: ResultInfo = if (need_rl) ri else .{
        .rl = switch (ri.rl) {
            .ptr => .{ .ty = (try ri.rl.resultType(parent_gz, node)).? },
            .inferred_ptr => .none,
            else => ri.rl,
        },
        .ctx = ri.ctx,
    };
    // We need to call `rvalue` to write through to the pointer only if we had a
    // result pointer and aren't forwarding it.
    const LocTag = @typeInfo(ResultInfo.Loc).@"union".tag_type.?;
    const need_result_rvalue = @as(LocTag, block_ri.rl) != @as(LocTag, ri.rl);

    const is_inline = for_full.inline_token != null;
    if (parent_gz.is_comptime and is_inline) {
        try astgen.appendErrorTok(for_full.inline_token.?, "redundant inline keyword in comptime scope", .{});
    }
    const tree = astgen.tree;
    const gpa = astgen.gpa;

    // For counters, this is the start value; for indexables, this is the base
    // pointer that can be used with elem_ptr and similar instructions.
    // Special value `none` means that this is a counter and its start value is
    // zero, indicating that the main index counter can be used directly.
    const indexables = try gpa.alloc(Zir.Inst.Ref, for_full.ast.inputs.len);
    defer gpa.free(indexables);
    // elements of this array can be `none`, indicating no length check.
    const lens = try gpa.alloc([2]Zir.Inst.Ref, for_full.ast.inputs.len);
    defer gpa.free(lens);

    // We will use a single zero-based counter no matter how many indexables there are.
    const index_ptr = blk: {
        const alloc_tag: Zir.Inst.Tag = if (is_inline) .alloc_comptime_mut else .alloc;
        const index_ptr = try parent_gz.addUnNode(alloc_tag, .usize_type, node);
        // initialize to zero
        _ = try parent_gz.addPlNode(.store_node, node, Zir.Inst.Bin{
            .lhs = index_ptr,
            .rhs = .zero_usize,
        });
        break :blk index_ptr;
    };

    var any_len_checks = false;

    {
        var capture_token = for_full.payload_token;
        for (for_full.ast.inputs, indexables, lens) |input, *indexable_ref, *len_refs| {
            const capture_is_ref = tree.tokenTag(capture_token) == .asterisk;
            const ident_tok = capture_token + @intFromBool(capture_is_ref);
            const is_discard = mem.eql(u8, tree.tokenSlice(ident_tok), "_");

            if (is_discard and capture_is_ref) {
                return astgen.failTok(capture_token, "pointer modifier invalid on discard", .{});
            }
            // Skip over the comma, and on to the next capture (or the ending pipe character).
            capture_token = ident_tok + 2;

            try emitDbgNode(parent_gz, input);
            if (tree.nodeTag(input) == .for_range) {
                if (capture_is_ref) {
                    return astgen.failTok(ident_tok, "cannot capture reference to range", .{});
                }
                const start_node, const end_node = tree.nodeData(input).node_and_opt_node;
                const start_val = try expr(parent_gz, scope, .{ .rl = .{ .ty = .usize_type } }, start_node);

                const end_val = if (end_node.unwrap()) |end|
                    try expr(parent_gz, scope, .{ .rl = .{ .ty = .usize_type } }, end)
                else
                    .none;

                if (end_val == .none and is_discard) {
                    try astgen.appendErrorTok(ident_tok, "discard of unbounded counter", .{});
                }

                if (end_val == .none) {
                    len_refs.* = .{ .none, .none };
                } else {
                    any_len_checks = true;
                    len_refs.* = .{ start_val, end_val };
                }

                const start_is_zero = nodeIsTriviallyZero(tree, start_node);
                indexable_ref.* = if (start_is_zero) .none else start_val;
            } else {
                const indexable = try expr(parent_gz, scope, .{ .rl = .none }, input);

                any_len_checks = true;
                indexable_ref.* = indexable;
                len_refs.* = .{ indexable, .none };
            }
        }
    }

    if (!any_len_checks) {
        return astgen.failNode(node, "unbounded for loop", .{});
    }

    // We use a dedicated ZIR instruction to assert the lengths to assist with
    // nicer error reporting as well as fewer ZIR bytes emitted.
    const len: Zir.Inst.Ref = len: {
        const all_lens = @as([*]Zir.Inst.Ref, @ptrCast(lens))[0 .. lens.len * 2];
        const lens_len: u32 = @intCast(all_lens.len);
        try astgen.extra.ensureUnusedCapacity(gpa, @typeInfo(Zir.Inst.MultiOp).@"struct".fields.len + lens_len);
        const len = try parent_gz.addPlNode(.for_len, node, Zir.Inst.MultiOp{
            .operands_len = lens_len,
        });
        appendRefsAssumeCapacity(astgen, all_lens);
        break :len len;
    };

    const loop_tag: Zir.Inst.Tag = if (is_inline) .block_inline else .loop;
    const loop_block = try parent_gz.makeBlockInst(loop_tag, node);
    try parent_gz.instructions.append(gpa, loop_block);

    var loop_scope = parent_gz.makeSubBlock(scope);
    loop_scope.is_inline = is_inline;
    loop_scope.setBreakResultInfo(block_ri);
    defer loop_scope.unstack();

    // We need to finish loop_scope later once we have the deferred refs from then_scope. However, the
    // load must be removed from instructions in the meantime or it appears to be part of parent_gz.
    const index = try loop_scope.addUnNode(.load, index_ptr, node);
    _ = loop_scope.instructions.pop();

    var cond_scope = parent_gz.makeSubBlock(&loop_scope.base);
    defer cond_scope.unstack();

    // Check the condition.
    const cond = try cond_scope.addPlNode(.cmp_lt, node, Zir.Inst.Bin{
        .lhs = index,
        .rhs = len,
    });

    const condbr_tag: Zir.Inst.Tag = if (is_inline) .condbr_inline else .condbr;
    const condbr = try cond_scope.addCondBr(condbr_tag, node);
    const block_tag: Zir.Inst.Tag = if (is_inline) .block_inline else .block;
    const cond_block = try loop_scope.makeBlockInst(block_tag, node);
    try cond_scope.setBlockBody(cond_block);

    loop_scope.break_block = loop_block.toOptional();
    loop_scope.continue_block = cond_block.toOptional();
    if (for_full.label_token) |label_token| {
        loop_scope.label = .{
            .token = label_token,
            .block_inst = loop_block,
        };
    }

    const then_node = for_full.ast.then_expr;
    var then_scope = parent_gz.makeSubBlock(&cond_scope.base);
    defer then_scope.unstack();

    const capture_scopes = try gpa.alloc(Scope.LocalVal, for_full.ast.inputs.len);
    defer gpa.free(capture_scopes);

    const then_sub_scope = blk: {
        var capture_token = for_full.payload_token;
        var capture_sub_scope: *Scope = &then_scope.base;
        for (for_full.ast.inputs, indexables, capture_scopes) |input, indexable_ref, *capture_scope| {
            const capture_is_ref = tree.tokenTag(capture_token) == .asterisk;
            const ident_tok = capture_token + @intFromBool(capture_is_ref);
            const capture_name = tree.tokenSlice(ident_tok);
            // Skip over the comma, and on to the next capture (or the ending pipe character).
            capture_token = ident_tok + 2;

            if (mem.eql(u8, capture_name, "_")) continue;

            const name_str_index = try astgen.identAsString(ident_tok);
            try astgen.detectLocalShadowing(capture_sub_scope, name_str_index, ident_tok, capture_name, .capture);

            const capture_inst = inst: {
                const is_counter = tree.nodeTag(input) == .for_range;

                if (indexable_ref == .none) {
                    // Special case: the main index can be used directly.
                    assert(is_counter);
                    assert(!capture_is_ref);
                    break :inst index;
                }

                // For counters, we add the index variable to the start value; for
                // indexables, we use it as an element index. This is so similar
                // that they can share the same code paths, branching only on the
                // ZIR tag.
                const switch_cond = (@as(u2, @intFromBool(capture_is_ref)) << 1) | @intFromBool(is_counter);
                const tag: Zir.Inst.Tag = switch (switch_cond) {
                    0b00 => .elem_val,
                    0b01 => .add,
                    0b10 => .elem_ptr,
                    0b11 => unreachable, // compile error emitted already
                };
                break :inst try then_scope.addPlNode(tag, input, Zir.Inst.Bin{
                    .lhs = indexable_ref,
                    .rhs = index,
                });
            };

            capture_scope.* = .{
                .parent = capture_sub_scope,
                .gen_zir = &then_scope,
                .name = name_str_index,
                .inst = capture_inst,
                .token_src = ident_tok,
                .id_cat = .capture,
            };

            try then_scope.addDbgVar(.dbg_var_val, name_str_index, capture_inst);
            capture_sub_scope = &capture_scope.base;
        }

        break :blk capture_sub_scope;
    };

    const then_result = try fullBodyExpr(&then_scope, then_sub_scope, .{ .rl = .none }, then_node, .allow_branch_hint);
    _ = try addEnsureResult(&then_scope, then_result, then_node);

    try checkUsed(parent_gz, &then_scope.base, then_sub_scope);

    astgen.advanceSourceCursor(tree.tokenStart(tree.lastToken(then_node)));
    try emitDbgStmt(parent_gz, .{ astgen.source_line - parent_gz.decl_line, astgen.source_column });
    _ = try parent_gz.add(.{
        .tag = .extended,
        .data = .{ .extended = .{
            .opcode = .dbg_empty_stmt,
            .small = undefined,
            .operand = undefined,
        } },
    });

    const break_tag: Zir.Inst.Tag = if (is_inline) .break_inline else .@"break";
    _ = try then_scope.addBreak(break_tag, cond_block, .void_value);

    var else_scope = parent_gz.makeSubBlock(&cond_scope.base);
    defer else_scope.unstack();

    if (for_full.ast.else_expr.unwrap()) |else_node| {
        const sub_scope = &else_scope.base;
        // Remove the continue block and break block so that `continue` and `break`
        // control flow apply to outer loops; not this one.
        loop_scope.continue_block = .none;
        loop_scope.break_block = .none;
        const else_result = try fullBodyExpr(&else_scope, sub_scope, loop_scope.break_result_info, else_node, .allow_branch_hint);
        if (is_statement) {
            _ = try addEnsureResult(&else_scope, else_result, else_node);
        }
        if (!else_scope.endsWithNoReturn()) {
            _ = try else_scope.addBreakWithSrcNode(break_tag, loop_block, else_result, else_node);
        }
    } else {
        const result = try rvalue(&else_scope, ri, .void_value, node);
        _ = try else_scope.addBreak(break_tag, loop_block, result);
    }

    if (loop_scope.label) |some| {
        if (!some.used) {
            try astgen.appendErrorTok(some.token, "unused for loop label", .{});
        }
    }

    try setCondBrPayload(condbr, cond, &then_scope, &else_scope);

    // then_block and else_block unstacked now, can resurrect loop_scope to finally finish it
    {
        loop_scope.instructions_top = loop_scope.instructions.items.len;
        try loop_scope.instructions.appendSlice(gpa, &.{ index.toIndex().?, cond_block });

        // Increment the index variable.
        const index_plus_one = try loop_scope.addPlNode(.add_unsafe, node, Zir.Inst.Bin{
            .lhs = index,
            .rhs = .one_usize,
        });
        _ = try loop_scope.addPlNode(.store_node, node, Zir.Inst.Bin{
            .lhs = index_ptr,
            .rhs = index_plus_one,
        });

        const repeat_tag: Zir.Inst.Tag = if (is_inline) .repeat_inline else .repeat;
        _ = try loop_scope.addNode(repeat_tag, node);

        try loop_scope.setBlockBody(loop_block);
    }

    const result = if (need_result_rvalue)
        try rvalue(parent_gz, ri, loop_block.toRef(), node)
    else
        loop_block.toRef();

    if (is_statement) {
        _ = try parent_gz.addUnNode(.ensure_result_used, result, node);
    }
    return result;
}

fn switchExprErrUnion(
    parent_gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    catch_or_if_node: Ast.Node.Index,
    node_ty: enum { @"catch", @"if" },
) InnerError!Zir.Inst.Ref {
    const astgen = parent_gz.astgen;
    const gpa = astgen.gpa;
    const tree = astgen.tree;

    const if_full = switch (node_ty) {
        .@"catch" => undefined,
        .@"if" => tree.fullIf(catch_or_if_node).?,
    };

    const switch_node, const operand_node, const error_payload = switch (node_ty) {
        .@"catch" => .{
            tree.nodeData(catch_or_if_node).node_and_node[1],
            tree.nodeData(catch_or_if_node).node_and_node[0],
            tree.nodeMainToken(catch_or_if_node) + 2,
        },
        .@"if" => .{
            if_full.ast.else_expr.unwrap().?,
            if_full.ast.cond_expr,
            if_full.error_token.?,
        },
    };
    const switch_full = tree.fullSwitch(switch_node).?;

    const do_err_trace = astgen.fn_block != null;
    const need_rl = astgen.nodes_need_rl.contains(catch_or_if_node);
    const block_ri: ResultInfo = if (need_rl) ri else .{
        .rl = switch (ri.rl) {
            .ptr => .{ .ty = (try ri.rl.resultType(parent_gz, catch_or_if_node)).? },
            .inferred_ptr => .none,
            else => ri.rl,
        },
        .ctx = ri.ctx,
    };

    const payload_is_ref = switch (node_ty) {
        .@"if" => if_full.payload_token != null and tree.tokenTag(if_full.payload_token.?) == .asterisk,
        .@"catch" => ri.rl == .ref or ri.rl == .ref_coerced_ty,
    };

    // We need to call `rvalue` to write through to the pointer only if we had a
    // result pointer and aren't forwarding it.
    const LocTag = @typeInfo(ResultInfo.Loc).@"union".tag_type.?;
    const need_result_rvalue = @as(LocTag, block_ri.rl) != @as(LocTag, ri.rl);
    var scalar_cases_len: u32 = 0;
    var multi_cases_len: u32 = 0;
    var inline_cases_len: u32 = 0;
    var has_else = false;
    var else_node: Ast.Node.OptionalIndex = .none;
    var else_src: ?Ast.TokenIndex = null;
    for (switch_full.ast.cases) |case_node| {
        const case = tree.fullSwitchCase(case_node).?;

        if (case.ast.values.len == 0) {
            const case_src = case.ast.arrow_token - 1;
            if (else_src) |src| {
                return astgen.failTokNotes(
                    case_src,
                    "multiple else prongs in switch expression",
                    .{},
                    &[_]u32{
                        try astgen.errNoteTok(
                            src,
                            "previous else prong here",
                            .{},
                        ),
                    },
                );
            }
            has_else = true;
            else_node = case_node.toOptional();
            else_src = case_src;
            continue;
        } else if (case.ast.values.len == 1 and
            tree.nodeTag(case.ast.values[0]) == .identifier and
            mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(case.ast.values[0])), "_"))
        {
            const case_src = case.ast.arrow_token - 1;
            return astgen.failTokNotes(
                case_src,
                "'_' prong is not allowed when switching on errors",
                .{},
                &[_]u32{
                    try astgen.errNoteTok(
                        case_src,
                        "consider using 'else'",
                        .{},
                    ),
                },
            );
        }

        for (case.ast.values) |val| {
            if (tree.nodeTag(val) == .string_literal)
                return astgen.failNode(val, "cannot switch on strings", .{});
        }

        if (case.ast.values.len == 1 and tree.nodeTag(case.ast.values[0]) != .switch_range) {
            scalar_cases_len += 1;
        } else {
            multi_cases_len += 1;
        }
        if (case.inline_token != null) {
            inline_cases_len += 1;
        }
    }

    const operand_ri: ResultInfo = .{
        .rl = if (payload_is_ref) .ref else .none,
        .ctx = .error_handling_expr,
    };

    astgen.advanceSourceCursorToNode(operand_node);
    const operand_lc: LineColumn = .{ astgen.source_line - parent_gz.decl_line, astgen.source_column };

    const raw_operand = try reachableExpr(parent_gz, scope, operand_ri, operand_node, switch_node);
    const item_ri: ResultInfo = .{ .rl = .none };

    // This contains the data that goes into the `extra` array for the SwitchBlockErrUnion, except
    // the first cases_nodes.len slots are a table that indexes payloads later in the array,
    // with the non-error and else case indices coming first, then scalar_cases_len indexes, then
    // multi_cases_len indexes
    const payloads = &astgen.scratch;
    const scratch_top = astgen.scratch.items.len;
    const case_table_start = scratch_top;
    const scalar_case_table = case_table_start + 1 + @intFromBool(has_else);
    const multi_case_table = scalar_case_table + scalar_cases_len;
    const case_table_end = multi_case_table + multi_cases_len;

    try astgen.scratch.resize(gpa, case_table_end);
    defer astgen.scratch.items.len = scratch_top;

    var block_scope = parent_gz.makeSubBlock(scope);
    // block_scope not used for collecting instructions
    block_scope.instructions_top = GenZir.unstacked_top;
    block_scope.setBreakResultInfo(block_ri);

    // Sema expects a dbg_stmt immediately before switch_block_err_union
    try emitDbgStmtForceCurrentIndex(parent_gz, operand_lc);
    // This gets added to the parent block later, after the item expressions.
    const switch_block = try parent_gz.makeBlockInst(.switch_block_err_union, switch_node);

    // We re-use this same scope for all cases, including the special prong, if any.
    var case_scope = parent_gz.makeSubBlock(&block_scope.base);
    case_scope.instructions_top = GenZir.unstacked_top;

    {
        const body_len_index: u32 = @intCast(payloads.items.len);
        payloads.items[case_table_start] = body_len_index;
        try payloads.resize(gpa, body_len_index + 1); // body_len

        case_scope.instructions_top = parent_gz.instructions.items.len;
        defer case_scope.unstack();

        const unwrap_payload_tag: Zir.Inst.Tag = if (payload_is_ref)
            .err_union_payload_unsafe_ptr
        else
            .err_union_payload_unsafe;

        const unwrapped_payload = try case_scope.addUnNode(
            unwrap_payload_tag,
            raw_operand,
            catch_or_if_node,
        );

        switch (node_ty) {
            .@"catch" => {
                const case_result = switch (ri.rl) {
                    .ref, .ref_coerced_ty => unwrapped_payload,
                    else => try rvalue(
                        &case_scope,
                        block_scope.break_result_info,
                        unwrapped_payload,
                        catch_or_if_node,
                    ),
                };
                _ = try case_scope.addBreakWithSrcNode(
                    .@"break",
                    switch_block,
                    case_result,
                    catch_or_if_node,
                );
            },
            .@"if" => {
                var payload_val_scope: Scope.LocalVal = undefined;

                const then_node = if_full.ast.then_expr;
                const then_sub_scope = s: {
                    assert(if_full.error_token != null);
                    if (if_full.payload_token) |payload_token| {
                        const token_name_index = payload_token + @intFromBool(payload_is_ref);
                        const ident_name = try astgen.identAsString(token_name_index);
                        const token_name_str = tree.tokenSlice(token_name_index);
                        if (mem.eql(u8, "_", token_name_str))
                            break :s &case_scope.base;
                        try astgen.detectLocalShadowing(
                            &case_scope.base,
                            ident_name,
                            token_name_index,
                            token_name_str,
                            .capture,
                        );
                        payload_val_scope = .{
                            .parent = &case_scope.base,
                            .gen_zir = &case_scope,
                            .name = ident_name,
                            .inst = unwrapped_payload,
                            .token_src = token_name_index,
                            .id_cat = .capture,
                        };
                        try case_scope.addDbgVar(.dbg_var_val, ident_name, unwrapped_payload);
                        break :s &payload_val_scope.base;
                    } else {
                        _ = try case_scope.addUnNode(
                            .ensure_err_union_payload_void,
                            raw_operand,
                            catch_or_if_node,
                        );
                        break :s &case_scope.base;
                    }
                };
                const then_result = try expr(
                    &case_scope,
                    then_sub_scope,
                    block_scope.break_result_info,
                    then_node,
                );
                try checkUsed(parent_gz, &case_scope.base, then_sub_scope);
                if (!case_scope.endsWithNoReturn()) {
                    _ = try case_scope.addBreakWithSrcNode(
                        .@"break",
                        switch_block,
                        then_result,
                        then_node,
                    );
                }
            },
        }

        const case_slice = case_scope.instructionsSlice();
        const body_len = astgen.countBodyLenAfterFixupsExtraRefs(case_slice, &.{switch_block});
        try payloads.ensureUnusedCapacity(gpa, body_len);
        const capture: Zir.Inst.SwitchBlock.ProngInfo.Capture = switch (node_ty) {
            .@"catch" => .none,
            .@"if" => if (if_full.payload_token == null)
                .none
            else if (payload_is_ref)
                .by_ref
            else
                .by_val,
        };
        payloads.items[body_len_index] = @bitCast(Zir.Inst.SwitchBlock.ProngInfo{
            .body_len = @intCast(body_len),
            .capture = capture,
            .is_inline = false,
            .has_tag_capture = false,
        });
        appendBodyWithFixupsExtraRefsArrayList(astgen, payloads, case_slice, &.{switch_block});
    }

    const err_name = blk: {
        const err_str = tree.tokenSlice(error_payload);
        if (mem.eql(u8, err_str, "_")) {
            // This is fatal because we already know we're switching on the captured error.
            return astgen.failTok(error_payload, "discard of error capture; omit it instead", .{});
        }
        const err_name = try astgen.identAsString(error_payload);
        try astgen.detectLocalShadowing(scope, err_name, error_payload, err_str, .capture);

        break :blk err_name;
    };

    // allocate a shared dummy instruction for the error capture
    const err_inst = err_inst: {
        const inst: Zir.Inst.Index = @enumFromInt(astgen.instructions.len);
        try astgen.instructions.append(astgen.gpa, .{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = .value_placeholder,
                .small = undefined,
                .operand = undefined,
            } },
        });
        break :err_inst inst;
    };

    // In this pass we generate all the item and prong expressions for error cases.
    var multi_case_index: u32 = 0;
    var scalar_case_index: u32 = 0;
    var any_uses_err_capture = false;
    for (switch_full.ast.cases) |case_node| {
        const case = tree.fullSwitchCase(case_node).?;

        const is_multi_case = case.ast.values.len > 1 or
            (case.ast.values.len == 1 and tree.nodeTag(case.ast.values[0]) == .switch_range);

        var dbg_var_name: Zir.NullTerminatedString = .empty;
        var dbg_var_inst: Zir.Inst.Ref = undefined;
        var err_scope: Scope.LocalVal = undefined;
        var capture_scope: Scope.LocalVal = undefined;

        const sub_scope = blk: {
            err_scope = .{
                .parent = &case_scope.base,
                .gen_zir = &case_scope,
                .name = err_name,
                .inst = err_inst.toRef(),
                .token_src = error_payload,
                .id_cat = .capture,
            };

            const capture_token = case.payload_token orelse break :blk &err_scope.base;
            if (tree.tokenTag(capture_token) != .identifier) {
                return astgen.failTok(capture_token + 1, "error set cannot be captured by reference", .{});
            }

            const capture_slice = tree.tokenSlice(capture_token);
            if (mem.eql(u8, capture_slice, "_")) {
                try astgen.appendErrorTok(capture_token, "discard of error capture; omit it instead", .{});
            }
            const tag_name = try astgen.identAsString(capture_token);
            try astgen.detectLocalShadowing(&case_scope.base, tag_name, capture_token, capture_slice, .capture);

            capture_scope = .{
                .parent = &case_scope.base,
                .gen_zir = &case_scope,
                .name = tag_name,
                .inst = switch_block.toRef(),
                .token_src = capture_token,
                .id_cat = .capture,
            };
            dbg_var_name = tag_name;
            dbg_var_inst = switch_block.toRef();

            err_scope.parent = &capture_scope.base;

            break :blk &err_scope.base;
        };

        const header_index: u32 = @intCast(payloads.items.len);
        const body_len_index = if (is_multi_case) blk: {
            payloads.items[multi_case_table + multi_case_index] = header_index;
            multi_case_index += 1;
            try payloads.resize(gpa, header_index + 3); // items_len, ranges_len, body_len

            // items
            var items_len: u32 = 0;
            for (case.ast.values) |item_node| {
                if (tree.nodeTag(item_node) == .switch_range) continue;
                items_len += 1;

                const item_inst = try comptimeExpr(parent_gz, scope, item_ri, item_node, .switch_item);
                try payloads.append(gpa, @intFromEnum(item_inst));
            }

            // ranges
            var ranges_len: u32 = 0;
            for (case.ast.values) |range| {
                if (tree.nodeTag(range) != .switch_range) continue;
                ranges_len += 1;

                const first_node, const last_node = tree.nodeData(range).node_and_node;
                const first = try comptimeExpr(parent_gz, scope, item_ri, first_node, .switch_item);
                const last = try comptimeExpr(parent_gz, scope, item_ri, last_node, .switch_item);
                try payloads.appendSlice(gpa, &[_]u32{
                    @intFromEnum(first), @intFromEnum(last),
                });
            }

            payloads.items[header_index] = items_len;
            payloads.items[header_index + 1] = ranges_len;
            break :blk header_index + 2;
        } else if (case_node.toOptional() == else_node) blk: {
            payloads.items[case_table_start + 1] = header_index;
            try payloads.resize(gpa, header_index + 1); // body_len
            break :blk header_index;
        } else blk: {
            payloads.items[scalar_case_table + scalar_case_index] = header_index;
            scalar_case_index += 1;
            try payloads.resize(gpa, header_index + 2); // item, body_len
            const item_node = case.ast.values[0];
            const item_inst = try comptimeExpr(parent_gz, scope, item_ri, item_node, .switch_item);
            payloads.items[header_index] = @intFromEnum(item_inst);
            break :blk header_index + 1;
        };

        {
            // temporarily stack case_scope on parent_gz
            case_scope.instructions_top = parent_gz.instructions.items.len;
            defer case_scope.unstack();

            if (do_err_trace and nodeMayAppendToErrorTrace(tree, operand_node))
                _ = try case_scope.addSaveErrRetIndex(.always);

            if (dbg_var_name != .empty) {
                try case_scope.addDbgVar(.dbg_var_val, dbg_var_name, dbg_var_inst);
            }

            const target_expr_node = case.ast.target_expr;
            const case_result = try fullBodyExpr(&case_scope, sub_scope, block_scope.break_result_info, target_expr_node, .allow_branch_hint);
            // check capture_scope, not err_scope to avoid false positive unused error capture
            try checkUsed(parent_gz, &case_scope.base, err_scope.parent);
            const uses_err = err_scope.used != .none or err_scope.discarded != .none;
            if (uses_err) {
                try case_scope.addDbgVar(.dbg_var_val, err_name, err_inst.toRef());
                any_uses_err_capture = true;
            }

            if (!parent_gz.refIsNoReturn(case_result)) {
                if (do_err_trace)
                    try restoreErrRetIndex(
                        &case_scope,
                        .{ .block = switch_block },
                        block_scope.break_result_info,
                        target_expr_node,
                        case_result,
                    );

                _ = try case_scope.addBreakWithSrcNode(.@"break", switch_block, case_result, target_expr_node);
            }

            const case_slice = case_scope.instructionsSlice();
            const extra_insts: []const Zir.Inst.Index = if (uses_err) &.{ switch_block, err_inst } else &.{switch_block};
            const body_len = astgen.countBodyLenAfterFixupsExtraRefs(case_slice, extra_insts);
            try payloads.ensureUnusedCapacity(gpa, body_len);
            payloads.items[body_len_index] = @bitCast(Zir.Inst.SwitchBlock.ProngInfo{
                .body_len = @intCast(body_len),
                .capture = if (case.payload_token != null) .by_val else .none,
                .is_inline = case.inline_token != null,
                .has_tag_capture = false,
            });
            appendBodyWithFixupsExtraRefsArrayList(astgen, payloads, case_slice, extra_insts);
        }
    }
    // Now that the item expressions are generated we can add this.
    try parent_gz.instructions.append(gpa, switch_block);

    try astgen.extra.ensureUnusedCapacity(gpa, @typeInfo(Zir.Inst.SwitchBlockErrUnion).@"struct".fields.len +
        @intFromBool(multi_cases_len != 0) +
        payloads.items.len - case_table_end +
        (case_table_end - case_table_start) * @typeInfo(Zir.Inst.As).@"struct".fields.len);

    const payload_index = astgen.addExtraAssumeCapacity(Zir.Inst.SwitchBlockErrUnion{
        .operand = raw_operand,
        .bits = Zir.Inst.SwitchBlockErrUnion.Bits{
            .has_multi_cases = multi_cases_len != 0,
            .has_else = has_else,
            .scalar_cases_len = @intCast(scalar_cases_len),
            .any_uses_err_capture = any_uses_err_capture,
            .payload_is_ref = payload_is_ref,
        },
        .main_src_node_offset = parent_gz.nodeIndexToRelative(catch_or_if_node),
    });

    if (multi_cases_len != 0) {
        astgen.extra.appendAssumeCapacity(multi_cases_len);
    }

    if (any_uses_err_capture) {
        astgen.extra.appendAssumeCapacity(@intFromEnum(err_inst));
    }

    const zir_datas = astgen.instructions.items(.data);
    zir_datas[@intFromEnum(switch_block)].pl_node.payload_index = payload_index;

    for (payloads.items[case_table_start..case_table_end], 0..) |start_index, i| {
        var body_len_index = start_index;
        var end_index = start_index;
        const table_index = case_table_start + i;
        if (table_index < scalar_case_table) {
            end_index += 1;
        } else if (table_index < multi_case_table) {
            body_len_index += 1;
            end_index += 2;
        } else {
            body_len_index += 2;
            const items_len = payloads.items[start_index];
            const ranges_len = payloads.items[start_index + 1];
            end_index += 3 + items_len + 2 * ranges_len;
        }
        const prong_info: Zir.Inst.SwitchBlock.ProngInfo = @bitCast(payloads.items[body_len_index]);
        end_index += prong_info.body_len;
        astgen.extra.appendSliceAssumeCapacity(payloads.items[start_index..end_index]);
    }

    if (need_result_rvalue) {
        return rvalue(parent_gz, ri, switch_block.toRef(), switch_node);
    } else {
        return switch_block.toRef();
    }
}

fn switchExpr(
    parent_gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    switch_full: Ast.full.Switch,
) InnerError!Zir.Inst.Ref {
    const astgen = parent_gz.astgen;
    const gpa = astgen.gpa;
    const tree = astgen.tree;
    const operand_node = switch_full.ast.condition;
    const case_nodes = switch_full.ast.cases;

    const need_rl = astgen.nodes_need_rl.contains(node);
    const block_ri: ResultInfo = if (need_rl) ri else .{
        .rl = switch (ri.rl) {
            .ptr => .{ .ty = (try ri.rl.resultType(parent_gz, node)).? },
            .inferred_ptr => .none,
            else => ri.rl,
        },
        .ctx = ri.ctx,
    };
    // We need to call `rvalue` to write through to the pointer only if we had a
    // result pointer and aren't forwarding it.
    const LocTag = @typeInfo(ResultInfo.Loc).@"union".tag_type.?;
    const need_result_rvalue = @as(LocTag, block_ri.rl) != @as(LocTag, ri.rl);

    if (switch_full.label_token) |label_token| {
        try astgen.checkLabelRedefinition(scope, label_token);
    }

    // We perform two passes over the AST. This first pass is to collect information
    // for the following variables, make note of the special prong AST node index,
    // and bail out with a compile error if there are multiple special prongs present.
    var any_payload_is_ref = false;
    var any_has_tag_capture = false;
    var any_non_inline_capture = false;
    var scalar_cases_len: u32 = 0;
    var multi_cases_len: u32 = 0;
    var inline_cases_len: u32 = 0;
    var special_prong: Zir.SpecialProng = .none;
    var special_node: Ast.Node.OptionalIndex = .none;
    var else_src: ?Ast.TokenIndex = null;
    var underscore_src: ?Ast.TokenIndex = null;
    for (case_nodes) |case_node| {
        const case = tree.fullSwitchCase(case_node).?;
        if (case.payload_token) |payload_token| {
            const ident = if (tree.tokenTag(payload_token) == .asterisk) blk: {
                any_payload_is_ref = true;
                break :blk payload_token + 1;
            } else payload_token;
            if (tree.tokenTag(ident + 1) == .comma) {
                any_has_tag_capture = true;
            }

            // If the first capture is ignored, then there is no runtime-known
            // capture, as the tag capture must be for an inline prong.
            // This check isn't perfect, because for things like enums, the
            // first prong *is* comptime-known for inline prongs! But such
            // knowledge requires semantic analysis.
            if (!mem.eql(u8, tree.tokenSlice(ident), "_")) {
                any_non_inline_capture = true;
            }
        }
        // Check for else/`_` prong.
        if (case.ast.values.len == 0) {
            const case_src = case.ast.arrow_token - 1;
            if (else_src) |src| {
                return astgen.failTokNotes(
                    case_src,
                    "multiple else prongs in switch expression",
                    .{},
                    &[_]u32{
                        try astgen.errNoteTok(
                            src,
                            "previous else prong here",
                            .{},
                        ),
                    },
                );
            } else if (underscore_src) |some_underscore| {
                return astgen.failNodeNotes(
                    node,
                    "else and '_' prong in switch expression",
                    .{},
                    &[_]u32{
                        try astgen.errNoteTok(
                            case_src,
                            "else prong here",
                            .{},
                        ),
                        try astgen.errNoteTok(
                            some_underscore,
                            "'_' prong here",
                            .{},
                        ),
                    },
                );
            }
            special_node = case_node.toOptional();
            special_prong = .@"else";
            else_src = case_src;
            continue;
        } else if (case.ast.values.len == 1 and
            tree.nodeTag(case.ast.values[0]) == .identifier and
            mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(case.ast.values[0])), "_"))
        {
            const case_src = case.ast.arrow_token - 1;
            if (underscore_src) |src| {
                return astgen.failTokNotes(
                    case_src,
                    "multiple '_' prongs in switch expression",
                    .{},
                    &[_]u32{
                        try astgen.errNoteTok(
                            src,
                            "previous '_' prong here",
                            .{},
                        ),
                    },
                );
            } else if (else_src) |some_else| {
                return astgen.failNodeNotes(
                    node,
                    "else and '_' prong in switch expression",
                    .{},
                    &[_]u32{
                        try astgen.errNoteTok(
                            some_else,
                            "else prong here",
                            .{},
                        ),
                        try astgen.errNoteTok(
                            case_src,
                            "'_' prong here",
                            .{},
                        ),
                    },
                );
            }
            if (case.inline_token != null) {
                return astgen.failTok(case_src, "cannot inline '_' prong", .{});
            }
            special_node = case_node.toOptional();
            special_prong = .under;
            underscore_src = case_src;
            continue;
        }

        for (case.ast.values) |val| {
            if (tree.nodeTag(val) == .string_literal)
                return astgen.failNode(val, "cannot switch on strings", .{});
        }

        if (case.ast.values.len == 1 and tree.nodeTag(case.ast.values[0]) != .switch_range) {
            scalar_cases_len += 1;
        } else {
            multi_cases_len += 1;
        }
        if (case.inline_token != null) {
            inline_cases_len += 1;
        }
    }

    const operand_ri: ResultInfo = .{ .rl = if (any_payload_is_ref) .ref else .none };

    astgen.advanceSourceCursorToNode(operand_node);
    const operand_lc: LineColumn = .{ astgen.source_line - parent_gz.decl_line, astgen.source_column };

    const raw_operand = try expr(parent_gz, scope, operand_ri, operand_node);
    const item_ri: ResultInfo = .{ .rl = .none };

    // If this switch is labeled, it may have `continue`s targeting it, and thus we need the operand type
    // to provide a result type.
    const raw_operand_ty_ref = if (switch_full.label_token != null) t: {
        break :t try parent_gz.addUnNode(.typeof, raw_operand, operand_node);
    } else undefined;

    // This contains the data that goes into the `extra` array for the SwitchBlock/SwitchBlockMulti,
    // except the first cases_nodes.len slots are a table that indexes payloads later in the array, with
    // the special case index coming first, then scalar_case_len indexes, then multi_cases_len indexes
    const payloads = &astgen.scratch;
    const scratch_top = astgen.scratch.items.len;
    const case_table_start = scratch_top;
    const scalar_case_table = case_table_start + @intFromBool(special_prong != .none);
    const multi_case_table = scalar_case_table + scalar_cases_len;
    const case_table_end = multi_case_table + multi_cases_len;
    try astgen.scratch.resize(gpa, case_table_end);
    defer astgen.scratch.items.len = scratch_top;

    var block_scope = parent_gz.makeSubBlock(scope);
    // block_scope not used for collecting instructions
    block_scope.instructions_top = GenZir.unstacked_top;
    block_scope.setBreakResultInfo(block_ri);

    // Sema expects a dbg_stmt immediately before switch_block(_ref)
    try emitDbgStmtForceCurrentIndex(parent_gz, operand_lc);
    // This gets added to the parent block later, after the item expressions.
    const switch_tag: Zir.Inst.Tag = if (any_payload_is_ref) .switch_block_ref else .switch_block;
    const switch_block = try parent_gz.makeBlockInst(switch_tag, node);

    if (switch_full.label_token) |label_token| {
        block_scope.continue_block = switch_block.toOptional();
        block_scope.continue_result_info = .{
            .rl = if (any_payload_is_ref)
                .{ .ref_coerced_ty = raw_operand_ty_ref }
            else
                .{ .coerced_ty = raw_operand_ty_ref },
        };

        block_scope.label = .{
            .token = label_token,
            .block_inst = switch_block,
        };
        // `break` can target this via `label.block_inst`
        // `break_result_info` already set by `setBreakResultInfo`
    }

    // We re-use this same scope for all cases, including the special prong, if any.
    var case_scope = parent_gz.makeSubBlock(&block_scope.base);
    case_scope.instructions_top = GenZir.unstacked_top;

    // If any prong has an inline tag capture, allocate a shared dummy instruction for it
    const tag_inst = if (any_has_tag_capture) tag_inst: {
        const inst: Zir.Inst.Index = @enumFromInt(astgen.instructions.len);
        try astgen.instructions.append(astgen.gpa, .{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = .value_placeholder,
                .small = undefined,
                .operand = undefined,
            } },
        });
        break :tag_inst inst;
    } else undefined;

    // In this pass we generate all the item and prong expressions.
    var multi_case_index: u32 = 0;
    var scalar_case_index: u32 = 0;
    for (case_nodes) |case_node| {
        const case = tree.fullSwitchCase(case_node).?;

        const is_multi_case = case.ast.values.len > 1 or
            (case.ast.values.len == 1 and tree.nodeTag(case.ast.values[0]) == .switch_range);

        var dbg_var_name: Zir.NullTerminatedString = .empty;
        var dbg_var_inst: Zir.Inst.Ref = undefined;
        var dbg_var_tag_name: Zir.NullTerminatedString = .empty;
        var dbg_var_tag_inst: Zir.Inst.Ref = undefined;
        var has_tag_capture = false;
        var capture_val_scope: Scope.LocalVal = undefined;
        var tag_scope: Scope.LocalVal = undefined;

        var capture: Zir.Inst.SwitchBlock.ProngInfo.Capture = .none;

        const sub_scope = blk: {
            const payload_token = case.payload_token orelse break :blk &case_scope.base;
            const capture_is_ref = tree.tokenTag(payload_token) == .asterisk;
            const ident = payload_token + @intFromBool(capture_is_ref);

            capture = if (capture_is_ref) .by_ref else .by_val;

            const ident_slice = tree.tokenSlice(ident);
            var payload_sub_scope: *Scope = undefined;
            if (mem.eql(u8, ident_slice, "_")) {
                if (capture_is_ref) {
                    return astgen.failTok(payload_token, "pointer modifier invalid on discard", .{});
                }
                payload_sub_scope = &case_scope.base;
            } else {
                const capture_name = try astgen.identAsString(ident);
                try astgen.detectLocalShadowing(&case_scope.base, capture_name, ident, ident_slice, .capture);
                capture_val_scope = .{
                    .parent = &case_scope.base,
                    .gen_zir = &case_scope,
                    .name = capture_name,
                    .inst = switch_block.toRef(),
                    .token_src = ident,
                    .id_cat = .capture,
                };
                dbg_var_name = capture_name;
                dbg_var_inst = switch_block.toRef();
                payload_sub_scope = &capture_val_scope.base;
            }

            const tag_token = if (tree.tokenTag(ident + 1) == .comma)
                ident + 2
            else
                break :blk payload_sub_scope;
            const tag_slice = tree.tokenSlice(tag_token);
            if (mem.eql(u8, tag_slice, "_")) {
                try astgen.appendErrorTok(tag_token, "discard of tag capture; omit it instead", .{});
            } else if (case.inline_token == null) {
                return astgen.failTok(tag_token, "tag capture on non-inline prong", .{});
            }
            const tag_name = try astgen.identAsString(tag_token);
            try astgen.detectLocalShadowing(payload_sub_scope, tag_name, tag_token, tag_slice, .@"switch tag capture");

            assert(any_has_tag_capture);
            has_tag_capture = true;

            tag_scope = .{
                .parent = payload_sub_scope,
                .gen_zir = &case_scope,
                .name = tag_name,
                .inst = tag_inst.toRef(),
                .token_src = tag_token,
                .id_cat = .@"switch tag capture",
            };
            dbg_var_tag_name = tag_name;
            dbg_var_tag_inst = tag_inst.toRef();
            break :blk &tag_scope.base;
        };

        const header_index: u32 = @intCast(payloads.items.len);
        const body_len_index = if (is_multi_case) blk: {
            payloads.items[multi_case_table + multi_case_index] = header_index;
            multi_case_index += 1;
            try payloads.resize(gpa, header_index + 3); // items_len, ranges_len, body_len

            // items
            var items_len: u32 = 0;
            for (case.ast.values) |item_node| {
                if (tree.nodeTag(item_node) == .switch_range) continue;
                items_len += 1;

                const item_inst = try comptimeExpr(parent_gz, scope, item_ri, item_node, .switch_item);
                try payloads.append(gpa, @intFromEnum(item_inst));
            }

            // ranges
            var ranges_len: u32 = 0;
            for (case.ast.values) |range| {
                if (tree.nodeTag(range) != .switch_range) continue;
                ranges_len += 1;

                const first_node, const last_node = tree.nodeData(range).node_and_node;
                const first = try comptimeExpr(parent_gz, scope, item_ri, first_node, .switch_item);
                const last = try comptimeExpr(parent_gz, scope, item_ri, last_node, .switch_item);
                try payloads.appendSlice(gpa, &[_]u32{
                    @intFromEnum(first), @intFromEnum(last),
                });
            }

            payloads.items[header_index] = items_len;
            payloads.items[header_index + 1] = ranges_len;
            break :blk header_index + 2;
        } else if (case_node.toOptional() == special_node) blk: {
            payloads.items[case_table_start] = header_index;
            try payloads.resize(gpa, header_index + 1); // body_len
            break :blk header_index;
        } else blk: {
            payloads.items[scalar_case_table + scalar_case_index] = header_index;
            scalar_case_index += 1;
            try payloads.resize(gpa, header_index + 2); // item, body_len
            const item_node = case.ast.values[0];
            const item_inst = try comptimeExpr(parent_gz, scope, item_ri, item_node, .switch_item);
            payloads.items[header_index] = @intFromEnum(item_inst);
            break :blk header_index + 1;
        };

        {
            // temporarily stack case_scope on parent_gz
            case_scope.instructions_top = parent_gz.instructions.items.len;
            defer case_scope.unstack();

            if (dbg_var_name != .empty) {
                try case_scope.addDbgVar(.dbg_var_val, dbg_var_name, dbg_var_inst);
            }
            if (dbg_var_tag_name != .empty) {
                try case_scope.addDbgVar(.dbg_var_val, dbg_var_tag_name, dbg_var_tag_inst);
            }
            const target_expr_node = case.ast.target_expr;
            const case_result = try fullBodyExpr(&case_scope, sub_scope, block_scope.break_result_info, target_expr_node, .allow_branch_hint);
            try checkUsed(parent_gz, &case_scope.base, sub_scope);
            if (!parent_gz.refIsNoReturn(case_result)) {
                _ = try case_scope.addBreakWithSrcNode(.@"break", switch_block, case_result, target_expr_node);
            }

            const case_slice = case_scope.instructionsSlice();
            const extra_insts: []const Zir.Inst.Index = if (has_tag_capture) &.{ switch_block, tag_inst } else &.{switch_block};
            const body_len = astgen.countBodyLenAfterFixupsExtraRefs(case_slice, extra_insts);
            try payloads.ensureUnusedCapacity(gpa, body_len);
            payloads.items[body_len_index] = @bitCast(Zir.Inst.SwitchBlock.ProngInfo{
                .body_len = @intCast(body_len),
                .capture = capture,
                .is_inline = case.inline_token != null,
                .has_tag_capture = has_tag_capture,
            });
            appendBodyWithFixupsExtraRefsArrayList(astgen, payloads, case_slice, extra_insts);
        }
    }

    if (switch_full.label_token) |label_token| if (!block_scope.label.?.used) {
        try astgen.appendErrorTok(label_token, "unused switch label", .{});
    };

    // Now that the item expressions are generated we can add this.
    try parent_gz.instructions.append(gpa, switch_block);

    try astgen.extra.ensureUnusedCapacity(gpa, @typeInfo(Zir.Inst.SwitchBlock).@"struct".fields.len +
        @intFromBool(multi_cases_len != 0) +
        @intFromBool(any_has_tag_capture) +
        payloads.items.len - case_table_end +
        (case_table_end - case_table_start) * @typeInfo(Zir.Inst.As).@"struct".fields.len);

    const payload_index = astgen.addExtraAssumeCapacity(Zir.Inst.SwitchBlock{
        .operand = raw_operand,
        .bits = Zir.Inst.SwitchBlock.Bits{
            .has_multi_cases = multi_cases_len != 0,
            .has_else = special_prong == .@"else",
            .has_under = special_prong == .under,
            .any_has_tag_capture = any_has_tag_capture,
            .any_non_inline_capture = any_non_inline_capture,
            .has_continue = switch_full.label_token != null and block_scope.label.?.used_for_continue,
            .scalar_cases_len = @intCast(scalar_cases_len),
        },
    });

    if (multi_cases_len != 0) {
        astgen.extra.appendAssumeCapacity(multi_cases_len);
    }

    if (any_has_tag_capture) {
        astgen.extra.appendAssumeCapacity(@intFromEnum(tag_inst));
    }

    const zir_datas = astgen.instructions.items(.data);
    zir_datas[@intFromEnum(switch_block)].pl_node.payload_index = payload_index;

    for (payloads.items[case_table_start..case_table_end], 0..) |start_index, i| {
        var body_len_index = start_index;
        var end_index = start_index;
        const table_index = case_table_start + i;
        if (table_index < scalar_case_table) {
            end_index += 1;
        } else if (table_index < multi_case_table) {
            body_len_index += 1;
            end_index += 2;
        } else {
            body_len_index += 2;
            const items_len = payloads.items[start_index];
            const ranges_len = payloads.items[start_index + 1];
            end_index += 3 + items_len + 2 * ranges_len;
        }
        const prong_info: Zir.Inst.SwitchBlock.ProngInfo = @bitCast(payloads.items[body_len_index]);
        end_index += prong_info.body_len;
        astgen.extra.appendSliceAssumeCapacity(payloads.items[start_index..end_index]);
    }

    if (need_result_rvalue) {
        return rvalue(parent_gz, ri, switch_block.toRef(), node);
    } else {
        return switch_block.toRef();
    }
}

fn ret(gz: *GenZir, scope: *Scope, node: Ast.Node.Index) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    if (astgen.fn_block == null) {
        return astgen.failNode(node, "'return' outside function scope", .{});
    }

    if (gz.any_defer_node.unwrap()) |any_defer_node| {
        return astgen.failNodeNotes(node, "cannot return from defer expression", .{}, &.{
            try astgen.errNoteNode(
                any_defer_node,
                "defer expression here",
                .{},
            ),
        });
    }

    // Ensure debug line/column information is emitted for this return expression.
    // Then we will save the line/column so that we can emit another one that goes
    // "backwards" because we want to evaluate the operand, but then put the debug
    // info back at the return keyword for error return tracing.
    if (!gz.is_comptime) {
        try emitDbgNode(gz, node);
    }
    const ret_lc: LineColumn = .{ astgen.source_line - gz.decl_line, astgen.source_column };

    const defer_outer = &astgen.fn_block.?.base;

    const operand_node = tree.nodeData(node).opt_node.unwrap() orelse {
        // Returning a void value; skip error defers.
        try genDefers(gz, defer_outer, scope, .normal_only);

        // As our last action before the return, "pop" the error trace if needed
        _ = try gz.addRestoreErrRetIndex(.ret, .always, node);

        _ = try gz.addUnNode(.ret_node, .void_value, node);
        return Zir.Inst.Ref.unreachable_value;
    };

    if (tree.nodeTag(operand_node) == .error_value) {
        // Hot path for `return error.Foo`. This bypasses result location logic as well as logic
        // for detecting whether to add something to the function's inferred error set.
        const ident_token = tree.nodeMainToken(operand_node) + 2;
        const err_name_str_index = try astgen.identAsString(ident_token);
        const defer_counts = countDefers(defer_outer, scope);
        if (!defer_counts.need_err_code) {
            try genDefers(gz, defer_outer, scope, .both_sans_err);
            try emitDbgStmt(gz, ret_lc);
            _ = try gz.addStrTok(.ret_err_value, err_name_str_index, ident_token);
            return Zir.Inst.Ref.unreachable_value;
        }
        const err_code = try gz.addStrTok(.ret_err_value_code, err_name_str_index, ident_token);
        try genDefers(gz, defer_outer, scope, .{ .both = err_code });
        try emitDbgStmt(gz, ret_lc);
        _ = try gz.addUnNode(.ret_node, err_code, node);
        return Zir.Inst.Ref.unreachable_value;
    }

    const ri: ResultInfo = if (astgen.nodes_need_rl.contains(node)) .{
        .rl = .{ .ptr = .{ .inst = try gz.addNode(.ret_ptr, node) } },
        .ctx = .@"return",
    } else .{
        .rl = .{ .coerced_ty = astgen.fn_ret_ty },
        .ctx = .@"return",
    };
    const operand: Zir.Inst.Ref = try nameStratExpr(gz, scope, ri, operand_node, .func) orelse
        try reachableExpr(gz, scope, ri, operand_node, node);

    switch (nodeMayEvalToError(tree, operand_node)) {
        .never => {
            // Returning a value that cannot be an error; skip error defers.
            try genDefers(gz, defer_outer, scope, .normal_only);

            // As our last action before the return, "pop" the error trace if needed
            _ = try gz.addRestoreErrRetIndex(.ret, .always, node);

            try emitDbgStmt(gz, ret_lc);
            try gz.addRet(ri, operand, node);
            return Zir.Inst.Ref.unreachable_value;
        },
        .always => {
            // Value is always an error. Emit both error defers and regular defers.
            const err_code = if (ri.rl == .ptr) try gz.addUnNode(.load, ri.rl.ptr.inst, node) else operand;
            try genDefers(gz, defer_outer, scope, .{ .both = err_code });
            try emitDbgStmt(gz, ret_lc);
            try gz.addRet(ri, operand, node);
            return Zir.Inst.Ref.unreachable_value;
        },
        .maybe => {
            const defer_counts = countDefers(defer_outer, scope);
            if (!defer_counts.have_err) {
                // Only regular defers; no branch needed.
                try genDefers(gz, defer_outer, scope, .normal_only);
                try emitDbgStmt(gz, ret_lc);

                // As our last action before the return, "pop" the error trace if needed
                const result = if (ri.rl == .ptr) try gz.addUnNode(.load, ri.rl.ptr.inst, node) else operand;
                _ = try gz.addRestoreErrRetIndex(.ret, .{ .if_non_error = result }, node);

                try gz.addRet(ri, operand, node);
                return Zir.Inst.Ref.unreachable_value;
            }

            // Emit conditional branch for generating errdefers.
            const result = if (ri.rl == .ptr) try gz.addUnNode(.load, ri.rl.ptr.inst, node) else operand;
            const is_non_err = try gz.addUnNode(.ret_is_non_err, result, node);
            const condbr = try gz.addCondBr(.condbr, node);

            var then_scope = gz.makeSubBlock(scope);
            defer then_scope.unstack();

            try genDefers(&then_scope, defer_outer, scope, .normal_only);

            // As our last action before the return, "pop" the error trace if needed
            _ = try then_scope.addRestoreErrRetIndex(.ret, .always, node);

            try emitDbgStmt(&then_scope, ret_lc);
            try then_scope.addRet(ri, operand, node);

            var else_scope = gz.makeSubBlock(scope);
            defer else_scope.unstack();

            const which_ones: DefersToEmit = if (!defer_counts.need_err_code) .both_sans_err else .{
                .both = try else_scope.addUnNode(.err_union_code, result, node),
            };
            try genDefers(&else_scope, defer_outer, scope, which_ones);
            try emitDbgStmt(&else_scope, ret_lc);
            try else_scope.addRet(ri, operand, node);

            try setCondBrPayload(condbr, is_non_err, &then_scope, &else_scope);

            return Zir.Inst.Ref.unreachable_value;
        },
    }
}

/// Parses the string `buf` as a base 10 integer of type `u16`.
///
/// Unlike std.fmt.parseInt, does not allow the '_' character in `buf`.
fn parseBitCount(buf: []const u8) std.fmt.ParseIntError!u16 {
    if (buf.len == 0) return error.InvalidCharacter;

    var x: u16 = 0;

    for (buf) |c| {
        const digit = switch (c) {
            '0'...'9' => c - '0',
            else => return error.InvalidCharacter,
        };

        if (x != 0) x = try std.math.mul(u16, x, 10);
        x = try std.math.add(u16, x, digit);
    }

    return x;
}

const ComptimeBlockInfo = struct {
    src_node: Ast.Node.Index,
    reason: std.zig.SimpleComptimeReason,
};

fn identifier(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    ident: Ast.Node.Index,
    force_comptime: ?ComptimeBlockInfo,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const ident_token = tree.nodeMainToken(ident);
    const ident_name_raw = tree.tokenSlice(ident_token);
    if (mem.eql(u8, ident_name_raw, "_")) {
        return astgen.failNode(ident, "'_' used as an identifier without @\"_\" syntax", .{});
    }

    // if not @"" syntax, just use raw token slice
    if (ident_name_raw[0] != '@') {
        if (primitive_instrs.get(ident_name_raw)) |zir_const_ref| {
            return rvalue(gz, ri, zir_const_ref, ident);
        }

        if (ident_name_raw.len >= 2) integer: {
            // Keep in sync with logic in `comptimeExpr2`.
            const first_c = ident_name_raw[0];
            if (first_c == 'i' or first_c == 'u') {
                const signedness: std.builtin.Signedness = switch (first_c == 'i') {
                    true => .signed,
                    false => .unsigned,
                };
                if (ident_name_raw.len >= 3 and ident_name_raw[1] == '0') {
                    return astgen.failNode(
                        ident,
                        "primitive integer type '{s}' has leading zero",
                        .{ident_name_raw},
                    );
                }
                const bit_count = parseBitCount(ident_name_raw[1..]) catch |err| switch (err) {
                    error.Overflow => return astgen.failNode(
                        ident,
                        "primitive integer type '{s}' exceeds maximum bit width of 65535",
                        .{ident_name_raw},
                    ),
                    error.InvalidCharacter => break :integer,
                };
                const result = try gz.add(.{
                    .tag = .int_type,
                    .data = .{ .int_type = .{
                        .src_node = gz.nodeIndexToRelative(ident),
                        .signedness = signedness,
                        .bit_count = bit_count,
                    } },
                });
                return rvalue(gz, ri, result, ident);
            }
        }
    }

    // Local variables, including function parameters, and container-level declarations.

    if (force_comptime) |fc| {
        // Mirrors the logic at the end of `comptimeExpr2`.
        const block_inst = try gz.makeBlockInst(.block_comptime, fc.src_node);

        var comptime_gz = gz.makeSubBlock(scope);
        comptime_gz.is_comptime = true;
        defer comptime_gz.unstack();

        const sub_ri: ResultInfo = .{
            .ctx = ri.ctx,
            .rl = .none, // no point providing a result type, it won't change anything
        };
        const block_result = try localVarRef(&comptime_gz, scope, sub_ri, ident, ident_token);
        assert(!comptime_gz.endsWithNoReturn());
        _ = try comptime_gz.addBreak(.break_inline, block_inst, block_result);

        try comptime_gz.setBlockComptimeBody(block_inst, fc.reason);
        try gz.instructions.append(astgen.gpa, block_inst);

        return rvalue(gz, ri, block_inst.toRef(), fc.src_node);
    } else {
        return localVarRef(gz, scope, ri, ident, ident_token);
    }
}

fn localVarRef(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    ident: Ast.Node.Index,
    ident_token: Ast.TokenIndex,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const name_str_index = try astgen.identAsString(ident_token);
    var s = scope;
    var found_already: ?Ast.Node.Index = null; // we have found a decl with the same name already
    var found_needs_tunnel: bool = undefined; // defined when `found_already != null`
    var found_namespaces_out: u32 = undefined; // defined when `found_already != null`

    // The number of namespaces above `gz` we currently are
    var num_namespaces_out: u32 = 0;
    // defined by `num_namespaces_out != 0`
    var capturing_namespace: *Scope.Namespace = undefined;

    while (true) switch (s.tag) {
        .local_val => {
            const local_val = s.cast(Scope.LocalVal).?;

            if (local_val.name == name_str_index) {
                // Locals cannot shadow anything, so we do not need to look for ambiguous
                // references in this case.
                if (ri.rl == .discard and ri.ctx == .assignment) {
                    local_val.discarded = .fromToken(ident_token);
                } else {
                    local_val.used = .fromToken(ident_token);
                }

                if (local_val.is_used_or_discarded) |ptr| ptr.* = true;

                const value_inst = if (num_namespaces_out != 0) try tunnelThroughClosure(
                    gz,
                    ident,
                    num_namespaces_out,
                    .{ .ref = local_val.inst },
                    .{ .token = local_val.token_src },
                    name_str_index,
                ) else local_val.inst;

                return rvalueNoCoercePreRef(gz, ri, value_inst, ident);
            }
            s = local_val.parent;
        },
        .local_ptr => {
            const local_ptr = s.cast(Scope.LocalPtr).?;
            if (local_ptr.name == name_str_index) {
                if (ri.rl == .discard and ri.ctx == .assignment) {
                    local_ptr.discarded = .fromToken(ident_token);
                } else {
                    local_ptr.used = .fromToken(ident_token);
                }

                // Can't close over a runtime variable
                if (num_namespaces_out != 0 and !local_ptr.maybe_comptime and !gz.is_typeof) {
                    const ident_name = try astgen.identifierTokenString(ident_token);
                    return astgen.failNodeNotes(ident, "mutable '{s}' not accessible from here", .{ident_name}, &.{
                        try astgen.errNoteTok(local_ptr.token_src, "declared mutable here", .{}),
                        try astgen.errNoteNode(capturing_namespace.node, "crosses namespace boundary here", .{}),
                    });
                }

                switch (ri.rl) {
                    .ref, .ref_coerced_ty => {
                        const ptr_inst = if (num_namespaces_out != 0) try tunnelThroughClosure(
                            gz,
                            ident,
                            num_namespaces_out,
                            .{ .ref = local_ptr.ptr },
                            .{ .token = local_ptr.token_src },
                            name_str_index,
                        ) else local_ptr.ptr;
                        local_ptr.used_as_lvalue = true;
                        return ptr_inst;
                    },
                    else => {
                        const val_inst = if (num_namespaces_out != 0) try tunnelThroughClosure(
                            gz,
                            ident,
                            num_namespaces_out,
                            .{ .ref_load = local_ptr.ptr },
                            .{ .token = local_ptr.token_src },
                            name_str_index,
                        ) else try gz.addUnNode(.load, local_ptr.ptr, ident);
                        return rvalueNoCoercePreRef(gz, ri, val_inst, ident);
                    },
                }
            }
            s = local_ptr.parent;
        },
        .gen_zir => s = s.cast(GenZir).?.parent,
        .defer_normal, .defer_error => s = s.cast(Scope.Defer).?.parent,
        .namespace => {
            const ns = s.cast(Scope.Namespace).?;
            if (ns.decls.get(name_str_index)) |i| {
                if (found_already) |f| {
                    return astgen.failNodeNotes(ident, "ambiguous reference", .{}, &.{
                        try astgen.errNoteNode(f, "declared here", .{}),
                        try astgen.errNoteNode(i, "also declared here", .{}),
                    });
                }
                // We found a match but must continue looking for ambiguous references to decls.
                found_already = i;
                found_needs_tunnel = ns.maybe_generic;
                found_namespaces_out = num_namespaces_out;
            }
            num_namespaces_out += 1;
            capturing_namespace = ns;
            s = ns.parent;
        },
        .top => break,
    };
    if (found_already == null) {
        const ident_name = try astgen.identifierTokenString(ident_token);
        return astgen.failNode(ident, "use of undeclared identifier '{s}'", .{ident_name});
    }

    // Decl references happen by name rather than ZIR index so that when unrelated
    // decls are modified, ZIR code containing references to them can be unmodified.

    if (found_namespaces_out > 0 and found_needs_tunnel) {
        switch (ri.rl) {
            .ref, .ref_coerced_ty => return tunnelThroughClosure(
                gz,
                ident,
                found_namespaces_out,
                .{ .decl_ref = name_str_index },
                .{ .node = found_already.? },
                name_str_index,
            ),
            else => {
                const result = try tunnelThroughClosure(
                    gz,
                    ident,
                    found_namespaces_out,
                    .{ .decl_val = name_str_index },
                    .{ .node = found_already.? },
                    name_str_index,
                );
                return rvalueNoCoercePreRef(gz, ri, result, ident);
            },
        }
    }

    switch (ri.rl) {
        .ref, .ref_coerced_ty => return gz.addStrTok(.decl_ref, name_str_index, ident_token),
        else => {
            const result = try gz.addStrTok(.decl_val, name_str_index, ident_token);
            return rvalueNoCoercePreRef(gz, ri, result, ident);
        },
    }
}

/// Access a ZIR instruction through closure. May tunnel through arbitrarily
/// many namespaces, adding closure captures as required.
/// Returns the index of the `closure_get` instruction added to `gz`.
fn tunnelThroughClosure(
    gz: *GenZir,
    /// The node which references the value to be captured.
    inner_ref_node: Ast.Node.Index,
    /// The number of namespaces being tunnelled through. At least 1.
    num_tunnels: u32,
    /// The value being captured.
    value: union(enum) {
        ref: Zir.Inst.Ref,
        ref_load: Zir.Inst.Ref,
        decl_val: Zir.NullTerminatedString,
        decl_ref: Zir.NullTerminatedString,
    },
    /// The location of the value's declaration.
    decl_src: union(enum) {
        token: Ast.TokenIndex,
        node: Ast.Node.Index,
    },
    name_str_index: Zir.NullTerminatedString,
) !Zir.Inst.Ref {
    switch (value) {
        .ref => |v| if (v.toIndex() == null) return v, // trivial value; do not need tunnel
        .ref_load => |v| assert(v.toIndex() != null), // there are no constant pointer refs
        .decl_val, .decl_ref => {},
    }

    const astgen = gz.astgen;
    const gpa = astgen.gpa;

    // Otherwise we need a tunnel. First, figure out the path of namespaces we
    // are tunneling through. This is usually only going to be one or two, so
    // use an SFBA to optimize for the common case.
    var sfba = std.heap.stackFallback(@sizeOf(usize) * 2, astgen.arena);
    var intermediate_tunnels = try sfba.get().alloc(*Scope.Namespace, num_tunnels - 1);

    const root_ns = ns: {
        var i: usize = num_tunnels - 1;
        var scope: *Scope = gz.parent;
        while (i > 0) {
            if (scope.cast(Scope.Namespace)) |mid_ns| {
                i -= 1;
                intermediate_tunnels[i] = mid_ns;
            }
            scope = scope.parent().?;
        }
        while (true) {
            if (scope.cast(Scope.Namespace)) |ns| break :ns ns;
            scope = scope.parent().?;
        }
    };

    // Now that we know the scopes we're tunneling through, begin adding
    // captures as required, starting with the outermost namespace.
    const root_capture: Zir.Inst.Capture = .wrap(switch (value) {
        .ref => |v| .{ .instruction = v.toIndex().? },
        .ref_load => |v| .{ .instruction_load = v.toIndex().? },
        .decl_val => |str| .{ .decl_val = str },
        .decl_ref => |str| .{ .decl_ref = str },
    });

    const root_gop = try root_ns.captures.getOrPut(gpa, root_capture);
    root_gop.value_ptr.* = name_str_index;
    var cur_capture_index = std.math.cast(u16, root_gop.index) orelse return astgen.failNodeNotes(
        root_ns.node,
        "this compiler implementation only supports up to 65536 captures per namespace",
        .{},
        &.{
            switch (decl_src) {
                .token => |t| try astgen.errNoteTok(t, "captured value here", .{}),
                .node => |n| try astgen.errNoteNode(n, "captured value here", .{}),
            },
            try astgen.errNoteNode(inner_ref_node, "value used here", .{}),
        },
    );

    for (intermediate_tunnels) |tunnel_ns| {
        const tunnel_gop = try tunnel_ns.captures.getOrPut(gpa, .wrap(.{ .nested = cur_capture_index }));
        tunnel_gop.value_ptr.* = name_str_index;
        cur_capture_index = std.math.cast(u16, tunnel_gop.index) orelse return astgen.failNodeNotes(
            tunnel_ns.node,
            "this compiler implementation only supports up to 65536 captures per namespace",
            .{},
            &.{
                switch (decl_src) {
                    .token => |t| try astgen.errNoteTok(t, "captured value here", .{}),
                    .node => |n| try astgen.errNoteNode(n, "captured value here", .{}),
                },
                try astgen.errNoteNode(inner_ref_node, "value used here", .{}),
            },
        );
    }

    // Incorporate the capture index into the source hash, so that changes in
    // the order of captures cause suitable re-analysis.
    astgen.src_hasher.update(std.mem.asBytes(&cur_capture_index));

    // Add an instruction to get the value from the closure.
    return gz.addExtendedNodeSmall(.closure_get, inner_ref_node, cur_capture_index);
}

fn stringLiteral(
    gz: *GenZir,
    ri: ResultInfo,
    node: Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const str_lit_token = tree.nodeMainToken(node);
    const str = try astgen.strLitAsString(str_lit_token);
    const result = try gz.add(.{
        .tag = .str,
        .data = .{ .str = .{
            .start = str.index,
            .len = str.len,
        } },
    });
    return rvalue(gz, ri, result, node);
}

fn multilineStringLiteral(
    gz: *GenZir,
    ri: ResultInfo,
    node: Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const str = try astgen.strLitNodeAsString(node);
    const result = try gz.add(.{
        .tag = .str,
        .data = .{ .str = .{
            .start = str.index,
            .len = str.len,
        } },
    });
    return rvalue(gz, ri, result, node);
}

fn charLiteral(gz: *GenZir, ri: ResultInfo, node: Ast.Node.Index) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const main_token = tree.nodeMainToken(node);
    const slice = tree.tokenSlice(main_token);

    switch (std.zig.parseCharLiteral(slice)) {
        .success => |codepoint| {
            const result = try gz.addInt(codepoint);
            return rvalue(gz, ri, result, node);
        },
        .failure => |err| return astgen.failWithStrLitError(err, main_token, slice, 0),
    }
}

const Sign = enum { negative, positive };

fn numberLiteral(gz: *GenZir, ri: ResultInfo, node: Ast.Node.Index, source_node: Ast.Node.Index, sign: Sign) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const num_token = tree.nodeMainToken(node);
    const bytes = tree.tokenSlice(num_token);

    const result: Zir.Inst.Ref = switch (std.zig.parseNumberLiteral(bytes)) {
        .int => |num| switch (num) {
            0 => if (sign == .positive) .zero else return astgen.failTokNotes(
                num_token,
                "integer literal '-0' is ambiguous",
                .{},
                &.{
                    try astgen.errNoteTok(num_token, "use '0' for an integer zero", .{}),
                    try astgen.errNoteTok(num_token, "use '-0.0' for a floating-point signed zero", .{}),
                },
            ),
            1 => {
                // Handle the negation here!
                const result: Zir.Inst.Ref = switch (sign) {
                    .positive => .one,
                    .negative => .negative_one,
                };
                return rvalue(gz, ri, result, source_node);
            },
            else => try gz.addInt(num),
        },
        .big_int => |base| big: {
            const gpa = astgen.gpa;
            var big_int = try std.math.big.int.Managed.init(gpa);
            defer big_int.deinit();
            const prefix_offset: usize = if (base == .decimal) 0 else 2;
            big_int.setString(@intFromEnum(base), bytes[prefix_offset..]) catch |err| switch (err) {
                error.InvalidCharacter => unreachable, // caught in `parseNumberLiteral`
                error.InvalidBase => unreachable, // we only pass 16, 8, 2, see above
                error.OutOfMemory => return error.OutOfMemory,
            };

            const limbs = big_int.limbs[0..big_int.len()];
            assert(big_int.isPositive());
            break :big try gz.addIntBig(limbs);
        },
        .float => {
            const unsigned_float_number = std.fmt.parseFloat(f128, bytes) catch |err| switch (err) {
                error.InvalidCharacter => unreachable, // validated by tokenizer
            };
            const float_number = switch (sign) {
                .negative => -unsigned_float_number,
                .positive => unsigned_float_number,
            };
            // If the value fits into a f64 without losing any precision, store it that way.
            @setFloatMode(.strict);
            const smaller_float: f64 = @floatCast(float_number);
            const bigger_again: f128 = smaller_float;
            if (bigger_again == float_number) {
                const result = try gz.addFloat(smaller_float);
                return rvalue(gz, ri, result, source_node);
            }
            // We need to use 128 bits. Break the float into 4 u32 values so we can
            // put it into the `extra` array.
            const int_bits: u128 = @bitCast(float_number);
            const result = try gz.addPlNode(.float128, node, Zir.Inst.Float128{
                .piece0 = @truncate(int_bits),
                .piece1 = @truncate(int_bits >> 32),
                .piece2 = @truncate(int_bits >> 64),
                .piece3 = @truncate(int_bits >> 96),
            });
            return rvalue(gz, ri, result, source_node);
        },
        .failure => |err| return astgen.failWithNumberError(err, num_token, bytes),
    };

    if (sign == .positive) {
        return rvalue(gz, ri, result, source_node);
    } else {
        const negated = try gz.addUnNode(.negate, result, source_node);
        return rvalue(gz, ri, negated, source_node);
    }
}

fn failWithNumberError(astgen: *AstGen, err: std.zig.number_literal.Error, token: Ast.TokenIndex, bytes: []const u8) InnerError {
    const is_float = std.mem.indexOfScalar(u8, bytes, '.') != null;
    switch (err) {
        .leading_zero => if (is_float) {
            return astgen.failTok(token, "number '{s}' has leading zero", .{bytes});
        } else {
            return astgen.failTokNotes(token, "number '{s}' has leading zero", .{bytes}, &.{
                try astgen.errNoteTok(token, "use '0o' prefix for octal literals", .{}),
            });
        },
        .digit_after_base => return astgen.failTok(token, "expected a digit after base prefix", .{}),
        .upper_case_base => |i| return astgen.failOff(token, @intCast(i), "base prefix must be lowercase", .{}),
        .invalid_float_base => |i| return astgen.failOff(token, @intCast(i), "invalid base for float literal", .{}),
        .repeated_underscore => |i| return astgen.failOff(token, @intCast(i), "repeated digit separator", .{}),
        .invalid_underscore_after_special => |i| return astgen.failOff(token, @intCast(i), "expected digit before digit separator", .{}),
        .invalid_digit => |info| return astgen.failOff(token, @intCast(info.i), "invalid digit '{c}' for {s} base", .{ bytes[info.i], @tagName(info.base) }),
        .invalid_digit_exponent => |i| return astgen.failOff(token, @intCast(i), "invalid digit '{c}' in exponent", .{bytes[i]}),
        .duplicate_exponent => |i| return astgen.failOff(token, @intCast(i), "duplicate exponent", .{}),
        .exponent_after_underscore => |i| return astgen.failOff(token, @intCast(i), "expected digit before exponent", .{}),
        .special_after_underscore => |i| return astgen.failOff(token, @intCast(i), "expected digit before '{c}'", .{bytes[i]}),
        .trailing_special => |i| return astgen.failOff(token, @intCast(i), "expected digit after '{c}'", .{bytes[i - 1]}),
        .trailing_underscore => |i| return astgen.failOff(token, @intCast(i), "trailing digit separator", .{}),
        .duplicate_period => unreachable, // Validated by tokenizer
        .invalid_character => unreachable, // Validated by tokenizer
        .invalid_exponent_sign => |i| {
            assert(bytes.len >= 2 and bytes[0] == '0' and bytes[1] == 'x'); // Validated by tokenizer
            return astgen.failOff(token, @intCast(i), "sign '{c}' cannot follow digit '{c}' in hex base", .{ bytes[i], bytes[i - 1] });
        },
        .period_after_exponent => |i| return astgen.failOff(token, @intCast(i), "unexpected period after exponent", .{}),
    }
}

fn asmExpr(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    full: Ast.full.Asm,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const TagAndTmpl = struct { tag: Zir.Inst.Extended, tmpl: Zir.NullTerminatedString };
    const tag_and_tmpl: TagAndTmpl = switch (tree.nodeTag(full.ast.template)) {
        .string_literal => .{
            .tag = .@"asm",
            .tmpl = (try astgen.strLitAsString(tree.nodeMainToken(full.ast.template))).index,
        },
        .multiline_string_literal => .{
            .tag = .@"asm",
            .tmpl = (try astgen.strLitNodeAsString(full.ast.template)).index,
        },
        else => .{
            .tag = .asm_expr,
            .tmpl = @enumFromInt(@intFromEnum(try comptimeExpr(gz, scope, .{ .rl = .none }, full.ast.template, .inline_assembly_code))),
        },
    };

    // See https://github.com/ziglang/zig/issues/215 and related issues discussing
    // possible inline assembly improvements. Until then here is status quo AstGen
    // for assembly syntax. It's used by std lib crypto aesni.zig.
    const is_container_asm = astgen.fn_block == null;
    if (is_container_asm) {
        if (full.volatile_token) |t|
            return astgen.failTok(t, "volatile is meaningless on global assembly", .{});
        if (full.outputs.len != 0 or full.inputs.len != 0 or full.ast.clobbers != .none)
            return astgen.failNode(node, "global assembly cannot have inputs, outputs, or clobbers", .{});
    } else {
        if (full.outputs.len == 0 and full.volatile_token == null) {
            return astgen.failNode(node, "assembly expression with no output must be marked volatile", .{});
        }
    }
    if (full.outputs.len >= 16) {
        return astgen.failNode(full.outputs[16], "too many asm outputs", .{});
    }
    var outputs_buffer: [15]Zir.Inst.Asm.Output = undefined;
    const outputs = outputs_buffer[0..full.outputs.len];

    var output_type_bits: u32 = 0;

    for (full.outputs, 0..) |output_node, i| {
        const symbolic_name = tree.nodeMainToken(output_node);
        const name = try astgen.identAsString(symbolic_name);
        const constraint_token = symbolic_name + 2;
        const constraint = (try astgen.strLitAsString(constraint_token)).index;
        const has_arrow = tree.tokenTag(symbolic_name + 4) == .arrow;
        if (has_arrow) {
            if (output_type_bits != 0) {
                return astgen.failNode(output_node, "inline assembly allows up to one output value", .{});
            }
            output_type_bits |= @as(u32, 1) << @intCast(i);
            const out_type_node = tree.nodeData(output_node).opt_node_and_token[0].unwrap().?;
            const out_type_inst = try typeExpr(gz, scope, out_type_node);
            outputs[i] = .{
                .name = name,
                .constraint = constraint,
                .operand = out_type_inst,
            };
        } else {
            const ident_token = symbolic_name + 4;
            // TODO have a look at #215 and related issues and decide how to
            // handle outputs. Do we want this to be identifiers?
            // Or maybe we want to force this to be expressions with a pointer type.
            outputs[i] = .{
                .name = name,
                .constraint = constraint,
                .operand = try localVarRef(gz, scope, .{ .rl = .ref }, node, ident_token),
            };
        }
    }

    if (full.inputs.len >= 32) {
        return astgen.failNode(full.inputs[32], "too many asm inputs", .{});
    }
    var inputs_buffer: [31]Zir.Inst.Asm.Input = undefined;
    const inputs = inputs_buffer[0..full.inputs.len];

    for (full.inputs, 0..) |input_node, i| {
        const symbolic_name = tree.nodeMainToken(input_node);
        const name = try astgen.identAsString(symbolic_name);
        const constraint_token = symbolic_name + 2;
        const constraint = (try astgen.strLitAsString(constraint_token)).index;
        const operand = try expr(gz, scope, .{ .rl = .none }, tree.nodeData(input_node).node_and_token[0]);
        inputs[i] = .{
            .name = name,
            .constraint = constraint,
            .operand = operand,
        };
    }

    const clobbers: Zir.Inst.Ref = if (full.ast.clobbers.unwrap()) |clobbers_node|
        try comptimeExpr(gz, scope, .{ .rl = .{
            .coerced_ty = try gz.addBuiltinValue(clobbers_node, .clobbers),
        } }, clobbers_node, .clobber)
    else
        .none;

    const result = try gz.addAsm(.{
        .tag = tag_and_tmpl.tag,
        .node = node,
        .asm_source = tag_and_tmpl.tmpl,
        .is_volatile = full.volatile_token != null,
        .output_type_bits = output_type_bits,
        .outputs = outputs,
        .inputs = inputs,
        .clobbers = clobbers,
    });
    return rvalue(gz, ri, result, node);
}

fn as(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    lhs: Ast.Node.Index,
    rhs: Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const dest_type = try typeExpr(gz, scope, lhs);
    const result = try reachableExpr(gz, scope, .{ .rl = .{ .ty = dest_type } }, rhs, node);
    return rvalue(gz, ri, result, node);
}

fn unionInit(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    params: []const Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const union_type = try typeExpr(gz, scope, params[0]);
    const field_name = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = .slice_const_u8_type } }, params[1], .union_field_name);
    const field_type = try gz.addPlNode(.field_type_ref, node, Zir.Inst.FieldTypeRef{
        .container_type = union_type,
        .field_name = field_name,
    });
    const init = try reachableExpr(gz, scope, .{ .rl = .{ .ty = field_type } }, params[2], node);
    const result = try gz.addPlNode(.union_init, node, Zir.Inst.UnionInit{
        .union_type = union_type,
        .init = init,
        .field_name = field_name,
    });
    return rvalue(gz, ri, result, node);
}

fn bitCast(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    operand_node: Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const dest_type = try ri.rl.resultTypeForCast(gz, node, "@bitCast");
    const operand = try reachableExpr(gz, scope, .{ .rl = .none }, operand_node, node);
    const result = try gz.addPlNode(.bitcast, node, Zir.Inst.Bin{
        .lhs = dest_type,
        .rhs = operand,
    });
    return rvalue(gz, ri, result, node);
}

/// Handle one or more nested pointer cast builtins:
/// * @ptrCast
/// * @alignCast
/// * @addrSpaceCast
/// * @constCast
/// * @volatileCast
/// Any sequence of such builtins is treated as a single operation. This allowed
/// for sequences like `@ptrCast(@alignCast(ptr))` to work correctly despite the
/// intermediate result type being unknown.
fn ptrCast(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    root_node: Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const FlagsInt = @typeInfo(Zir.Inst.FullPtrCastFlags).@"struct".backing_integer.?;
    var flags: Zir.Inst.FullPtrCastFlags = .{};

    // Note that all pointer cast builtins have one parameter, so we only need
    // to handle `builtin_call_two`.
    var node = root_node;
    while (true) {
        switch (tree.nodeTag(node)) {
            .builtin_call_two, .builtin_call_two_comma => {},
            .grouped_expression => {
                // Handle the chaining even with redundant parentheses
                node = tree.nodeData(node).node_and_token[0];
                continue;
            },
            else => break,
        }

        var buf: [2]Ast.Node.Index = undefined;
        const args = tree.builtinCallParams(&buf, node).?;
        std.debug.assert(args.len <= 2);

        if (args.len == 0) break; // 0 args

        const builtin_token = tree.nodeMainToken(node);
        const builtin_name = tree.tokenSlice(builtin_token);
        const info = BuiltinFn.list.get(builtin_name) orelse break;
        if (args.len == 1) {
            if (info.param_count != 1) break;

            switch (info.tag) {
                else => break,
                inline .ptr_cast,
                .align_cast,
                .addrspace_cast,
                .const_cast,
                .volatile_cast,
                => |tag| {
                    if (@field(flags, @tagName(tag))) {
                        return astgen.failNode(node, "redundant {s}", .{builtin_name});
                    }
                    @field(flags, @tagName(tag)) = true;
                },
            }

            node = args[0];
        } else {
            std.debug.assert(args.len == 2);
            if (info.param_count != 2) break;

            switch (info.tag) {
                else => break,
                .field_parent_ptr => {
                    if (flags.ptr_cast) break;

                    const flags_int: FlagsInt = @bitCast(flags);
                    const cursor = maybeAdvanceSourceCursorToMainToken(gz, root_node);
                    const parent_ptr_type = try ri.rl.resultTypeForCast(gz, root_node, "@alignCast");
                    const field_name = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = .slice_const_u8_type } }, args[0], .field_name);
                    const field_ptr = try expr(gz, scope, .{ .rl = .none }, args[1]);
                    try emitDbgStmt(gz, cursor);
                    const result = try gz.addExtendedPayloadSmall(.field_parent_ptr, flags_int, Zir.Inst.FieldParentPtr{
                        .src_node = gz.nodeIndexToRelative(node),
                        .parent_ptr_type = parent_ptr_type,
                        .field_name = field_name,
                        .field_ptr = field_ptr,
                    });
                    return rvalue(gz, ri, result, root_node);
                },
            }
        }
    }

    const flags_int: FlagsInt = @bitCast(flags);
    assert(flags_int != 0);

    const ptr_only: Zir.Inst.FullPtrCastFlags = .{ .ptr_cast = true };
    if (flags_int == @as(FlagsInt, @bitCast(ptr_only))) {
        // Special case: simpler representation
        return typeCast(gz, scope, ri, root_node, node, .ptr_cast, "@ptrCast");
    }

    const no_result_ty_flags: Zir.Inst.FullPtrCastFlags = .{
        .const_cast = true,
        .volatile_cast = true,
    };
    if ((flags_int & ~@as(FlagsInt, @bitCast(no_result_ty_flags))) == 0) {
        // Result type not needed
        const cursor = maybeAdvanceSourceCursorToMainToken(gz, root_node);
        const operand = try expr(gz, scope, .{ .rl = .none }, node);
        try emitDbgStmt(gz, cursor);
        const result = try gz.addExtendedPayloadSmall(.ptr_cast_no_dest, flags_int, Zir.Inst.UnNode{
            .node = gz.nodeIndexToRelative(root_node),
            .operand = operand,
        });
        return rvalue(gz, ri, result, root_node);
    }

    // Full cast including result type

    const cursor = maybeAdvanceSourceCursorToMainToken(gz, root_node);
    const result_type = try ri.rl.resultTypeForCast(gz, root_node, flags.needResultTypeBuiltinName());
    const operand = try expr(gz, scope, .{ .rl = .none }, node);
    try emitDbgStmt(gz, cursor);
    const result = try gz.addExtendedPayloadSmall(.ptr_cast_full, flags_int, Zir.Inst.BinNode{
        .node = gz.nodeIndexToRelative(root_node),
        .lhs = result_type,
        .rhs = operand,
    });
    return rvalue(gz, ri, result, root_node);
}

fn typeOf(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    args: []const Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    if (args.len < 1) {
        return astgen.failNode(node, "expected at least 1 argument, found 0", .{});
    }
    const gpa = astgen.gpa;
    if (args.len == 1) {
        const typeof_inst = try gz.makeBlockInst(.typeof_builtin, node);

        var typeof_scope = gz.makeSubBlock(scope);
        typeof_scope.is_comptime = false;
        typeof_scope.is_typeof = true;
        typeof_scope.c_import = false;
        defer typeof_scope.unstack();

        const ty_expr = try reachableExpr(&typeof_scope, &typeof_scope.base, .{ .rl = .none }, args[0], node);
        if (!gz.refIsNoReturn(ty_expr)) {
            _ = try typeof_scope.addBreak(.break_inline, typeof_inst, ty_expr);
        }
        try typeof_scope.setBlockBody(typeof_inst);

        // typeof_scope unstacked now, can add new instructions to gz
        try gz.instructions.append(gpa, typeof_inst);
        return rvalue(gz, ri, typeof_inst.toRef(), node);
    }
    const payload_size: u32 = std.meta.fields(Zir.Inst.TypeOfPeer).len;
    const payload_index = try reserveExtra(astgen, payload_size + args.len);
    const args_index = payload_index + payload_size;

    const typeof_inst = try gz.addExtendedMultiOpPayloadIndex(.typeof_peer, payload_index, args.len);

    var typeof_scope = gz.makeSubBlock(scope);
    typeof_scope.is_comptime = false;

    for (args, 0..) |arg, i| {
        const param_ref = try reachableExpr(&typeof_scope, &typeof_scope.base, .{ .rl = .none }, arg, node);
        astgen.extra.items[args_index + i] = @intFromEnum(param_ref);
    }
    _ = try typeof_scope.addBreak(.break_inline, typeof_inst.toIndex().?, .void_value);

    const body = typeof_scope.instructionsSlice();
    const body_len = astgen.countBodyLenAfterFixups(body);
    astgen.setExtra(payload_index, Zir.Inst.TypeOfPeer{
        .body_len = @intCast(body_len),
        .body_index = @intCast(astgen.extra.items.len),
        .src_node = gz.nodeIndexToRelative(node),
    });
    try astgen.extra.ensureUnusedCapacity(gpa, body_len);
    astgen.appendBodyWithFixups(body);
    typeof_scope.unstack();

    return rvalue(gz, ri, typeof_inst, node);
}

fn minMax(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    args: []const Ast.Node.Index,
    comptime op: enum { min, max },
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    if (args.len < 2) {
        return astgen.failNode(node, "expected at least 2 arguments, found {}", .{args.len});
    }
    if (args.len == 2) {
        const tag: Zir.Inst.Tag = switch (op) {
            .min => .min,
            .max => .max,
        };
        const a = try expr(gz, scope, .{ .rl = .none }, args[0]);
        const b = try expr(gz, scope, .{ .rl = .none }, args[1]);
        const result = try gz.addPlNode(tag, node, Zir.Inst.Bin{
            .lhs = a,
            .rhs = b,
        });
        return rvalue(gz, ri, result, node);
    }
    const payload_index = try addExtra(astgen, Zir.Inst.NodeMultiOp{
        .src_node = gz.nodeIndexToRelative(node),
    });
    var extra_index = try reserveExtra(gz.astgen, args.len);
    for (args) |arg| {
        const arg_ref = try expr(gz, scope, .{ .rl = .none }, arg);
        astgen.extra.items[extra_index] = @intFromEnum(arg_ref);
        extra_index += 1;
    }
    const tag: Zir.Inst.Extended = switch (op) {
        .min => .min_multi,
        .max => .max_multi,
    };
    const result = try gz.addExtendedMultiOpPayloadIndex(tag, payload_index, args.len);
    return rvalue(gz, ri, result, node);
}

fn builtinCall(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    params: []const Ast.Node.Index,
    allow_branch_hint: bool,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const builtin_token = tree.nodeMainToken(node);
    const builtin_name = tree.tokenSlice(builtin_token);

    // We handle the different builtins manually because they have different semantics depending
    // on the function. For example, `@as` and others participate in result location semantics,
    // and `@cImport` creates a special scope that collects a .c source code text buffer.
    // Also, some builtins have a variable number of parameters.

    const info = BuiltinFn.list.get(builtin_name) orelse {
        return astgen.failNode(node, "invalid builtin function: '{s}'", .{
            builtin_name,
        });
    };
    if (info.param_count) |expected| {
        if (expected != params.len) {
            const s = if (expected == 1) "" else "s";
            return astgen.failNode(node, "expected {d} argument{s}, found {d}", .{
                expected, s, params.len,
            });
        }
    }

    // Check function scope-only builtins

    if (astgen.fn_block == null and info.illegal_outside_function)
        return astgen.failNode(node, "'{s}' outside function scope", .{builtin_name});

    switch (info.tag) {
        .branch_hint => {
            if (!allow_branch_hint) {
                return astgen.failNode(node, "'@branchHint' must appear as the first statement in a function or conditional branch", .{});
            }
            const hint_ty = try gz.addBuiltinValue(node, .branch_hint);
            const hint_val = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = hint_ty } }, params[0], .operand_branchHint);
            _ = try gz.addExtendedPayload(.branch_hint, Zir.Inst.UnNode{
                .node = gz.nodeIndexToRelative(node),
                .operand = hint_val,
            });
            return rvalue(gz, ri, .void_value, node);
        },
        .import => {
            const operand_node = params[0];

            if (tree.nodeTag(operand_node) != .string_literal) {
                // Spec reference: https://github.com/ziglang/zig/issues/2206
                return astgen.failNode(operand_node, "@import operand must be a string literal", .{});
            }
            const str_lit_token = tree.nodeMainToken(operand_node);
            const str = try astgen.strLitAsString(str_lit_token);
            const str_slice = astgen.string_bytes.items[@intFromEnum(str.index)..][0..str.len];
            if (mem.indexOfScalar(u8, str_slice, 0) != null) {
                return astgen.failTok(str_lit_token, "import path cannot contain null bytes", .{});
            } else if (str.len == 0) {
                return astgen.failTok(str_lit_token, "import path cannot be empty", .{});
            }
            const res_ty = try ri.rl.resultType(gz, node) orelse .none;
            const payload_index = try addExtra(gz.astgen, Zir.Inst.Import{
                .res_ty = res_ty,
                .path = str.index,
            });
            const result = try gz.add(.{
                .tag = .import,
                .data = .{ .pl_tok = .{
                    .src_tok = gz.tokenIndexToRelative(str_lit_token),
                    .payload_index = payload_index,
                } },
            });
            const gop = try astgen.imports.getOrPut(astgen.gpa, str.index);
            if (!gop.found_existing) {
                gop.value_ptr.* = str_lit_token;
            }
            return rvalue(gz, ri, result, node);
        },
        .compile_log => {
            const payload_index = try addExtra(gz.astgen, Zir.Inst.NodeMultiOp{
                .src_node = gz.nodeIndexToRelative(node),
            });
            var extra_index = try reserveExtra(gz.astgen, params.len);
            for (params) |param| {
                const param_ref = try expr(gz, scope, .{ .rl = .none }, param);
                astgen.extra.items[extra_index] = @intFromEnum(param_ref);
                extra_index += 1;
            }
            const result = try gz.addExtendedMultiOpPayloadIndex(.compile_log, payload_index, params.len);
            return rvalue(gz, ri, result, node);
        },
        .field => {
            if (ri.rl == .ref or ri.rl == .ref_coerced_ty) {
                return gz.addPlNode(.field_ptr_named, node, Zir.Inst.FieldNamed{
                    .lhs = try expr(gz, scope, .{ .rl = .ref }, params[0]),
                    .field_name = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = .slice_const_u8_type } }, params[1], .field_name),
                });
            }
            const result = try gz.addPlNode(.field_val_named, node, Zir.Inst.FieldNamed{
                .lhs = try expr(gz, scope, .{ .rl = .none }, params[0]),
                .field_name = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = .slice_const_u8_type } }, params[1], .field_name),
            });
            return rvalue(gz, ri, result, node);
        },
        .FieldType => {
            const ty_inst = try typeExpr(gz, scope, params[0]);
            const name_inst = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = .slice_const_u8_type } }, params[1], .field_name);
            const result = try gz.addPlNode(.field_type_ref, node, Zir.Inst.FieldTypeRef{
                .container_type = ty_inst,
                .field_name = name_inst,
            });
            return rvalue(gz, ri, result, node);
        },

        // zig fmt: off
        .as         => return as(       gz, scope, ri, node, params[0], params[1]),
        .bit_cast   => return bitCast(  gz, scope, ri, node, params[0]),
        .TypeOf     => return typeOf(   gz, scope, ri, node, params),
        .union_init => return unionInit(gz, scope, ri, node, params),
        .c_import   => return cImport(  gz, scope,     node, params[0]),
        .min        => return minMax(   gz, scope, ri, node, params, .min),
        .max        => return minMax(   gz, scope, ri, node, params, .max),
        // zig fmt: on

        .@"export" => {
            const exported = try expr(gz, scope, .{ .rl = .none }, params[0]);
            const export_options_ty = try gz.addBuiltinValue(node, .export_options);
            const options = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = export_options_ty } }, params[1], .export_options);
            _ = try gz.addPlNode(.@"export", node, Zir.Inst.Export{
                .exported = exported,
                .options = options,
            });
            return rvalue(gz, ri, .void_value, node);
        },
        .@"extern" => {
            const type_inst = try typeExpr(gz, scope, params[0]);
            const extern_options_ty = try gz.addBuiltinValue(node, .extern_options);
            const options = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = extern_options_ty } }, params[1], .extern_options);
            const result = try gz.addExtendedPayload(.builtin_extern, Zir.Inst.BinNode{
                .node = gz.nodeIndexToRelative(node),
                .lhs = type_inst,
                .rhs = options,
            });
            return rvalue(gz, ri, result, node);
        },
        .set_float_mode => {
            const float_mode_ty = try gz.addBuiltinValue(node, .float_mode);
            const order = try expr(gz, scope, .{ .rl = .{ .coerced_ty = float_mode_ty } }, params[0]);
            _ = try gz.addExtendedPayload(.set_float_mode, Zir.Inst.UnNode{
                .node = gz.nodeIndexToRelative(node),
                .operand = order,
            });
            return rvalue(gz, ri, .void_value, node);
        },

        .src => {
            // Incorporate the source location into the source hash, so that
            // changes in the source location of `@src()` result in re-analysis.
            astgen.src_hasher.update(
                std.mem.asBytes(&astgen.source_line) ++
                    std.mem.asBytes(&astgen.source_column),
            );

            const node_start = tree.tokenStart(tree.firstToken(node));
            astgen.advanceSourceCursor(node_start);
            const result = try gz.addExtendedPayload(.builtin_src, Zir.Inst.Src{
                .node = gz.nodeIndexToRelative(node),
                .line = astgen.source_line,
                .column = astgen.source_column,
            });
            return rvalue(gz, ri, result, node);
        },

        // zig fmt: off
        .This                    => return rvalue(gz, ri, try gz.addNodeExtended(.this,                    node), node),
        .return_address          => return rvalue(gz, ri, try gz.addNodeExtended(.ret_addr,                node), node),
        .error_return_trace      => return rvalue(gz, ri, try gz.addNodeExtended(.error_return_trace,      node), node),
        .frame                   => return rvalue(gz, ri, try gz.addNodeExtended(.frame,                   node), node),
        .frame_address           => return rvalue(gz, ri, try gz.addNodeExtended(.frame_address,           node), node),
        .breakpoint              => return rvalue(gz, ri, try gz.addNodeExtended(.breakpoint,              node), node),
        .disable_instrumentation => return rvalue(gz, ri, try gz.addNodeExtended(.disable_instrumentation, node), node),
        .disable_intrinsics      => return rvalue(gz, ri, try gz.addNodeExtended(.disable_intrinsics,      node), node),

        .type_info   => return simpleUnOpType(gz, scope, ri, node, params[0], .type_info),
        .size_of     => return simpleUnOpType(gz, scope, ri, node, params[0], .size_of),
        .bit_size_of => return simpleUnOpType(gz, scope, ri, node, params[0], .bit_size_of),
        .align_of    => return simpleUnOpType(gz, scope, ri, node, params[0], .align_of),

        .int_from_ptr          => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none },                                     params[0], .int_from_ptr),
        .compile_error         => return simpleUnOp(gz, scope, ri, node, .{ .rl = .{ .coerced_ty = .slice_const_u8_type } },   params[0], .compile_error),
        .set_eval_branch_quota => return simpleUnOp(gz, scope, ri, node, .{ .rl = .{ .coerced_ty = .u32_type } },              params[0], .set_eval_branch_quota),
        .int_from_enum         => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none },                                     params[0], .int_from_enum),
        .int_from_bool         => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none },                                     params[0], .int_from_bool),
        .embed_file            => return simpleUnOp(gz, scope, ri, node, .{ .rl = .{ .coerced_ty = .slice_const_u8_type } },   params[0], .embed_file),
        .error_name            => return simpleUnOp(gz, scope, ri, node, .{ .rl = .{ .coerced_ty = .anyerror_type } },         params[0], .error_name),
        .set_runtime_safety    => return simpleUnOp(gz, scope, ri, node, coerced_bool_ri,                                      params[0], .set_runtime_safety),
        .sqrt                  => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none },                                     params[0], .sqrt),
        .sin                   => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none },                                     params[0], .sin),
        .cos                   => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none },                                     params[0], .cos),
        .tan                   => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none },                                     params[0], .tan),
        .exp                   => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none },                                     params[0], .exp),
        .exp2                  => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none },                                     params[0], .exp2),
        .log                   => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none },                                     params[0], .log),
        .log2                  => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none },                                     params[0], .log2),
        .log10                 => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none },                                     params[0], .log10),
        .abs                   => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none },                                     params[0], .abs),
        .floor                 => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none },                                     params[0], .floor),
        .ceil                  => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none },                                     params[0], .ceil),
        .trunc                 => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none },                                     params[0], .trunc),
        .round                 => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none },                                     params[0], .round),
        .tag_name              => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none },                                     params[0], .tag_name),
        .type_name             => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none },                                     params[0], .type_name),
        .Frame                 => return simpleUnOp(gz, scope, ri, node, .{ .rl = .none },                                     params[0], .frame_type),

        .int_from_float => return typeCast(gz, scope, ri, node, params[0], .int_from_float, builtin_name),
        .float_from_int => return typeCast(gz, scope, ri, node, params[0], .float_from_int, builtin_name),
        .ptr_from_int   => return typeCast(gz, scope, ri, node, params[0], .ptr_from_int, builtin_name),
        .enum_from_int  => return typeCast(gz, scope, ri, node, params[0], .enum_from_int, builtin_name),
        .float_cast     => return typeCast(gz, scope, ri, node, params[0], .float_cast, builtin_name),
        .int_cast       => return typeCast(gz, scope, ri, node, params[0], .int_cast, builtin_name),
        .truncate       => return typeCast(gz, scope, ri, node, params[0], .truncate, builtin_name),
        // zig fmt: on

        .in_comptime => if (gz.is_comptime) {
            return astgen.failNode(node, "redundant '@inComptime' in comptime scope", .{});
        } else {
            return rvalue(gz, ri, try gz.addNodeExtended(.in_comptime, node), node);
        },

        .Type => {
            return builtinReify(gz, scope, ri, node, params[0], .anon);
        },
        .panic => {
            try emitDbgNode(gz, node);
            return simpleUnOp(gz, scope, ri, node, .{ .rl = .{ .coerced_ty = .slice_const_u8_type } }, params[0], .panic);
        },
        .trap => {
            try emitDbgNode(gz, node);
            _ = try gz.addNode(.trap, node);
            return rvalue(gz, ri, .unreachable_value, node);
        },
        .int_from_error => {
            const operand = try expr(gz, scope, .{ .rl = .none }, params[0]);
            const result = try gz.addExtendedPayload(.int_from_error, Zir.Inst.UnNode{
                .node = gz.nodeIndexToRelative(node),
                .operand = operand,
            });
            return rvalue(gz, ri, result, node);
        },
        .error_from_int => {
            const operand = try expr(gz, scope, .{ .rl = .none }, params[0]);
            const result = try gz.addExtendedPayload(.error_from_int, Zir.Inst.UnNode{
                .node = gz.nodeIndexToRelative(node),
                .operand = operand,
            });
            return rvalue(gz, ri, result, node);
        },
        .error_cast => {
            try emitDbgNode(gz, node);

            const result = try gz.addExtendedPayload(.error_cast, Zir.Inst.BinNode{
                .lhs = try ri.rl.resultTypeForCast(gz, node, builtin_name),
                .rhs = try expr(gz, scope, .{ .rl = .none }, params[0]),
                .node = gz.nodeIndexToRelative(node),
            });
            return rvalue(gz, ri, result, node);
        },
        .ptr_cast,
        .align_cast,
        .addrspace_cast,
        .const_cast,
        .volatile_cast,
        => return ptrCast(gz, scope, ri, node),

        // zig fmt: off
        .has_decl  => return hasDeclOrField(gz, scope, ri, node, params[0], params[1], .has_decl),
        .has_field => return hasDeclOrField(gz, scope, ri, node, params[0], params[1], .has_field),

        .clz         => return bitBuiltin(gz, scope, ri, node, params[0], .clz),
        .ctz         => return bitBuiltin(gz, scope, ri, node, params[0], .ctz),
        .pop_count   => return bitBuiltin(gz, scope, ri, node, params[0], .pop_count),
        .byte_swap   => return bitBuiltin(gz, scope, ri, node, params[0], .byte_swap),
        .bit_reverse => return bitBuiltin(gz, scope, ri, node, params[0], .bit_reverse),

        .div_exact => return divBuiltin(gz, scope, ri, node, params[0], params[1], .div_exact),
        .div_floor => return divBuiltin(gz, scope, ri, node, params[0], params[1], .div_floor),
        .div_trunc => return divBuiltin(gz, scope, ri, node, params[0], params[1], .div_trunc),
        .mod       => return divBuiltin(gz, scope, ri, node, params[0], params[1], .mod),
        .rem       => return divBuiltin(gz, scope, ri, node, params[0], params[1], .rem),

        .shl_exact => return shiftOp(gz, scope, ri, node, params[0], params[1], .shl_exact),
        .shr_exact => return shiftOp(gz, scope, ri, node, params[0], params[1], .shr_exact),

        .bit_offset_of => return offsetOf(gz, scope, ri, node, params[0], params[1], .bit_offset_of),
        .offset_of     => return offsetOf(gz, scope, ri, node, params[0], params[1], .offset_of),

        .c_undef   => return simpleCBuiltin(gz, scope, ri, node, params[0], .c_undef),
        .c_include => return simpleCBuiltin(gz, scope, ri, node, params[0], .c_include),

        .cmpxchg_strong => return cmpxchg(gz, scope, ri, node, params, 1),
        .cmpxchg_weak   => return cmpxchg(gz, scope, ri, node, params, 0),
        // zig fmt: on

        .wasm_memory_size => {
            const operand = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = .u32_type } }, params[0], .wasm_memory_index);
            const result = try gz.addExtendedPayload(.wasm_memory_size, Zir.Inst.UnNode{
                .node = gz.nodeIndexToRelative(node),
                .operand = operand,
            });
            return rvalue(gz, ri, result, node);
        },
        .wasm_memory_grow => {
            const index_arg = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = .u32_type } }, params[0], .wasm_memory_index);
            const delta_arg = try expr(gz, scope, .{ .rl = .{ .coerced_ty = .usize_type } }, params[1]);
            const result = try gz.addExtendedPayload(.wasm_memory_grow, Zir.Inst.BinNode{
                .node = gz.nodeIndexToRelative(node),
                .lhs = index_arg,
                .rhs = delta_arg,
            });
            return rvalue(gz, ri, result, node);
        },
        .c_define => {
            if (!gz.c_import) return gz.astgen.failNode(node, "C define valid only inside C import block", .{});
            const name = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = .slice_const_u8_type } }, params[0], .operand_cDefine_macro_name);
            const value = try comptimeExpr(gz, scope, .{ .rl = .none }, params[1], .operand_cDefine_macro_value);
            const result = try gz.addExtendedPayload(.c_define, Zir.Inst.BinNode{
                .node = gz.nodeIndexToRelative(node),
                .lhs = name,
                .rhs = value,
            });
            return rvalue(gz, ri, result, node);
        },

        .splat => {
            const result_type = try ri.rl.resultTypeForCast(gz, node, builtin_name);
            const elem_type = try gz.addUnNode(.vec_arr_elem_type, result_type, node);
            const scalar = try expr(gz, scope, .{ .rl = .{ .ty = elem_type } }, params[0]);
            const result = try gz.addPlNode(.splat, node, Zir.Inst.Bin{
                .lhs = result_type,
                .rhs = scalar,
            });
            return rvalue(gz, ri, result, node);
        },
        .reduce => {
            const reduce_op_ty = try gz.addBuiltinValue(node, .reduce_op);
            const op = try expr(gz, scope, .{ .rl = .{ .coerced_ty = reduce_op_ty } }, params[0]);
            const scalar = try expr(gz, scope, .{ .rl = .none }, params[1]);
            const result = try gz.addPlNode(.reduce, node, Zir.Inst.Bin{
                .lhs = op,
                .rhs = scalar,
            });
            return rvalue(gz, ri, result, node);
        },

        .add_with_overflow => return overflowArithmetic(gz, scope, ri, node, params, .add_with_overflow),
        .sub_with_overflow => return overflowArithmetic(gz, scope, ri, node, params, .sub_with_overflow),
        .mul_with_overflow => return overflowArithmetic(gz, scope, ri, node, params, .mul_with_overflow),
        .shl_with_overflow => return overflowArithmetic(gz, scope, ri, node, params, .shl_with_overflow),

        .atomic_load => {
            const atomic_order_type = try gz.addBuiltinValue(node, .atomic_order);
            const result = try gz.addPlNode(.atomic_load, node, Zir.Inst.AtomicLoad{
                // zig fmt: off
                .elem_type = try typeExpr(gz, scope,                                                  params[0]),
                .ptr       = try expr    (gz, scope, .{ .rl = .none },                                params[1]),
                .ordering  = try expr    (gz, scope, .{ .rl = .{ .coerced_ty = atomic_order_type } }, params[2]),
                // zig fmt: on
            });
            return rvalue(gz, ri, result, node);
        },
        .atomic_rmw => {
            const atomic_order_type = try gz.addBuiltinValue(node, .atomic_order);
            const atomic_rmw_op_type = try gz.addBuiltinValue(node, .atomic_rmw_op);
            const int_type = try typeExpr(gz, scope, params[0]);
            const result = try gz.addPlNode(.atomic_rmw, node, Zir.Inst.AtomicRmw{
                // zig fmt: off
                .ptr       = try expr(gz, scope, .{ .rl = .none },                                 params[1]),
                .operation = try expr(gz, scope, .{ .rl = .{ .coerced_ty = atomic_rmw_op_type } }, params[2]),
                .operand   = try expr(gz, scope, .{ .rl = .{ .ty = int_type } },                   params[3]),
                .ordering  = try expr(gz, scope, .{ .rl = .{ .coerced_ty = atomic_order_type } },  params[4]),
                // zig fmt: on
            });
            return rvalue(gz, ri, result, node);
        },
        .atomic_store => {
            const atomic_order_type = try gz.addBuiltinValue(node, .atomic_order);
            const int_type = try typeExpr(gz, scope, params[0]);
            _ = try gz.addPlNode(.atomic_store, node, Zir.Inst.AtomicStore{
                // zig fmt: off
                .ptr      = try expr(gz, scope, .{ .rl = .none },                                params[1]),
                .operand  = try expr(gz, scope, .{ .rl = .{ .ty = int_type } },                  params[2]),
                .ordering = try expr(gz, scope, .{ .rl = .{ .coerced_ty = atomic_order_type } }, params[3]),
                // zig fmt: on
            });
            return rvalue(gz, ri, .void_value, node);
        },
        .mul_add => {
            const float_type = try typeExpr(gz, scope, params[0]);
            const mulend1 = try expr(gz, scope, .{ .rl = .{ .coerced_ty = float_type } }, params[1]);
            const mulend2 = try expr(gz, scope, .{ .rl = .{ .coerced_ty = float_type } }, params[2]);
            const addend = try expr(gz, scope, .{ .rl = .{ .ty = float_type } }, params[3]);
            const result = try gz.addPlNode(.mul_add, node, Zir.Inst.MulAdd{
                .mulend1 = mulend1,
                .mulend2 = mulend2,
                .addend = addend,
            });
            return rvalue(gz, ri, result, node);
        },
        .call => {
            const call_modifier_ty = try gz.addBuiltinValue(node, .call_modifier);
            const modifier = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = call_modifier_ty } }, params[0], .call_modifier);
            const callee = try expr(gz, scope, .{ .rl = .none }, params[1]);
            const args = try expr(gz, scope, .{ .rl = .none }, params[2]);
            const result = try gz.addPlNode(.builtin_call, node, Zir.Inst.BuiltinCall{
                .modifier = modifier,
                .callee = callee,
                .args = args,
                .flags = .{
                    .is_nosuspend = gz.nosuspend_node != .none,
                    .ensure_result_used = false,
                },
            });
            return rvalue(gz, ri, result, node);
        },
        .field_parent_ptr => {
            const parent_ptr_type = try ri.rl.resultTypeForCast(gz, node, builtin_name);
            const field_name = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = .slice_const_u8_type } }, params[0], .field_name);
            const result = try gz.addExtendedPayloadSmall(.field_parent_ptr, 0, Zir.Inst.FieldParentPtr{
                .src_node = gz.nodeIndexToRelative(node),
                .parent_ptr_type = parent_ptr_type,
                .field_name = field_name,
                .field_ptr = try expr(gz, scope, .{ .rl = .none }, params[1]),
            });
            return rvalue(gz, ri, result, node);
        },
        .memcpy => {
            _ = try gz.addPlNode(.memcpy, node, Zir.Inst.Bin{
                .lhs = try expr(gz, scope, .{ .rl = .none }, params[0]),
                .rhs = try expr(gz, scope, .{ .rl = .none }, params[1]),
            });
            return rvalue(gz, ri, .void_value, node);
        },
        .memset => {
            const lhs = try expr(gz, scope, .{ .rl = .none }, params[0]);
            const lhs_ty = try gz.addUnNode(.typeof, lhs, params[0]);
            const elem_ty = try gz.addUnNode(.indexable_ptr_elem_type, lhs_ty, params[0]);
            _ = try gz.addPlNode(.memset, node, Zir.Inst.Bin{
                .lhs = lhs,
                .rhs = try expr(gz, scope, .{ .rl = .{ .coerced_ty = elem_ty } }, params[1]),
            });
            return rvalue(gz, ri, .void_value, node);
        },
        .memmove => {
            _ = try gz.addPlNode(.memmove, node, Zir.Inst.Bin{
                .lhs = try expr(gz, scope, .{ .rl = .none }, params[0]),
                .rhs = try expr(gz, scope, .{ .rl = .none }, params[1]),
            });
            return rvalue(gz, ri, .void_value, node);
        },
        .shuffle => {
            const result = try gz.addPlNode(.shuffle, node, Zir.Inst.Shuffle{
                .elem_type = try typeExpr(gz, scope, params[0]),
                .a = try expr(gz, scope, .{ .rl = .none }, params[1]),
                .b = try expr(gz, scope, .{ .rl = .none }, params[2]),
                .mask = try comptimeExpr(gz, scope, .{ .rl = .none }, params[3], .operand_shuffle_mask),
            });
            return rvalue(gz, ri, result, node);
        },
        .select => {
            const result = try gz.addExtendedPayload(.select, Zir.Inst.Select{
                .node = gz.nodeIndexToRelative(node),
                .elem_type = try typeExpr(gz, scope, params[0]),
                .pred = try expr(gz, scope, .{ .rl = .none }, params[1]),
                .a = try expr(gz, scope, .{ .rl = .none }, params[2]),
                .b = try expr(gz, scope, .{ .rl = .none }, params[3]),
            });
            return rvalue(gz, ri, result, node);
        },
        .Vector => {
            const result = try gz.addPlNode(.vector_type, node, Zir.Inst.Bin{
                .lhs = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = .u32_type } }, params[0], .type),
                .rhs = try typeExpr(gz, scope, params[1]),
            });
            return rvalue(gz, ri, result, node);
        },
        .prefetch => {
            const prefetch_options_ty = try gz.addBuiltinValue(node, .prefetch_options);
            const ptr = try expr(gz, scope, .{ .rl = .none }, params[0]);
            const options = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = prefetch_options_ty } }, params[1], .prefetch_options);
            _ = try gz.addExtendedPayload(.prefetch, Zir.Inst.BinNode{
                .node = gz.nodeIndexToRelative(node),
                .lhs = ptr,
                .rhs = options,
            });
            return rvalue(gz, ri, .void_value, node);
        },
        .c_va_arg => {
            const result = try gz.addExtendedPayload(.c_va_arg, Zir.Inst.BinNode{
                .node = gz.nodeIndexToRelative(node),
                .lhs = try expr(gz, scope, .{ .rl = .none }, params[0]),
                .rhs = try typeExpr(gz, scope, params[1]),
            });
            return rvalue(gz, ri, result, node);
        },
        .c_va_copy => {
            const result = try gz.addExtendedPayload(.c_va_copy, Zir.Inst.UnNode{
                .node = gz.nodeIndexToRelative(node),
                .operand = try expr(gz, scope, .{ .rl = .none }, params[0]),
            });
            return rvalue(gz, ri, result, node);
        },
        .c_va_end => {
            const result = try gz.addExtendedPayload(.c_va_end, Zir.Inst.UnNode{
                .node = gz.nodeIndexToRelative(node),
                .operand = try expr(gz, scope, .{ .rl = .none }, params[0]),
            });
            return rvalue(gz, ri, result, node);
        },
        .c_va_start => {
            if (!astgen.fn_var_args) {
                return astgen.failNode(node, "'@cVaStart' in a non-variadic function", .{});
            }
            return rvalue(gz, ri, try gz.addNodeExtended(.c_va_start, node), node);
        },

        .work_item_id => {
            const operand = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = .u32_type } }, params[0], .work_group_dim_index);
            const result = try gz.addExtendedPayload(.work_item_id, Zir.Inst.UnNode{
                .node = gz.nodeIndexToRelative(node),
                .operand = operand,
            });
            return rvalue(gz, ri, result, node);
        },
        .work_group_size => {
            const operand = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = .u32_type } }, params[0], .work_group_dim_index);
            const result = try gz.addExtendedPayload(.work_group_size, Zir.Inst.UnNode{
                .node = gz.nodeIndexToRelative(node),
                .operand = operand,
            });
            return rvalue(gz, ri, result, node);
        },
        .work_group_id => {
            const operand = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = .u32_type } }, params[0], .work_group_dim_index);
            const result = try gz.addExtendedPayload(.work_group_id, Zir.Inst.UnNode{
                .node = gz.nodeIndexToRelative(node),
                .operand = operand,
            });
            return rvalue(gz, ri, result, node);
        },
    }
}
fn builtinReify(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    arg_node: Ast.Node.Index,
    name_strat: Zir.Inst.NameStrategy,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const gpa = astgen.gpa;

    const type_info_ty = try gz.addBuiltinValue(node, .type_info);
    const operand = try expr(gz, scope, .{ .rl = .{ .coerced_ty = type_info_ty } }, arg_node);

    try gz.instructions.ensureUnusedCapacity(gpa, 1);
    try astgen.instructions.ensureUnusedCapacity(gpa, 1);

    const payload_index = try astgen.addExtra(Zir.Inst.Reify{
        .node = node, // Absolute node index -- see the definition of `Reify`.
        .operand = operand,
        .src_line = astgen.source_line,
    });
    const new_index: Zir.Inst.Index = @enumFromInt(astgen.instructions.len);
    astgen.instructions.appendAssumeCapacity(.{
        .tag = .extended,
        .data = .{ .extended = .{
            .opcode = .reify,
            .small = @intFromEnum(name_strat),
            .operand = payload_index,
        } },
    });
    gz.instructions.appendAssumeCapacity(new_index);
    const result = new_index.toRef();
    return rvalue(gz, ri, result, node);
}

fn hasDeclOrField(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    lhs_node: Ast.Node.Index,
    rhs_node: Ast.Node.Index,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const container_type = try typeExpr(gz, scope, lhs_node);
    const name = try comptimeExpr(
        gz,
        scope,
        .{ .rl = .{ .coerced_ty = .slice_const_u8_type } },
        rhs_node,
        if (tag == .has_decl) .decl_name else .field_name,
    );
    const result = try gz.addPlNode(tag, node, Zir.Inst.Bin{
        .lhs = container_type,
        .rhs = name,
    });
    return rvalue(gz, ri, result, node);
}

fn typeCast(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    operand_node: Ast.Node.Index,
    tag: Zir.Inst.Tag,
    builtin_name: []const u8,
) InnerError!Zir.Inst.Ref {
    const cursor = maybeAdvanceSourceCursorToMainToken(gz, node);
    const result_type = try ri.rl.resultTypeForCast(gz, node, builtin_name);
    const operand = try expr(gz, scope, .{ .rl = .none }, operand_node);

    try emitDbgStmt(gz, cursor);
    const result = try gz.addPlNode(tag, node, Zir.Inst.Bin{
        .lhs = result_type,
        .rhs = operand,
    });
    return rvalue(gz, ri, result, node);
}

fn simpleUnOpType(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    operand_node: Ast.Node.Index,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const operand = try typeExpr(gz, scope, operand_node);
    const result = try gz.addUnNode(tag, operand, node);
    return rvalue(gz, ri, result, node);
}

fn simpleUnOp(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    operand_ri: ResultInfo,
    operand_node: Ast.Node.Index,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const cursor = maybeAdvanceSourceCursorToMainToken(gz, node);
    const operand = if (tag == .compile_error)
        try comptimeExpr(gz, scope, operand_ri, operand_node, .compile_error_string)
    else
        try expr(gz, scope, operand_ri, operand_node);
    switch (tag) {
        .tag_name, .error_name, .int_from_ptr => try emitDbgStmt(gz, cursor),
        else => {},
    }
    const result = try gz.addUnNode(tag, operand, node);
    return rvalue(gz, ri, result, node);
}

fn negation(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    // Check for float literal as the sub-expression because we want to preserve
    // its negativity rather than having it go through comptime subtraction.
    const operand_node = tree.nodeData(node).node;
    if (tree.nodeTag(operand_node) == .number_literal) {
        return numberLiteral(gz, ri, operand_node, node, .negative);
    }

    const operand = try expr(gz, scope, .{ .rl = .none }, operand_node);
    const result = try gz.addUnNode(.negate, operand, node);
    return rvalue(gz, ri, result, node);
}

fn cmpxchg(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    params: []const Ast.Node.Index,
    small: u16,
) InnerError!Zir.Inst.Ref {
    const int_type = try typeExpr(gz, scope, params[0]);
    const atomic_order_type = try gz.addBuiltinValue(node, .atomic_order);
    const result = try gz.addExtendedPayloadSmall(.cmpxchg, small, Zir.Inst.Cmpxchg{
        // zig fmt: off
        .node           = gz.nodeIndexToRelative(node),
        .ptr            = try expr(gz, scope, .{ .rl = .none },                                params[1]),
        .expected_value = try expr(gz, scope, .{ .rl = .{ .ty = int_type } },                  params[2]),
        .new_value      = try expr(gz, scope, .{ .rl = .{ .coerced_ty = int_type } },          params[3]),
        .success_order  = try expr(gz, scope, .{ .rl = .{ .coerced_ty = atomic_order_type } }, params[4]),
        .failure_order  = try expr(gz, scope, .{ .rl = .{ .coerced_ty = atomic_order_type } }, params[5]),
        // zig fmt: on
    });
    return rvalue(gz, ri, result, node);
}

fn bitBuiltin(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    operand_node: Ast.Node.Index,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const operand = try expr(gz, scope, .{ .rl = .none }, operand_node);
    const result = try gz.addUnNode(tag, operand, node);
    return rvalue(gz, ri, result, node);
}

fn divBuiltin(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    lhs_node: Ast.Node.Index,
    rhs_node: Ast.Node.Index,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const cursor = maybeAdvanceSourceCursorToMainToken(gz, node);
    const lhs = try expr(gz, scope, .{ .rl = .none }, lhs_node);
    const rhs = try expr(gz, scope, .{ .rl = .none }, rhs_node);

    try emitDbgStmt(gz, cursor);
    const result = try gz.addPlNode(tag, node, Zir.Inst.Bin{ .lhs = lhs, .rhs = rhs });
    return rvalue(gz, ri, result, node);
}

fn simpleCBuiltin(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    operand_node: Ast.Node.Index,
    tag: Zir.Inst.Extended,
) InnerError!Zir.Inst.Ref {
    const name: []const u8 = if (tag == .c_undef) "C undef" else "C include";
    if (!gz.c_import) return gz.astgen.failNode(node, "{s} valid only inside C import block", .{name});
    const operand = try comptimeExpr(
        gz,
        scope,
        .{ .rl = .{ .coerced_ty = .slice_const_u8_type } },
        operand_node,
        if (tag == .c_undef) .operand_cUndef_macro_name else .operand_cInclude_file_name,
    );
    _ = try gz.addExtendedPayload(tag, Zir.Inst.UnNode{
        .node = gz.nodeIndexToRelative(node),
        .operand = operand,
    });
    return rvalue(gz, ri, .void_value, node);
}

fn offsetOf(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    lhs_node: Ast.Node.Index,
    rhs_node: Ast.Node.Index,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const type_inst = try typeExpr(gz, scope, lhs_node);
    const field_name = try comptimeExpr(gz, scope, .{ .rl = .{ .coerced_ty = .slice_const_u8_type } }, rhs_node, .field_name);
    const result = try gz.addPlNode(tag, node, Zir.Inst.Bin{
        .lhs = type_inst,
        .rhs = field_name,
    });
    return rvalue(gz, ri, result, node);
}

fn shiftOp(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    lhs_node: Ast.Node.Index,
    rhs_node: Ast.Node.Index,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const lhs = try expr(gz, scope, .{ .rl = .none }, lhs_node);

    const cursor = switch (gz.astgen.tree.nodeTag(node)) {
        .shl, .shr => maybeAdvanceSourceCursorToMainToken(gz, node),
        else => undefined,
    };

    const log2_int_type = try gz.addUnNode(.typeof_log2_int_type, lhs, lhs_node);
    const rhs = try expr(gz, scope, .{ .rl = .{ .ty = log2_int_type }, .ctx = .shift_op }, rhs_node);

    switch (gz.astgen.tree.nodeTag(node)) {
        .shl, .shr => try emitDbgStmt(gz, cursor),
        else => undefined,
    }

    const result = try gz.addPlNode(tag, node, Zir.Inst.Bin{
        .lhs = lhs,
        .rhs = rhs,
    });
    return rvalue(gz, ri, result, node);
}

fn cImport(
    gz: *GenZir,
    scope: *Scope,
    node: Ast.Node.Index,
    body_node: Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const gpa = astgen.gpa;

    if (gz.c_import) return gz.astgen.failNode(node, "cannot nest @cImport", .{});

    var block_scope = gz.makeSubBlock(scope);
    block_scope.is_comptime = true;
    block_scope.c_import = true;
    defer block_scope.unstack();

    const block_inst = try gz.makeBlockInst(.c_import, node);
    const block_result = try fullBodyExpr(&block_scope, &block_scope.base, .{ .rl = .none }, body_node, .normal);
    _ = try gz.addUnNode(.ensure_result_used, block_result, node);
    if (!gz.refIsNoReturn(block_result)) {
        _ = try block_scope.addBreak(.break_inline, block_inst, .void_value);
    }
    try block_scope.setBlockBody(block_inst);
    // block_scope unstacked now, can add new instructions to gz
    try gz.instructions.append(gpa, block_inst);

    return block_inst.toRef();
}

fn overflowArithmetic(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    node: Ast.Node.Index,
    params: []const Ast.Node.Index,
    tag: Zir.Inst.Extended,
) InnerError!Zir.Inst.Ref {
    const lhs = try expr(gz, scope, .{ .rl = .none }, params[0]);
    const rhs = try expr(gz, scope, .{ .rl = .none }, params[1]);
    const result = try gz.addExtendedPayload(tag, Zir.Inst.BinNode{
        .node = gz.nodeIndexToRelative(node),
        .lhs = lhs,
        .rhs = rhs,
    });
    return rvalue(gz, ri, result, node);
}

fn callExpr(
    gz: *GenZir,
    scope: *Scope,
    ri: ResultInfo,
    /// If this is not `.none` and this call is a decl literal form (`.foo(...)`), then this
    /// type is used as the decl literal result type instead of the result type from `ri.rl`.
    override_decl_literal_type: Zir.Inst.Ref,
    node: Ast.Node.Index,
    call: Ast.full.Call,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;

    const callee = try calleeExpr(gz, scope, ri.rl, override_decl_literal_type, call.ast.fn_expr);
    const modifier: std.builtin.CallModifier = blk: {
        if (gz.nosuspend_node != .none) {
            break :blk .no_suspend;
        }
        break :blk .auto;
    };

    {
        astgen.advanceSourceCursor(astgen.tree.tokenStart(call.ast.lparen));
        const line = astgen.source_line - gz.decl_line;
        const column = astgen.source_column;
        // Sema expects a dbg_stmt immediately before call,
        try emitDbgStmtForceCurrentIndex(gz, .{ line, column });
    }

    switch (callee) {
        .direct => |obj| assert(obj != .none),
        .field => |field| assert(field.obj_ptr != .none),
    }

    const call_index: Zir.Inst.Index = @enumFromInt(astgen.instructions.len);
    const call_inst = call_index.toRef();
    try gz.astgen.instructions.append(astgen.gpa, undefined);
    try gz.instructions.append(astgen.gpa, call_index);

    const scratch_top = astgen.scratch.items.len;
    defer astgen.scratch.items.len = scratch_top;

    var scratch_index = scratch_top;
    try astgen.scratch.resize(astgen.gpa, scratch_top + call.ast.params.len);

    for (call.ast.params) |param_node| {
        var arg_block = gz.makeSubBlock(scope);
        defer arg_block.unstack();

        // `call_inst` is reused to provide the param type.
        const arg_ref = try fullBodyExpr(&arg_block, &arg_block.base, .{ .rl = .{ .coerced_ty = call_inst }, .ctx = .fn_arg }, param_node, .normal);
        _ = try arg_block.addBreakWithSrcNode(.break_inline, call_index, arg_ref, param_node);

        const body = arg_block.instructionsSlice();
        try astgen.scratch.ensureUnusedCapacity(astgen.gpa, countBodyLenAfterFixups(astgen, body));
        appendBodyWithFixupsArrayList(astgen, &astgen.scratch, body);

        astgen.scratch.items[scratch_index] = @intCast(astgen.scratch.items.len - scratch_top);
        scratch_index += 1;
    }

    // If our result location is a try/catch/error-union-if/return, a function argument,
    // or an initializer for a `const` variable, the error trace propagates.
    // Otherwise, it should always be popped (handled in Sema).
    const propagate_error_trace = switch (ri.ctx) {
        .error_handling_expr, .@"return", .fn_arg, .const_init => true,
        else => false,
    };

    switch (callee) {
        .direct => |callee_obj| {
            const payload_index = try addExtra(astgen, Zir.Inst.Call{
                .callee = callee_obj,
                .flags = .{
                    .pop_error_return_trace = !propagate_error_trace,
                    .packed_modifier = @intCast(@intFromEnum(modifier)),
                    .args_len = @intCast(call.ast.params.len),
                },
            });
            if (call.ast.params.len != 0) {
                try astgen.extra.appendSlice(astgen.gpa, astgen.scratch.items[scratch_top..]);
            }
            gz.astgen.instructions.set(@intFromEnum(call_index), .{
                .tag = .call,
                .data = .{ .pl_node = .{
                    .src_node = gz.nodeIndexToRelative(node),
                    .payload_index = payload_index,
                } },
            });
        },
        .field => |callee_field| {
            const payload_index = try addExtra(astgen, Zir.Inst.FieldCall{
                .obj_ptr = callee_field.obj_ptr,
                .field_name_start = callee_field.field_name_start,
                .flags = .{
                    .pop_error_return_trace = !propagate_error_trace,
                    .packed_modifier = @intCast(@intFromEnum(modifier)),
                    .args_len = @intCast(call.ast.params.len),
                },
            });
            if (call.ast.params.len != 0) {
                try astgen.extra.appendSlice(astgen.gpa, astgen.scratch.items[scratch_top..]);
            }
            gz.astgen.instructions.set(@intFromEnum(call_index), .{
                .tag = .field_call,
                .data = .{ .pl_node = .{
                    .src_node = gz.nodeIndexToRelative(node),
                    .payload_index = payload_index,
                } },
            });
        },
    }
    return rvalue(gz, ri, call_inst, node); // TODO function call with result location
}

const Callee = union(enum) {
    field: struct {
        /// A *pointer* to the object the field is fetched on, so that we can
        /// promote the lvalue to an address if the first parameter requires it.
        obj_ptr: Zir.Inst.Ref,
        /// Offset into `string_bytes`.
        field_name_start: Zir.NullTerminatedString,
    },
    direct: Zir.Inst.Ref,
};

/// calleeExpr generates the function part of a call expression (f in f(x)), but
/// *not* the callee argument to the @call() builtin. Its purpose is to
/// distinguish between standard calls and method call syntax `a.b()`. Thus, if
/// the lhs is a field access, we return using the `field` union field;
/// otherwise, we use the `direct` union field.
fn calleeExpr(
    gz: *GenZir,
    scope: *Scope,
    call_rl: ResultInfo.Loc,
    /// If this is not `.none` and this call is a decl literal form (`.foo(...)`), then this
    /// type is used as the decl literal result type instead of the result type from `call_rl`.
    override_decl_literal_type: Zir.Inst.Ref,
    node: Ast.Node.Index,
) InnerError!Callee {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    const tag = tree.nodeTag(node);
    switch (tag) {
        .field_access => {
            const object_node, const field_ident = tree.nodeData(node).node_and_token;
            const str_index = try astgen.identAsString(field_ident);
            // Capture the object by reference so we can promote it to an
            // address in Sema if needed.
            const lhs = try expr(gz, scope, .{ .rl = .ref }, object_node);

            const cursor = maybeAdvanceSourceCursorToMainToken(gz, node);
            try emitDbgStmt(gz, cursor);

            return .{ .field = .{
                .obj_ptr = lhs,
                .field_name_start = str_index,
            } };
        },
        .enum_literal => {
            const res_ty = res_ty: {
                if (override_decl_literal_type != .none) break :res_ty override_decl_literal_type;
                break :res_ty try call_rl.resultType(gz, node) orelse {
                    // No result type; lower to a literal call of an enum literal.
                    return .{ .direct = try expr(gz, scope, .{ .rl = .none }, node) };
                };
            };
            // Decl literal call syntax, e.g.
            // `const foo: T = .init();`
            // Look up `init` in `T`, but don't try and coerce it.
            const str_index = try astgen.identAsString(tree.nodeMainToken(node));
            const callee = try gz.addPlNode(.decl_literal_no_coerce, node, Zir.Inst.Field{
                .lhs = res_ty,
                .field_name_start = str_index,
            });
            return .{ .direct = callee };
        },
        else => return .{ .direct = try expr(gz, scope, .{ .rl = .none }, node) },
    }
}

const primitive_instrs = std.StaticStringMap(Zir.Inst.Ref).initComptime(.{
    .{ "anyerror", .anyerror_type },
    .{ "anyframe", .anyframe_type },
    .{ "anyopaque", .anyopaque_type },
    .{ "bool", .bool_type },
    .{ "c_int", .c_int_type },
    .{ "c_long", .c_long_type },
    .{ "c_longdouble", .c_longdouble_type },
    .{ "c_longlong", .c_longlong_type },
    .{ "c_char", .c_char_type },
    .{ "c_short", .c_short_type },
    .{ "c_uint", .c_uint_type },
    .{ "c_ulong", .c_ulong_type },
    .{ "c_ulonglong", .c_ulonglong_type },
    .{ "c_ushort", .c_ushort_type },
    .{ "comptime_float", .comptime_float_type },
    .{ "comptime_int", .comptime_int_type },
    .{ "f128", .f128_type },
    .{ "f16", .f16_type },
    .{ "f32", .f32_type },
    .{ "f64", .f64_type },
    .{ "f80", .f80_type },
    .{ "false", .bool_false },
    .{ "i16", .i16_type },
    .{ "i32", .i32_type },
    .{ "i64", .i64_type },
    .{ "i128", .i128_type },
    .{ "i8", .i8_type },
    .{ "isize", .isize_type },
    .{ "noreturn", .noreturn_type },
    .{ "null", .null_value },
    .{ "true", .bool_true },
    .{ "type", .type_type },
    .{ "u16", .u16_type },
    .{ "u29", .u29_type },
    .{ "u32", .u32_type },
    .{ "u64", .u64_type },
    .{ "u128", .u128_type },
    .{ "u1", .u1_type },
    .{ "u8", .u8_type },
    .{ "undefined", .undef },
    .{ "usize", .usize_type },
    .{ "void", .void_type },
});

comptime {
    // These checks ensure that std.zig.primitives stays in sync with the primitive->Zir map.
    const primitives = std.zig.primitives;
    for (primitive_instrs.keys(), primitive_instrs.values()) |key, value| {
        if (!primitives.isPrimitive(key)) {
            @compileError("std.zig.isPrimitive() is not aware of Zir instr '" ++ @tagName(value) ++ "'");
        }
    }
    for (primitives.names.keys()) |key| {
        if (primitive_instrs.get(key) == null) {
            @compileError("std.zig.primitives entry '" ++ key ++ "' does not have a corresponding Zir instr");
        }
    }
}

fn nodeIsTriviallyZero(tree: *const Ast, node: Ast.Node.Index) bool {
    switch (tree.nodeTag(node)) {
        .number_literal => {
            const ident = tree.nodeMainToken(node);
            return switch (std.zig.parseNumberLiteral(tree.tokenSlice(ident))) {
                .int => |number| switch (number) {
                    0 => true,
                    else => false,
                },
                else => false,
            };
        },
        else => return false,
    }
}

fn nodeMayAppendToErrorTrace(tree: *const Ast, start_node: Ast.Node.Index) bool {
    var node = start_node;
    while (true) {
        switch (tree.nodeTag(node)) {
            // These don't have the opportunity to call any runtime functions.
            .error_value,
            .identifier,
            .@"comptime",
            => return false,

            // Forward the question to the LHS sub-expression.
            .@"try",
            .@"nosuspend",
            => node = tree.nodeData(node).node,
            .grouped_expression,
            .unwrap_optional,
            => node = tree.nodeData(node).node_and_token[0],

            // Anything that does not eval to an error is guaranteed to pop any
            // additions to the error trace, so it effectively does not append.
            else => return nodeMayEvalToError(tree, start_node) != .never,
        }
    }
}

fn nodeMayEvalToError(tree: *const Ast, start_node: Ast.Node.Index) BuiltinFn.EvalToError {
    var node = start_node;
    while (true) {
        switch (tree.nodeTag(node)) {
            .root,
            .test_decl,
            .switch_case,
            .switch_case_inline,
            .switch_case_one,
            .switch_case_inline_one,
            .container_field_init,
            .container_field_align,
            .container_field,
            .asm_output,
            .asm_input,
            => unreachable,

            .error_value => return .always,

            .@"asm",
            .asm_simple,
            .asm_legacy,
            .identifier,
            .field_access,
            .deref,
            .array_access,
            .while_simple,
            .while_cont,
            .for_simple,
            .if_simple,
            .@"while",
            .@"if",
            .@"for",
            .@"switch",
            .switch_comma,
            .call_one,
            .call_one_comma,
            .call,
            .call_comma,
            => return .maybe,

            .@"return",
            .@"break",
            .@"continue",
            .bit_not,
            .bool_not,
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            .@"defer",
            .@"errdefer",
            .address_of,
            .optional_type,
            .negation,
            .negation_wrap,
            .@"resume",
            .array_type,
            .array_type_sentinel,
            .ptr_type_aligned,
            .ptr_type_sentinel,
            .ptr_type,
            .ptr_type_bit_range,
            .@"suspend",
            .fn_proto_simple,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto,
            .fn_decl,
            .anyframe_type,
            .anyframe_literal,
            .number_literal,
            .enum_literal,
            .string_literal,
            .multiline_string_literal,
            .char_literal,
            .unreachable_literal,
            .error_set_decl,
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            .add,
            .add_wrap,
            .add_sat,
            .array_cat,
            .array_mult,
            .assign,
            .assign_destructure,
            .assign_bit_and,
            .assign_bit_or,
            .assign_shl,
            .assign_shl_sat,
            .assign_shr,
            .assign_bit_xor,
            .assign_div,
            .assign_sub,
            .assign_sub_wrap,
            .assign_sub_sat,
            .assign_mod,
            .assign_add,
            .assign_add_wrap,
            .assign_add_sat,
            .assign_mul,
            .assign_mul_wrap,
            .assign_mul_sat,
            .bang_equal,
            .bit_and,
            .bit_or,
            .shl,
            .shl_sat,
            .shr,
            .bit_xor,
            .bool_and,
            .bool_or,
            .div,
            .equal_equal,
            .error_union,
            .greater_or_equal,
            .greater_than,
            .less_or_equal,
            .less_than,
            .merge_error_sets,
            .mod,
            .mul,
            .mul_wrap,
            .mul_sat,
            .switch_range,
            .for_range,
            .sub,
            .sub_wrap,
            .sub_sat,
            .slice,
            .slice_open,
            .slice_sentinel,
            .array_init_one,
            .array_init_one_comma,
            .array_init_dot_two,
            .array_init_dot_two_comma,
            .array_init_dot,
            .array_init_dot_comma,
            .array_init,
            .array_init_comma,
            .struct_init_one,
            .struct_init_one_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init,
            .struct_init_comma,
            => return .never,

            // Forward the question to the LHS sub-expression.
            .@"try",
            .@"comptime",
            .@"nosuspend",
            => node = tree.nodeData(node).node,
            .grouped_expression,
            .unwrap_optional,
            => node = tree.nodeData(node).node_and_token[0],

            // LHS sub-expression may still be an error under the outer optional or error union
            .@"catch",
            .@"orelse",
            => return .maybe,

            .block_two,
            .block_two_semicolon,
            .block,
            .block_semicolon,
            => {
                const lbrace = tree.nodeMainToken(node);
                if (tree.tokenTag(lbrace - 1) == .colon) {
                    // Labeled blocks may need a memory location to forward
                    // to their break statements.
                    return .maybe;
                } else {
                    return .never;
                }
            },

            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            => {
                const builtin_token = tree.nodeMainToken(node);
                const builtin_name = tree.tokenSlice(builtin_token);
                // If the builtin is an invalid name, we don't cause an error here; instead
                // let it pass, and the error will be "invalid builtin function" later.
                const builtin_info = BuiltinFn.list.get(builtin_name) orelse return .maybe;
                return builtin_info.eval_to_error;
            },
        }
    }
}

/// Returns `true` if it is known the type expression has more than one possible value;
/// `false` otherwise.
fn nodeImpliesMoreThanOnePossibleValue(tree: *const Ast, start_node: Ast.Node.Index) bool {
    var node = start_node;
    while (true) {
        switch (tree.nodeTag(node)) {
            .root,
            .test_decl,
            .switch_case,
            .switch_case_inline,
            .switch_case_one,
            .switch_case_inline_one,
            .container_field_init,
            .container_field_align,
            .container_field,
            .asm_output,
            .asm_input,
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            => unreachable,

            .@"return",
            .@"break",
            .@"continue",
            .bit_not,
            .bool_not,
            .@"defer",
            .@"errdefer",
            .address_of,
            .negation,
            .negation_wrap,
            .@"resume",
            .array_type,
            .@"suspend",
            .fn_decl,
            .anyframe_literal,
            .number_literal,
            .enum_literal,
            .string_literal,
            .multiline_string_literal,
            .char_literal,
            .unreachable_literal,
            .error_set_decl,
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            .@"asm",
            .asm_simple,
            .asm_legacy,
            .add,
            .add_wrap,
            .add_sat,
            .array_cat,
            .array_mult,
            .assign,
            .assign_destructure,
            .assign_bit_and,
            .assign_bit_or,
            .assign_shl,
            .assign_shl_sat,
            .assign_shr,
            .assign_bit_xor,
            .assign_div,
            .assign_sub,
            .assign_sub_wrap,
            .assign_sub_sat,
            .assign_mod,
            .assign_add,
            .assign_add_wrap,
            .assign_add_sat,
            .assign_mul,
            .assign_mul_wrap,
            .assign_mul_sat,
            .bang_equal,
            .bit_and,
            .bit_or,
            .shl,
            .shl_sat,
            .shr,
            .bit_xor,
            .bool_and,
            .bool_or,
            .div,
            .equal_equal,
            .error_union,
            .greater_or_equal,
            .greater_than,
            .less_or_equal,
            .less_than,
            .merge_error_sets,
            .mod,
            .mul,
            .mul_wrap,
            .mul_sat,
            .switch_range,
            .for_range,
            .field_access,
            .sub,
            .sub_wrap,
            .sub_sat,
            .slice,
            .slice_open,
            .slice_sentinel,
            .deref,
            .array_access,
            .error_value,
            .while_simple,
            .while_cont,
            .for_simple,
            .if_simple,
            .@"catch",
            .@"orelse",
            .array_init_one,
            .array_init_one_comma,
            .array_init_dot_two,
            .array_init_dot_two_comma,
            .array_init_dot,
            .array_init_dot_comma,
            .array_init,
            .array_init_comma,
            .struct_init_one,
            .struct_init_one_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init,
            .struct_init_comma,
            .@"while",
            .@"if",
            .@"for",
            .@"switch",
            .switch_comma,
            .call_one,
            .call_one_comma,
            .call,
            .call_comma,
            .block_two,
            .block_two_semicolon,
            .block,
            .block_semicolon,
            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            // these are function bodies, not pointers
            .fn_proto_simple,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto,
            => return false,

            // Forward the question to the LHS sub-expression.
            .@"try",
            .@"comptime",
            .@"nosuspend",
            => node = tree.nodeData(node).node,
            .grouped_expression,
            .unwrap_optional,
            => node = tree.nodeData(node).node_and_token[0],

            .ptr_type_aligned,
            .ptr_type_sentinel,
            .ptr_type,
            .ptr_type_bit_range,
            .optional_type,
            .anyframe_type,
            .array_type_sentinel,
            => return true,

            .identifier => {
                const ident_bytes = tree.tokenSlice(tree.nodeMainToken(node));
                if (primitive_instrs.get(ident_bytes)) |primitive| switch (primitive) {
                    .anyerror_type,
                    .anyframe_type,
                    .anyopaque_type,
                    .bool_type,
                    .c_int_type,
                    .c_long_type,
                    .c_longdouble_type,
                    .c_longlong_type,
                    .c_char_type,
                    .c_short_type,
                    .c_uint_type,
                    .c_ulong_type,
                    .c_ulonglong_type,
                    .c_ushort_type,
                    .comptime_float_type,
                    .comptime_int_type,
                    .f16_type,
                    .f32_type,
                    .f64_type,
                    .f80_type,
                    .f128_type,
                    .i16_type,
                    .i32_type,
                    .i64_type,
                    .i128_type,
                    .i8_type,
                    .isize_type,
                    .type_type,
                    .u16_type,
                    .u29_type,
                    .u32_type,
                    .u64_type,
                    .u128_type,
                    .u1_type,
                    .u8_type,
                    .usize_type,
                    => return true,

                    .void_type,
                    .bool_false,
                    .bool_true,
                    .null_value,
                    .undef,
                    .noreturn_type,
                    => return false,

                    else => unreachable, // that's all the values from `primitives`.
                } else {
                    return false;
                }
            },
        }
    }
}

/// Returns `true` if it is known the expression is a type that cannot be used at runtime;
/// `false` otherwise.
fn nodeImpliesComptimeOnly(tree: *const Ast, start_node: Ast.Node.Index) bool {
    var node = start_node;
    while (true) {
        switch (tree.nodeTag(node)) {
            .root,
            .test_decl,
            .switch_case,
            .switch_case_inline,
            .switch_case_one,
            .switch_case_inline_one,
            .container_field_init,
            .container_field_align,
            .container_field,
            .asm_output,
            .asm_input,
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            => unreachable,

            .@"return",
            .@"break",
            .@"continue",
            .bit_not,
            .bool_not,
            .@"defer",
            .@"errdefer",
            .address_of,
            .negation,
            .negation_wrap,
            .@"resume",
            .array_type,
            .@"suspend",
            .fn_decl,
            .anyframe_literal,
            .number_literal,
            .enum_literal,
            .string_literal,
            .multiline_string_literal,
            .char_literal,
            .unreachable_literal,
            .error_set_decl,
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            .@"asm",
            .asm_simple,
            .asm_legacy,
            .add,
            .add_wrap,
            .add_sat,
            .array_cat,
            .array_mult,
            .assign,
            .assign_destructure,
            .assign_bit_and,
            .assign_bit_or,
            .assign_shl,
            .assign_shl_sat,
            .assign_shr,
            .assign_bit_xor,
            .assign_div,
            .assign_sub,
            .assign_sub_wrap,
            .assign_sub_sat,
            .assign_mod,
            .assign_add,
            .assign_add_wrap,
            .assign_add_sat,
            .assign_mul,
            .assign_mul_wrap,
            .assign_mul_sat,
            .bang_equal,
            .bit_and,
            .bit_or,
            .shl,
            .shl_sat,
            .shr,
            .bit_xor,
            .bool_and,
            .bool_or,
            .div,
            .equal_equal,
            .error_union,
            .greater_or_equal,
            .greater_than,
            .less_or_equal,
            .less_than,
            .merge_error_sets,
            .mod,
            .mul,
            .mul_wrap,
            .mul_sat,
            .switch_range,
            .for_range,
            .field_access,
            .sub,
            .sub_wrap,
            .sub_sat,
            .slice,
            .slice_open,
            .slice_sentinel,
            .deref,
            .array_access,
            .error_value,
            .while_simple,
            .while_cont,
            .for_simple,
            .if_simple,
            .@"catch",
            .@"orelse",
            .array_init_one,
            .array_init_one_comma,
            .array_init_dot_two,
            .array_init_dot_two_comma,
            .array_init_dot,
            .array_init_dot_comma,
            .array_init,
            .array_init_comma,
            .struct_init_one,
            .struct_init_one_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init,
            .struct_init_comma,
            .@"while",
            .@"if",
            .@"for",
            .@"switch",
            .switch_comma,
            .call_one,
            .call_one_comma,
            .call,
            .call_comma,
            .block_two,
            .block_two_semicolon,
            .block,
            .block_semicolon,
            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            .ptr_type_aligned,
            .ptr_type_sentinel,
            .ptr_type,
            .ptr_type_bit_range,
            .optional_type,
            .anyframe_type,
            .array_type_sentinel,
            => return false,

            // these are function bodies, not pointers
            .fn_proto_simple,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto,
            => return true,

            // Forward the question to the LHS sub-expression.
            .@"try",
            .@"comptime",
            .@"nosuspend",
            => node = tree.nodeData(node).node,
            .grouped_expression,
            .unwrap_optional,
            => node = tree.nodeData(node).node_and_token[0],

            .identifier => {
                const ident_bytes = tree.tokenSlice(tree.nodeMainToken(node));
                if (primitive_instrs.get(ident_bytes)) |primitive| switch (primitive) {
                    .anyerror_type,
                    .anyframe_type,
                    .anyopaque_type,
                    .bool_type,
                    .c_int_type,
                    .c_long_type,
                    .c_longdouble_type,
                    .c_longlong_type,
                    .c_char_type,
                    .c_short_type,
                    .c_uint_type,
                    .c_ulong_type,
                    .c_ulonglong_type,
                    .c_ushort_type,
                    .f16_type,
                    .f32_type,
                    .f64_type,
                    .f80_type,
                    .f128_type,
                    .i16_type,
                    .i32_type,
                    .i64_type,
                    .i128_type,
                    .i8_type,
                    .isize_type,
                    .u16_type,
                    .u29_type,
                    .u32_type,
                    .u64_type,
                    .u128_type,
                    .u1_type,
                    .u8_type,
                    .usize_type,
                    .void_type,
                    .bool_false,
                    .bool_true,
                    .null_value,
                    .undef,
                    .noreturn_type,
                    => return false,

                    .comptime_float_type,
                    .comptime_int_type,
                    .type_type,
                    => return true,

                    else => unreachable, // that's all the values from `primitives`.
                } else {
                    return false;
                }
            },
        }
    }
}

/// Applies `rl` semantics to `result`. Expressions which do not do their own handling of
/// result locations must call this function on their result.
/// As an example, if `ri.rl` is `.ptr`, it will write the result to the pointer.
/// If `ri.rl` is `.ty`, it will coerce the result to the type.
/// Assumes nothing stacked on `gz`.
fn rvalue(
    gz: *GenZir,
    ri: ResultInfo,
    raw_result: Zir.Inst.Ref,
    src_node: Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    return rvalueInner(gz, ri, raw_result, src_node, true);
}

/// Like `rvalue`, but refuses to perform coercions before taking references for
/// the `ref_coerced_ty` result type. This is used for local variables which do
/// not have `alloc`s, because we want variables to have consistent addresses,
/// i.e. we want them to act like lvalues.
fn rvalueNoCoercePreRef(
    gz: *GenZir,
    ri: ResultInfo,
    raw_result: Zir.Inst.Ref,
    src_node: Ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    return rvalueInner(gz, ri, raw_result, src_node, false);
}

fn rvalueInner(
    gz: *GenZir,
    ri: ResultInfo,
    raw_result: Zir.Inst.Ref,
    src_node: Ast.Node.Index,
    allow_coerce_pre_ref: bool,
) InnerError!Zir.Inst.Ref {
    const result = r: {
        if (raw_result.toIndex()) |result_index| {
            const zir_tags = gz.astgen.instructions.items(.tag);
            const data = gz.astgen.instructions.items(.data)[@intFromEnum(result_index)];
            if (zir_tags[@intFromEnum(result_index)].isAlwaysVoid(data)) {
                break :r Zir.Inst.Ref.void_value;
            }
        }
        break :r raw_result;
    };
    if (gz.endsWithNoReturn()) return result;
    switch (ri.rl) {
        .none, .coerced_ty => return result,
        .discard => {
            // Emit a compile error for discarding error values.
            _ = try gz.addUnNode(.ensure_result_non_error, result, src_node);
            return .void_value;
        },
        .ref, .ref_coerced_ty => {
            const coerced_result = if (allow_coerce_pre_ref and ri.rl == .ref_coerced_ty) res: {
                const ptr_ty = ri.rl.ref_coerced_ty;
                break :res try gz.addPlNode(.coerce_ptr_elem_ty, src_node, Zir.Inst.Bin{
                    .lhs = ptr_ty,
                    .rhs = result,
                });
            } else result;
            // We need a pointer but we have a value.
            // Unfortunately it's not quite as simple as directly emitting a ref
            // instruction here because we need subsequent address-of operator on
            // const locals to return the same address.
            const astgen = gz.astgen;
            const tree = astgen.tree;
            const src_token = tree.firstToken(src_node);
            const result_index = coerced_result.toIndex() orelse
                return gz.addUnTok(.ref, coerced_result, src_token);
            const gop = try astgen.ref_table.getOrPut(astgen.gpa, result_index);
            if (!gop.found_existing) {
                gop.value_ptr.* = try gz.makeUnTok(.ref, coerced_result, src_token);
            }
            return gop.value_ptr.*.toRef();
        },
        .ty => |ty_inst| {
            // Quickly eliminate some common, unnecessary type coercion.
            const as_ty = @as(u64, @intFromEnum(Zir.Inst.Ref.type_type)) << 32;
            const as_bool = @as(u64, @intFromEnum(Zir.Inst.Ref.bool_type)) << 32;
            const as_void = @as(u64, @intFromEnum(Zir.Inst.Ref.void_type)) << 32;
            const as_comptime_int = @as(u64, @intFromEnum(Zir.Inst.Ref.comptime_int_type)) << 32;
            const as_usize = @as(u64, @intFromEnum(Zir.Inst.Ref.usize_type)) << 32;
            const as_u1 = @as(u64, @intFromEnum(Zir.Inst.Ref.u1_type)) << 32;
            const as_u8 = @as(u64, @intFromEnum(Zir.Inst.Ref.u8_type)) << 32;
            switch ((@as(u64, @intFromEnum(ty_inst)) << 32) | @as(u64, @intFromEnum(result))) {
                as_ty | @intFromEnum(Zir.Inst.Ref.u1_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.u8_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.i8_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.u16_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.u29_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.i16_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.u32_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.i32_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.u64_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.i64_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.u128_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.i128_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.usize_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.isize_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.c_char_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.c_short_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.c_ushort_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.c_int_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.c_uint_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.c_long_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.c_ulong_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.c_longlong_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.c_ulonglong_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.c_longdouble_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.f16_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.f32_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.f64_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.f80_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.f128_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.anyopaque_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.bool_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.void_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.type_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.anyerror_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.comptime_int_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.comptime_float_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.noreturn_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.anyframe_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.null_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.undefined_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.enum_literal_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.ptr_usize_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.ptr_const_comptime_int_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.manyptr_u8_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.manyptr_const_u8_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.manyptr_const_u8_sentinel_0_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.slice_const_u8_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.slice_const_u8_sentinel_0_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.anyerror_void_error_union_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.generic_poison_type),
                as_ty | @intFromEnum(Zir.Inst.Ref.empty_tuple_type),
                as_comptime_int | @intFromEnum(Zir.Inst.Ref.zero),
                as_comptime_int | @intFromEnum(Zir.Inst.Ref.one),
                as_comptime_int | @intFromEnum(Zir.Inst.Ref.negative_one),
                as_usize | @intFromEnum(Zir.Inst.Ref.undef_usize),
                as_usize | @intFromEnum(Zir.Inst.Ref.zero_usize),
                as_usize | @intFromEnum(Zir.Inst.Ref.one_usize),
                as_u1 | @intFromEnum(Zir.Inst.Ref.undef_u1),
                as_u1 | @intFromEnum(Zir.Inst.Ref.zero_u1),
                as_u1 | @intFromEnum(Zir.Inst.Ref.one_u1),
                as_u8 | @intFromEnum(Zir.Inst.Ref.zero_u8),
                as_u8 | @intFromEnum(Zir.Inst.Ref.one_u8),
                as_u8 | @intFromEnum(Zir.Inst.Ref.four_u8),
                as_bool | @intFromEnum(Zir.Inst.Ref.undef_bool),
                as_bool | @intFromEnum(Zir.Inst.Ref.bool_true),
                as_bool | @intFromEnum(Zir.Inst.Ref.bool_false),
                as_void | @intFromEnum(Zir.Inst.Ref.void_value),
                => return result, // type of result is already correct

                as_bool | @intFromEnum(Zir.Inst.Ref.undef) => return .undef_bool,
                as_usize | @intFromEnum(Zir.Inst.Ref.undef) => return .undef_usize,
                as_usize | @intFromEnum(Zir.Inst.Ref.undef_u1) => return .undef_usize,
                as_u1 | @intFromEnum(Zir.Inst.Ref.undef) => return .undef_u1,

                as_usize | @intFromEnum(Zir.Inst.Ref.zero) => return .zero_usize,
                as_u1 | @intFromEnum(Zir.Inst.Ref.zero) => return .zero_u1,
                as_u8 | @intFromEnum(Zir.Inst.Ref.zero) => return .zero_u8,
                as_usize | @intFromEnum(Zir.Inst.Ref.one) => return .one_usize,
                as_u1 | @intFromEnum(Zir.Inst.Ref.one) => return .one_u1,
                as_u8 | @intFromEnum(Zir.Inst.Ref.one) => return .one_u8,
                as_comptime_int | @intFromEnum(Zir.Inst.Ref.zero_usize) => return .zero,
                as_u1 | @intFromEnum(Zir.Inst.Ref.zero_usize) => return .zero_u1,
                as_u8 | @intFromEnum(Zir.Inst.Ref.zero_usize) => return .zero_u8,
                as_comptime_int | @intFromEnum(Zir.Inst.Ref.one_usize) => return .one,
                as_u1 | @intFromEnum(Zir.Inst.Ref.one_usize) => return .one_u1,
                as_u8 | @intFromEnum(Zir.Inst.Ref.one_usize) => return .one_u8,
                as_comptime_int | @intFromEnum(Zir.Inst.Ref.zero_u1) => return .zero,
                as_comptime_int | @intFromEnum(Zir.Inst.Ref.zero_u8) => return .zero,
                as_usize | @intFromEnum(Zir.Inst.Ref.zero_u1) => return .zero_usize,
                as_usize | @intFromEnum(Zir.Inst.Ref.zero_u8) => return .zero_usize,
                as_comptime_int | @intFromEnum(Zir.Inst.Ref.one_u1) => return .one,
                as_comptime_int | @intFromEnum(Zir.Inst.Ref.one_u8) => return .one,
                as_usize | @intFromEnum(Zir.Inst.Ref.one_u1) => return .one_usize,
                as_usize | @intFromEnum(Zir.Inst.Ref.one_u8) => return .one_usize,

                // Need an explicit type coercion instruction.
                else => return gz.addPlNode(ri.zirTag(), src_node, Zir.Inst.As{
                    .dest_type = ty_inst,
                    .operand = result,
                }),
            }
        },
        .ptr => |ptr_res| {
            _ = try gz.addPlNode(.store_node, ptr_res.src_node orelse src_node, Zir.Inst.Bin{
                .lhs = ptr_res.inst,
                .rhs = result,
            });
            return .void_value;
        },
        .inferred_ptr => |alloc| {
            _ = try gz.addPlNode(.store_to_inferred_ptr, src_node, Zir.Inst.Bin{
                .lhs = alloc,
                .rhs = result,
            });
            return .void_value;
        },
        .destructure => |destructure| {
            const components = destructure.components;
            _ = try gz.addPlNode(.validate_destructure, src_node, Zir.Inst.ValidateDestructure{
                .operand = result,
                .destructure_node = gz.nodeIndexToRelative(destructure.src_node),
                .expect_len = @intCast(components.len),
            });
            for (components, 0..) |component, i| {
                if (component == .discard) continue;
                const elem_val = try gz.add(.{
                    .tag = .elem_val_imm,
                    .data = .{ .elem_val_imm = .{
                        .operand = result,
                        .idx = @intCast(i),
                    } },
                });
                switch (component) {
                    .typed_ptr => |ptr_res| {
                        _ = try gz.addPlNode(.store_node, ptr_res.src_node orelse src_node, Zir.Inst.Bin{
                            .lhs = ptr_res.inst,
                            .rhs = elem_val,
                        });
                    },
                    .inferred_ptr => |ptr_inst| {
                        _ = try gz.addPlNode(.store_to_inferred_ptr, src_node, Zir.Inst.Bin{
                            .lhs = ptr_inst,
                            .rhs = elem_val,
                        });
                    },
                    .discard => unreachable,
                }
            }
            return .void_value;
        },
    }
}

/// Given an identifier token, obtain the string for it.
/// If the token uses @"" syntax, parses as a string, reports errors if applicable,
/// and allocates the result within `astgen.arena`.
/// Otherwise, returns a reference to the source code bytes directly.
/// See also `appendIdentStr` and `parseStrLit`.
fn identifierTokenString(astgen: *AstGen, token: Ast.TokenIndex) InnerError![]const u8 {
    const tree = astgen.tree;
    assert(tree.tokenTag(token) == .identifier);
    const ident_name = tree.tokenSlice(token);
    if (!mem.startsWith(u8, ident_name, "@")) {
        return ident_name;
    }
    var buf: ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(astgen.gpa);
    try astgen.parseStrLit(token, &buf, ident_name, 1);
    if (mem.indexOfScalar(u8, buf.items, 0) != null) {
        return astgen.failTok(token, "identifier cannot contain null bytes", .{});
    } else if (buf.items.len == 0) {
        return astgen.failTok(token, "identifier cannot be empty", .{});
    }
    const duped = try astgen.arena.dupe(u8, buf.items);
    return duped;
}

/// Given an identifier token, obtain the string for it (possibly parsing as a string
/// literal if it is @"" syntax), and append the string to `buf`.
/// See also `identifierTokenString` and `parseStrLit`.
fn appendIdentStr(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    buf: *ArrayListUnmanaged(u8),
) InnerError!void {
    const tree = astgen.tree;
    assert(tree.tokenTag(token) == .identifier);
    const ident_name = tree.tokenSlice(token);
    if (!mem.startsWith(u8, ident_name, "@")) {
        return buf.appendSlice(astgen.gpa, ident_name);
    } else {
        const start = buf.items.len;
        try astgen.parseStrLit(token, buf, ident_name, 1);
        const slice = buf.items[start..];
        if (mem.indexOfScalar(u8, slice, 0) != null) {
            return astgen.failTok(token, "identifier cannot contain null bytes", .{});
        } else if (slice.len == 0) {
            return astgen.failTok(token, "identifier cannot be empty", .{});
        }
    }
}

/// Appends the result to `buf`.
fn parseStrLit(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    buf: *ArrayListUnmanaged(u8),
    bytes: []const u8,
    offset: u32,
) InnerError!void {
    const raw_string = bytes[offset..];
    const result = r: {
        var aw: std.io.Writer.Allocating = .fromArrayList(astgen.gpa, buf);
        defer buf.* = aw.toArrayList();
        break :r std.zig.string_literal.parseWrite(&aw.writer, raw_string) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };
    };
    switch (result) {
        .success => return,
        .failure => |err| return astgen.failWithStrLitError(err, token, bytes, offset),
    }
}

fn failWithStrLitError(
    astgen: *AstGen,
    err: std.zig.string_literal.Error,
    token: Ast.TokenIndex,
    bytes: []const u8,
    offset: u32,
) InnerError {
    const raw_string = bytes[offset..];
    return failOff(astgen, token, @intCast(offset + err.offset()), "{f}", .{err.fmt(raw_string)});
}

fn failNode(
    astgen: *AstGen,
    node: Ast.Node.Index,
    comptime format: []const u8,
    args: anytype,
) InnerError {
    return astgen.failNodeNotes(node, format, args, &[0]u32{});
}

fn appendErrorNode(
    astgen: *AstGen,
    node: Ast.Node.Index,
    comptime format: []const u8,
    args: anytype,
) Allocator.Error!void {
    try astgen.appendErrorNodeNotes(node, format, args, &[0]u32{});
}

fn appendErrorNodeNotes(
    astgen: *AstGen,
    node: Ast.Node.Index,
    comptime format: []const u8,
    args: anytype,
    notes: []const u32,
) Allocator.Error!void {
    @branchHint(.cold);
    const gpa = astgen.gpa;
    const string_bytes = &astgen.string_bytes;
    const msg: Zir.NullTerminatedString = @enumFromInt(string_bytes.items.len);
    try string_bytes.print(gpa, format ++ "\x00", args);
    const notes_index: u32 = if (notes.len != 0) blk: {
        const notes_start = astgen.extra.items.len;
        try astgen.extra.ensureTotalCapacity(gpa, notes_start + 1 + notes.len);
        astgen.extra.appendAssumeCapacity(@intCast(notes.len));
        astgen.extra.appendSliceAssumeCapacity(notes);
        break :blk @intCast(notes_start);
    } else 0;
    try astgen.compile_errors.append(gpa, .{
        .msg = msg,
        .node = node.toOptional(),
        .token = .none,
        .byte_offset = 0,
        .notes = notes_index,
    });
}

fn failNodeNotes(
    astgen: *AstGen,
    node: Ast.Node.Index,
    comptime format: []const u8,
    args: anytype,
    notes: []const u32,
) InnerError {
    try appendErrorNodeNotes(astgen, node, format, args, notes);
    return error.AnalysisFail;
}

fn failTok(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    comptime format: []const u8,
    args: anytype,
) InnerError {
    return astgen.failTokNotes(token, format, args, &[0]u32{});
}

fn appendErrorTok(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    comptime format: []const u8,
    args: anytype,
) !void {
    try astgen.appendErrorTokNotesOff(token, 0, format, args, &[0]u32{});
}

fn failTokNotes(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    comptime format: []const u8,
    args: anytype,
    notes: []const u32,
) InnerError {
    try appendErrorTokNotesOff(astgen, token, 0, format, args, notes);
    return error.AnalysisFail;
}

fn appendErrorTokNotes(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    comptime format: []const u8,
    args: anytype,
    notes: []const u32,
) !void {
    return appendErrorTokNotesOff(astgen, token, 0, format, args, notes);
}

/// Same as `fail`, except given a token plus an offset from its starting byte
/// offset.
fn failOff(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    byte_offset: u32,
    comptime format: []const u8,
    args: anytype,
) InnerError {
    try appendErrorTokNotesOff(astgen, token, byte_offset, format, args, &.{});
    return error.AnalysisFail;
}

fn appendErrorTokNotesOff(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    byte_offset: u32,
    comptime format: []const u8,
    args: anytype,
    notes: []const u32,
) !void {
    @branchHint(.cold);
    const gpa = astgen.gpa;
    const string_bytes = &astgen.string_bytes;
    const msg: Zir.NullTerminatedString = @enumFromInt(string_bytes.items.len);
    try string_bytes.print(gpa, format ++ "\x00", args);
    const notes_index: u32 = if (notes.len != 0) blk: {
        const notes_start = astgen.extra.items.len;
        try astgen.extra.ensureTotalCapacity(gpa, notes_start + 1 + notes.len);
        astgen.extra.appendAssumeCapacity(@intCast(notes.len));
        astgen.extra.appendSliceAssumeCapacity(notes);
        break :blk @intCast(notes_start);
    } else 0;
    try astgen.compile_errors.append(gpa, .{
        .msg = msg,
        .node = .none,
        .token = .fromToken(token),
        .byte_offset = byte_offset,
        .notes = notes_index,
    });
}

fn errNoteTok(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    comptime format: []const u8,
    args: anytype,
) Allocator.Error!u32 {
    return errNoteTokOff(astgen, token, 0, format, args);
}

fn errNoteTokOff(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    byte_offset: u32,
    comptime format: []const u8,
    args: anytype,
) Allocator.Error!u32 {
    @branchHint(.cold);
    const string_bytes = &astgen.string_bytes;
    const msg: Zir.NullTerminatedString = @enumFromInt(string_bytes.items.len);
    try string_bytes.print(astgen.gpa, format ++ "\x00", args);
    return astgen.addExtra(Zir.Inst.CompileErrors.Item{
        .msg = msg,
        .node = .none,
        .token = .fromToken(token),
        .byte_offset = byte_offset,
        .notes = 0,
    });
}

fn errNoteNode(
    astgen: *AstGen,
    node: Ast.Node.Index,
    comptime format: []const u8,
    args: anytype,
) Allocator.Error!u32 {
    @branchHint(.cold);
    const string_bytes = &astgen.string_bytes;
    const msg: Zir.NullTerminatedString = @enumFromInt(string_bytes.items.len);
    try string_bytes.print(astgen.gpa, format ++ "\x00", args);
    return astgen.addExtra(Zir.Inst.CompileErrors.Item{
        .msg = msg,
        .node = node.toOptional(),
        .token = .none,
        .byte_offset = 0,
        .notes = 0,
    });
}

fn identAsString(astgen: *AstGen, ident_token: Ast.TokenIndex) !Zir.NullTerminatedString {
    const gpa = astgen.gpa;
    const string_bytes = &astgen.string_bytes;
    const str_index: u32 = @intCast(string_bytes.items.len);
    try astgen.appendIdentStr(ident_token, string_bytes);
    const key: []const u8 = string_bytes.items[str_index..];
    const gop = try astgen.string_table.getOrPutContextAdapted(gpa, key, StringIndexAdapter{
        .bytes = string_bytes,
    }, StringIndexContext{
        .bytes = string_bytes,
    });
    if (gop.found_existing) {
        string_bytes.shrinkRetainingCapacity(str_index);
        return @enumFromInt(gop.key_ptr.*);
    } else {
        gop.key_ptr.* = str_index;
        try string_bytes.append(gpa, 0);
        return @enumFromInt(str_index);
    }
}

const IndexSlice = struct { index: Zir.NullTerminatedString, len: u32 };

fn strLitAsString(astgen: *AstGen, str_lit_token: Ast.TokenIndex) !IndexSlice {
    const gpa = astgen.gpa;
    const string_bytes = &astgen.string_bytes;
    const str_index: u32 = @intCast(string_bytes.items.len);
    const token_bytes = astgen.tree.tokenSlice(str_lit_token);
    try astgen.parseStrLit(str_lit_token, string_bytes, token_bytes, 0);
    const key: []const u8 = string_bytes.items[str_index..];
    if (std.mem.indexOfScalar(u8, key, 0)) |_| return .{
        .index = @enumFromInt(str_index),
        .len = @intCast(key.len),
    };
    const gop = try astgen.string_table.getOrPutContextAdapted(gpa, key, StringIndexAdapter{
        .bytes = string_bytes,
    }, StringIndexContext{
        .bytes = string_bytes,
    });
    if (gop.found_existing) {
        string_bytes.shrinkRetainingCapacity(str_index);
        return .{
            .index = @enumFromInt(gop.key_ptr.*),
            .len = @intCast(key.len),
        };
    } else {
        gop.key_ptr.* = str_index;
        // Still need a null byte because we are using the same table
        // to lookup null terminated strings, so if we get a match, it has to
        // be null terminated for that to work.
        try string_bytes.append(gpa, 0);
        return .{
            .index = @enumFromInt(str_index),
            .len = @intCast(key.len),
        };
    }
}

fn strLitNodeAsString(astgen: *AstGen, node: Ast.Node.Index) !IndexSlice {
    const tree = astgen.tree;

    const start, const end = tree.nodeData(node).token_and_token;

    const gpa = astgen.gpa;
    const string_bytes = &astgen.string_bytes;
    const str_index = string_bytes.items.len;

    // First line: do not append a newline.
    var tok_i = start;
    {
        const slice = tree.tokenSlice(tok_i);
        const line_bytes = slice[2..];
        try string_bytes.appendSlice(gpa, line_bytes);
        tok_i += 1;
    }
    // Following lines: each line prepends a newline.
    while (tok_i <= end) : (tok_i += 1) {
        const slice = tree.tokenSlice(tok_i);
        const line_bytes = slice[2..];
        try string_bytes.ensureUnusedCapacity(gpa, line_bytes.len + 1);
        string_bytes.appendAssumeCapacity('\n');
        string_bytes.appendSliceAssumeCapacity(line_bytes);
    }
    const len = string_bytes.items.len - str_index;
    try string_bytes.append(gpa, 0);
    return IndexSlice{
        .index = @enumFromInt(str_index),
        .len = @intCast(len),
    };
}

const Scope = struct {
    tag: Tag,

    fn cast(base: *Scope, comptime T: type) ?*T {
        if (T == Defer) {
            switch (base.tag) {
                .defer_normal, .defer_error => return @alignCast(@fieldParentPtr("base", base)),
                else => return null,
            }
        }
        if (T == Namespace) {
            switch (base.tag) {
                .namespace => return @alignCast(@fieldParentPtr("base", base)),
                else => return null,
            }
        }
        if (base.tag != T.base_tag)
            return null;

        return @alignCast(@fieldParentPtr("base", base));
    }

    fn parent(base: *Scope) ?*Scope {
        return switch (base.tag) {
            .gen_zir => base.cast(GenZir).?.parent,
            .local_val => base.cast(LocalVal).?.parent,
            .local_ptr => base.cast(LocalPtr).?.parent,
            .defer_normal, .defer_error => base.cast(Defer).?.parent,
            .namespace => base.cast(Namespace).?.parent,
            .top => null,
        };
    }

    const Tag = enum {
        gen_zir,
        local_val,
        local_ptr,
        defer_normal,
        defer_error,
        namespace,
        top,
    };

    /// The category of identifier. These tag names are user-visible in compile errors.
    const IdCat = enum {
        @"function parameter",
        @"local constant",
        @"local variable",
        @"switch tag capture",
        capture,
    };

    /// This is always a `const` local and importantly the `inst` is a value type, not a pointer.
    /// This structure lives as long as the AST generation of the Block
    /// node that contains the variable.
    const LocalVal = struct {
        const base_tag: Tag = .local_val;
        base: Scope = Scope{ .tag = base_tag },
        /// Parents can be: `LocalVal`, `LocalPtr`, `GenZir`, `Defer`, `Namespace`.
        parent: *Scope,
        gen_zir: *GenZir,
        inst: Zir.Inst.Ref,
        /// Source location of the corresponding variable declaration.
        token_src: Ast.TokenIndex,
        /// Track the first identifier where it is referenced.
        /// .none means never referenced.
        used: Ast.OptionalTokenIndex = .none,
        /// Track the identifier where it is discarded, like this `_ = foo;`.
        /// .none means never discarded.
        discarded: Ast.OptionalTokenIndex = .none,
        is_used_or_discarded: ?*bool = null,
        /// String table index.
        name: Zir.NullTerminatedString,
        id_cat: IdCat,
    };

    /// This could be a `const` or `var` local. It has a pointer instead of a value.
    /// This structure lives as long as the AST generation of the Block
    /// node that contains the variable.
    const LocalPtr = struct {
        const base_tag: Tag = .local_ptr;
        base: Scope = Scope{ .tag = base_tag },
        /// Parents can be: `LocalVal`, `LocalPtr`, `GenZir`, `Defer`, `Namespace`.
        parent: *Scope,
        gen_zir: *GenZir,
        ptr: Zir.Inst.Ref,
        /// Source location of the corresponding variable declaration.
        token_src: Ast.TokenIndex,
        /// Track the first identifier where it is referenced.
        /// .none means never referenced.
        used: Ast.OptionalTokenIndex = .none,
        /// Track the identifier where it is discarded, like this `_ = foo;`.
        /// .none means never discarded.
        discarded: Ast.OptionalTokenIndex = .none,
        /// Whether this value is used as an lvalue after initialization.
        /// If not, we know it can be `const`, so will emit a compile error if it is `var`.
        used_as_lvalue: bool = false,
        /// String table index.
        name: Zir.NullTerminatedString,
        id_cat: IdCat,
        /// true means we find out during Sema whether the value is comptime.
        /// false means it is already known at AstGen the value is runtime-known.
        maybe_comptime: bool,
    };

    const Defer = struct {
        base: Scope,
        /// Parents can be: `LocalVal`, `LocalPtr`, `GenZir`, `Defer`, `Namespace`.
        parent: *Scope,
        index: u32,
        len: u32,
        remapped_err_code: Zir.Inst.OptionalIndex = .none,
    };

    /// Represents a global scope that has any number of declarations in it.
    /// Each declaration has this as the parent scope.
    const Namespace = struct {
        const base_tag: Tag = .namespace;
        base: Scope = Scope{ .tag = base_tag },

        /// Parents can be: `LocalVal`, `LocalPtr`, `GenZir`, `Defer`, `Namespace`.
        parent: *Scope,
        /// Maps string table index to the source location of declaration,
        /// for the purposes of reporting name shadowing compile errors.
        decls: std.AutoHashMapUnmanaged(Zir.NullTerminatedString, Ast.Node.Index) = .empty,
        node: Ast.Node.Index,
        inst: Zir.Inst.Index,
        maybe_generic: bool,

        /// The astgen scope containing this namespace.
        /// Only valid during astgen.
        declaring_gz: ?*GenZir,

        /// Set of captures used by this namespace.
        captures: std.AutoArrayHashMapUnmanaged(Zir.Inst.Capture, Zir.NullTerminatedString) = .empty,

        fn deinit(self: *Namespace, gpa: Allocator) void {
            self.decls.deinit(gpa);
            self.captures.deinit(gpa);
            self.* = undefined;
        }
    };

    const Top = struct {
        const base_tag: Scope.Tag = .top;
        base: Scope = Scope{ .tag = base_tag },
    };
};

/// This is a temporary structure; references to it are valid only
/// while constructing a `Zir`.
const GenZir = struct {
    const base_tag: Scope.Tag = .gen_zir;
    base: Scope = Scope{ .tag = base_tag },
    /// Whether we're already in a scope known to be comptime. This is set
    /// whenever we know Sema will analyze the current block with `is_comptime`,
    /// for instance when we're within a `struct_decl` or a `block_comptime`.
    is_comptime: bool,
    /// Whether we're in an expression within a `@TypeOf` operand. In this case, closure of runtime
    /// variables is permitted where it is usually not.
    is_typeof: bool = false,
    /// This is set to true for a `GenZir` of a `block_inline`, indicating that
    /// exits from this block should use `break_inline` rather than `break`.
    is_inline: bool = false,
    c_import: bool = false,
    /// The containing decl AST node.
    decl_node_index: Ast.Node.Index,
    /// The containing decl line index, absolute.
    decl_line: u32,
    /// Parents can be: `LocalVal`, `LocalPtr`, `GenZir`, `Defer`, `Namespace`.
    parent: *Scope,
    /// All `GenZir` scopes for the same ZIR share this.
    astgen: *AstGen,
    /// Keeps track of the list of instructions in this scope. Possibly shared.
    /// Indexes to instructions in `astgen`.
    instructions: *ArrayListUnmanaged(Zir.Inst.Index),
    /// A sub-block may share its instructions ArrayList with containing GenZir,
    /// if use is strictly nested. This saves prior size of list for unstacking.
    instructions_top: usize,
    label: ?Label = null,
    break_block: Zir.Inst.OptionalIndex = .none,
    continue_block: Zir.Inst.OptionalIndex = .none,
    /// Only valid when setBreakResultInfo is called.
    break_result_info: AstGen.ResultInfo = undefined,
    continue_result_info: AstGen.ResultInfo = undefined,

    suspend_node: Ast.Node.OptionalIndex = .none,
    nosuspend_node: Ast.Node.OptionalIndex = .none,
    /// Set if this GenZir is a defer.
    cur_defer_node: Ast.Node.OptionalIndex = .none,
    // Set if this GenZir is a defer or it is inside a defer.
    any_defer_node: Ast.Node.OptionalIndex = .none,

    const unstacked_top = std.math.maxInt(usize);
    /// Call unstack before adding any new instructions to containing GenZir.
    fn unstack(self: *GenZir) void {
        if (self.instructions_top != unstacked_top) {
            self.instructions.items.len = self.instructions_top;
            self.instructions_top = unstacked_top;
        }
    }

    fn isEmpty(self: *const GenZir) bool {
        return (self.instructions_top == unstacked_top) or
            (self.instructions.items.len == self.instructions_top);
    }

    fn instructionsSlice(self: *const GenZir) []Zir.Inst.Index {
        return if (self.instructions_top == unstacked_top)
            &[0]Zir.Inst.Index{}
        else
            self.instructions.items[self.instructions_top..];
    }

    fn instructionsSliceUpto(self: *const GenZir, stacked_gz: *GenZir) []Zir.Inst.Index {
        return if (self.instructions_top == unstacked_top)
            &[0]Zir.Inst.Index{}
        else if (self.instructions == stacked_gz.instructions and stacked_gz.instructions_top != unstacked_top)
            self.instructions.items[self.instructions_top..stacked_gz.instructions_top]
        else
            self.instructions.items[self.instructions_top..];
    }

    fn instructionsSliceUptoOpt(gz: *const GenZir, maybe_stacked_gz: ?*GenZir) []Zir.Inst.Index {
        if (maybe_stacked_gz) |stacked_gz| {
            return gz.instructionsSliceUpto(stacked_gz);
        } else {
            return gz.instructionsSlice();
        }
    }

    fn makeSubBlock(gz: *GenZir, scope: *Scope) GenZir {
        return .{
            .is_comptime = gz.is_comptime,
            .is_typeof = gz.is_typeof,
            .c_import = gz.c_import,
            .decl_node_index = gz.decl_node_index,
            .decl_line = gz.decl_line,
            .parent = scope,
            .astgen = gz.astgen,
            .suspend_node = gz.suspend_node,
            .nosuspend_node = gz.nosuspend_node,
            .any_defer_node = gz.any_defer_node,
            .instructions = gz.instructions,
            .instructions_top = gz.instructions.items.len,
        };
    }

    const Label = struct {
        token: Ast.TokenIndex,
        block_inst: Zir.Inst.Index,
        used: bool = false,
        used_for_continue: bool = false,
    };

    /// Assumes nothing stacked on `gz`.
    fn endsWithNoReturn(gz: GenZir) bool {
        if (gz.isEmpty()) return false;
        const tags = gz.astgen.instructions.items(.tag);
        const last_inst = gz.instructions.items[gz.instructions.items.len - 1];
        return tags[@intFromEnum(last_inst)].isNoReturn();
    }

    /// TODO all uses of this should be replaced with uses of `endsWithNoReturn`.
    fn refIsNoReturn(gz: GenZir, inst_ref: Zir.Inst.Ref) bool {
        if (inst_ref == .unreachable_value) return true;
        if (inst_ref.toIndex()) |inst_index| {
            return gz.astgen.instructions.items(.tag)[@intFromEnum(inst_index)].isNoReturn();
        }
        return false;
    }

    fn nodeIndexToRelative(gz: GenZir, node_index: Ast.Node.Index) Ast.Node.Offset {
        return gz.decl_node_index.toOffset(node_index);
    }

    fn tokenIndexToRelative(gz: GenZir, token: Ast.TokenIndex) Ast.TokenOffset {
        return .init(gz.srcToken(), token);
    }

    fn srcToken(gz: GenZir) Ast.TokenIndex {
        return gz.astgen.tree.firstToken(gz.decl_node_index);
    }

    fn setBreakResultInfo(gz: *GenZir, parent_ri: AstGen.ResultInfo) void {
        // Depending on whether the result location is a pointer or value, different
        // ZIR needs to be generated. In the former case we rely on storing to the
        // pointer to communicate the result, and use breakvoid; in the latter case
        // the block break instructions will have the result values.
        switch (parent_ri.rl) {
            .coerced_ty => |ty_inst| {
                // Type coercion needs to happen before breaks.
                gz.break_result_info = .{ .rl = .{ .ty = ty_inst }, .ctx = parent_ri.ctx };
            },
            .discard => {
                // We don't forward the result context here. This prevents
                // "unnecessary discard" errors from being caused by expressions
                // far from the actual discard, such as a `break` from a
                // discarded block.
                gz.break_result_info = .{ .rl = .discard };
            },
            else => {
                gz.break_result_info = parent_ri;
            },
        }
    }

    /// Assumes nothing stacked on `gz`. Unstacks `gz`.
    fn setBoolBrBody(gz: *GenZir, bool_br: Zir.Inst.Index, bool_br_lhs: Zir.Inst.Ref) !void {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;
        const body = gz.instructionsSlice();
        const body_len = astgen.countBodyLenAfterFixups(body);
        try astgen.extra.ensureUnusedCapacity(
            gpa,
            @typeInfo(Zir.Inst.BoolBr).@"struct".fields.len + body_len,
        );
        const zir_datas = astgen.instructions.items(.data);
        zir_datas[@intFromEnum(bool_br)].pl_node.payload_index = astgen.addExtraAssumeCapacity(Zir.Inst.BoolBr{
            .lhs = bool_br_lhs,
            .body_len = body_len,
        });
        astgen.appendBodyWithFixups(body);
        gz.unstack();
    }

    /// Assumes nothing stacked on `gz`. Unstacks `gz`.
    /// Asserts `inst` is not a `block_comptime`.
    fn setBlockBody(gz: *GenZir, inst: Zir.Inst.Index) !void {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;
        const body = gz.instructionsSlice();
        const body_len = astgen.countBodyLenAfterFixups(body);

        const zir_tags = astgen.instructions.items(.tag);
        assert(zir_tags[@intFromEnum(inst)] != .block_comptime); // use `setComptimeBlockBody` instead

        try astgen.extra.ensureUnusedCapacity(
            gpa,
            @typeInfo(Zir.Inst.Block).@"struct".fields.len + body_len,
        );
        const zir_datas = astgen.instructions.items(.data);
        zir_datas[@intFromEnum(inst)].pl_node.payload_index = astgen.addExtraAssumeCapacity(
            Zir.Inst.Block{ .body_len = body_len },
        );
        astgen.appendBodyWithFixups(body);
        gz.unstack();
    }

    /// Assumes nothing stacked on `gz`. Unstacks `gz`.
    /// Asserts `inst` is a `block_comptime`.
    fn setBlockComptimeBody(gz: *GenZir, inst: Zir.Inst.Index, comptime_reason: std.zig.SimpleComptimeReason) !void {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;
        const body = gz.instructionsSlice();
        const body_len = astgen.countBodyLenAfterFixups(body);

        const zir_tags = astgen.instructions.items(.tag);
        assert(zir_tags[@intFromEnum(inst)] == .block_comptime); // use `setBlockBody` instead

        try astgen.extra.ensureUnusedCapacity(
            gpa,
            @typeInfo(Zir.Inst.BlockComptime).@"struct".fields.len + body_len,
        );
        const zir_datas = astgen.instructions.items(.data);
        zir_datas[@intFromEnum(inst)].pl_node.payload_index = astgen.addExtraAssumeCapacity(
            Zir.Inst.BlockComptime{
                .reason = comptime_reason,
                .body_len = body_len,
            },
        );
        astgen.appendBodyWithFixups(body);
        gz.unstack();
    }

    /// Assumes nothing stacked on `gz`. Unstacks `gz`.
    fn setTryBody(gz: *GenZir, inst: Zir.Inst.Index, operand: Zir.Inst.Ref) !void {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;
        const body = gz.instructionsSlice();
        const body_len = astgen.countBodyLenAfterFixups(body);
        try astgen.extra.ensureUnusedCapacity(
            gpa,
            @typeInfo(Zir.Inst.Try).@"struct".fields.len + body_len,
        );
        const zir_datas = astgen.instructions.items(.data);
        zir_datas[@intFromEnum(inst)].pl_node.payload_index = astgen.addExtraAssumeCapacity(
            Zir.Inst.Try{
                .operand = operand,
                .body_len = body_len,
            },
        );
        astgen.appendBodyWithFixups(body);
        gz.unstack();
    }

    /// Must be called with the following stack set up:
    ///  * gz (bottom)
    ///  * ret_gz
    ///  * cc_gz
    ///  * body_gz (top)
    /// Unstacks all of those except for `gz`.
    fn addFunc(
        gz: *GenZir,
        args: struct {
            src_node: Ast.Node.Index,
            lbrace_line: u32 = 0,
            lbrace_column: u32 = 0,
            param_block: Zir.Inst.Index,

            ret_gz: ?*GenZir,
            body_gz: ?*GenZir,
            cc_gz: ?*GenZir,

            ret_param_refs: []Zir.Inst.Index,
            param_insts: []Zir.Inst.Index, // refs to params in `body_gz` should still be in `astgen.ref_table`
            ret_ty_is_generic: bool,

            cc_ref: Zir.Inst.Ref,
            ret_ref: Zir.Inst.Ref,

            noalias_bits: u32,
            is_var_args: bool,
            is_inferred_error: bool,
            is_noinline: bool,

            /// Ignored if `body_gz == null`.
            proto_hash: std.zig.SrcHash,
        },
    ) !Zir.Inst.Ref {
        assert(args.src_node != .root);
        const astgen = gz.astgen;
        const gpa = astgen.gpa;
        const ret_ref = if (args.ret_ref == .void_type) .none else args.ret_ref;
        const new_index: Zir.Inst.Index = @enumFromInt(astgen.instructions.len);

        try gz.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.instructions.ensureUnusedCapacity(gpa, 1);

        const body, const cc_body, const ret_body = bodies: {
            var stacked_gz: ?*GenZir = null;
            const body: []const Zir.Inst.Index = if (args.body_gz) |body_gz| body: {
                const body = body_gz.instructionsSliceUptoOpt(stacked_gz);
                stacked_gz = body_gz;
                break :body body;
            } else &.{};
            const cc_body: []const Zir.Inst.Index = if (args.cc_gz) |cc_gz| body: {
                const cc_body = cc_gz.instructionsSliceUptoOpt(stacked_gz);
                stacked_gz = cc_gz;
                break :body cc_body;
            } else &.{};
            const ret_body: []const Zir.Inst.Index = if (args.ret_gz) |ret_gz| body: {
                const ret_body = ret_gz.instructionsSliceUptoOpt(stacked_gz);
                stacked_gz = ret_gz;
                break :body ret_body;
            } else &.{};
            break :bodies .{ body, cc_body, ret_body };
        };

        var src_locs_and_hash_buffer: [7]u32 = undefined;
        const src_locs_and_hash: []const u32 = if (args.body_gz != null) src_locs_and_hash: {
            const tree = astgen.tree;
            const fn_decl = args.src_node;
            const block = switch (tree.nodeTag(fn_decl)) {
                .fn_decl => tree.nodeData(fn_decl).node_and_node[1],
                .test_decl => tree.nodeData(fn_decl).opt_token_and_node[1],
                else => unreachable,
            };
            const rbrace_start = tree.tokenStart(tree.lastToken(block));
            astgen.advanceSourceCursor(rbrace_start);
            const rbrace_line: u32 = @intCast(astgen.source_line - gz.decl_line);
            const rbrace_column: u32 = @intCast(astgen.source_column);

            const columns = args.lbrace_column | (rbrace_column << 16);

            const proto_hash_arr: [4]u32 = @bitCast(args.proto_hash);

            src_locs_and_hash_buffer = .{
                args.lbrace_line,
                rbrace_line,
                columns,
                proto_hash_arr[0],
                proto_hash_arr[1],
                proto_hash_arr[2],
                proto_hash_arr[3],
            };
            break :src_locs_and_hash &src_locs_and_hash_buffer;
        } else &.{};

        const body_len = astgen.countBodyLenAfterFixupsExtraRefs(body, args.param_insts);

        const tag: Zir.Inst.Tag, const payload_index: u32 = if (args.cc_ref != .none or
            args.is_var_args or args.noalias_bits != 0 or args.is_noinline)
        inst_info: {
            try astgen.extra.ensureUnusedCapacity(
                gpa,
                @typeInfo(Zir.Inst.FuncFancy).@"struct".fields.len +
                    fancyFnExprExtraLen(astgen, &.{}, cc_body, args.cc_ref) +
                    fancyFnExprExtraLen(astgen, args.ret_param_refs, ret_body, ret_ref) +
                    body_len + src_locs_and_hash.len +
                    @intFromBool(args.noalias_bits != 0),
            );
            const payload_index = astgen.addExtraAssumeCapacity(Zir.Inst.FuncFancy{
                .param_block = args.param_block,
                .body_len = body_len,
                .bits = .{
                    .is_var_args = args.is_var_args,
                    .is_inferred_error = args.is_inferred_error,
                    .is_noinline = args.is_noinline,
                    .has_any_noalias = args.noalias_bits != 0,

                    .has_cc_ref = args.cc_ref != .none,
                    .has_ret_ty_ref = ret_ref != .none,

                    .has_cc_body = cc_body.len != 0,
                    .has_ret_ty_body = ret_body.len != 0,

                    .ret_ty_is_generic = args.ret_ty_is_generic,
                },
            });

            const zir_datas = astgen.instructions.items(.data);
            if (cc_body.len != 0) {
                astgen.extra.appendAssumeCapacity(astgen.countBodyLenAfterFixups(cc_body));
                astgen.appendBodyWithFixups(cc_body);
                const break_extra = zir_datas[@intFromEnum(cc_body[cc_body.len - 1])].@"break".payload_index;
                astgen.extra.items[break_extra + std.meta.fieldIndex(Zir.Inst.Break, "block_inst").?] =
                    @intFromEnum(new_index);
            } else if (args.cc_ref != .none) {
                astgen.extra.appendAssumeCapacity(@intFromEnum(args.cc_ref));
            }
            if (ret_body.len != 0) {
                astgen.extra.appendAssumeCapacity(
                    astgen.countBodyLenAfterFixups(args.ret_param_refs) +
                        astgen.countBodyLenAfterFixups(ret_body),
                );
                astgen.appendBodyWithFixups(args.ret_param_refs);
                astgen.appendBodyWithFixups(ret_body);
                const break_extra = zir_datas[@intFromEnum(ret_body[ret_body.len - 1])].@"break".payload_index;
                astgen.extra.items[break_extra + std.meta.fieldIndex(Zir.Inst.Break, "block_inst").?] =
                    @intFromEnum(new_index);
            } else if (ret_ref != .none) {
                astgen.extra.appendAssumeCapacity(@intFromEnum(ret_ref));
            }

            if (args.noalias_bits != 0) {
                astgen.extra.appendAssumeCapacity(args.noalias_bits);
            }

            astgen.appendBodyWithFixupsExtraRefsArrayList(&astgen.extra, body, args.param_insts);
            astgen.extra.appendSliceAssumeCapacity(src_locs_and_hash);

            break :inst_info .{ .func_fancy, payload_index };
        } else inst_info: {
            try astgen.extra.ensureUnusedCapacity(
                gpa,
                @typeInfo(Zir.Inst.Func).@"struct".fields.len + 1 +
                    fancyFnExprExtraLen(astgen, args.ret_param_refs, ret_body, ret_ref) +
                    body_len + src_locs_and_hash.len,
            );

            const ret_body_len = if (ret_body.len != 0)
                countBodyLenAfterFixups(astgen, args.ret_param_refs) + countBodyLenAfterFixups(astgen, ret_body)
            else
                @intFromBool(ret_ref != .none);

            const payload_index = astgen.addExtraAssumeCapacity(Zir.Inst.Func{
                .param_block = args.param_block,
                .ret_ty = .{
                    .body_len = @intCast(ret_body_len),
                    .is_generic = args.ret_ty_is_generic,
                },
                .body_len = body_len,
            });
            const zir_datas = astgen.instructions.items(.data);
            if (ret_body.len != 0) {
                astgen.appendBodyWithFixups(args.ret_param_refs);
                astgen.appendBodyWithFixups(ret_body);

                const break_extra = zir_datas[@intFromEnum(ret_body[ret_body.len - 1])].@"break".payload_index;
                astgen.extra.items[break_extra + std.meta.fieldIndex(Zir.Inst.Break, "block_inst").?] =
                    @intFromEnum(new_index);
            } else if (ret_ref != .none) {
                astgen.extra.appendAssumeCapacity(@intFromEnum(ret_ref));
            }
            astgen.appendBodyWithFixupsExtraRefsArrayList(&astgen.extra, body, args.param_insts);
            astgen.extra.appendSliceAssumeCapacity(src_locs_and_hash);

            break :inst_info .{
                if (args.is_inferred_error) .func_inferred else .func,
                payload_index,
            };
        };

        // Order is important when unstacking.
        if (args.body_gz) |body_gz| body_gz.unstack();
        if (args.cc_gz) |cc_gz| cc_gz.unstack();
        if (args.ret_gz) |ret_gz| ret_gz.unstack();

        astgen.instructions.appendAssumeCapacity(.{
            .tag = tag,
            .data = .{ .pl_node = .{
                .src_node = gz.nodeIndexToRelative(args.src_node),
                .payload_index = payload_index,
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        return new_index.toRef();
    }

    fn fancyFnExprExtraLen(astgen: *AstGen, param_refs_body: []const Zir.Inst.Index, main_body: []const Zir.Inst.Index, ref: Zir.Inst.Ref) u32 {
        return countBodyLenAfterFixups(astgen, param_refs_body) +
            countBodyLenAfterFixups(astgen, main_body) +
            // If there is a body, we need an element for its length; otherwise, if there is a ref, we need to include that.
            @intFromBool(main_body.len > 0 or ref != .none);
    }

    fn addInt(gz: *GenZir, integer: u64) !Zir.Inst.Ref {
        return gz.add(.{
            .tag = .int,
            .data = .{ .int = integer },
        });
    }

    fn addIntBig(gz: *GenZir, limbs: []const std.math.big.Limb) !Zir.Inst.Ref {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;
        try gz.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.string_bytes.ensureUnusedCapacity(gpa, @sizeOf(std.math.big.Limb) * limbs.len);

        const new_index: Zir.Inst.Index = @enumFromInt(astgen.instructions.len);
        astgen.instructions.appendAssumeCapacity(.{
            .tag = .int_big,
            .data = .{ .str = .{
                .start = @enumFromInt(astgen.string_bytes.items.len),
                .len = @intCast(limbs.len),
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        astgen.string_bytes.appendSliceAssumeCapacity(mem.sliceAsBytes(limbs));
        return new_index.toRef();
    }

    fn addFloat(gz: *GenZir, number: f64) !Zir.Inst.Ref {
        return gz.add(.{
            .tag = .float,
            .data = .{ .float = number },
        });
    }

    fn addUnNode(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        operand: Zir.Inst.Ref,
        /// Absolute node index. This function does the conversion to offset from Decl.
        src_node: Ast.Node.Index,
    ) !Zir.Inst.Ref {
        assert(operand != .none);
        return gz.add(.{
            .tag = tag,
            .data = .{ .un_node = .{
                .operand = operand,
                .src_node = gz.nodeIndexToRelative(src_node),
            } },
        });
    }

    fn makeUnNode(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        operand: Zir.Inst.Ref,
        /// Absolute node index. This function does the conversion to offset from Decl.
        src_node: Ast.Node.Index,
    ) !Zir.Inst.Index {
        assert(operand != .none);
        const new_index: Zir.Inst.Index = @enumFromInt(gz.astgen.instructions.len);
        try gz.astgen.instructions.append(gz.astgen.gpa, .{
            .tag = tag,
            .data = .{ .un_node = .{
                .operand = operand,
                .src_node = gz.nodeIndexToRelative(src_node),
            } },
        });
        return new_index;
    }

    fn addPlNode(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        /// Absolute node index. This function does the conversion to offset from Decl.
        src_node: Ast.Node.Index,
        extra: anytype,
    ) !Zir.Inst.Ref {
        const gpa = gz.astgen.gpa;
        try gz.instructions.ensureUnusedCapacity(gpa, 1);
        try gz.astgen.instructions.ensureUnusedCapacity(gpa, 1);

        const payload_index = try gz.astgen.addExtra(extra);
        const new_index: Zir.Inst.Index = @enumFromInt(gz.astgen.instructions.len);
        gz.astgen.instructions.appendAssumeCapacity(.{
            .tag = tag,
            .data = .{ .pl_node = .{
                .src_node = gz.nodeIndexToRelative(src_node),
                .payload_index = payload_index,
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        return new_index.toRef();
    }

    fn addPlNodePayloadIndex(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        /// Absolute node index. This function does the conversion to offset from Decl.
        src_node: Ast.Node.Index,
        payload_index: u32,
    ) !Zir.Inst.Ref {
        return try gz.add(.{
            .tag = tag,
            .data = .{ .pl_node = .{
                .src_node = gz.nodeIndexToRelative(src_node),
                .payload_index = payload_index,
            } },
        });
    }

    /// Supports `param_gz` stacked on `gz`. Assumes nothing stacked on `param_gz`. Unstacks `param_gz`.
    fn addParam(
        gz: *GenZir,
        param_gz: *GenZir,
        /// Previous parameters, which might be referenced in `param_gz` (the new parameter type).
        /// `ref`s of these instructions will be put into this param's type body, and removed from `AstGen.ref_table`.
        prev_param_insts: []const Zir.Inst.Index,
        ty_is_generic: bool,
        tag: Zir.Inst.Tag,
        /// Absolute token index. This function does the conversion to Decl offset.
        abs_tok_index: Ast.TokenIndex,
        name: Zir.NullTerminatedString,
    ) !Zir.Inst.Index {
        const gpa = gz.astgen.gpa;
        const param_body = param_gz.instructionsSlice();
        const body_len = gz.astgen.countBodyLenAfterFixupsExtraRefs(param_body, prev_param_insts);
        try gz.astgen.instructions.ensureUnusedCapacity(gpa, 1);
        try gz.astgen.extra.ensureUnusedCapacity(gpa, @typeInfo(Zir.Inst.Param).@"struct".fields.len + body_len);

        const payload_index = gz.astgen.addExtraAssumeCapacity(Zir.Inst.Param{
            .name = name,
            .type = .{
                .body_len = @intCast(body_len),
                .is_generic = ty_is_generic,
            },
        });
        gz.astgen.appendBodyWithFixupsExtraRefsArrayList(&gz.astgen.extra, param_body, prev_param_insts);
        param_gz.unstack();

        const new_index: Zir.Inst.Index = @enumFromInt(gz.astgen.instructions.len);
        gz.astgen.instructions.appendAssumeCapacity(.{
            .tag = tag,
            .data = .{ .pl_tok = .{
                .src_tok = gz.tokenIndexToRelative(abs_tok_index),
                .payload_index = payload_index,
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        return new_index;
    }

    fn addBuiltinValue(gz: *GenZir, src_node: Ast.Node.Index, val: Zir.Inst.BuiltinValue) !Zir.Inst.Ref {
        return addExtendedNodeSmall(gz, .builtin_value, src_node, @intFromEnum(val));
    }

    fn addExtendedPayload(gz: *GenZir, opcode: Zir.Inst.Extended, extra: anytype) !Zir.Inst.Ref {
        return addExtendedPayloadSmall(gz, opcode, undefined, extra);
    }

    fn addExtendedPayloadSmall(
        gz: *GenZir,
        opcode: Zir.Inst.Extended,
        small: u16,
        extra: anytype,
    ) !Zir.Inst.Ref {
        const gpa = gz.astgen.gpa;

        try gz.instructions.ensureUnusedCapacity(gpa, 1);
        try gz.astgen.instructions.ensureUnusedCapacity(gpa, 1);

        const payload_index = try gz.astgen.addExtra(extra);
        const new_index: Zir.Inst.Index = @enumFromInt(gz.astgen.instructions.len);
        gz.astgen.instructions.appendAssumeCapacity(.{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = opcode,
                .small = small,
                .operand = payload_index,
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        return new_index.toRef();
    }

    fn addExtendedMultiOp(
        gz: *GenZir,
        opcode: Zir.Inst.Extended,
        node: Ast.Node.Index,
        operands: []const Zir.Inst.Ref,
    ) !Zir.Inst.Ref {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;

        try gz.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.extra.ensureUnusedCapacity(
            gpa,
            @typeInfo(Zir.Inst.NodeMultiOp).@"struct".fields.len + operands.len,
        );

        const payload_index = astgen.addExtraAssumeCapacity(Zir.Inst.NodeMultiOp{
            .src_node = gz.nodeIndexToRelative(node),
        });
        const new_index: Zir.Inst.Index = @enumFromInt(astgen.instructions.len);
        astgen.instructions.appendAssumeCapacity(.{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = opcode,
                .small = @intCast(operands.len),
                .operand = payload_index,
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        astgen.appendRefsAssumeCapacity(operands);
        return new_index.toRef();
    }

    fn addExtendedMultiOpPayloadIndex(
        gz: *GenZir,
        opcode: Zir.Inst.Extended,
        payload_index: u32,
        trailing_len: usize,
    ) !Zir.Inst.Ref {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;

        try gz.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.instructions.ensureUnusedCapacity(gpa, 1);
        const new_index: Zir.Inst.Index = @enumFromInt(astgen.instructions.len);
        astgen.instructions.appendAssumeCapacity(.{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = opcode,
                .small = @intCast(trailing_len),
                .operand = payload_index,
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        return new_index.toRef();
    }

    fn addExtendedNodeSmall(
        gz: *GenZir,
        opcode: Zir.Inst.Extended,
        src_node: Ast.Node.Index,
        small: u16,
    ) !Zir.Inst.Ref {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;

        try gz.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.instructions.ensureUnusedCapacity(gpa, 1);
        const new_index: Zir.Inst.Index = @enumFromInt(astgen.instructions.len);
        astgen.instructions.appendAssumeCapacity(.{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = opcode,
                .small = small,
                .operand = @bitCast(@intFromEnum(gz.nodeIndexToRelative(src_node))),
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        return new_index.toRef();
    }

    fn addUnTok(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        operand: Zir.Inst.Ref,
        /// Absolute token index. This function does the conversion to Decl offset.
        abs_tok_index: Ast.TokenIndex,
    ) !Zir.Inst.Ref {
        assert(operand != .none);
        return gz.add(.{
            .tag = tag,
            .data = .{ .un_tok = .{
                .operand = operand,
                .src_tok = gz.tokenIndexToRelative(abs_tok_index),
            } },
        });
    }

    fn makeUnTok(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        operand: Zir.Inst.Ref,
        /// Absolute token index. This function does the conversion to Decl offset.
        abs_tok_index: Ast.TokenIndex,
    ) !Zir.Inst.Index {
        const astgen = gz.astgen;
        const new_index: Zir.Inst.Index = @enumFromInt(astgen.instructions.len);
        assert(operand != .none);
        try astgen.instructions.append(astgen.gpa, .{
            .tag = tag,
            .data = .{ .un_tok = .{
                .operand = operand,
                .src_tok = gz.tokenIndexToRelative(abs_tok_index),
            } },
        });
        return new_index;
    }

    fn addStrTok(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        str_index: Zir.NullTerminatedString,
        /// Absolute token index. This function does the conversion to Decl offset.
        abs_tok_index: Ast.TokenIndex,
    ) !Zir.Inst.Ref {
        return gz.add(.{
            .tag = tag,
            .data = .{ .str_tok = .{
                .start = str_index,
                .src_tok = gz.tokenIndexToRelative(abs_tok_index),
            } },
        });
    }

    fn addSaveErrRetIndex(
        gz: *GenZir,
        cond: union(enum) {
            always: void,
            if_of_error_type: Zir.Inst.Ref,
        },
    ) !Zir.Inst.Index {
        return gz.addAsIndex(.{
            .tag = .save_err_ret_index,
            .data = .{ .save_err_ret_index = .{
                .operand = switch (cond) {
                    .if_of_error_type => |x| x,
                    else => .none,
                },
            } },
        });
    }

    const BranchTarget = union(enum) {
        ret,
        block: Zir.Inst.Index,
    };

    fn addRestoreErrRetIndex(
        gz: *GenZir,
        bt: BranchTarget,
        cond: union(enum) {
            always: void,
            if_non_error: Zir.Inst.Ref,
        },
        src_node: Ast.Node.Index,
    ) !Zir.Inst.Index {
        switch (cond) {
            .always => return gz.addAsIndex(.{
                .tag = .restore_err_ret_index_unconditional,
                .data = .{ .un_node = .{
                    .operand = switch (bt) {
                        .ret => .none,
                        .block => |b| b.toRef(),
                    },
                    .src_node = gz.nodeIndexToRelative(src_node),
                } },
            }),
            .if_non_error => |operand| switch (bt) {
                .ret => return gz.addAsIndex(.{
                    .tag = .restore_err_ret_index_fn_entry,
                    .data = .{ .un_node = .{
                        .operand = operand,
                        .src_node = gz.nodeIndexToRelative(src_node),
                    } },
                }),
                .block => |block| return (try gz.addExtendedPayload(
                    .restore_err_ret_index,
                    Zir.Inst.RestoreErrRetIndex{
                        .src_node = gz.nodeIndexToRelative(src_node),
                        .block = block.toRef(),
                        .operand = operand,
                    },
                )).toIndex().?,
            },
        }
    }

    fn addBreak(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        block_inst: Zir.Inst.Index,
        operand: Zir.Inst.Ref,
    ) !Zir.Inst.Index {
        const gpa = gz.astgen.gpa;
        try gz.instructions.ensureUnusedCapacity(gpa, 1);

        const new_index = try gz.makeBreak(tag, block_inst, operand);
        gz.instructions.appendAssumeCapacity(new_index);
        return new_index;
    }

    fn makeBreak(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        block_inst: Zir.Inst.Index,
        operand: Zir.Inst.Ref,
    ) !Zir.Inst.Index {
        return gz.makeBreakCommon(tag, block_inst, operand, null);
    }

    fn addBreakWithSrcNode(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        block_inst: Zir.Inst.Index,
        operand: Zir.Inst.Ref,
        operand_src_node: Ast.Node.Index,
    ) !Zir.Inst.Index {
        const gpa = gz.astgen.gpa;
        try gz.instructions.ensureUnusedCapacity(gpa, 1);

        const new_index = try gz.makeBreakWithSrcNode(tag, block_inst, operand, operand_src_node);
        gz.instructions.appendAssumeCapacity(new_index);
        return new_index;
    }

    fn makeBreakWithSrcNode(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        block_inst: Zir.Inst.Index,
        operand: Zir.Inst.Ref,
        operand_src_node: Ast.Node.Index,
    ) !Zir.Inst.Index {
        return gz.makeBreakCommon(tag, block_inst, operand, operand_src_node);
    }

    fn makeBreakCommon(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        block_inst: Zir.Inst.Index,
        operand: Zir.Inst.Ref,
        operand_src_node: ?Ast.Node.Index,
    ) !Zir.Inst.Index {
        const gpa = gz.astgen.gpa;
        try gz.astgen.instructions.ensureUnusedCapacity(gpa, 1);
        try gz.astgen.extra.ensureUnusedCapacity(gpa, @typeInfo(Zir.Inst.Break).@"struct".fields.len);

        const new_index: Zir.Inst.Index = @enumFromInt(gz.astgen.instructions.len);
        gz.astgen.instructions.appendAssumeCapacity(.{
            .tag = tag,
            .data = .{ .@"break" = .{
                .operand = operand,
                .payload_index = gz.astgen.addExtraAssumeCapacity(Zir.Inst.Break{
                    .operand_src_node = if (operand_src_node) |src_node|
                        gz.nodeIndexToRelative(src_node).toOptional()
                    else
                        .none,
                    .block_inst = block_inst,
                }),
            } },
        });
        return new_index;
    }

    fn addBin(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        lhs: Zir.Inst.Ref,
        rhs: Zir.Inst.Ref,
    ) !Zir.Inst.Ref {
        assert(lhs != .none);
        assert(rhs != .none);
        return gz.add(.{
            .tag = tag,
            .data = .{ .bin = .{
                .lhs = lhs,
                .rhs = rhs,
            } },
        });
    }

    fn addDefer(gz: *GenZir, index: u32, len: u32) !void {
        _ = try gz.add(.{
            .tag = .@"defer",
            .data = .{ .@"defer" = .{
                .index = index,
                .len = len,
            } },
        });
    }

    fn addDecl(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        decl_index: u32,
        src_node: Ast.Node.Index,
    ) !Zir.Inst.Ref {
        return gz.add(.{
            .tag = tag,
            .data = .{ .pl_node = .{
                .src_node = gz.nodeIndexToRelative(src_node),
                .payload_index = decl_index,
            } },
        });
    }

    fn addNode(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        /// Absolute node index. This function does the conversion to offset from Decl.
        src_node: Ast.Node.Index,
    ) !Zir.Inst.Ref {
        return gz.add(.{
            .tag = tag,
            .data = .{ .node = gz.nodeIndexToRelative(src_node) },
        });
    }

    fn addInstNode(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        inst: Zir.Inst.Index,
        /// Absolute node index. This function does the conversion to offset from Decl.
        src_node: Ast.Node.Index,
    ) !Zir.Inst.Ref {
        return gz.add(.{
            .tag = tag,
            .data = .{ .inst_node = .{
                .inst = inst,
                .src_node = gz.nodeIndexToRelative(src_node),
            } },
        });
    }

    fn addNodeExtended(
        gz: *GenZir,
        opcode: Zir.Inst.Extended,
        /// Absolute node index. This function does the conversion to offset from Decl.
        src_node: Ast.Node.Index,
    ) !Zir.Inst.Ref {
        return gz.add(.{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = opcode,
                .small = undefined,
                .operand = @bitCast(@intFromEnum(gz.nodeIndexToRelative(src_node))),
            } },
        });
    }

    fn addAllocExtended(
        gz: *GenZir,
        args: struct {
            /// Absolute node index. This function does the conversion to offset from Decl.
            node: Ast.Node.Index,
            type_inst: Zir.Inst.Ref,
            align_inst: Zir.Inst.Ref,
            is_const: bool,
            is_comptime: bool,
        },
    ) !Zir.Inst.Ref {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;

        try gz.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.extra.ensureUnusedCapacity(
            gpa,
            @typeInfo(Zir.Inst.AllocExtended).@"struct".fields.len +
                @intFromBool(args.type_inst != .none) +
                @intFromBool(args.align_inst != .none),
        );
        const payload_index = gz.astgen.addExtraAssumeCapacity(Zir.Inst.AllocExtended{
            .src_node = gz.nodeIndexToRelative(args.node),
        });
        if (args.type_inst != .none) {
            astgen.extra.appendAssumeCapacity(@intFromEnum(args.type_inst));
        }
        if (args.align_inst != .none) {
            astgen.extra.appendAssumeCapacity(@intFromEnum(args.align_inst));
        }

        const has_type: u4 = @intFromBool(args.type_inst != .none);
        const has_align: u4 = @intFromBool(args.align_inst != .none);
        const is_const: u4 = @intFromBool(args.is_const);
        const is_comptime: u4 = @intFromBool(args.is_comptime);
        const small: u16 = has_type | (has_align << 1) | (is_const << 2) | (is_comptime << 3);

        const new_index: Zir.Inst.Index = @enumFromInt(astgen.instructions.len);
        astgen.instructions.appendAssumeCapacity(.{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = .alloc,
                .small = small,
                .operand = payload_index,
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        return new_index.toRef();
    }

    fn addAsm(
        gz: *GenZir,
        args: struct {
            tag: Zir.Inst.Extended,
            /// Absolute node index. This function does the conversion to offset from Decl.
            node: Ast.Node.Index,
            asm_source: Zir.NullTerminatedString,
            output_type_bits: u32,
            is_volatile: bool,
            outputs: []const Zir.Inst.Asm.Output,
            inputs: []const Zir.Inst.Asm.Input,
            clobbers: Zir.Inst.Ref,
        },
    ) !Zir.Inst.Ref {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;

        try gz.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.extra.ensureUnusedCapacity(gpa, @typeInfo(Zir.Inst.Asm).@"struct".fields.len +
            args.outputs.len * @typeInfo(Zir.Inst.Asm.Output).@"struct".fields.len +
            args.inputs.len * @typeInfo(Zir.Inst.Asm.Input).@"struct".fields.len);

        const payload_index = gz.astgen.addExtraAssumeCapacity(Zir.Inst.Asm{
            .src_node = gz.nodeIndexToRelative(args.node),
            .asm_source = args.asm_source,
            .output_type_bits = args.output_type_bits,
            .clobbers = args.clobbers,
        });
        for (args.outputs) |output| {
            _ = gz.astgen.addExtraAssumeCapacity(output);
        }
        for (args.inputs) |input| {
            _ = gz.astgen.addExtraAssumeCapacity(input);
        }

        const small: Zir.Inst.Asm.Small = .{
            .outputs_len = @intCast(args.outputs.len),
            .inputs_len = @intCast(args.inputs.len),
            .is_volatile = args.is_volatile,
        };

        const new_index: Zir.Inst.Index = @enumFromInt(astgen.instructions.len);
        astgen.instructions.appendAssumeCapacity(.{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = args.tag,
                .small = @bitCast(small),
                .operand = payload_index,
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        return new_index.toRef();
    }

    /// Note that this returns a `Zir.Inst.Index` not a ref.
    /// Does *not* append the block instruction to the scope.
    /// Leaves the `payload_index` field undefined.
    fn makeBlockInst(gz: *GenZir, tag: Zir.Inst.Tag, node: Ast.Node.Index) !Zir.Inst.Index {
        const new_index: Zir.Inst.Index = @enumFromInt(gz.astgen.instructions.len);
        const gpa = gz.astgen.gpa;
        try gz.astgen.instructions.append(gpa, .{
            .tag = tag,
            .data = .{ .pl_node = .{
                .src_node = gz.nodeIndexToRelative(node),
                .payload_index = undefined,
            } },
        });
        return new_index;
    }

    /// Note that this returns a `Zir.Inst.Index` not a ref.
    /// Does *not* append the block instruction to the scope.
    /// Leaves the `payload_index` field undefined. Use `setDeclaration` to finalize.
    fn makeDeclaration(gz: *GenZir, node: Ast.Node.Index) !Zir.Inst.Index {
        const new_index: Zir.Inst.Index = @enumFromInt(gz.astgen.instructions.len);
        try gz.astgen.instructions.append(gz.astgen.gpa, .{
            .tag = .declaration,
            .data = .{ .declaration = .{
                .src_node = node,
                .payload_index = undefined,
            } },
        });
        return new_index;
    }

    /// Note that this returns a `Zir.Inst.Index` not a ref.
    /// Leaves the `payload_index` field undefined.
    fn addCondBr(gz: *GenZir, tag: Zir.Inst.Tag, node: Ast.Node.Index) !Zir.Inst.Index {
        const gpa = gz.astgen.gpa;
        try gz.instructions.ensureUnusedCapacity(gpa, 1);
        const new_index: Zir.Inst.Index = @enumFromInt(gz.astgen.instructions.len);
        try gz.astgen.instructions.append(gpa, .{
            .tag = tag,
            .data = .{ .pl_node = .{
                .src_node = gz.nodeIndexToRelative(node),
                .payload_index = undefined,
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        return new_index;
    }

    fn setStruct(gz: *GenZir, inst: Zir.Inst.Index, args: struct {
        src_node: Ast.Node.Index,
        captures_len: u32,
        fields_len: u32,
        decls_len: u32,
        has_backing_int: bool,
        layout: std.builtin.Type.ContainerLayout,
        known_non_opv: bool,
        known_comptime_only: bool,
        any_comptime_fields: bool,
        any_default_inits: bool,
        any_aligned_fields: bool,
        fields_hash: std.zig.SrcHash,
        name_strat: Zir.Inst.NameStrategy,
    }) !void {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;

        // Node .root is valid for the root `struct_decl` of a file!
        assert(args.src_node != .root or gz.parent.tag == .top);

        const fields_hash_arr: [4]u32 = @bitCast(args.fields_hash);

        try astgen.extra.ensureUnusedCapacity(gpa, @typeInfo(Zir.Inst.StructDecl).@"struct".fields.len + 3);
        const payload_index = astgen.addExtraAssumeCapacity(Zir.Inst.StructDecl{
            .fields_hash_0 = fields_hash_arr[0],
            .fields_hash_1 = fields_hash_arr[1],
            .fields_hash_2 = fields_hash_arr[2],
            .fields_hash_3 = fields_hash_arr[3],
            .src_line = astgen.source_line,
            .src_node = args.src_node,
        });

        if (args.captures_len != 0) {
            astgen.extra.appendAssumeCapacity(args.captures_len);
        }
        if (args.fields_len != 0) {
            astgen.extra.appendAssumeCapacity(args.fields_len);
        }
        if (args.decls_len != 0) {
            astgen.extra.appendAssumeCapacity(args.decls_len);
        }
        astgen.instructions.set(@intFromEnum(inst), .{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = .struct_decl,
                .small = @bitCast(Zir.Inst.StructDecl.Small{
                    .has_captures_len = args.captures_len != 0,
                    .has_fields_len = args.fields_len != 0,
                    .has_decls_len = args.decls_len != 0,
                    .has_backing_int = args.has_backing_int,
                    .known_non_opv = args.known_non_opv,
                    .known_comptime_only = args.known_comptime_only,
                    .name_strategy = args.name_strat,
                    .layout = args.layout,
                    .any_comptime_fields = args.any_comptime_fields,
                    .any_default_inits = args.any_default_inits,
                    .any_aligned_fields = args.any_aligned_fields,
                }),
                .operand = payload_index,
            } },
        });
    }

    fn setUnion(gz: *GenZir, inst: Zir.Inst.Index, args: struct {
        src_node: Ast.Node.Index,
        tag_type: Zir.Inst.Ref,
        captures_len: u32,
        body_len: u32,
        fields_len: u32,
        decls_len: u32,
        layout: std.builtin.Type.ContainerLayout,
        auto_enum_tag: bool,
        any_aligned_fields: bool,
        fields_hash: std.zig.SrcHash,
        name_strat: Zir.Inst.NameStrategy,
    }) !void {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;

        assert(args.src_node != .root);

        const fields_hash_arr: [4]u32 = @bitCast(args.fields_hash);

        try astgen.extra.ensureUnusedCapacity(gpa, @typeInfo(Zir.Inst.UnionDecl).@"struct".fields.len + 5);
        const payload_index = astgen.addExtraAssumeCapacity(Zir.Inst.UnionDecl{
            .fields_hash_0 = fields_hash_arr[0],
            .fields_hash_1 = fields_hash_arr[1],
            .fields_hash_2 = fields_hash_arr[2],
            .fields_hash_3 = fields_hash_arr[3],
            .src_line = astgen.source_line,
            .src_node = args.src_node,
        });

        if (args.tag_type != .none) {
            astgen.extra.appendAssumeCapacity(@intFromEnum(args.tag_type));
        }
        if (args.captures_len != 0) {
            astgen.extra.appendAssumeCapacity(args.captures_len);
        }
        if (args.body_len != 0) {
            astgen.extra.appendAssumeCapacity(args.body_len);
        }
        if (args.fields_len != 0) {
            astgen.extra.appendAssumeCapacity(args.fields_len);
        }
        if (args.decls_len != 0) {
            astgen.extra.appendAssumeCapacity(args.decls_len);
        }
        astgen.instructions.set(@intFromEnum(inst), .{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = .union_decl,
                .small = @bitCast(Zir.Inst.UnionDecl.Small{
                    .has_tag_type = args.tag_type != .none,
                    .has_captures_len = args.captures_len != 0,
                    .has_body_len = args.body_len != 0,
                    .has_fields_len = args.fields_len != 0,
                    .has_decls_len = args.decls_len != 0,
                    .name_strategy = args.name_strat,
                    .layout = args.layout,
                    .auto_enum_tag = args.auto_enum_tag,
                    .any_aligned_fields = args.any_aligned_fields,
                }),
                .operand = payload_index,
            } },
        });
    }

    fn setEnum(gz: *GenZir, inst: Zir.Inst.Index, args: struct {
        src_node: Ast.Node.Index,
        tag_type: Zir.Inst.Ref,
        captures_len: u32,
        body_len: u32,
        fields_len: u32,
        decls_len: u32,
        nonexhaustive: bool,
        fields_hash: std.zig.SrcHash,
        name_strat: Zir.Inst.NameStrategy,
    }) !void {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;

        assert(args.src_node != .root);

        const fields_hash_arr: [4]u32 = @bitCast(args.fields_hash);

        try astgen.extra.ensureUnusedCapacity(gpa, @typeInfo(Zir.Inst.EnumDecl).@"struct".fields.len + 5);
        const payload_index = astgen.addExtraAssumeCapacity(Zir.Inst.EnumDecl{
            .fields_hash_0 = fields_hash_arr[0],
            .fields_hash_1 = fields_hash_arr[1],
            .fields_hash_2 = fields_hash_arr[2],
            .fields_hash_3 = fields_hash_arr[3],
            .src_line = astgen.source_line,
            .src_node = args.src_node,
        });

        if (args.tag_type != .none) {
            astgen.extra.appendAssumeCapacity(@intFromEnum(args.tag_type));
        }
        if (args.captures_len != 0) {
            astgen.extra.appendAssumeCapacity(args.captures_len);
        }
        if (args.body_len != 0) {
            astgen.extra.appendAssumeCapacity(args.body_len);
        }
        if (args.fields_len != 0) {
            astgen.extra.appendAssumeCapacity(args.fields_len);
        }
        if (args.decls_len != 0) {
            astgen.extra.appendAssumeCapacity(args.decls_len);
        }
        astgen.instructions.set(@intFromEnum(inst), .{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = .enum_decl,
                .small = @bitCast(Zir.Inst.EnumDecl.Small{
                    .has_tag_type = args.tag_type != .none,
                    .has_captures_len = args.captures_len != 0,
                    .has_body_len = args.body_len != 0,
                    .has_fields_len = args.fields_len != 0,
                    .has_decls_len = args.decls_len != 0,
                    .name_strategy = args.name_strat,
                    .nonexhaustive = args.nonexhaustive,
                }),
                .operand = payload_index,
            } },
        });
    }

    fn setOpaque(gz: *GenZir, inst: Zir.Inst.Index, args: struct {
        src_node: Ast.Node.Index,
        captures_len: u32,
        decls_len: u32,
        name_strat: Zir.Inst.NameStrategy,
    }) !void {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;

        assert(args.src_node != .root);

        try astgen.extra.ensureUnusedCapacity(gpa, @typeInfo(Zir.Inst.OpaqueDecl).@"struct".fields.len + 2);
        const payload_index = astgen.addExtraAssumeCapacity(Zir.Inst.OpaqueDecl{
            .src_line = astgen.source_line,
            .src_node = args.src_node,
        });

        if (args.captures_len != 0) {
            astgen.extra.appendAssumeCapacity(args.captures_len);
        }
        if (args.decls_len != 0) {
            astgen.extra.appendAssumeCapacity(args.decls_len);
        }
        astgen.instructions.set(@intFromEnum(inst), .{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = .opaque_decl,
                .small = @bitCast(Zir.Inst.OpaqueDecl.Small{
                    .has_captures_len = args.captures_len != 0,
                    .has_decls_len = args.decls_len != 0,
                    .name_strategy = args.name_strat,
                }),
                .operand = payload_index,
            } },
        });
    }

    fn add(gz: *GenZir, inst: Zir.Inst) !Zir.Inst.Ref {
        return (try gz.addAsIndex(inst)).toRef();
    }

    fn addAsIndex(gz: *GenZir, inst: Zir.Inst) !Zir.Inst.Index {
        const gpa = gz.astgen.gpa;
        try gz.instructions.ensureUnusedCapacity(gpa, 1);
        try gz.astgen.instructions.ensureUnusedCapacity(gpa, 1);

        const new_index: Zir.Inst.Index = @enumFromInt(gz.astgen.instructions.len);
        gz.astgen.instructions.appendAssumeCapacity(inst);
        gz.instructions.appendAssumeCapacity(new_index);
        return new_index;
    }

    fn reserveInstructionIndex(gz: *GenZir) !Zir.Inst.Index {
        const gpa = gz.astgen.gpa;
        try gz.instructions.ensureUnusedCapacity(gpa, 1);
        try gz.astgen.instructions.ensureUnusedCapacity(gpa, 1);

        const new_index: Zir.Inst.Index = @enumFromInt(gz.astgen.instructions.len);
        gz.astgen.instructions.len += 1;
        gz.instructions.appendAssumeCapacity(new_index);
        return new_index;
    }

    fn addRet(gz: *GenZir, ri: ResultInfo, operand: Zir.Inst.Ref, node: Ast.Node.Index) !void {
        switch (ri.rl) {
            .ptr => |ptr_res| _ = try gz.addUnNode(.ret_load, ptr_res.inst, node),
            .coerced_ty => _ = try gz.addUnNode(.ret_node, operand, node),
            else => unreachable,
        }
    }

    fn addDbgVar(gz: *GenZir, tag: Zir.Inst.Tag, name: Zir.NullTerminatedString, inst: Zir.Inst.Ref) !void {
        if (gz.is_comptime) return;

        _ = try gz.add(.{ .tag = tag, .data = .{
            .str_op = .{
                .str = name,
                .operand = inst,
            },
        } });
    }
};

/// This can only be for short-lived references; the memory becomes invalidated
/// when another string is added.
fn nullTerminatedString(astgen: AstGen, index: Zir.NullTerminatedString) [*:0]const u8 {
    return @ptrCast(astgen.string_bytes.items[@intFromEnum(index)..]);
}

/// Local variables shadowing detection, including function parameters.
fn detectLocalShadowing(
    astgen: *AstGen,
    scope: *Scope,
    ident_name: Zir.NullTerminatedString,
    name_token: Ast.TokenIndex,
    token_bytes: []const u8,
    id_cat: Scope.IdCat,
) !void {
    const gpa = astgen.gpa;
    if (token_bytes[0] != '@' and isPrimitive(token_bytes)) {
        return astgen.failTokNotes(name_token, "name shadows primitive '{s}'", .{
            token_bytes,
        }, &[_]u32{
            try astgen.errNoteTok(name_token, "consider using @\"{s}\" to disambiguate", .{
                token_bytes,
            }),
        });
    }

    var s = scope;
    var outer_scope = false;
    while (true) switch (s.tag) {
        .local_val => {
            const local_val = s.cast(Scope.LocalVal).?;
            if (local_val.name == ident_name) {
                const name_slice = mem.span(astgen.nullTerminatedString(ident_name));
                const name = try gpa.dupe(u8, name_slice);
                defer gpa.free(name);
                if (outer_scope) {
                    return astgen.failTokNotes(name_token, "{s} '{s}' shadows {s} from outer scope", .{
                        @tagName(id_cat), name, @tagName(local_val.id_cat),
                    }, &[_]u32{
                        try astgen.errNoteTok(
                            local_val.token_src,
                            "previous declaration here",
                            .{},
                        ),
                    });
                }
                return astgen.failTokNotes(name_token, "redeclaration of {s} '{s}'", .{
                    @tagName(local_val.id_cat), name,
                }, &[_]u32{
                    try astgen.errNoteTok(
                        local_val.token_src,
                        "previous declaration here",
                        .{},
                    ),
                });
            }
            s = local_val.parent;
        },
        .local_ptr => {
            const local_ptr = s.cast(Scope.LocalPtr).?;
            if (local_ptr.name == ident_name) {
                const name_slice = mem.span(astgen.nullTerminatedString(ident_name));
                const name = try gpa.dupe(u8, name_slice);
                defer gpa.free(name);
                if (outer_scope) {
                    return astgen.failTokNotes(name_token, "{s} '{s}' shadows {s} from outer scope", .{
                        @tagName(id_cat), name, @tagName(local_ptr.id_cat),
                    }, &[_]u32{
                        try astgen.errNoteTok(
                            local_ptr.token_src,
                            "previous declaration here",
                            .{},
                        ),
                    });
                }
                return astgen.failTokNotes(name_token, "redeclaration of {s} '{s}'", .{
                    @tagName(local_ptr.id_cat), name,
                }, &[_]u32{
                    try astgen.errNoteTok(
                        local_ptr.token_src,
                        "previous declaration here",
                        .{},
                    ),
                });
            }
            s = local_ptr.parent;
        },
        .namespace => {
            outer_scope = true;
            const ns = s.cast(Scope.Namespace).?;
            const decl_node = ns.decls.get(ident_name) orelse {
                s = ns.parent;
                continue;
            };
            const name_slice = mem.span(astgen.nullTerminatedString(ident_name));
            const name = try gpa.dupe(u8, name_slice);
            defer gpa.free(name);
            return astgen.failTokNotes(name_token, "{s} shadows declaration of '{s}'", .{
                @tagName(id_cat), name,
            }, &[_]u32{
                try astgen.errNoteNode(decl_node, "declared here", .{}),
            });
        },
        .gen_zir => {
            s = s.cast(GenZir).?.parent;
            outer_scope = true;
        },
        .defer_normal, .defer_error => s = s.cast(Scope.Defer).?.parent,
        .top => break,
    };
}

const LineColumn = struct { u32, u32 };

/// Advances the source cursor to the main token of `node` if not in comptime scope.
/// Usually paired with `emitDbgStmt`.
fn maybeAdvanceSourceCursorToMainToken(gz: *GenZir, node: Ast.Node.Index) LineColumn {
    if (gz.is_comptime) return .{ gz.astgen.source_line - gz.decl_line, gz.astgen.source_column };

    const tree = gz.astgen.tree;
    const node_start = tree.tokenStart(tree.nodeMainToken(node));
    gz.astgen.advanceSourceCursor(node_start);

    return .{ gz.astgen.source_line - gz.decl_line, gz.astgen.source_column };
}

/// Advances the source cursor to the beginning of `node`.
fn advanceSourceCursorToNode(astgen: *AstGen, node: Ast.Node.Index) void {
    const tree = astgen.tree;
    const node_start = tree.tokenStart(tree.firstToken(node));
    astgen.advanceSourceCursor(node_start);
}

/// Advances the source cursor to an absolute byte offset `end` in the file.
fn advanceSourceCursor(astgen: *AstGen, end: usize) void {
    const source = astgen.tree.source;
    var i = astgen.source_offset;
    var line = astgen.source_line;
    var column = astgen.source_column;
    assert(i <= end);
    while (i < end) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            column = 0;
        } else {
            column += 1;
        }
    }
    astgen.source_offset = i;
    astgen.source_line = line;
    astgen.source_column = column;
}

const SourceCursor = struct {
    offset: u32,
    line: u32,
    column: u32,
};

/// Get the current source cursor, to be restored later with `restoreSourceCursor`.
/// This is useful when analyzing source code out-of-order.
fn saveSourceCursor(astgen: *const AstGen) SourceCursor {
    return .{
        .offset = astgen.source_offset,
        .line = astgen.source_line,
        .column = astgen.source_column,
    };
}
fn restoreSourceCursor(astgen: *AstGen, cursor: SourceCursor) void {
    astgen.source_offset = cursor.offset;
    astgen.source_line = cursor.line;
    astgen.source_column = cursor.column;
}

/// Detects name conflicts for decls and fields, and populates `namespace.decls` with all named declarations.
/// Returns the number of declarations in the namespace, including unnamed declarations (e.g. `comptime` decls).
fn scanContainer(
    astgen: *AstGen,
    namespace: *Scope.Namespace,
    members: []const Ast.Node.Index,
    container_kind: enum { @"struct", @"union", @"enum", @"opaque" },
) !u32 {
    const gpa = astgen.gpa;
    const tree = astgen.tree;

    var any_invalid_declarations = false;

    // This type forms a linked list of source tokens declaring the same name.
    const NameEntry = struct {
        tok: Ast.TokenIndex,
        /// Using a linked list here simplifies memory management, and is acceptable since
        ///ewntries are only allocated in error situations. The entries are allocated into the
        /// AstGen arena.
        next: ?*@This(),
    };

    // The maps below are allocated into this SFBA to avoid using the GPA for small namespaces.
    var sfba_state = std.heap.stackFallback(512, astgen.gpa);
    const sfba = sfba_state.get();

    var names: std.AutoArrayHashMapUnmanaged(Zir.NullTerminatedString, NameEntry) = .empty;
    var test_names: std.AutoArrayHashMapUnmanaged(Zir.NullTerminatedString, NameEntry) = .empty;
    var decltest_names: std.AutoArrayHashMapUnmanaged(Zir.NullTerminatedString, NameEntry) = .empty;
    defer {
        names.deinit(sfba);
        test_names.deinit(sfba);
        decltest_names.deinit(sfba);
    }

    var any_duplicates = false;
    var decl_count: u32 = 0;
    for (members) |member_node| {
        const Kind = enum { decl, field };
        const kind: Kind, const name_token = switch (tree.nodeTag(member_node)) {
            .container_field_init,
            .container_field_align,
            .container_field,
            => blk: {
                var full = tree.fullContainerField(member_node).?;
                switch (container_kind) {
                    .@"struct", .@"opaque" => {},
                    .@"union", .@"enum" => full.convertToNonTupleLike(astgen.tree),
                }
                if (full.ast.tuple_like) continue;
                break :blk .{ .field, full.ast.main_token };
            },

            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            => blk: {
                decl_count += 1;
                break :blk .{ .decl, tree.nodeMainToken(member_node) + 1 };
            },

            .fn_proto_simple,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto,
            .fn_decl,
            => blk: {
                decl_count += 1;
                const ident = tree.nodeMainToken(member_node) + 1;
                if (tree.tokenTag(ident) != .identifier) {
                    try astgen.appendErrorNode(member_node, "missing function name", .{});
                    any_invalid_declarations = true;
                    continue;
                }
                break :blk .{ .decl, ident };
            },

            .@"comptime" => {
                decl_count += 1;
                continue;
            },

            .test_decl => {
                decl_count += 1;
                // We don't want shadowing detection here, and test names work a bit differently, so
                // we must do the redeclaration detection ourselves.
                const test_name_token = tree.nodeMainToken(member_node) + 1;
                const new_ent: NameEntry = .{
                    .tok = test_name_token,
                    .next = null,
                };
                switch (tree.tokenTag(test_name_token)) {
                    else => {}, // unnamed test
                    .string_literal => {
                        const name = try astgen.strLitAsString(test_name_token);
                        const gop = try test_names.getOrPut(sfba, name.index);
                        if (gop.found_existing) {
                            var e = gop.value_ptr;
                            while (e.next) |n| e = n;
                            e.next = try astgen.arena.create(NameEntry);
                            e.next.?.* = new_ent;
                            any_duplicates = true;
                        } else {
                            gop.value_ptr.* = new_ent;
                        }
                    },
                    .identifier => {
                        const name = try astgen.identAsString(test_name_token);
                        const gop = try decltest_names.getOrPut(sfba, name);
                        if (gop.found_existing) {
                            var e = gop.value_ptr;
                            while (e.next) |n| e = n;
                            e.next = try astgen.arena.create(NameEntry);
                            e.next.?.* = new_ent;
                            any_duplicates = true;
                        } else {
                            gop.value_ptr.* = new_ent;
                        }
                    },
                }
                continue;
            },

            else => unreachable,
        };

        const name_str_index = try astgen.identAsString(name_token);

        if (kind == .decl) {
            // Put the name straight into `decls`, even if there are compile errors.
            // This avoids incorrect "undeclared identifier" errors later on.
            try namespace.decls.put(gpa, name_str_index, member_node);
        }

        {
            const gop = try names.getOrPut(sfba, name_str_index);
            const new_ent: NameEntry = .{
                .tok = name_token,
                .next = null,
            };
            if (gop.found_existing) {
                var e = gop.value_ptr;
                while (e.next) |n| e = n;
                e.next = try astgen.arena.create(NameEntry);
                e.next.?.* = new_ent;
                any_duplicates = true;
                continue;
            } else {
                gop.value_ptr.* = new_ent;
            }
        }

        // For fields, we only needed the duplicate check! Decls have some more checks to do, though.
        switch (kind) {
            .decl => {},
            .field => continue,
        }

        const token_bytes = astgen.tree.tokenSlice(name_token);
        if (token_bytes[0] != '@' and isPrimitive(token_bytes)) {
            try astgen.appendErrorTokNotes(name_token, "name shadows primitive '{s}'", .{
                token_bytes,
            }, &.{
                try astgen.errNoteTok(name_token, "consider using @\"{s}\" to disambiguate", .{
                    token_bytes,
                }),
            });
            any_invalid_declarations = true;
            continue;
        }

        var s = namespace.parent;
        while (true) switch (s.tag) {
            .local_val => {
                const local_val = s.cast(Scope.LocalVal).?;
                if (local_val.name == name_str_index) {
                    try astgen.appendErrorTokNotes(name_token, "declaration '{s}' shadows {s} from outer scope", .{
                        token_bytes, @tagName(local_val.id_cat),
                    }, &.{
                        try astgen.errNoteTok(
                            local_val.token_src,
                            "previous declaration here",
                            .{},
                        ),
                    });
                    any_invalid_declarations = true;
                    break;
                }
                s = local_val.parent;
            },
            .local_ptr => {
                const local_ptr = s.cast(Scope.LocalPtr).?;
                if (local_ptr.name == name_str_index) {
                    try astgen.appendErrorTokNotes(name_token, "declaration '{s}' shadows {s} from outer scope", .{
                        token_bytes, @tagName(local_ptr.id_cat),
                    }, &.{
                        try astgen.errNoteTok(
                            local_ptr.token_src,
                            "previous declaration here",
                            .{},
                        ),
                    });
                    any_invalid_declarations = true;
                    break;
                }
                s = local_ptr.parent;
            },
            .namespace => s = s.cast(Scope.Namespace).?.parent,
            .gen_zir => s = s.cast(GenZir).?.parent,
            .defer_normal, .defer_error => s = s.cast(Scope.Defer).?.parent,
            .top => break,
        };
    }

    if (!any_duplicates) {
        if (any_invalid_declarations) return error.AnalysisFail;
        return decl_count;
    }

    for (names.keys(), names.values()) |name, first| {
        if (first.next == null) continue;
        var notes: std.ArrayListUnmanaged(u32) = .empty;
        var prev: NameEntry = first;
        while (prev.next) |cur| : (prev = cur.*) {
            try notes.append(astgen.arena, try astgen.errNoteTok(cur.tok, "duplicate name here", .{}));
        }
        try notes.append(astgen.arena, try astgen.errNoteNode(namespace.node, "{s} declared here", .{@tagName(container_kind)}));
        const name_duped = try astgen.arena.dupe(u8, mem.span(astgen.nullTerminatedString(name)));
        try astgen.appendErrorTokNotes(first.tok, "duplicate {s} member name '{s}'", .{ @tagName(container_kind), name_duped }, notes.items);
        any_invalid_declarations = true;
    }

    for (test_names.keys(), test_names.values()) |name, first| {
        if (first.next == null) continue;
        var notes: std.ArrayListUnmanaged(u32) = .empty;
        var prev: NameEntry = first;
        while (prev.next) |cur| : (prev = cur.*) {
            try notes.append(astgen.arena, try astgen.errNoteTok(cur.tok, "duplicate test here", .{}));
        }
        try notes.append(astgen.arena, try astgen.errNoteNode(namespace.node, "{s} declared here", .{@tagName(container_kind)}));
        const name_duped = try astgen.arena.dupe(u8, mem.span(astgen.nullTerminatedString(name)));
        try astgen.appendErrorTokNotes(first.tok, "duplicate test name '{s}'", .{name_duped}, notes.items);
        any_invalid_declarations = true;
    }

    for (decltest_names.keys(), decltest_names.values()) |name, first| {
        if (first.next == null) continue;
        var notes: std.ArrayListUnmanaged(u32) = .empty;
        var prev: NameEntry = first;
        while (prev.next) |cur| : (prev = cur.*) {
            try notes.append(astgen.arena, try astgen.errNoteTok(cur.tok, "duplicate decltest here", .{}));
        }
        try notes.append(astgen.arena, try astgen.errNoteNode(namespace.node, "{s} declared here", .{@tagName(container_kind)}));
        const name_duped = try astgen.arena.dupe(u8, mem.span(astgen.nullTerminatedString(name)));
        try astgen.appendErrorTokNotes(first.tok, "duplicate decltest '{s}'", .{name_duped}, notes.items);
        any_invalid_declarations = true;
    }

    assert(any_invalid_declarations);
    return error.AnalysisFail;
}

/// Assumes capacity for body has already been added. Needed capacity taking into
/// account fixups can be found with `countBodyLenAfterFixups`.
fn appendBodyWithFixups(astgen: *AstGen, body: []const Zir.Inst.Index) void {
    return appendBodyWithFixupsArrayList(astgen, &astgen.extra, body);
}

fn appendBodyWithFixupsArrayList(
    astgen: *AstGen,
    list: *std.ArrayListUnmanaged(u32),
    body: []const Zir.Inst.Index,
) void {
    astgen.appendBodyWithFixupsExtraRefsArrayList(list, body, &.{});
}

fn appendBodyWithFixupsExtraRefsArrayList(
    astgen: *AstGen,
    list: *std.ArrayListUnmanaged(u32),
    body: []const Zir.Inst.Index,
    extra_refs: []const Zir.Inst.Index,
) void {
    for (extra_refs) |extra_inst| {
        if (astgen.ref_table.fetchRemove(extra_inst)) |kv| {
            appendPossiblyRefdBodyInst(astgen, list, kv.value);
        }
    }
    for (body) |body_inst| {
        appendPossiblyRefdBodyInst(astgen, list, body_inst);
    }
}

fn appendPossiblyRefdBodyInst(
    astgen: *AstGen,
    list: *std.ArrayListUnmanaged(u32),
    body_inst: Zir.Inst.Index,
) void {
    list.appendAssumeCapacity(@intFromEnum(body_inst));
    const kv = astgen.ref_table.fetchRemove(body_inst) orelse return;
    const ref_inst = kv.value;
    return appendPossiblyRefdBodyInst(astgen, list, ref_inst);
}

fn countBodyLenAfterFixups(astgen: *AstGen, body: []const Zir.Inst.Index) u32 {
    return astgen.countBodyLenAfterFixupsExtraRefs(body, &.{});
}

/// Return the number of instructions in `body` after prepending the `ref` instructions in `ref_table`.
/// As well as all instructions in `body`, we also prepend `ref`s of any instruction in `extra_refs`.
/// For instance, if an index has been reserved with a special meaning to a child block, it must be
/// passed to `extra_refs` to ensure `ref`s of that index are added correctly.
fn countBodyLenAfterFixupsExtraRefs(astgen: *AstGen, body: []const Zir.Inst.Index, extra_refs: []const Zir.Inst.Index) u32 {
    var count = body.len;
    for (body) |body_inst| {
        var check_inst = body_inst;
        while (astgen.ref_table.get(check_inst)) |ref_inst| {
            count += 1;
            check_inst = ref_inst;
        }
    }
    for (extra_refs) |extra_inst| {
        var check_inst = extra_inst;
        while (astgen.ref_table.get(check_inst)) |ref_inst| {
            count += 1;
            check_inst = ref_inst;
        }
    }
    return @intCast(count);
}

fn emitDbgStmt(gz: *GenZir, lc: LineColumn) !void {
    if (gz.is_comptime) return;
    if (gz.instructions.items.len > gz.instructions_top) {
        const astgen = gz.astgen;
        const last = gz.instructions.items[gz.instructions.items.len - 1];
        if (astgen.instructions.items(.tag)[@intFromEnum(last)] == .dbg_stmt) {
            astgen.instructions.items(.data)[@intFromEnum(last)].dbg_stmt = .{
                .line = lc[0],
                .column = lc[1],
            };
            return;
        }
    }

    _ = try gz.add(.{ .tag = .dbg_stmt, .data = .{
        .dbg_stmt = .{
            .line = lc[0],
            .column = lc[1],
        },
    } });
}

/// In some cases, Sema expects us to generate a `dbg_stmt` at the instruction
/// *index* directly preceding the next instruction (e.g. if a call is %10, it
/// expects a dbg_stmt at %9). TODO: this logic may allow redundant dbg_stmt
/// instructions; fix up Sema so we don't need it!
fn emitDbgStmtForceCurrentIndex(gz: *GenZir, lc: LineColumn) !void {
    const astgen = gz.astgen;
    if (gz.instructions.items.len > gz.instructions_top and
        @intFromEnum(gz.instructions.items[gz.instructions.items.len - 1]) == astgen.instructions.len - 1)
    {
        const last = astgen.instructions.len - 1;
        if (astgen.instructions.items(.tag)[last] == .dbg_stmt) {
            astgen.instructions.items(.data)[last].dbg_stmt = .{
                .line = lc[0],
                .column = lc[1],
            };
            return;
        }
    }

    _ = try gz.add(.{ .tag = .dbg_stmt, .data = .{
        .dbg_stmt = .{
            .line = lc[0],
            .column = lc[1],
        },
    } });
}

fn lowerAstErrors(astgen: *AstGen) error{OutOfMemory}!void {
    const gpa = astgen.gpa;
    const tree = astgen.tree;
    assert(tree.errors.len > 0);

    var msg: std.io.Writer.Allocating = .init(gpa);
    defer msg.deinit();
    const msg_w = &msg.writer;

    var notes: std.ArrayListUnmanaged(u32) = .empty;
    defer notes.deinit(gpa);

    const token_starts = tree.tokens.items(.start);
    const token_tags = tree.tokens.items(.tag);
    const parse_err = tree.errors[0];
    const tok = parse_err.token + @intFromBool(parse_err.token_is_prev);
    const tok_start = token_starts[tok];
    const start_char = tree.source[tok_start];

    if (token_tags[tok] == .invalid and
        (start_char == '\"' or start_char == '\'' or start_char == '/' or mem.startsWith(u8, tree.source[tok_start..], "\\\\")))
    {
        const tok_len: u32 = @intCast(tree.tokenSlice(tok).len);
        const tok_end = tok_start + tok_len;
        const bad_off = blk: {
            var idx = tok_start;
            while (idx < tok_end) : (idx += 1) {
                switch (tree.source[idx]) {
                    0x00...0x09, 0x0b...0x1f, 0x7f => break,
                    else => {},
                }
            }
            break :blk idx - tok_start;
        };

        const ast_err: Ast.Error = .{
            .tag = Ast.Error.Tag.invalid_byte,
            .token = tok,
            .extra = .{ .offset = bad_off },
        };
        msg.clearRetainingCapacity();
        tree.renderError(ast_err, msg_w) catch return error.OutOfMemory;
        return try astgen.appendErrorTokNotesOff(tok, bad_off, "{s}", .{msg.getWritten()}, notes.items);
    }

    var cur_err = tree.errors[0];
    for (tree.errors[1..]) |err| {
        if (err.is_note) {
            tree.renderError(err, msg_w) catch return error.OutOfMemory;
            try notes.append(gpa, try astgen.errNoteTok(err.token, "{s}", .{msg.getWritten()}));
        } else {
            // Flush error
            const extra_offset = tree.errorOffset(cur_err);
            tree.renderError(cur_err, msg_w) catch return error.OutOfMemory;
            try astgen.appendErrorTokNotesOff(cur_err.token, extra_offset, "{s}", .{msg.getWritten()}, notes.items);
            notes.clearRetainingCapacity();
            cur_err = err;

            // TODO: `Parse` currently does not have good error recovery mechanisms, so the remaining errors could be bogus.
            // As such, we'll ignore all remaining errors for now. We should improve `Parse` so that we can report all the errors.
            return;
        }
        msg.clearRetainingCapacity();
    }

    // Flush error
    const extra_offset = tree.errorOffset(cur_err);
    tree.renderError(cur_err, msg_w) catch return error.OutOfMemory;
    try astgen.appendErrorTokNotesOff(cur_err.token, extra_offset, "{s}", .{msg.getWritten()}, notes.items);
}

const DeclarationName = union(enum) {
    named: Ast.TokenIndex,
    named_test: Ast.TokenIndex,
    decltest: Ast.TokenIndex,
    unnamed_test,
    @"comptime",
};

fn addFailedDeclaration(
    wip_members: *WipMembers,
    gz: *GenZir,
    kind: Zir.Inst.Declaration.Unwrapped.Kind,
    name: Zir.NullTerminatedString,
    src_node: Ast.Node.Index,
    is_pub: bool,
) !void {
    const decl_inst = try gz.makeDeclaration(src_node);
    wip_members.nextDecl(decl_inst);

    var dummy_gz = gz.makeSubBlock(&gz.base);

    var value_gz = gz.makeSubBlock(&gz.base); // scope doesn't matter here
    _ = try value_gz.add(.{
        .tag = .extended,
        .data = .{ .extended = .{
            .opcode = .astgen_error,
            .small = undefined,
            .operand = undefined,
        } },
    });

    try setDeclaration(decl_inst, .{
        .src_hash = @splat(0), // use a fixed hash to represent an AstGen failure; we don't care about source changes if AstGen still failed!
        .src_line = gz.astgen.source_line,
        .src_column = gz.astgen.source_column,
        .kind = kind,
        .name = name,
        .is_pub = is_pub,
        .is_threadlocal = false,
        .linkage = .normal,
        .type_gz = &dummy_gz,
        .align_gz = &dummy_gz,
        .linksection_gz = &dummy_gz,
        .addrspace_gz = &dummy_gz,
        .value_gz = &value_gz,
    });
}

/// Sets all extra data for a `declaration` instruction.
/// Unstacks `type_gz`, `align_gz`, `linksection_gz`, `addrspace_gz`, and `value_gz`.
fn setDeclaration(
    decl_inst: Zir.Inst.Index,
    args: struct {
        src_hash: std.zig.SrcHash,
        src_line: u32,
        src_column: u32,

        kind: Zir.Inst.Declaration.Unwrapped.Kind,
        name: Zir.NullTerminatedString,
        is_pub: bool,
        is_threadlocal: bool,
        linkage: Zir.Inst.Declaration.Unwrapped.Linkage,
        lib_name: Zir.NullTerminatedString = .empty,

        type_gz: *GenZir,
        /// Must be stacked on `type_gz`.
        align_gz: *GenZir,
        /// Must be stacked on `align_gz`.
        linksection_gz: *GenZir,
        /// Must be stacked on `linksection_gz`.
        addrspace_gz: *GenZir,
        /// Must be stacked on `addrspace_gz` and have nothing stacked on top of it.
        value_gz: *GenZir,
    },
) !void {
    const astgen = args.value_gz.astgen;
    const gpa = astgen.gpa;

    const type_body = args.type_gz.instructionsSliceUpto(args.align_gz);
    const align_body = args.align_gz.instructionsSliceUpto(args.linksection_gz);
    const linksection_body = args.linksection_gz.instructionsSliceUpto(args.addrspace_gz);
    const addrspace_body = args.addrspace_gz.instructionsSliceUpto(args.value_gz);
    const value_body = args.value_gz.instructionsSlice();

    const has_name = args.name != .empty;
    const has_lib_name = args.lib_name != .empty;
    const has_type_body = type_body.len != 0;
    const has_special_body = align_body.len != 0 or linksection_body.len != 0 or addrspace_body.len != 0;
    const has_value_body = value_body.len != 0;

    const id: Zir.Inst.Declaration.Flags.Id = switch (args.kind) {
        .unnamed_test => .unnamed_test,
        .@"test" => .@"test",
        .decltest => .decltest,
        .@"comptime" => .@"comptime",
        .@"const" => switch (args.linkage) {
            .normal => if (args.is_pub) id: {
                if (has_special_body) break :id .pub_const;
                if (has_type_body) break :id .pub_const_typed;
                break :id .pub_const_simple;
            } else id: {
                if (has_special_body) break :id .@"const";
                if (has_type_body) break :id .const_typed;
                break :id .const_simple;
            },
            .@"extern" => if (args.is_pub) id: {
                if (has_lib_name) break :id .pub_extern_const;
                if (has_special_body) break :id .pub_extern_const;
                break :id .pub_extern_const_simple;
            } else id: {
                if (has_lib_name) break :id .extern_const;
                if (has_special_body) break :id .extern_const;
                break :id .extern_const_simple;
            },
            .@"export" => if (args.is_pub) .pub_export_const else .export_const,
        },
        .@"var" => switch (args.linkage) {
            .normal => if (args.is_pub) id: {
                if (args.is_threadlocal) break :id .pub_var_threadlocal;
                if (has_special_body) break :id .pub_var;
                if (has_type_body) break :id .pub_var;
                break :id .pub_var_simple;
            } else id: {
                if (args.is_threadlocal) break :id .var_threadlocal;
                if (has_special_body) break :id .@"var";
                if (has_type_body) break :id .@"var";
                break :id .var_simple;
            },
            .@"extern" => if (args.is_pub) id: {
                if (args.is_threadlocal) break :id .pub_extern_var_threadlocal;
                break :id .pub_extern_var;
            } else id: {
                if (args.is_threadlocal) break :id .extern_var_threadlocal;
                break :id .extern_var;
            },
            .@"export" => if (args.is_pub) id: {
                if (args.is_threadlocal) break :id .pub_export_var_threadlocal;
                break :id .pub_export_var;
            } else id: {
                if (args.is_threadlocal) break :id .export_var_threadlocal;
                break :id .export_var;
            },
        },
    };

    assert(id.hasTypeBody() or !has_type_body);
    assert(id.hasSpecialBodies() or !has_special_body);
    assert(id.hasValueBody() == has_value_body);
    assert(id.linkage() == args.linkage);
    assert(id.hasName() == has_name);
    assert(id.hasLibName() or !has_lib_name);
    assert(id.isPub() == args.is_pub);
    assert(id.isThreadlocal() == args.is_threadlocal);

    const type_len = astgen.countBodyLenAfterFixups(type_body);
    const align_len = astgen.countBodyLenAfterFixups(align_body);
    const linksection_len = astgen.countBodyLenAfterFixups(linksection_body);
    const addrspace_len = astgen.countBodyLenAfterFixups(addrspace_body);
    const value_len = astgen.countBodyLenAfterFixups(value_body);

    const src_hash_arr: [4]u32 = @bitCast(args.src_hash);
    const flags: Zir.Inst.Declaration.Flags = .{
        .src_line = @intCast(args.src_line),
        .src_column = @intCast(args.src_column),
        .id = id,
    };
    const flags_arr: [2]u32 = @bitCast(flags);

    const need_extra: usize =
        @typeInfo(Zir.Inst.Declaration).@"struct".fields.len +
        @as(usize, @intFromBool(id.hasName())) +
        @as(usize, @intFromBool(id.hasLibName())) +
        @as(usize, @intFromBool(id.hasTypeBody())) +
        3 * @as(usize, @intFromBool(id.hasSpecialBodies())) +
        @as(usize, @intFromBool(id.hasValueBody())) +
        type_len + align_len + linksection_len + addrspace_len + value_len;

    try astgen.extra.ensureUnusedCapacity(gpa, need_extra);

    const extra: Zir.Inst.Declaration = .{
        .src_hash_0 = src_hash_arr[0],
        .src_hash_1 = src_hash_arr[1],
        .src_hash_2 = src_hash_arr[2],
        .src_hash_3 = src_hash_arr[3],
        .flags_0 = flags_arr[0],
        .flags_1 = flags_arr[1],
    };
    astgen.instructions.items(.data)[@intFromEnum(decl_inst)].declaration.payload_index =
        astgen.addExtraAssumeCapacity(extra);

    if (id.hasName()) {
        astgen.extra.appendAssumeCapacity(@intFromEnum(args.name));
    }
    if (id.hasLibName()) {
        astgen.extra.appendAssumeCapacity(@intFromEnum(args.lib_name));
    }
    if (id.hasTypeBody()) {
        astgen.extra.appendAssumeCapacity(type_len);
    }
    if (id.hasSpecialBodies()) {
        astgen.extra.appendSliceAssumeCapacity(&.{
            align_len,
            linksection_len,
            addrspace_len,
        });
    }
    if (id.hasValueBody()) {
        astgen.extra.appendAssumeCapacity(value_len);
    }

    astgen.appendBodyWithFixups(type_body);
    astgen.appendBodyWithFixups(align_body);
    astgen.appendBodyWithFixups(linksection_body);
    astgen.appendBodyWithFixups(addrspace_body);
    astgen.appendBodyWithFixups(value_body);

    args.value_gz.unstack();
    args.addrspace_gz.unstack();
    args.linksection_gz.unstack();
    args.align_gz.unstack();
    args.type_gz.unstack();
}

/// Given a list of instructions, returns a list of all instructions which are a `ref` of one of the originals,
/// from `astgen.ref_table`, non-recursively. The entries are removed from `astgen.ref_table`, and the returned
/// slice can then be treated as its own body, to append `ref` instructions to a body other than the one they
/// would normally exist in.
///
/// This is used when lowering functions. Very rarely, the callconv expression, align expression, etc may reference
/// function parameters via `&param`; in this case, we need to lower to a `ref` instruction in the callconv/align/etc
/// body, rather than in the declaration body. However, we don't append these bodies to `extra` until we've evaluated
/// *all* of the bodies into a big `GenZir` stack. Therefore, we use this function to pull out these per-body `ref`
/// instructions which must be emitted.
fn fetchRemoveRefEntries(astgen: *AstGen, param_insts: []const Zir.Inst.Index) ![]Zir.Inst.Index {
    var refs: std.ArrayListUnmanaged(Zir.Inst.Index) = .empty;
    for (param_insts) |param_inst| {
        if (astgen.ref_table.fetchRemove(param_inst)) |kv| {
            try refs.append(astgen.arena, kv.value);
        }
    }
    return refs.items;
}

test {
    _ = &generate;
}
