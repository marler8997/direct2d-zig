const std = @import("std");
const ddui = @import("ddui");
const win32 = @import("win32").everything;

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

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const apiFailNoreturn = ddui.apiFailNoreturnDefault;
fn lastErrorI32() i32 {
    return @bitCast(@intFromEnum(win32.GetLastError()));
}

fn dpiFromHwnd(hwnd: win32.HWND) u32 {
    const value = win32.GetDpiForWindow(hwnd);
    if (value == 0) apiFailNoreturn("GetDpiForWindow", lastErrorI32());
    return value;
}
const Dpi = struct {
    value: u32,
    pub fn eql(self: Dpi, other: Dpi) bool {
        return self.value == other.value;
    }
};
fn createTextFormatCenter18pt(dpi: Dpi) *win32.IDWriteTextFormat {
    var err: ddui.HResultError = undefined;
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

fn invalidateHwnd(hwnd: win32.HWND) void {
    if (0 == win32.InvalidateRect(hwnd, null, 0)) apiFailNoreturn("InvalidateRect", lastErrorI32());
}

const State = struct {
    render: ddui.Render,
    layout: Layout = undefined,
    bg_erased: bool = false,
    text_format_center_18pt: ddui.TextFormatCache(Dpi, createTextFormatCenter18pt) = .{},
    mouse: ddui.mouse.State(MouseTarget) = .{},
    pub fn deinit(self: *State) void {
        self.render.deinit();
    }
};

pub fn paint(
    render: *ddui.Render,
    dpi: u32,
    layout: *const Layout,
    mouse: *const ddui.mouse.State(MouseTarget),
    text_format_center_18pt: *win32.IDWriteTextFormat,
) void {
    render.DrawText(
        win32.L("ddui: A Zig library for making UIs with Direct2D."),
        text_format_center_18pt,
        ddui.rectFloatFromInt(layout.title),
        ddui.shade8(255),
        .{},
        .NATURAL,
    );
    const round = ddui.scaleDpiT(f32, 4, dpi);
    render.FillRoundedRectangle(
        layout.new_window_button,
        round,
        round,
        ddui.shade8(mouse.resolveLeft(u8, .new_window_button, .{
            .none = 40,
            .hover = 50,
            .down = 30,
        })),
    );
    render.DrawText(
        win32.L("New Window"),
        text_format_center_18pt,
        ddui.rectFloatFromInt(layout.new_window_button),
        ddui.shade8(255),
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
    if (global.window_class == 0) apiFailNoreturn("RegisterClass", lastErrorI32());

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
    ) orelse apiFailNoreturn("CreateWindow", lastErrorI32());

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

    if (0 == win32.UpdateWindow(hwnd)) apiFailNoreturn("UpdateWindow", lastErrorI32());

    // for some reason this causes the window to paint before being shown so we
    // don't get a white flicker when the window shows up
    if (0 == win32.SetWindowPos(hwnd, null, 0, 0, 0, 0, .{
        .NOMOVE = 1,
        .NOSIZE = 1,
        .NOOWNERZORDER = 1,
    })) apiFailNoreturn("SetWindowPos", lastErrorI32());
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
        if (hr < 0) std.debug.panic("DWriteCreateFactory failed, hresult=0x{x}", .{@as(u32, @bitCast(hr))});
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
                invalidateHwnd(hwnd);
            }
        },
        win32.WM_LBUTTONDOWN => {
            const point = ddui.pointFromLparam(lparam);
            const state = stateFromHwnd(hwnd);
            if (state.mouse.updateTarget(targetFromPoint(&state.layout, point))) {
                invalidateHwnd(hwnd);
            }
            state.mouse.setLeftDown();
        },
        win32.WM_LBUTTONUP => {
            const point = ddui.pointFromLparam(lparam);
            const state = stateFromHwnd(hwnd);
            if (state.mouse.updateTarget(targetFromPoint(&state.layout, point))) {
                invalidateHwnd(hwnd);
            }
            if (state.mouse.setLeftUp()) |target| switch (target) {
                .new_window_button => newWindow(),
            };
        },
        win32.WM_PAINT => {
            const dpi = dpiFromHwnd(hwnd);
            const client_size = getClientSize(hwnd);
            const state = stateFromHwnd(hwnd);
            state.layout.update(dpi, client_size);

            var ps: win32.PAINTSTRUCT = undefined;
            {
                var err: ddui.Error = undefined;
                state.render.beginPaintHwnd(&ps, dpi, .{
                    .width = @intCast(client_size.x),
                    .height = @intCast(client_size.y),
                }, &err) catch std.debug.panic(
                    "Direct2D BeginPaint failed, context={s}, hresult=0x{x}",
                    .{ @tagName(err.context), err.hr },
                );
            }
            state.render.Clear(ddui.shade8(window_bg_shade));
            paint(
                &state.render,
                dpi,
                &state.layout,
                &state.mouse,
                state.text_format_center_18pt.getOrCreate(Dpi{ .value = dpi }),
            );
            {
                var err: ddui.Error = undefined;
                state.render.endPaintHwnd(&ps, &err) catch std.debug.panic(
                    "Direct2D EndPaint failed, context={s}, hresult=0x{x}",
                    .{ @tagName(err.context), err.hr },
                );
            }

            return 0;
        },
        win32.WM_ERASEBKGND => {
            const state = stateFromHwnd(hwnd);
            if (!state.bg_erased) {
                state.bg_erased = true;
                const hdc: win32.HDC = @ptrFromInt(wparam);
                const client_size = getClientSize(hwnd);
                const brush = win32.CreateSolidBrush(colorrefFromShade(window_bg_shade)) orelse apiFailNoreturn("CreateSolidBrush", lastErrorI32());
                defer if (0 == win32.DeleteObject(brush)) apiFailNoreturn("DeleteObject", lastErrorI32());
                const client_rect: win32.RECT = .{
                    .left = 0,
                    .top = 0,
                    .right = client_size.x,
                    .bottom = client_size.y,
                };
                if (0 == win32.FillRect(hdc, &client_rect, brush)) apiFailNoreturn("FillRect", lastErrorI32());
            }
            return 1;
        },
        win32.WM_CREATE => {
            var err: ddui.Error = undefined;
            const state = global.gpa.create(State) catch |e| oom(e);
            errdefer global.gpa.destroy(state);
            state.* = .{
                .render = ddui.initHwnd(hwnd, &err, .{}) catch std.debug.panic(
                    "failed to initialize Direct2D, context={s}, hresult=0x{x}",
                    .{ @tagName(err.context), err.hr },
                ),
            };
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

fn closeHandle(handle: win32.HANDLE) void {
    if (0 == win32.CloseHandle(handle)) apiFailNoreturn("CloseHandle", lastErrorI32());
}

fn getClientSize(hwnd: win32.HWND) XY(i32) {
    var rect: win32.RECT = undefined;
    if (0 == win32.GetClientRect(hwnd, &rect)) apiFailNoreturn("GetClientRect", lastErrorI32());
    if (rect.left != 0) std.debug.panic("client rect non-zero left {}", .{rect.left});
    if (rect.top != 0) std.debug.panic("client rect non-zero top {}", .{rect.top});
    return .{ .x = rect.right, .y = rect.bottom };
}

fn colorrefFromShade(shade: u8) u32 {
    return (@as(u32, shade) << 0) | (@as(u32, shade) << 8) | (@as(u32, shade) << 16);
}
