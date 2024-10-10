pub const Interaction = struct {
    left: bool = false,
    right: bool = false,
};

fn InteractionOptions(comptime T: type) type {
    return struct {
        none: T,
        hover: T,
        down: T,
    };
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

        pub fn setLeftDown(self: *Self) void {
            if (self.maybe_target_state) |*s| {
                s.interaction.left = true;
            }
        }
        // returns a target if the mouse was already on a target with the left interaction down
        pub fn setLeftUp(self: *Self) ?Target {
            const target_state = if (self.maybe_target_state) |*t| t else return null;
            if (!target_state.interaction.left) return null;
            target_state.interaction.left = false;
            return target_state.target;
        }

        // returns true if the target has changed
        pub fn updateTarget(self: *Self, maybe_target: ?Target) bool {
            if (maybe_target) |target| {
                if (self.maybe_target_state) |state| {
                    if (state.target == target)
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
            return if (interaction.left) opt.down else opt.hover;
        }
    };
}
