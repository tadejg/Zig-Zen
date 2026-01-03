const std = @import("std");

const Self = @This();

buff: []u8,
freeStack: []u32,
freeStackTop: u32,
numChunks: u32,
chunkSize: u32,

pub const InitError = error{FreeStackTooSmall};

/// freeStack must have at least `floor(buff.len / chunkSize)` elements
pub fn init(buff: []u8, freeStack: []u32, chunkSize: u32) InitError!Self {
    const numChunks: u32 = @intCast(buff.len / chunkSize);
    if(freeStack.len < numChunks) return error.FreeStackTooSmall;
    for (0..numChunks) |i| freeStack[i] = @intCast(i);
    return .{
        .buff = buff,
        .freeStack = freeStack,
        .freeStackTop = numChunks - 1,
        .numChunks = numChunks,
        .chunkSize = chunkSize,
    };
}

pub const AllocError = error{OutOfMemory};

pub fn alloc(self: *Self) AllocError![]u8 {
    if (self.freeStackTop == 0) return error.OutOfMemory;
    const idx = self.freeStack[self.freeStackTop];
    self.freeStackTop -= 1;
    const start = idx * self.chunkSize;
    return self.buff[start .. start + self.chunkSize];
}

pub fn free(self: *Self, buff: []u8) void {
    if (buff.ptr < self.buff.ptr or buff.ptr > (self.buff.ptr + buff.len - 1)) return;
    const idx = (buff.ptr - self.buff.ptr) / self.chunkSize;
    self.freeStack[self.freeStackTop + 1] = idx;
    self.freeStackTop += 1;
    std.debug.assert(self.freeStackTop < self.numChunks);
}
