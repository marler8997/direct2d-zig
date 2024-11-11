const std = @import("std");
const root = @import("root");
const win32 = struct {
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").graphics.direct_write;
    usingnamespace @import("win32").graphics.direct2d.common;
    usingnamespace @import("win32").graphics.gdi;
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").graphics.direct2d;
    usingnamespace @import("win32").zig;
};
pub const mouse = @import("ddui/mouse.zig");

pub fn loword(value: anytype) u16 {
    switch (@typeInfo(@TypeOf(value))) {
        .Int => |int| switch (int.signedness) {
            .signed => return loword(@as(@Type(.{ .Int = .{ .signedness = .unsigned, .bits = int.bits } }), @bitCast(value))),
            .unsigned => return if (int.bits <= 16) value else @intCast(0xffff & value),
        },
        else => {},
    }
    @compileError("unsupported type " ++ @typeName(@TypeOf(value)));
}
pub fn hiword(value: anytype) u16 {
    switch (@typeInfo(@TypeOf(value))) {
        .Int => |int| switch (int.signedness) {
            .signed => return hiword(@as(@Type(.{ .Int = .{ .signedness = .unsigned, .bits = int.bits } }), @bitCast(value))),
            .unsigned => return @intCast(0xffff & (value >> 16)),
        },
        else => {},
    }
    @compileError("unsupported type " ++ @typeName(@TypeOf(value)));
}

fn xFromLparam(lparam: win32.LPARAM) i16 {
    return @bitCast(loword(lparam));
}
fn yFromLparam(lparam: win32.LPARAM) i16 {
    return @bitCast(hiword(lparam));
}

pub fn pointFromLparam(lparam: win32.LPARAM) win32.POINT {
    return win32.POINT{ .x = xFromLparam(lparam), .y = yFromLparam(lparam) };
}

pub fn rectFloatFromInt(rect: win32.RECT) win32.D2D_RECT_F {
    return .{
        .left = @floatFromInt(rect.left),
        .right = @floatFromInt(rect.right),
        .top = @floatFromInt(rect.top),
        .bottom = @floatFromInt(rect.bottom),
    };
}
pub fn rectIntFromSize(args: struct { left: i32, top: i32, width: i32, height: i32 }) win32.RECT {
    return .{
        .left = args.left,
        .top = args.top,
        .right = args.left + args.width,
        .bottom = args.top + args.height,
    };
}

pub fn rectContainsPoint(r: win32.RECT, p: win32.POINT) bool {
    return p.x >= r.left and
        p.x < r.right and
        p.y >= r.top and
        p.y < r.bottom;
}

pub fn scaleDpiT(comptime T: type, value: anytype, dpi: u32) T {
    std.debug.assert(dpi >= 96);
    switch (@typeInfo(T)) {
        .ComptimeFloat => @compileError("should this work?"),
        .Float => {
            return value * (@as(T, @floatFromInt(dpi)) / @as(T, 96.0));
        },
        .Int => return @intFromFloat(@as(f32, @floatFromInt(value)) * (@as(f32, @floatFromInt(dpi)) / 96.0)),
        else => @compileError("scale_dpi does not support type " ++ @typeName(@TypeOf(value))),
    }
}
pub fn scaleDpi(value: anytype, dpi: u32) @TypeOf(value) {
    return scaleDpiT(@TypeOf(value), dpi);
}

pub fn shade8(shade: u8) win32.D2D_COLOR_F {
    return .{
        .r = @as(f32, @floatFromInt(shade)) / 255.0,
        .g = @as(f32, @floatFromInt(shade)) / 255.0,
        .b = @as(f32, @floatFromInt(shade)) / 255.0,
        .a = 1.0,
    };
}
pub fn rgb8(r: u8, g: u8, b: u8) win32.D2D_COLOR_F {
    return .{
        .r = @as(f32, @floatFromInt(r)) / 255.0,
        .g = @as(f32, @floatFromInt(g)) / 255.0,
        .b = @as(f32, @floatFromInt(b)) / 255.0,
        .a = 1.0,
    };
}

pub fn createFactory(
    factory_type: win32.D2D1_FACTORY_TYPE,
    opt: struct {
        debug_level: win32.D2D1_DEBUG_LEVEL = .NONE,
    },
    err: *HResultError,
) error{HResult}!*win32.ID2D1Factory {
    var factory: *win32.ID2D1Factory = undefined;
    const options: win32.D2D1_FACTORY_OPTIONS = .{
        .debugLevel = opt.debug_level,
    };
    const hr = win32.D2D1CreateFactory(
        factory_type,
        win32.IID_ID2D1Factory,
        &options,
        @ptrCast(&factory),
    );
    if (hr < 0) return err.set(hr, "D2D1CreateFactory");
    return factory;
}

pub fn FillRoundedRectangle(
    target: *const win32.ID2D1RenderTarget,
    rect: win32.RECT,
    roundX: f32,
    roundY: f32,
    b: *win32.ID2D1Brush,
) void {
    const rounded_rect: win32.D2D1_ROUNDED_RECT = .{
        .rect = rectFloatFromInt(rect),
        .radiusX = roundX,
        .radiusY = roundY,
    };
    target.FillRoundedRectangle(&rounded_rect, b);
}

pub fn DrawText(
    target: *const win32.ID2D1RenderTarget,
    str: []const u16,
    text_format: *win32.IDWriteTextFormat,
    rect: win32.D2D_RECT_F,
    brush: *win32.ID2D1Brush,
    opt: win32.D2D1_DRAW_TEXT_OPTIONS,
    measure: win32.DWRITE_MEASURING_MODE,
) void {
    target.DrawText(
        @ptrCast(str.ptr),
        @intCast(str.len),
        text_format,
        &rect,
        brush,
        opt,
        measure,
    );
}

pub const TextFormatOptions = struct {
    family_name: [:0]const u16,
    size: f32,
    locale: [:0]const u16 = win32.L(""),
    weight: win32.DWRITE_FONT_WEIGHT = win32.DWRITE_FONT_WEIGHT_NORMAL,
    style: win32.DWRITE_FONT_STYLE = win32.DWRITE_FONT_STYLE_NORMAL,
    center_x: bool = false,
    center_y: bool = false,
    nowrap: bool = false,
    //trimming: ?win32.DWRITE_TRIMMING = null,
};

pub const HResultError = struct {
    /// a win32 HRESULT
    hr: i32 = 0,
    context: [:0]const u8,
    pub fn set(
        self: *HResultError,
        hr: win32.HRESULT,
        context: [:0]const u8,
    ) error{HResult} {
        self.* = .{ .hr = @bitCast(hr), .context = context };
        return error.HResult;
    }
    pub fn format(
        self: HResultError,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            "{s} failed, hresult=0x{x}",
            .{ self.context, @as(u32, @bitCast(self.hr)) },
        );
    }
};

pub fn createTextFormat(
    factory: *win32.IDWriteFactory,
    err_store: *HResultError,
    opt: TextFormatOptions,
) error{HResult}!*win32.IDWriteTextFormat {
    var text_format: *win32.IDWriteTextFormat = undefined;

    {
        const hr = factory.CreateTextFormat(
            opt.family_name,
            null,
            opt.weight,
            opt.style,
            win32.DWRITE_FONT_STRETCH_NORMAL,
            opt.size,
            opt.locale,
            @ptrCast(&text_format),
        );
        if (hr < 0) return err_store.set(hr, "CreateTextFormat");
    }
    errdefer _ = text_format.IUnknown.Release();

    if (opt.center_x) {
        const hr = text_format.SetTextAlignment(win32.DWRITE_TEXT_ALIGNMENT_CENTER);
        if (hr < 0) return err_store.set(hr, "SetTextAlignment");
    }
    if (opt.center_y) {
        const hr = text_format.SetParagraphAlignment(win32.DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        if (hr < 0) return err_store.set(hr, "SetParagraphAlignment");
    }
    if (opt.nowrap) {
        const hr = text_format.SetWordWrapping(win32.DWRITE_WORD_WRAPPING_NO_WRAP);
        if (hr < 0) return err_store.set(hr, "SetWordWrapping");
    }
    //    if (opt.trimming) |trimming| {
    //        IDWriteInlineObject *ellipsis;
    //        {
    //            HRESULT hr = factory.CreateEllipsisTrimmingSign(
    //                text_format, &ellipsis
    //            );
    //            if (FAILED(hr))
    //                return CreateTextFormatError(hr, "CreateEllipsisTrimmingSign");
    //        }
    //        defer2(ellipsis.Release());
    //        {
    //            HRESULT hr = text_format.SetTrimming(&opt.trimming.value(), ellipsis);
    //            if (FAILED(hr))
    //                return CreateTextFormatError(hr, "SetTrimming");
    //        }
    //    }

    return text_format;
}

pub fn TextFormatCache(
    comptime Input: type,
    comptime Creator: fn (Input) *win32.IDWriteTextFormat,
) type {
    return struct {
        maybe_cache: ?struct {
            format: *win32.IDWriteTextFormat,
            input: Input,
        } = null,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            if (self.maybe_format) |format| {
                format.IUnknown.Release();
            }
        }

        pub fn getOrCreate(self: *Self, input: Input) *win32.IDWriteTextFormat {
            if (self.maybe_cache) |*cache| {
                if (cache.input.eql(input))
                    return cache.format;

                _ = cache.format.IUnknown.Release();
                self.maybe_cache = null;
            }

            const format = Creator(input);
            self.maybe_cache = .{
                .format = format,
                .input = input,
            };
            return format;
        }
    };
}
