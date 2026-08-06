const std = @import("std");

pub const NixPackage = struct {
    attr: []const u8,
    pname: []const u8,
    version: []const u8,
    description: []const u8,
    // true when the search required NIXPKGS_ALLOW_UNFREE=1 to return this package.
    // The install step uses this to pass the same env so the profile add succeeds.
    unfree: bool = false,
};

pub const Machine = struct {
    name: []const u8 = "local",
    config_path: []const u8 = "/etc/nixos",
    local: bool = true,
    default: bool = false,
    host: ?[]const u8 = null,
    user: ?[]const u8 = null,
    ssh_key: ?[]const u8 = null,
};

pub const NinaConfig = struct {
    editor: []const u8 = "vim",
    generations: u32 = 5,
    confirm: bool = true,
    teach: bool = false,
    color: bool = true,
    // Flake-based system (vs nixos channels). Channel commands warn when set.
    flake: bool = false,
    machines: []Machine = &.{},
};

pub const GenerationInfo = struct {
    number: u32,
    date: []const u8,
    time: []const u8,
    current: bool,
};

pub const ServiceInfo = struct {
    name: []const u8,
    state: ServiceState,
    uptime: ?[]const u8 = null,
};

pub const ServiceState = enum { active, failed, inactive, unknown };

pub const ChannelInfo = struct {
    name: []const u8,
    url: []const u8,
};

pub const DiffEntry = struct {
    op: DiffOp,
    package: []const u8,
    old_version: ?[]const u8 = null,
    new_version: ?[]const u8 = null,
};

pub const DiffOp = enum { add, remove, change };

pub const FlakeInput = struct {
    name: []const u8,
    old_rev: ?[]const u8 = null,
    new_rev: ?[]const u8 = null,
    changed: bool = false,
};

pub const StoreInfo = struct {
    total_size: []const u8,
    live_paths: u64,
    reclaimable_paths: u64,
};

pub const BootEntry = struct {
    title: []const u8,
    date: ?[]const u8 = null,
    current: bool = false,
};

pub const DoctorCheck = struct {
    name: []const u8,
    status: DoctorStatus,
    note: ?[]const u8 = null,
};

pub const DoctorStatus = enum { ok, warn, fail };

pub const InstallPath = enum { profile, system };

test "types are defined" {
    const p = NixPackage{
        .attr = "firefox",
        .pname = "firefox",
        .version = "124.0",
        .description = "A browser",
    };
    try std.testing.expectEqualStrings("firefox", p.attr);
}
