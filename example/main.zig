const std = @import("std");
const ddui = @import("ddui");
const win32 = @import("win32").everything;

const HResultError = ddui.HResultError;

threadlocal var thread_is_panicing = false;
pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    if (!thread_is_panicing) {
        thread_is_panicing = true;
        const msg_z: [:0]const u8 = if (std.fmt.allocPrintZ(
            std.heap.page_allocator,
            "{s}",
            .{msg},
        )) |msg_z| msg_z else |_| "failed allocate error message";
        _ = win32.MessageBoxA(null, msg_z, "Ddui Example: Panic", .{ .ICONASTERISK = 1 });
    }
    std.builtin.default_panic(msg, error_return_trace, ret_addr);
}

pub const ErrorCode = union(enum) {
    win32: win32.WIN32_ERROR,
    hresult: i32,
};
pub fn apiFailNoreturn(comptime function_name: []const u8, ec: ErrorCode) noreturn {
    switch (ec) {
        .win32 => |e| std.debug.panic(function_name ++ " unexpectedly failed with {}", .{e.fmt()}),
        .hresult => |hr| std.debug.panic(function_name ++ " unexpectedly failed, hresult=0x{x}", .{@as(u32, @bitCast(hr))}),
    }
}

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const Dpi = struct {
    value: u32,
    pub fn eql(self: Dpi, other: Dpi) bool {
        return self.value == other.value;
    }
};
fn createTextFormatCenter18pt(dpi: Dpi) *win32.IDWriteTextFormat {
    var err: HResultError = undefined;
    return ddui.createTextFormat(global.dwrite_factory, &err, .{
        .size = ddui.scaleDpiT(f32, 18, dpi.value),
        .family_name = win32.L("Segoe UI Emoji"),
        .center_x = true,
        .center_y = true,
    }) catch std.debug.panic("{s} failed, hresult=0x{x}", .{ err.context, err.hr });
}

const global = struct {
    pub var gpa_instance: std.heap.GeneralPurposeAllocator(.{}) = .{};
    pub const gpa = gpa_instance.allocator();
    pub var dwrite_factory: *win32.IDWriteFactory = undefined;
    pub var d2d_factory: *win32.ID2D1Factory = undefined;
    pub var window_class: u16 = 0;
    pub var window_count: usize = 0;
};

const Layout = struct {
    title: win32.RECT,
    new_window_button: win32.RECT,
    pub fn update(self: *Layout, dpi: u32, client_size: XY(i32)) void {
        const margin = ddui.scaleDpiT(i32, 30, dpi);
        // todo: actually calculate font metrics?
        const max_main_font_height: i32 = ddui.scaleDpiT(i32, 30, dpi);
        const button_height: i32 = ddui.scaleDpiT(i32, 40, dpi);
        const button_width: i32 = ddui.scaleDpiT(i32, 150, dpi);
        const title_bottom: i32 = margin + max_main_font_height;
        const button_y: i32 = title_bottom + ddui.scaleDpiT(i32, 40, dpi);
        self.* = .{
            .title = .{
                .left = margin,
                .top = margin,
                .right = client_size.x - margin,
                .bottom = title_bottom,
            },
            .new_window_button = ddui.rectIntFromSize(.{
                .left = @divTrunc(client_size.x - button_width, 2),
                .top = button_y,
                .width = button_width,
                .height = button_height,
            }),
        };
    }
};

const MouseTarget = enum {
    new_window_button,
};

pub fn targetFromPoint(layout: *const Layout, point: win32.POINT) ?MouseTarget {
    if (ddui.rectContainsPoint(layout.new_window_button, point))
        return .new_window_button;
    return null;
}

const D2d = struct {
    target: *win32.ID2D1HwndRenderTarget,
    brush: *win32.ID2D1SolidColorBrush,
    pub fn init(hwnd: win32.HWND, err: *HResultError) error{HResult}!D2d {
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
            const hr = global.d2d_factory.CreateHwndRenderTarget(
                &target_props,
                &hwnd_target_props,
                @ptrCast(&target),
            );
            if (hr < 0) return err.set(hr, "CreateHwndRenderTarget");
        }
        errdefer _ = target.IUnknown.Release();

        {
            var dc: *win32.ID2D1DeviceContext = undefined;
            {
                const hr = target.IUnknown.QueryInterface(win32.IID_ID2D1DeviceContext, @ptrCast(&dc));
                if (hr < 0) return err.set(hr, "GetDeviceContext");
            }
            defer _ = dc.IUnknown.Release();
            // just make everything DPI aware, all applications should just do this
            dc.SetUnitMode(win32.D2D1_UNIT_MODE_PIXELS);
        }

        var brush: *win32.ID2D1SolidColorBrush = undefined;
        {
            const color: win32.D2D_COLOR_F = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
            const hr = target.ID2D1RenderTarget.CreateSolidColorBrush(&color, null, @ptrCast(&brush));
            if (hr < 0) return err.set(hr, "CreateSolidBrush");
        }
        errdefer _ = brush.IUnknown.Release();

        return .{
            .target = @ptrCast(target),
            .brush = brush,
        };
    }
    pub fn deinit(self: *D2d) void {
        _ = self.brush.IUnknown.Release();
        _ = self.target.IUnknown.Release();
    }
    pub fn solid(self: *const D2d, color: win32.D2D_COLOR_F) *win32.ID2D1Brush {
        self.brush.SetColor(&color);
        return &self.brush.ID2D1Brush;
    }
};

const State = struct {
    bg_erased: bool = false,
    layout: Layout = undefined,
    maybe_d2d: ?D2d = null,
    text_format_center_18pt: ddui.TextFormatCache(Dpi, createTextFormatCenter18pt) = .{},
    mouse: ddui.mouse.State(MouseTarget) = .{},
    pub fn deinit(self: *State) void {
        if (self.maybe_d2d) |*d2d| d2d.deinit();
        self.* = undefined;
    }
};

pub fn paint(
    d2d: *const D2d,
    dpi: u32,
    layout: *const Layout,
    mouse: *const ddui.mouse.State(MouseTarget),
    text_format_center_18pt: *win32.IDWriteTextFormat,
) void {
    d2d.target.ID2D1RenderTarget.SetDpi(@floatFromInt(dpi), @floatFromInt(dpi));
    {
        const color = ddui.shade8(window_bg_shade);
        d2d.target.ID2D1RenderTarget.Clear(&color);
    }
    ddui.DrawText(
        &d2d.target.ID2D1RenderTarget,
        win32.L("ddui: A Zig library for making UIs with Direct2D."),
        text_format_center_18pt,
        ddui.rectFloatFromInt(layout.title),
        d2d.solid(ddui.shade8(255)),
        .{},
        .NATURAL,
    );
    const round = ddui.scaleDpiT(f32, 4, dpi);
    ddui.FillRoundedRectangle(
        &d2d.target.ID2D1RenderTarget,
        layout.new_window_button,
        round,
        round,
        d2d.solid(ddui.shade8(mouse.resolveLeft(u8, .new_window_button, .{
            .none = 40,
            .hover = 50,
            .down = 30,
        }))),
    );
    ddui.DrawText(
        &d2d.target.ID2D1RenderTarget,
        win32.L("New Window"),
        text_format_center_18pt,
        ddui.rectFloatFromInt(layout.new_window_button),
        d2d.solid(ddui.shade8(255)),
        .{},
        .NATURAL,
    );
}

const window_bg_shade = 29;

fn newWindow() void {
    const CLASS_NAME = win32.L("DduiExampleWindow");

    if (global.window_class == 0) {
        const wc = win32.WNDCLASSEXW{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = .{ .VREDRAW = 1, .HREDRAW = 1 },
            .lpfnWndProc = WndProc,
            .cbClsExtra = 0,
            .cbWndExtra = @sizeOf(*State),
            .hInstance = win32.GetModuleHandleW(null),
            .hIcon = null,
            .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null, //L("Some Menu Name"),
            .lpszClassName = CLASS_NAME,
            .hIconSm = null,
        };
        global.window_class = win32.RegisterClassExW(&wc);
    }
    if (global.window_class == 0) apiFailNoreturn("RegisterClass", .{ .win32 = win32.GetLastError() });

    const hwnd = win32.CreateWindowExW(
        .{},
        CLASS_NAME,
        win32.L("DduiExample"),
        win32.WS_OVERLAPPEDWINDOW,
        win32.CW_USEDEFAULT, // x
        win32.CW_USEDEFAULT, // y
        600, // width
        400, // height
        null, // parent window
        null, // menu
        win32.GetModuleHandleW(null),
        null, // WM_CREATE user data
    ) orelse apiFailNoreturn("CreateWindow", .{ .win32 = win32.GetLastError() });

    {
        // TODO: maybe use DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 if applicable
        // see https://stackoverflow.com/questions/57124243/winforms-dark-title-bar-on-windows-10
        //int attribute = DWMWA_USE_IMMERSIVE_DARK_MODE;
        const dark_value: c_int = 1;
        const hr = win32.DwmSetWindowAttribute(
            hwnd,
            win32.DWMWA_USE_IMMERSIVE_DARK_MODE,
            &dark_value,
            @sizeOf(@TypeOf(dark_value)),
        );
        if (hr < 0) std.log.warn(
            "DwmSetWindowAttribute for dark={} failed, error={}",
            .{ dark_value, win32.GetLastError() },
        );
    }

    if (0 == win32.UpdateWindow(hwnd)) apiFailNoreturn("UpdateWindow", .{ .win32 = win32.GetLastError() });

    // for some reason this causes the window to paint before being shown so we
    // don't get a white flicker when the window shows up
    if (0 == win32.SetWindowPos(hwnd, null, 0, 0, 0, 0, .{
        .NOMOVE = 1,
        .NOSIZE = 1,
        .NOOWNERZORDER = 1,
    })) apiFailNoreturn("SetWindowPos", .{ .win32 = win32.GetLastError() });
    _ = win32.ShowWindow(hwnd, .{ .SHOWNORMAL = 1 });
    global.window_count += 1;
}

pub export fn wWinMain(
    hinstance: win32.HINSTANCE,
    _: ?win32.HINSTANCE,
    cmdline: [*:0]u16,
    cmdshow: c_int,
) c_int {
    _ = hinstance;
    _ = cmdline;
    _ = cmdshow;

    {
        const hr = win32.DWriteCreateFactory(
            win32.DWRITE_FACTORY_TYPE_SHARED,
            win32.IID_IDWriteFactory,
            @ptrCast(&global.dwrite_factory),
        );
        if (hr < 0) apiFailNoreturn("DWriteCreateFactory", .{ .hresult = hr });
    }
    {
        var err: HResultError = undefined;
        global.d2d_factory = ddui.createFactory(
            .SINGLE_THREADED,
            .{},
            &err,
        ) catch std.debug.panic("{}", .{err});
    }

    newWindow();

    var msg: win32.MSG = undefined;
    while (win32.GetMessageW(&msg, null, 0, 0) != 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
    return @intCast(msg.wParam);
}

fn stateFromHwnd(hwnd: win32.HWND) *State {
    const addr: usize = @bitCast(win32.GetWindowLongPtrW(hwnd, @enumFromInt(0)));
    if (addr == 0) std.debug.panic("window is missing it's state!", .{});
    return @ptrFromInt(addr);
}

fn WndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(std.os.windows.WINAPI) win32.LRESULT {
    switch (msg) {
        win32.WM_MOUSEMOVE => {
            const point = ddui.pointFromLparam(lparam);
            const state = stateFromHwnd(hwnd);
            if (state.mouse.updateTarget(targetFromPoint(&state.layout, point))) {
                win32.invalidateHwnd(hwnd);
            }
        },
        win32.WM_LBUTTONDOWN => {
            const point = ddui.pointFromLparam(lparam);
            const state = stateFromHwnd(hwnd);
            if (state.mouse.updateTarget(targetFromPoint(&state.layout, point))) {
                win32.invalidateHwnd(hwnd);
            }
            state.mouse.setLeftDown();
        },
        win32.WM_LBUTTONUP => {
            const point = ddui.pointFromLparam(lparam);
            const state = stateFromHwnd(hwnd);
            if (state.mouse.updateTarget(targetFromPoint(&state.layout, point))) {
                win32.invalidateHwnd(hwnd);
            }
            if (state.mouse.setLeftUp()) |target| switch (target) {
                .new_window_button => newWindow(),
            };
        },
        win32.WM_DISPLAYCHANGE => {
            win32.invalidateHwnd(hwnd);
            return 0;
        },
        win32.WM_PAINT => {
            const dpi = win32.dpiFromHwnd(hwnd);
            const client_size = getClientSize(hwnd);
            const state = stateFromHwnd(hwnd);

            const err: HResultError = blk: {
                var ps: win32.PAINTSTRUCT = undefined;
                _ = win32.BeginPaint(hwnd, &ps) orelse return apiFailNoreturn(
                    "BeginPaint",
                    .{ .win32 = win32.GetLastError() },
                );
                defer if (0 == win32.EndPaint(hwnd, &ps)) apiFailNoreturn(
                    "EndPaint",
                    .{ .win32 = win32.GetLastError() },
                );

                if (state.maybe_d2d == null) {
                    var err: HResultError = undefined;
                    state.maybe_d2d = D2d.init(hwnd, &err) catch break :blk err;
                }

                state.layout.update(dpi, client_size);

                {
                    const size: win32.D2D_SIZE_U = .{
                        .width = @intCast(client_size.x),
                        .height = @intCast(client_size.y),
                    };
                    const hr = state.maybe_d2d.?.target.Resize(&size);
                    if (hr < 0) break :blk HResultError{ .context = "D2dResize", .hr = hr };
                }
                state.maybe_d2d.?.target.ID2D1RenderTarget.BeginDraw();

                paint(
                    &state.maybe_d2d.?,
                    dpi,
                    &state.layout,
                    &state.mouse,
                    state.text_format_center_18pt.getOrCreate(Dpi{ .value = dpi }),
                );

                break :blk HResultError{
                    .context = "D2dEndDraw",
                    .hr = state.maybe_d2d.?.target.ID2D1RenderTarget.EndDraw(null, null),
                };
            };

            if (err.hr == win32.D2DERR_RECREATE_TARGET) {
                std.log.debug("D2DERR_RECREATE_TARGET", .{});
                state.maybe_d2d.?.deinit();
                state.maybe_d2d = null;
                win32.invalidateHwnd(hwnd);
            } else if (err.hr < 0) std.debug.panic("paint error: {}", .{err});

            return 0;
        },
        win32.WM_ERASEBKGND => {
            const state = stateFromHwnd(hwnd);
            if (!state.bg_erased) {
                state.bg_erased = true;
                const hdc: win32.HDC = @ptrFromInt(wparam);
                const client_size = getClientSize(hwnd);
                const brush = win32.CreateSolidBrush(
                    colorrefFromShade(window_bg_shade),
                ) orelse apiFailNoreturn("CreateSolidBrush", .{ .win32 = win32.GetLastError() });
                defer if (0 == win32.DeleteObject(brush)) apiFailNoreturn("DeleteObject", .{ .win32 = win32.GetLastError() });
                const client_rect: win32.RECT = .{
                    .left = 0,
                    .top = 0,
                    .right = client_size.x,
                    .bottom = client_size.y,
                };
                if (0 == win32.FillRect(hdc, &client_rect, brush)) apiFailNoreturn(
                    "FillRect",
                    .{ .win32 = win32.GetLastError() },
                );
            }
            return 1;
        },
        win32.WM_CREATE => {
            const state = global.gpa.create(State) catch |e| oom(e);
            errdefer global.gpa.destroy(state);
            state.* = .{};
            std.debug.assert(0 == win32.SetWindowLongPtrW(
                hwnd,
                @enumFromInt(0),
                @bitCast(@intFromPtr(state)),
            ));
            std.debug.assert(stateFromHwnd(hwnd) == state);
        },
        win32.WM_DESTROY => {
            {
                const state = stateFromHwnd(hwnd);
                state.deinit();
                state.* = undefined;
                global.gpa.destroy(state);
            }
            global.window_count -= 1;
            if (global.window_count == 0) {
                win32.PostQuitMessage(0);
            }
            return 0;
        },
        else => {},
    }
    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

pub fn XY(comptime T: type) type {
    return struct {
        x: T,
        y: T,
        pub fn init(x: T, y: T) @This() {
            return .{ .x = x, .y = y };
        }
    };
}

fn getClientSize(hwnd: win32.HWND) XY(i32) {
    var rect: win32.RECT = undefined;
    if (0 == win32.GetClientRect(hwnd, &rect)) apiFailNoreturn("GetClientRect", .{ .win32 = win32.GetLastError() });
    if (rect.left != 0) std.debug.panic("client rect non-zero left {}", .{rect.left});
    if (rect.top != 0) std.debug.panic("client rect non-zero top {}", .{rect.top});
    return .{ .x = rect.right, .y = rect.bottom };
}

fn colorrefFromShade(shade: u8) u32 {
    return (@as(u32, shade) << 0) | (@as(u32, shade) << 8) | (@as(u32, shade) << 16);
}
