//! Shared lifecycle wrapper for player-facing RmlUi documents.

const UISystem = @import("engine-ui").UISystem;
const rmlui = @import("engine-ui").rmlui;
const Screen = @import("screen.zig");
const EngineContext = Screen.EngineContext;

pub const Page = struct {
    context: EngineContext,
    backend: *rmlui.RmlUi,
    document: rmlui.Document,
    click_action: ?rmlui.Action = null,
    change_action: ?rmlui.Action = null,
    warned_empty_render: bool = false,

    pub fn init(context: EngineContext, path: [*:0]const u8, owner: *anyopaque, callback: rmlui.ActionCallback) !Page {
        const backend = context.ui_manager.getRmlUi() orelse return error.RmlUiUnavailable;
        const document = try backend.loadDocument(path);
        errdefer backend.closeDocument(document);
        const click_action = try backend.addAction(document, "click", callback, owner);
        errdefer backend.removeAction(click_action);
        const change_action = try backend.addAction(document, "change", callback, owner);
        return .{
            .context = context,
            .backend = backend,
            .document = document,
            .click_action = click_action,
            .change_action = change_action,
        };
    }

    pub fn deinit(self: *Page) void {
        if (self.click_action) |action| self.backend.removeAction(action);
        if (self.change_action) |action| self.backend.removeAction(action);
        self.backend.closeDocument(self.document);
        self.* = undefined;
    }

    pub fn draw(self: *Page, ui: *UISystem) void {
        ui.begin();
        defer ui.end();
        if (self.backend.updateAndRender() == 0 and !self.warned_empty_render) {
            @import("engine-core").log.log.warn("RmlUi menu document produced no geometry", .{});
            self.warned_empty_render = true;
        }
    }

    pub fn onEnter(self: *Page) void {
        self.context.input.setMouseCapture(@ptrCast(self.context.window_manager.window), false);
        self.context.ui_manager.setRmlUiInputEnabled(true);
        self.backend.showDocument(self.document);
    }

    pub fn onExit(self: *Page) void {
        self.context.ui_manager.setRmlUiInputEnabled(false);
        self.backend.hideDocument(self.document);
    }
};
