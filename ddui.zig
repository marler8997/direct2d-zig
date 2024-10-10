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

// A function has failed that we never expect to fail, so much so that we don't see a point
// in adding an error code or even continuing on in the program if it does.
// TODO: allow the root package to override this
pub fn apiFailNoreturnDefault(comptime function_name: []const u8, last_error: i32) noreturn {
    // TODO: WIN32_ERROR should be marked as non-exhaustive and we should
    //       try to get the tag name but it's not marked that way
    std.debug.panic(function_name ++ " unexpectedly failed, error={}", .{last_error});
}
const apiFailNoreturn = if (@hasDecl(root, "apiFatalNoreturn")) root.apiFailNoreturn else apiFailNoreturnDefault;

fn lastErrorI32() i32 {
    return @bitCast(@intFromEnum(win32.GetLastError()));
}

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

const ErrorContext = enum {
    CreateFactory,
    CreateRenderTarget,
    BindDC,
    EndDraw,
    CreatePathGeometry,
    PathGeometryOpen,
    ResizeRenderTarget,
    GetDeviceContext,
};

pub const Error = struct {
    /// a win32 HRESULT
    hr: u32 = 0,
    context: ErrorContext = undefined,
    pub fn set(
        self: *Error,
        hr: win32.HRESULT,
        context: ErrorContext,
    ) error{Ddui} {
        self.* = .{ .hr = @bitCast(hr), .context = context };
        return error.Ddui;
    }
};

fn createFactory(debug_level: win32.D2D1_DEBUG_LEVEL, err: *Error) error{Ddui}!*win32.ID2D1Factory {
    var factory: *win32.ID2D1Factory = undefined;
    const options: win32.D2D1_FACTORY_OPTIONS = .{
        .debugLevel = debug_level,
    };
    const hr = win32.D2D1CreateFactory(
        .SINGLE_THREADED,
        win32.IID_ID2D1Factory,
        &options,
        @ptrCast(&factory),
    );
    if (hr != win32.S_OK) return err.set(hr, .CreateFactory);
    return factory;
}

pub const InitOptions = struct {
    debug_level: win32.D2D1_DEBUG_LEVEL = .NONE,
};

pub fn initHwnd(hwnd: win32.HWND, err: *Error, options: InitOptions) error{Ddui}!Render {
    const factory = try createFactory(options.debug_level, err);
    errdefer _ = factory.IUnknown.Release();

    var target: *win32.ID2D1HwndRenderTarget = undefined;
    const target_props = win32.D2D1_RENDER_TARGET_PROPERTIES{
        .type = .DEFAULT,
        .pixelFormat = .{
            .format = .B8G8R8A8_UNORM,
            .alphaMode = .PREMULTIPLIED,
        },
        .dpiX = 0,
        .dpiY = 0,
        .usage = .{},
        .minLevel = .DEFAULT,
    };
    const hwnd_target_props = win32.D2D1_HWND_RENDER_TARGET_PROPERTIES{
        .hwnd = hwnd,
        .pixelSize = .{ .width = 0, .height = 0 },
        .presentOptions = .{},
    };

    {
        const hr = factory.CreateHwndRenderTarget(
            &target_props,
            &hwnd_target_props,
            @ptrCast(&target),
        );
        if (hr < 0) return err.set(hr, .CreateRenderTarget);
    }

    {
        var dc: *win32.ID2D1DeviceContext = undefined;
        {
            const hr = target.IUnknown.QueryInterface(win32.IID_ID2D1DeviceContext, @ptrCast(&dc));
            if (hr < 0) return err.set(hr, .GetDeviceContext);
        }
        defer _ = dc.IUnknown.Release();
        // just make everything DPI aware, all applications should just do this
        dc.SetUnitMode(win32.D2D1_UNIT_MODE_PIXELS);
    }

    return .{
        .factory = factory,
        .target = @ptrCast(target),
        .kind = .{ .hwnd = hwnd },
    };
}

pub const Render = struct {
    factory: *win32.ID2D1Factory,
    target: *win32.ID2D1RenderTarget,
    kind: union(enum) {
        hwnd: win32.HWND,
    },
    solid_brushes: [2]?*win32.ID2D1SolidColorBrush = [2]?*win32.ID2D1SolidColorBrush{ null, null },

    pub fn deinit(self: *Render) void {
        for (self.solid_brushes) |maybe_brush| {
            if (maybe_brush) |b| {
                _ = b.IUnknown.Release();
            }
        }
        _ = self.target.IUnknown.Release();
        _ = self.factory.IUnknown.Release();
        self.* = undefined;
    }

    pub fn beginPaintHwnd(
        self: *const Render,
        paint: *win32.PAINTSTRUCT,
        dpi: u32,
        size: win32.D2D_SIZE_U,
        err: *Error,
    ) error{Ddui}!void {
        std.debug.assert(self.kind == .hwnd);
        _ = win32.BeginPaint(self.kind.hwnd, paint) orelse apiFailNoreturn("BeginPaint", lastErrorI32());
        self.target.SetDpi(@floatFromInt(dpi), @floatFromInt(dpi));

        {
            const hr = (@as(*win32.ID2D1HwndRenderTarget, @ptrCast(self.target))).Resize(&size);
            if (hr != win32.S_OK)
                return err.set(hr, .ResizeRenderTarget);
        }
        self.target.BeginDraw();
    }

    pub fn endPaintHwnd(self: *const Render, paint: *win32.PAINTSTRUCT, err: *Error) error{Ddui}!void {
        std.debug.assert(self.kind == .hwnd);
        {
            const hr = self.target.EndDraw(null, null);
            if (hr != win32.S_OK)
                return err.set(hr, .EndDraw);
        }
        if (0 == win32.EndPaint(self.kind.hwnd, paint)) apiFailNoreturn("EndPaint", lastErrorI32());
    }

    pub fn brush0(self: *Render, color: win32.D2D_COLOR_F) *win32.ID2D1Brush {
        return self.brush(0, color);
    }
    pub fn brush1(self: *Render, color: win32.D2D_COLOR_F) *win32.ID2D1Brush {
        return self.brush(1, color);
    }
    pub fn brush(self: *Render, index: usize, color: win32.D2D_COLOR_F) *win32.ID2D1Brush {
        if (self.solid_brushes[index]) |b| {
            b.SetColor(&color);
        } else {
            const hr = self.target.CreateSolidColorBrush(&color, null, &self.solid_brushes[index]);
            if (hr != win32.S_OK) apiFailNoreturn("CreateSolidBrush", hr);
        }
        return &self.solid_brushes[index].?.ID2D1Brush;
    }

    pub fn Clear(self: *const Render, color: win32.D2D_COLOR_F) void {
        self.target.Clear(&color);
    }

    pub fn FillRoundedRectangle(self: *Render, rect: win32.RECT, roundX: f32, roundY: f32, c: win32.D2D_COLOR_F) void {
        const rounded_rect: win32.D2D1_ROUNDED_RECT = .{
            .rect = rectFloatFromInt(rect),
            .radiusX = roundX,
            .radiusY = roundY,
        };
        //const rect_f = rectFloatFromInt(rect);
        self.target.FillRoundedRectangle(&rounded_rect, self.brush0(c));
    }

    // This takes a RECT which uses integers and results in crisp edges for filling rectangles.
    pub fn FillRectangle(self: *Render, rect: win32.RECT, color: win32.D2D_COLOR_F) void {
        const rect_f = rectFloatFromInt(rect);
        self.target.FillRectangle(&rect_f, self.brush0(color));
    }

    pub fn DrawText(
        self: *Render,
        str: []const u16,
        text_format: *win32.IDWriteTextFormat,
        rect: win32.D2D_RECT_F,
        color: win32.D2D_COLOR_F,
        opt: win32.D2D1_DRAW_TEXT_OPTIONS,
        measure: win32.DWRITE_MEASURING_MODE,
    ) void {
        self.target.DrawText(
            @ptrCast(str.ptr),
            @intCast(str.len),
            text_format,
            &rect,
            self.brush0(color),
            opt,
            measure,
        );
    }
};

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
    hr: u32 = 0,
    context: []const u8,
    pub fn set(
        self: *HResultError,
        hr: win32.HRESULT,
        context: []const u8,
    ) error{HResult} {
        self.* = .{ .hr = @bitCast(hr), .context = context };
        return error.HResult;
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
