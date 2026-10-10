/// Stable entity identity. The generation changes whenever an ID is reused.
pub const Entity = struct {
    id: u32,
    generation: u32,
};
