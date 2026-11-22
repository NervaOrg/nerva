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

/// The longest value accepted, in bytes. Every name and group joined is under 50, so a longer one
/// is a mistake, refused (NRV-E1246) before it is split. It bounds the number of entries too.
pub const value_max = 256;

pub const Selection = union(enum) {
    /// What to run: never empty.
    run: Set,
    /// The first entry of the value that is neither a scenario nor a group (an empty entry too).
    unknown: []const u8,
    /// The value was longer than `value_max`: its length.
    too_long: usize,
};

/// `value` is the variable's value, null when it is unset.
pub fn select(value: ?[]const u8) Selection {
    const list = value orelse {
        const all = Set.initFull();
        assert(all.count() > 0);
        return .{ .run = all };
    };
    if (list.len > value_max) return .{ .too_long = list.len };
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

/// The longest line `refusal` writes: an entry of at most `value_max` bytes, the names, the text.
pub const refusal_max = 640;

/// The NRV-E1246 line (no newline) for a selection that is not `.run`, for the executable to
/// print. It is here, not in `main`, so that a unit test pins its code and its text.
pub fn refusal(buffer: *[refusal_max]u8, selection: Selection) []const u8 {
    return (switch (selection) {
        .run => unreachable,
        .unknown => |entry| std.fmt.bufPrint(
            buffer,
            "error: NRV-E1246: {s} names '{s}', which is not a scenario ({s}); " ++
                "unset it to run every scenario",
            .{ environment_name, entry, names },
        ),
        .too_long => |length| std.fmt.bufPrint(
            buffer,
            "error: NRV-E1246: {s} is {d} bytes, more than the {d} a list of scenarios " ++
                "needs ({s}); unset it to run every scenario",
            .{ environment_name, length, value_max, names },
        ),
    }) catch unreachable; // `value_max` bounds the entry: the buffer holds the line.
}

/// The line for a value that could not be read at all (no memory for it).
pub const unreadable = "error: NRV-E1246: " ++ environment_name ++
    " could not be read (out of memory); unset it to run every scenario";

fn expect_run(selection: Selection) !Set {
    return switch (selection) {
        .run => |set| set,
        .unknown, .too_long => error.TestUnexpectedResult,
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
            .run, .too_long => return error.TestUnexpectedResult,
            .unknown => {},
        }
    }
    // The entry reported is the first that is wrong.
    try testing.expectEqualStrings("lat", select("cluster,lat,nope").unknown);
    try testing.expectEqualStrings("", select("").unknown);
}

test "integration scenarios: the value has a bound, at it and one past it" {
    // At the bound the value is split as usual (one entry of `value_max` bytes, not a scenario).
    const at_bound = "x" ** value_max;
    try testing.expectEqualStrings(at_bound, select(at_bound).unknown);
    const past_bound = "x" ** (value_max + 1);
    try testing.expectEqual(@as(usize, value_max + 1), select(past_bound).too_long);
    // A list of scenarios as long as the bound is accepted.
    const padded = "latency," ** 31 ++ "latency";
    try testing.expect(padded.len <= value_max);
    try testing.expectEqual(try expect_run(select("latency")), try expect_run(select(padded)));
}

test "integration scenarios: the NRV-E1246 lines" {
    var buffer: [refusal_max]u8 = undefined;
    try testing.expectEqualStrings(
        "error: NRV-E1246: NERVA_INTEGRATION_SCENARIOS names 'bogus', which is not a scenario " ++
            "(cluster, peer_auth, latency, untimed, timed); unset it to run every scenario",
        refusal(&buffer, select("bogus")),
    );
    try testing.expect(std.mem.startsWith(
        u8,
        refusal(&buffer, select("x" ** (value_max + 1))),
        "error: NRV-E1246: NERVA_INTEGRATION_SCENARIOS is 257 bytes, more than the 256",
    ));
    // The widest entry the bound lets through fits the buffer.
    const widest = refusal(&buffer, select("x" ** value_max));
    try testing.expect(std.mem.startsWith(u8, widest, "error: NRV-E1246: "));
    try testing.expect(std.mem.startsWith(u8, unreadable, "error: NRV-E1246: "));
}
