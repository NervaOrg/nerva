//! Which scenarios of `src/integration_tests.zig` one run executes (decision O12).
//!
//! `NERVA_INTEGRATION_SCENARIOS` is a comma-separated list of scenario names, or of the groups
//! `untimed` and `timed`; unset, every scenario runs, as `zig build test:integration` always did.
//! A *timed* scenario asserts a wall-clock bound (the median lookup is under one tick), so CI runs
//! it alone on the host, after the untimed ones, which take the minutes. A name that is not a
//! scenario is refused (NRV-E1246), never a run that executes nothing and passes.
//!
//! Kept apart from the executable so that `test:unit` can reach its tests.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub const Scenario = enum {
    cluster,
    peer_auth,
    latency,

    /// Whether the scenario asserts a wall-clock bound, and so must run with nothing else on the
    /// host. The switch is exhaustive: a new scenario must say.
    pub fn timed(scenario: Scenario) bool {
        return switch (scenario) {
            .latency => true,
            .cluster, .peer_auth => false,
        };
    }
};

pub const Set = std.enums.EnumSet(Scenario);

pub const environment_name = "NERVA_INTEGRATION_SCENARIOS";
const group_untimed = "untimed";
const group_timed = "timed";

pub const Selection = union(enum) {
    /// What to run: never empty.
    run: Set,
    /// The first entry of the value that is neither a scenario nor a group (an empty entry too).
    unknown: []const u8,
};

/// `value` is the variable's value, null when it is unset.
pub fn select(value: ?[]const u8) Selection {
    const list = value orelse {
        const all = Set.initFull();
        assert(all.count() > 0);
        return .{ .run = all };
    };
    var chosen: Set = .{};
    var entries = std.mem.splitScalar(u8, list, ',');
    while (entries.next()) |entry| {
        if (std.mem.eql(u8, entry, group_untimed) or std.mem.eql(u8, entry, group_timed)) {
            const want_timed = std.mem.eql(u8, entry, group_timed);
            var all = Set.initFull().iterator();
            while (all.next()) |scenario| {
                if (scenario.timed() == want_timed) chosen.insert(scenario);
            }
        } else if (std.meta.stringToEnum(Scenario, entry)) |scenario| {
            chosen.insert(scenario);
        } else {
            return .{ .unknown = entry };
        }
    }
    // Every entry added at least one scenario (the test below: neither group is empty).
    assert(chosen.count() > 0);
    return .{ .run = chosen };
}

/// The names `select` accepts, for the message of NRV-E1246.
pub const names = blk: {
    var text: []const u8 = "";
    for (std.meta.fieldNames(Scenario)) |name| text = text ++ name ++ ", ";
    break :blk text ++ group_untimed ++ ", " ++ group_timed;
};

fn expect_run(selection: Selection) !Set {
    return switch (selection) {
        .run => |set| set,
        .unknown => error.TestUnexpectedResult,
    };
}

test "integration scenarios: unset runs every scenario" {
    try testing.expectEqual(Set.initFull(), try expect_run(select(null)));
}

test "integration scenarios: names and groups" {
    const latency = try expect_run(select("latency"));
    try testing.expectEqual(@as(usize, 1), latency.count());
    try testing.expect(latency.contains(.latency));

    const timed = try expect_run(select("timed"));
    const untimed = try expect_run(select("untimed"));
    // The groups partition the scenarios, and neither is empty.
    try testing.expect(timed.count() > 0 and untimed.count() > 0);
    try testing.expectEqual(Set.initFull(), timed.unionWith(untimed));
    try testing.expectEqual(@as(usize, 0), timed.intersectWith(untimed).count());
    try testing.expect(timed.contains(.latency));
    try testing.expect(!untimed.contains(.latency));
    try testing.expect(untimed.contains(.cluster) and untimed.contains(.peer_auth));

    // A list; a repeated entry is the same scenario.
    const two = try expect_run(select("peer_auth,latency,latency"));
    try testing.expectEqual(@as(usize, 2), two.count());
    try testing.expect(two.contains(.peer_auth) and two.contains(.latency));
    try testing.expectEqual(Set.initFull(), try expect_run(select("untimed,timed")));
}

test "integration scenarios: anything else is refused, never an empty run" {
    const refused = [_][]const u8{
        "",         "nothing",          "Latency",  "latency,",
        ",latency", "cluster,,latency", " latency", "all",
    };
    for (refused) |value| {
        switch (select(value)) {
            .run => return error.TestUnexpectedResult,
            .unknown => {},
        }
    }
    // The entry reported is the first that is wrong.
    try testing.expectEqualStrings("lat", select("cluster,lat,nope").unknown);
    try testing.expectEqualStrings("", select("").unknown);
}
