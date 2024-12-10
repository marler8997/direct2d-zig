pub const Button = enum { left, right };
pub const ButtonState = enum { up, down };

pub const Interaction = struct {
    left: ButtonState = .up,
    right: ButtonState = .up,

    pub fn get(self: *const Interaction, button: Button) ButtonState {
        return switch (button) {
            .left => self.left,
            .right => self.right,
        };
    }
    pub fn set(self: *Interaction, button: Button, state: ButtonState) bool {
        const ref = switch (button) {
            .left => &self.left,
            .right => &self.right,
        };
        if (ref.* == state) return false;
        ref.* = state;
        return true;
    }
};

fn InteractionOptions(comptime T: type) type {
    return struct {
        none: T,
        hover: T,
        down: T,
    };
}

pub fn mouseTargetsEqual(comptime Target: type, a: Target, b: Target) bool {
    switch (@typeInfo(Target)) {
        .Enum => return a == b,
        .Struct, .Union => return a.eql(b),
        else => @compileError("don't know how to check if two mouse targets of type " ++ @typeName(Target) ++ " are equal"),
    }
}

pub fn State(comptime Target: type) type {
    return struct {
        maybe_target_state: ?TargetState = null,

        const Self = @This();

        pub const TargetState = struct {
            target: Target,
            interaction: Interaction = .{},
        };

        pub fn getTarget(self: *const Self) ?Target {
            return (self.maybe_target_state orelse return null).target;
        }
        pub fn getTargetInteraction(self: *const Self, target: Target) ?Interaction {
            const state = self.maybe_target_state orelse return null;
            if (state.target != target) return null;
            return state.interaction;
        }

        // returns true if there is a target and its state changed
        pub fn set(self: *Self, button: Button, state: ButtonState) bool {
            if (self.maybe_target_state) |*s| {
                return s.interaction.set(button, state);
            }
            return false;
        }
        pub fn setLeftDown(self: *Self) void {
            if (self.maybe_target_state) |*s| {
                s.interaction.left = .down;
            }
        }
        // returns a target if the mouse was already on a target with the left interaction down
        pub fn setLeftUp(self: *Self) ?Target {
            const target_state = if (self.maybe_target_state) |*t| t else return null;
            if (target_state.interaction.left == .up) return null;
            target_state.interaction.left = .up;
            return target_state.target;
        }

        // returns true if the target has changed
        pub fn updateTarget(self: *Self, maybe_target: ?Target) bool {
            if (maybe_target) |target| {
                if (self.maybe_target_state) |state| {
                    if (mouseTargetsEqual(Target, state.target, target))
                        return false;
                }
                self.maybe_target_state = .{ .target = target };
                return true;
            } else if (self.maybe_target_state == null) {
                return false;
            } else {
                self.maybe_target_state = null;
                return true;
            }
        }

        pub fn resolveLeft(
            self: *const Self,
            comptime T: type,
            target: Target,
            opt: InteractionOptions(T),
        ) T {
            const interaction = self.getTargetInteraction(target) orelse return opt.none;
            return if (interaction.left == .down) opt.down else opt.hover;
        }
    };
}
