/// CGEvent-based mouse and keyboard actions (built-in @cliclick command)
///
/// Implements a subset of the cliclick tool's functionality using macOS CGEvent APIs
/// directly from Zig, eliminating the need to shell out to an external binary.
const std = @import("std");
const c = @import("c.zig");
const log = std.log.scoped(.cliclick);

pub const Action = union(enum) {
    click: Point, // c:x,y - left click
    doubleclick: Point, // dc:x,y - double click
    tripleclick: Point, // tc:x,y - triple click
    rightclick: Point, // rc:x,y - right click
    move: Point, // m:x,y - move mouse
    drag_down: Point, // dd:x,y - mouse down (start drag)
    drag_up: Point, // du:x,y - mouse up (end drag)
    key_press: u16, // kp:key - key press (down + up)
    key_down: u16, // kd:key - key down
    key_up: u16, // ku:key - key up

    pub fn deinit(self: Action, _: std.mem.Allocator) void {
        // All variants use value types, no heap memory to free
        _ = self;
    }

    pub fn format(self: Action, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .click => |p| try writer.print("click({},{})", .{ p.x, p.y }),
            .doubleclick => |p| try writer.print("doubleclick({},{})", .{ p.x, p.y }),
            .tripleclick => |p| try writer.print("tripleclick({},{})", .{ p.x, p.y }),
            .rightclick => |p| try writer.print("rightclick({},{})", .{ p.x, p.y }),
            .move => |p| try writer.print("move({},{})", .{ p.x, p.y }),
            .drag_down => |p| try writer.print("drag_down({},{})", .{ p.x, p.y }),
            .drag_up => |p| try writer.print("drag_up({},{})", .{ p.x, p.y }),
            .key_press => |k| try writer.print("key_press({})", .{k}),
            .key_down => |k| try writer.print("key_down({})", .{k}),
            .key_up => |k| try writer.print("key_up({})", .{k}),
        }
    }

    pub fn eql(a: Action, b: Action) bool {
        const tag_a = std.meta.activeTag(a);
        const tag_b = std.meta.activeTag(b);
        if (tag_a != tag_b) return false;
        return switch (a) {
            .click => |pa| pa.eql(b.click),
            .doubleclick => |pa| pa.eql(b.doubleclick),
            .tripleclick => |pa| pa.eql(b.tripleclick),
            .rightclick => |pa| pa.eql(b.rightclick),
            .move => |pa| pa.eql(b.move),
            .drag_down => |pa| pa.eql(b.drag_down),
            .drag_up => |pa| pa.eql(b.drag_up),
            .key_press => |ka| ka == b.key_press,
            .key_down => |ka| ka == b.key_down,
            .key_up => |ka| ka == b.key_up,
        };
    }
};

pub const Point = struct {
    x: i32,
    y: i32,
    rel_x: bool = false,
    rel_y: bool = false,

    pub fn eql(a: Point, b: Point) bool {
        return a.x == b.x and a.y == b.y and a.rel_x == b.rel_x and a.rel_y == b.rel_y;
    }
};

pub const ParseError = error{
    UnknownCommand,
    InvalidArgumentCount,
    InvalidCoordinate,
    UnknownKeyName,
};

/// Parse a cliclick action from command name and string arguments.
///
/// Examples:
///   parseAction("c", &.{"100", "200"})   → Action{ .click = .{ .x = 100, .y = 200 } }
///   parseAction("kp", &.{"return"})       → Action{ .key_press = 0x24 }
///   parseAction("m", &.{".", "."})        → Action{ .move = current mouse position }
pub fn parseAction(cmd: []const u8, args: []const []const u8) ParseError!Action {
    // Mouse commands that take x,y
    if (std.mem.eql(u8, cmd, "c")) {
        const point = try parsePoint(args);
        return .{ .click = point };
    } else if (std.mem.eql(u8, cmd, "dc")) {
        const point = try parsePoint(args);
        return .{ .doubleclick = point };
    } else if (std.mem.eql(u8, cmd, "tc")) {
        const point = try parsePoint(args);
        return .{ .tripleclick = point };
    } else if (std.mem.eql(u8, cmd, "rc")) {
        const point = try parsePoint(args);
        return .{ .rightclick = point };
    } else if (std.mem.eql(u8, cmd, "m")) {
        const point = try parsePoint(args);
        return .{ .move = point };
    } else if (std.mem.eql(u8, cmd, "dd")) {
        const point = try parsePoint(args);
        return .{ .drag_down = point };
    } else if (std.mem.eql(u8, cmd, "du")) {
        const point = try parsePoint(args);
        return .{ .drag_up = point };
    }
    // Key commands that take a key name
    else if (std.mem.eql(u8, cmd, "kp")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        const keycode = resolveKeyName(args[0]) orelse return error.UnknownKeyName;
        return .{ .key_press = keycode };
    } else if (std.mem.eql(u8, cmd, "kd")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        const keycode = resolveKeyName(args[0]) orelse return error.UnknownKeyName;
        return .{ .key_down = keycode };
    } else if (std.mem.eql(u8, cmd, "ku")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        const keycode = resolveKeyName(args[0]) orelse return error.UnknownKeyName;
        return .{ .key_up = keycode };
    } else {
        return error.UnknownCommand;
    }
}

fn parsePoint(args: []const []const u8) ParseError!Point {
    if (args.len != 2) return error.InvalidArgumentCount;
    var point = Point{ .x = 0, .y = 0 };
    point.x = parseCoordinate(args[0], &point.rel_x) orelse return error.InvalidCoordinate;
    point.y = parseCoordinate(args[1], &point.rel_y) orelse return error.InvalidCoordinate;
    return point;
}

fn parseCoordinate(s: []const u8, is_relative: *bool) ?i32 {
    // "." means current mouse position — resolved at execution time
    if (std.mem.eql(u8, s, ".")) {
        is_relative.* = true;
        return 0;
    }

    if (s.len == 0) return null;

    var input = s;
    if (input[0] == '+') {
        is_relative.* = true;
        input = input[1..];
    } else if (input[0] == '-') {
        is_relative.* = true;
        // parseInt handles the - sign, so we keep it
    } else {
        is_relative.* = false;
    }

    return std.fmt.parseInt(i32, input, 10) catch null;
}

/// Sentinel value meaning "use current mouse position for this coordinate"
const CURRENT_POS_SENTINEL: i32 = std.math.minInt(i32);

fn getCurrentMousePosition() Point {
    const event = c.CGEventCreate(null);
    if (event) |ev| {
        defer c.CFRelease(ev);
        const loc = c.CGEventGetLocation(ev);
        return .{
            .x = @intFromFloat(loc.x),
            .y = @intFromFloat(loc.y),
        };
    }
    return .{ .x = 0, .y = 0 };
}

fn resolvePoint(point: Point) Point {
    if (point.rel_x or point.rel_y) {
        const current = getCurrentMousePosition();
        return .{
            .x = if (point.rel_x) current.x + point.x else point.x,
            .y = if (point.rel_y) current.y + point.y else point.y,
            .rel_x = false,
            .rel_y = false,
        };
    }
    return point;
}

/// Execute a cliclick action by posting CGEvent(s).
pub fn execute(action: Action) !void {
    switch (action) {
        .click => |p| try mouseClick(p, c.kCGEventLeftMouseDown, c.kCGEventLeftMouseUp, c.kCGMouseButtonLeft, 1),
        .doubleclick => |p| try mouseClick(p, c.kCGEventLeftMouseDown, c.kCGEventLeftMouseUp, c.kCGMouseButtonLeft, 2),
        .tripleclick => |p| try mouseClick(p, c.kCGEventLeftMouseDown, c.kCGEventLeftMouseUp, c.kCGMouseButtonLeft, 3),
        .rightclick => |p| try mouseClick(p, c.kCGEventRightMouseDown, c.kCGEventRightMouseUp, c.kCGMouseButtonRight, 1),
        .move => |p| try mouseMove(p),
        .drag_down => |p| try mouseDragDown(p),
        .drag_up => |p| try mouseDragUp(p),
        .key_press => |keycode| try keyPress(keycode),
        .key_down => |keycode| try keyEvent(keycode, true),
        .key_up => |keycode| try keyEvent(keycode, false),
    }
}

// ── Mouse actions ──────────────────────────────────────────────────

fn mouseClick(point: Point, down_type: c.CGEventType, up_type: c.CGEventType, button: c.CGMouseButton, click_count: u32) !void {
    const resolved = resolvePoint(point);
    const cgpoint = c.CGPointMake(@floatFromInt(resolved.x), @floatFromInt(resolved.y));

    const source = c.CGEventSourceCreate(c.kCGEventSourceStateHIDSystemState);
    if (source == null) return error.FailedToCreateEventSource;
    defer c.CFRelease(source);

    var i: u32 = 0;
    while (i < click_count) : (i += 1) {
        const down_event = c.CGEventCreateMouseEvent(source, down_type, cgpoint, button);
        if (down_event == null) return error.FailedToCreateMouseEvent;
        defer c.CFRelease(down_event);

        const up_event = c.CGEventCreateMouseEvent(source, up_type, cgpoint, button);
        if (up_event == null) return error.FailedToCreateMouseEvent;
        defer c.CFRelease(up_event);

        // Set click count for multi-click
        c.CGEventSetIntegerValueField(down_event, c.kCGMouseEventClickState, i + 1);
        c.CGEventSetIntegerValueField(up_event, c.kCGMouseEventClickState, i + 1);

        c.CGEventPost(c.kCGHIDEventTap, down_event);
        c.CGEventPost(c.kCGHIDEventTap, up_event);
    }

    log.debug("cliclick: mouse action at ({},{})", .{ resolved.x, resolved.y });
}

fn mouseMove(point: Point) !void {
    const resolved = resolvePoint(point);
    const cgpoint = c.CGPointMake(@floatFromInt(resolved.x), @floatFromInt(resolved.y));

    const source = c.CGEventSourceCreate(c.kCGEventSourceStateHIDSystemState);
    if (source == null) return error.FailedToCreateEventSource;
    defer c.CFRelease(source);

    const move_event = c.CGEventCreateMouseEvent(source, c.kCGEventMouseMoved, cgpoint, c.kCGMouseButtonLeft);
    if (move_event == null) return error.FailedToCreateMouseEvent;
    defer c.CFRelease(move_event);

    c.CGEventPost(c.kCGHIDEventTap, move_event);
    log.debug("cliclick: move to ({},{})", .{ resolved.x, resolved.y });
}

fn mouseDragDown(point: Point) !void {
    const resolved = resolvePoint(point);
    const cgpoint = c.CGPointMake(@floatFromInt(resolved.x), @floatFromInt(resolved.y));

    const source = c.CGEventSourceCreate(c.kCGEventSourceStateHIDSystemState);
    if (source == null) return error.FailedToCreateEventSource;
    defer c.CFRelease(source);

    const down_event = c.CGEventCreateMouseEvent(source, c.kCGEventLeftMouseDown, cgpoint, c.kCGMouseButtonLeft);
    if (down_event == null) return error.FailedToCreateMouseEvent;
    defer c.CFRelease(down_event);

    c.CGEventPost(c.kCGHIDEventTap, down_event);
    log.debug("cliclick: drag down at ({},{})", .{ resolved.x, resolved.y });
}

fn mouseDragUp(point: Point) !void {
    const resolved = resolvePoint(point);
    const cgpoint = c.CGPointMake(@floatFromInt(resolved.x), @floatFromInt(resolved.y));

    const source = c.CGEventSourceCreate(c.kCGEventSourceStateHIDSystemState);
    if (source == null) return error.FailedToCreateEventSource;
    defer c.CFRelease(source);

    const up_event = c.CGEventCreateMouseEvent(source, c.kCGEventLeftMouseUp, cgpoint, c.kCGMouseButtonLeft);
    if (up_event == null) return error.FailedToCreateMouseEvent;
    defer c.CFRelease(up_event);

    c.CGEventPost(c.kCGHIDEventTap, up_event);
    log.debug("cliclick: drag up at ({},{})", .{ resolved.x, resolved.y });
}

// ── Keyboard actions ───────────────────────────────────────────────

fn keyPress(keycode: u16) !void {
    try keyEvent(keycode, true);
    try keyEvent(keycode, false);
}

fn keyEvent(keycode: u16, key_down: bool) !void {
    const source = c.CGEventSourceCreate(c.kCGEventSourceStateHIDSystemState);
    if (source == null) return error.FailedToCreateEventSource;
    defer c.CFRelease(source);

    const event = c.CGEventCreateKeyboardEvent(source, keycode, key_down);
    if (event == null) return error.FailedToCreateKeyboardEvent;
    defer c.CFRelease(event);

    c.CGEventPost(c.kCGHIDEventTap, event);
    log.debug("cliclick: key {} ({})", .{ keycode, if (key_down) "down" else "up" });
}

// ── Key name resolution ────────────────────────────────────────────

/// Resolve a key name to a macOS virtual keycode.
/// Supports common key names compatible with cliclick's key naming.
fn resolveKeyName(name: []const u8) ?u16 {
    const map = .{
        .{ "return", 0x24 },
        .{ "enter", 0x24 },
        .{ "tab", 0x30 },
        .{ "space", 0x31 },
        .{ "delete", 0x33 },
        .{ "backspace", 0x33 },
        .{ "escape", 0x35 },
        .{ "esc", 0x35 },
        .{ "cmd", 0x37 },
        .{ "command", 0x37 },
        .{ "shift", 0x38 },
        .{ "capslock", 0x39 },
        .{ "alt", 0x3A },
        .{ "option", 0x3A },
        .{ "ctrl", 0x3B },
        .{ "control", 0x3B },
        .{ "fn", 0x3F },
        .{ "home", 0x73 },
        .{ "pageup", 0x74 },
        .{ "fwd-delete", 0x75 },
        .{ "end", 0x77 },
        .{ "pagedown", 0x79 },
        .{ "left", 0x7B },
        .{ "right", 0x7C },
        .{ "down", 0x7D },
        .{ "up", 0x7E },
        // Function keys
        .{ "f1", 0x7A },
        .{ "f2", 0x78 },
        .{ "f3", 0x63 },
        .{ "f4", 0x76 },
        .{ "f5", 0x60 },
        .{ "f6", 0x61 },
        .{ "f7", 0x62 },
        .{ "f8", 0x64 },
        .{ "f9", 0x65 },
        .{ "f10", 0x6D },
        .{ "f11", 0x67 },
        .{ "f12", 0x6F },
    };

    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }

    // Try parsing as a raw numeric keycode
    return std.fmt.parseInt(u16, name, 0) catch null;
}

// ── Tests ──────────────────────────────────────────────────────────

test "parseAction - click" {
    const action = try parseAction("c", &.{ "100", "200" });
    try std.testing.expect(action == .click);
    try std.testing.expectEqual(@as(i32, 100), action.click.x);
    try std.testing.expectEqual(@as(i32, 200), action.click.y);
}

test "parseAction - doubleclick" {
    const action = try parseAction("dc", &.{ "50", "75" });
    try std.testing.expect(action == .doubleclick);
    try std.testing.expectEqual(@as(i32, 50), action.doubleclick.x);
    try std.testing.expectEqual(@as(i32, 75), action.doubleclick.y);
}

test "parseAction - tripleclick" {
    const action = try parseAction("tc", &.{ "0", "0" });
    try std.testing.expect(action == .tripleclick);
}

test "parseAction - rightclick" {
    const action = try parseAction("rc", &.{ "300", "400" });
    try std.testing.expect(action == .rightclick);
}

test "parseAction - move" {
    const action = try parseAction("m", &.{ "500", "600" });
    try std.testing.expect(action == .move);
    try std.testing.expectEqual(@as(i32, 500), action.move.x);
    try std.testing.expectEqual(@as(i32, 600), action.move.y);
}

test "parseAction - drag_down" {
    const action = try parseAction("dd", &.{ "10", "20" });
    try std.testing.expect(action == .drag_down);
}

test "parseAction - drag_up" {
    const action = try parseAction("du", &.{ "30", "40" });
    try std.testing.expect(action == .drag_up);
}

test "parseAction - key_press" {
    const action = try parseAction("kp", &.{"return"});
    try std.testing.expect(action == .key_press);
    try std.testing.expectEqual(@as(u16, 0x24), action.key_press);
}

test "parseAction - key_down" {
    const action = try parseAction("kd", &.{"escape"});
    try std.testing.expect(action == .key_down);
    try std.testing.expectEqual(@as(u16, 0x35), action.key_down);
}

test "parseAction - key_up" {
    const action = try parseAction("ku", &.{"tab"});
    try std.testing.expect(action == .key_up);
    try std.testing.expectEqual(@as(u16, 0x30), action.key_up);
}

test "parseAction - dot means current position" {
    const action = try parseAction("c", &.{ ".", "." });
    try std.testing.expect(action == .click);
    try std.testing.expect(action.click.rel_x);
    try std.testing.expect(action.click.rel_y);
    try std.testing.expectEqual(@as(i32, 0), action.click.x);
    try std.testing.expectEqual(@as(i32, 0), action.click.y);
}

test "parseAction - relative coordinates with +" {
    const action = try parseAction("m", &.{ "+100", "+200" });
    try std.testing.expect(action == .move);
    try std.testing.expect(action.move.rel_x);
    try std.testing.expect(action.move.rel_y);
    try std.testing.expectEqual(@as(i32, 100), action.move.x);
    try std.testing.expectEqual(@as(i32, 200), action.move.y);
}

test "parseAction - relative coordinates with -" {
    const action = try parseAction("m", &.{ "-50", "-75" });
    try std.testing.expect(action == .move);
    try std.testing.expect(action.move.rel_x);
    try std.testing.expect(action.move.rel_y);
    try std.testing.expectEqual(@as(i32, -50), action.move.x);
    try std.testing.expectEqual(@as(i32, -75), action.move.y);
}

test "parseAction - absolute mixed with relative" {
    const action = try parseAction("c", &.{ "500", "+10" });
    try std.testing.expect(action == .click);
    try std.testing.expect(!action.click.rel_x);
    try std.testing.expect(action.click.rel_y);
    try std.testing.expectEqual(@as(i32, 500), action.click.x);
    try std.testing.expectEqual(@as(i32, 10), action.click.y);
}

test "parseAction - negative coordinates (absolute vs relative)" {
    // In cliclick, "-100" is relative. Absolute negative coords aren't really a thing for screen space, 
    // but we treat any sign as relative to match cliclick tool behavior.
    const action = try parseAction("m", &.{ "-100", "-200" });
    try std.testing.expect(action == .move);
    try std.testing.expect(action.move.rel_x);
    try std.testing.expectEqual(@as(i32, -100), action.move.x);
}

test "parseAction - unknown command" {
    const result = parseAction("zz", &.{ "1", "2" });
    try std.testing.expectError(error.UnknownCommand, result);
}

test "parseAction - invalid arg count for mouse" {
    const result = parseAction("c", &.{"100"});
    try std.testing.expectError(error.InvalidArgumentCount, result);
}

test "parseAction - invalid arg count for key" {
    const result = parseAction("kp", &.{ "return", "extra" });
    try std.testing.expectError(error.InvalidArgumentCount, result);
}

test "parseAction - invalid coordinate" {
    const result = parseAction("c", &.{ "abc", "200" });
    try std.testing.expectError(error.InvalidCoordinate, result);
}

test "parseAction - unknown key name" {
    const result = parseAction("kp", &.{"nonexistent_key"});
    try std.testing.expectError(error.UnknownKeyName, result);
}

test "parseAction - raw keycode for key" {
    const action = try parseAction("kp", &.{"0x24"});
    try std.testing.expect(action == .key_press);
    try std.testing.expectEqual(@as(u16, 0x24), action.key_press);
}

test "resolveKeyName - all known keys" {
    // Spot check a selection of keys
    try std.testing.expectEqual(@as(?u16, 0x24), resolveKeyName("return"));
    try std.testing.expectEqual(@as(?u16, 0x24), resolveKeyName("enter"));
    try std.testing.expectEqual(@as(?u16, 0x30), resolveKeyName("tab"));
    try std.testing.expectEqual(@as(?u16, 0x31), resolveKeyName("space"));
    try std.testing.expectEqual(@as(?u16, 0x33), resolveKeyName("delete"));
    try std.testing.expectEqual(@as(?u16, 0x35), resolveKeyName("escape"));
    try std.testing.expectEqual(@as(?u16, 0x35), resolveKeyName("esc"));
    try std.testing.expectEqual(@as(?u16, 0x7B), resolveKeyName("left"));
    try std.testing.expectEqual(@as(?u16, 0x7C), resolveKeyName("right"));
    try std.testing.expectEqual(@as(?u16, 0x7D), resolveKeyName("down"));
    try std.testing.expectEqual(@as(?u16, 0x7E), resolveKeyName("up"));
    try std.testing.expectEqual(@as(?u16, 0x7A), resolveKeyName("f1"));
    try std.testing.expectEqual(@as(?u16, 0x6F), resolveKeyName("f12"));
}

test "resolveKeyName - unknown returns null" {
    try std.testing.expectEqual(@as(?u16, null), resolveKeyName("nonexistent"));
}

test "Action.eql" {
    const a = Action{ .click = .{ .x = 100, .y = 200 } };
    const b = Action{ .click = .{ .x = 100, .y = 200 } };
    const d = Action{ .click = .{ .x = 999, .y = 999 } };
    const e = Action{ .move = .{ .x = 100, .y = 200 } };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(d));
    try std.testing.expect(!a.eql(e));
}
