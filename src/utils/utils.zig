//! Cross-cutting utilities shared by all Zant packages.
//! - `allocator`: project-wide allocator facade (swappable via build options).
pub const build_options = @import("build_options");
pub const allocator = @import("allocator.zig");
