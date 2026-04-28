//! Compatibility wrappers for 0.16 synchronization primitives.

const std = @import("std");

const io = std.Options.debug_io;

pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(io);
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(io);
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }
};

pub const RwLock = struct {
    inner: std.Io.RwLock = .init,

    pub fn lock(self: *RwLock) void {
        self.inner.lockUncancelable(io);
    }

    pub fn unlock(self: *RwLock) void {
        self.inner.unlock(io);
    }

    pub fn lockShared(self: *RwLock) void {
        self.inner.lockSharedUncancelable(io);
    }

    pub fn unlockShared(self: *RwLock) void {
        self.inner.unlockShared(io);
    }

    pub fn tryLock(self: *RwLock) bool {
        return self.inner.tryLock(io);
    }

    pub fn tryLockShared(self: *RwLock) bool {
        return self.inner.tryLockShared(io);
    }
};

pub const Condition = struct {
    inner: std.Io.Condition = .init,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.waitUncancelable(io, &mutex.inner);
    }

    pub fn signal(self: *Condition) void {
        self.inner.signal(io);
    }

    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast(io);
    }
};
