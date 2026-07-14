// SPDX-License-Identifier: MIT
#include "zigcraft_rmlui.h"

#include <RmlUi/Core.h>

#include <algorithm>
#include <cstddef>
#include <chrono>
#include <memory>
#include <string>
#include <vector>

namespace {

static_assert(sizeof(ZigCraftRmlUiVertex) == sizeof(Rml::Vertex));
static_assert(alignof(ZigCraftRmlUiVertex) == alignof(Rml::Vertex));
static_assert(sizeof(int) == sizeof(int32_t));
static_assert(offsetof(ZigCraftRmlUiVertex, x) == offsetof(Rml::Vertex, position));
static_assert(offsetof(ZigCraftRmlUiVertex, color) == offsetof(Rml::Vertex, colour));
static_assert(offsetof(ZigCraftRmlUiVertex, u) == offsetof(Rml::Vertex, tex_coord));

int key_modifiers(SDL_Keymod modifiers) {
    int result = 0;
    if (modifiers & SDL_KMOD_CTRL) result |= Rml::Input::KM_CTRL;
    if (modifiers & SDL_KMOD_SHIFT) result |= Rml::Input::KM_SHIFT;
    if (modifiers & SDL_KMOD_ALT) result |= Rml::Input::KM_ALT;
    if (modifiers & SDL_KMOD_GUI) result |= Rml::Input::KM_META;
    if (modifiers & SDL_KMOD_CAPS) result |= Rml::Input::KM_CAPSLOCK;
    if (modifiers & SDL_KMOD_NUM) result |= Rml::Input::KM_NUMLOCK;
    if (modifiers & SDL_KMOD_SCROLL) result |= Rml::Input::KM_SCROLLLOCK;
    return result;
}

Rml::Input::KeyIdentifier convert_key(SDL_Keycode key) {
    if (key >= SDLK_0 && key <= SDLK_9)
        return static_cast<Rml::Input::KeyIdentifier>(Rml::Input::KI_0 + key - SDLK_0);
    if (key >= SDLK_A && key <= SDLK_Z)
        return static_cast<Rml::Input::KeyIdentifier>(Rml::Input::KI_A + key - SDLK_A);
    if (key >= SDLK_F1 && key <= SDLK_F24)
        return static_cast<Rml::Input::KeyIdentifier>(Rml::Input::KI_F1 + key - SDLK_F1);

    switch (key) {
    case SDLK_UNKNOWN: return Rml::Input::KI_UNKNOWN;
    case SDLK_ESCAPE: return Rml::Input::KI_ESCAPE;
    case SDLK_SPACE: return Rml::Input::KI_SPACE;
    case SDLK_SEMICOLON: return Rml::Input::KI_OEM_1;
    case SDLK_PLUS: return Rml::Input::KI_OEM_PLUS;
    case SDLK_COMMA: return Rml::Input::KI_OEM_COMMA;
    case SDLK_MINUS: return Rml::Input::KI_OEM_MINUS;
    case SDLK_PERIOD: return Rml::Input::KI_OEM_PERIOD;
    case SDLK_SLASH: return Rml::Input::KI_OEM_2;
    case SDLK_GRAVE: return Rml::Input::KI_OEM_3;
    case SDLK_LEFTBRACKET: return Rml::Input::KI_OEM_4;
    case SDLK_BACKSLASH: return Rml::Input::KI_OEM_5;
    case SDLK_RIGHTBRACKET: return Rml::Input::KI_OEM_6;
    case SDLK_DBLAPOSTROPHE: return Rml::Input::KI_OEM_7;
    case SDLK_KP_0: return Rml::Input::KI_NUMPAD0;
    case SDLK_KP_1: return Rml::Input::KI_NUMPAD1;
    case SDLK_KP_2: return Rml::Input::KI_NUMPAD2;
    case SDLK_KP_3: return Rml::Input::KI_NUMPAD3;
    case SDLK_KP_4: return Rml::Input::KI_NUMPAD4;
    case SDLK_KP_5: return Rml::Input::KI_NUMPAD5;
    case SDLK_KP_6: return Rml::Input::KI_NUMPAD6;
    case SDLK_KP_7: return Rml::Input::KI_NUMPAD7;
    case SDLK_KP_8: return Rml::Input::KI_NUMPAD8;
    case SDLK_KP_9: return Rml::Input::KI_NUMPAD9;
    case SDLK_KP_ENTER: return Rml::Input::KI_NUMPADENTER;
    case SDLK_KP_MULTIPLY: return Rml::Input::KI_MULTIPLY;
    case SDLK_KP_PLUS: return Rml::Input::KI_ADD;
    case SDLK_KP_MINUS: return Rml::Input::KI_SUBTRACT;
    case SDLK_KP_PERIOD: return Rml::Input::KI_DECIMAL;
    case SDLK_KP_DIVIDE: return Rml::Input::KI_DIVIDE;
    case SDLK_KP_EQUALS: return Rml::Input::KI_OEM_NEC_EQUAL;
    case SDLK_BACKSPACE: return Rml::Input::KI_BACK;
    case SDLK_TAB: return Rml::Input::KI_TAB;
    case SDLK_CLEAR: return Rml::Input::KI_CLEAR;
    case SDLK_RETURN: return Rml::Input::KI_RETURN;
    case SDLK_PAUSE: return Rml::Input::KI_PAUSE;
    case SDLK_CAPSLOCK: return Rml::Input::KI_CAPITAL;
    case SDLK_PAGEUP: return Rml::Input::KI_PRIOR;
    case SDLK_PAGEDOWN: return Rml::Input::KI_NEXT;
    case SDLK_END: return Rml::Input::KI_END;
    case SDLK_HOME: return Rml::Input::KI_HOME;
    case SDLK_LEFT: return Rml::Input::KI_LEFT;
    case SDLK_UP: return Rml::Input::KI_UP;
    case SDLK_RIGHT: return Rml::Input::KI_RIGHT;
    case SDLK_DOWN: return Rml::Input::KI_DOWN;
    case SDLK_INSERT: return Rml::Input::KI_INSERT;
    case SDLK_DELETE: return Rml::Input::KI_DELETE;
    case SDLK_HELP: return Rml::Input::KI_HELP;
    case SDLK_NUMLOCKCLEAR: return Rml::Input::KI_NUMLOCK;
    case SDLK_SCROLLLOCK: return Rml::Input::KI_SCROLL;
    case SDLK_LSHIFT: return Rml::Input::KI_LSHIFT;
    case SDLK_RSHIFT: return Rml::Input::KI_RSHIFT;
    case SDLK_LCTRL: return Rml::Input::KI_LCONTROL;
    case SDLK_RCTRL: return Rml::Input::KI_RCONTROL;
    case SDLK_LALT: return Rml::Input::KI_LMENU;
    case SDLK_RALT: return Rml::Input::KI_RMENU;
    case SDLK_LGUI: return Rml::Input::KI_LMETA;
    case SDLK_RGUI: return Rml::Input::KI_RMETA;
    default: return Rml::Input::KI_UNKNOWN;
    }
}

int mouse_button(Uint8 button) {
    switch (button) {
    case SDL_BUTTON_LEFT: return 0;
    case SDL_BUTTON_RIGHT: return 1;
    case SDL_BUTTON_MIDDLE: return 2;
    default: return 3;
    }
}

class BridgeSystemInterface final : public Rml::SystemInterface {
public:
    void set_window(SDL_Window *new_window) { window = new_window; }
    SDL_Window *get_window() const { return window; }

    double GetElapsedTime() override {
        const auto elapsed = std::chrono::steady_clock::now() - started_at;
        return std::chrono::duration<double>(elapsed).count();
    }

    void SetClipboardText(const Rml::String &text) override { SDL_SetClipboardText(text.c_str()); }

    void GetClipboardText(Rml::String &text) override {
        char *clipboard_text = SDL_GetClipboardText();
        text = clipboard_text ? clipboard_text : "";
        SDL_free(clipboard_text);
    }

    void ActivateKeyboard(Rml::Vector2f caret_position, float line_height) override {
        if (!window) return;
        const SDL_Rect rect = {int(caret_position.x), int(caret_position.y), 1, int(line_height)};
        SDL_SetTextInputArea(window, &rect, 0);
        SDL_StartTextInput(window);
    }

    void DeactivateKeyboard() override {
        if (window) SDL_StopTextInput(window);
    }

private:
    SDL_Window *window = nullptr;
    std::chrono::steady_clock::time_point started_at = std::chrono::steady_clock::now();
};

class BridgeRenderInterface final : public Rml::RenderInterface {
public:
    explicit BridgeRenderInterface(ZigCraftRmlUiRenderCallbacks callbacks) : callbacks(callbacks) {}

    Rml::CompiledGeometryHandle CompileGeometry(Rml::Span<const Rml::Vertex> vertices, Rml::Span<const int> indices) override {
        if (!callbacks.compile_geometry) return 0;
        return callbacks.compile_geometry(
            callbacks.user_data,
            reinterpret_cast<const ZigCraftRmlUiVertex *>(vertices.data()),
            vertices.size(),
            reinterpret_cast<const int32_t *>(indices.data()),
            indices.size());
    }

    void RenderGeometry(Rml::CompiledGeometryHandle geometry, Rml::Vector2f translation, Rml::TextureHandle texture) override {
        if (callbacks.render_geometry)
            callbacks.render_geometry(callbacks.user_data, geometry, translation.x, translation.y, texture);
    }

    void ReleaseGeometry(Rml::CompiledGeometryHandle geometry) override {
        if (callbacks.release_geometry) callbacks.release_geometry(callbacks.user_data, geometry);
    }

    Rml::TextureHandle LoadTexture(Rml::Vector2i &dimensions, const Rml::String &source) override {
        if (!callbacks.load_texture) return 0;
        return callbacks.load_texture(callbacks.user_data, source.c_str(), &dimensions.x, &dimensions.y);
    }

    Rml::TextureHandle GenerateTexture(Rml::Span<const Rml::byte> source, Rml::Vector2i dimensions) override {
        if (!callbacks.generate_texture) return 0;
        return callbacks.generate_texture(callbacks.user_data, source.data(), source.size(), dimensions.x, dimensions.y);
    }

    void ReleaseTexture(Rml::TextureHandle texture) override {
        if (callbacks.release_texture) callbacks.release_texture(callbacks.user_data, texture);
    }

    void EnableScissorRegion(bool enable) override {
        if (callbacks.enable_scissor) callbacks.enable_scissor(callbacks.user_data, enable);
    }

    void SetScissorRegion(Rml::Rectanglei region) override {
        if (callbacks.set_scissor)
            callbacks.set_scissor(callbacks.user_data, region.Left(), region.Top(), region.Width(), region.Height());
    }

private:
    ZigCraftRmlUiRenderCallbacks callbacks;
};

} // namespace

struct ZigCraftRmlUiAction : Rml::EventListener {
    ZigCraftRmlUiDocument *document = nullptr;
    std::string event_type;
    ZigCraftRmlUiActionCallback callback = nullptr;
    void *user_data = nullptr;
    bool attached = false;

    void ProcessEvent(Rml::Event &event) override {
        if (!attached || !callback) return;
        Rml::Element *target = event.GetTargetElement();
        while (target && target->GetId().empty()) target = target->GetParentNode();
        callback(user_data, event.GetType().c_str(), target ? target->GetId().c_str() : "");
    }

    void OnDetach(Rml::Element *) override { attached = false; }
};

struct ZigCraftRmlUi {
    explicit ZigCraftRmlUi(const ZigCraftRmlUiRenderCallbacks &callbacks) : render_interface(callbacks) {}

    BridgeSystemInterface system_interface;
    BridgeRenderInterface render_interface;
    std::vector<std::unique_ptr<ZigCraftRmlUiAction>> actions;
};

namespace {

bool runtime_exists = false;

Rml::Context *as_context(ZigCraftRmlUiContext *context) { return reinterpret_cast<Rml::Context *>(context); }
Rml::ElementDocument *as_document(ZigCraftRmlUiDocument *document) {
    return reinterpret_cast<Rml::ElementDocument *>(document);
}

void detach_action(ZigCraftRmlUiAction *action) {
    if (action && action->attached) {
        as_document(action->document)->RemoveEventListener(action->event_type, action);
        action->attached = false;
    }
}

void remove_actions_for_document(ZigCraftRmlUi *rmlui, ZigCraftRmlUiDocument *document) {
    auto &actions = rmlui->actions;
    for (const auto &action : actions)
        if (action->document == document) detach_action(action.get());
    actions.erase(std::remove_if(actions.begin(), actions.end(), [document](const auto &action) {
                      return action->document == document;
                  }),
                  actions.end());
}

void remove_actions_for_context(ZigCraftRmlUi *rmlui, Rml::Context *context) {
    auto &actions = rmlui->actions;
    for (const auto &action : actions)
        if (as_document(action->document)->GetContext() == context) detach_action(action.get());
    actions.erase(std::remove_if(actions.begin(), actions.end(), [context](const auto &action) {
                      return as_document(action->document)->GetContext() == context;
                  }),
                  actions.end());
}

} // namespace

extern "C" {

ZigCraftRmlUi *zigcraft_rmlui_init(const ZigCraftRmlUiRenderCallbacks *callbacks) {
    if (!callbacks || runtime_exists) return nullptr;

    auto *rmlui = new ZigCraftRmlUi(*callbacks);
    Rml::SetSystemInterface(&rmlui->system_interface);
    Rml::SetRenderInterface(&rmlui->render_interface);
    if (!Rml::Initialise()) {
        delete rmlui;
        return nullptr;
    }
    runtime_exists = true;
    return rmlui;
}

void zigcraft_rmlui_destroy(ZigCraftRmlUi *rmlui) {
    if (!rmlui) return;
    for (const auto &action : rmlui->actions) detach_action(action.get());
    rmlui->actions.clear();
    Rml::Shutdown();
    runtime_exists = false;
    delete rmlui;
}

void zigcraft_rmlui_set_sdl_window(ZigCraftRmlUi *rmlui, SDL_Window *window) {
    if (rmlui) rmlui->system_interface.set_window(window);
}

ZigCraftRmlUiContext *zigcraft_rmlui_context_create(ZigCraftRmlUi *rmlui, const char *name, int width, int height) {
    if (!rmlui || !name) return nullptr;
    Rml::Context *context = Rml::CreateContext(name, {width, height});
    if (!context) return nullptr;

    if (SDL_Window *window = rmlui->system_interface.get_window()) {
        const float display_scale = SDL_GetWindowDisplayScale(window);
        if (display_scale > 0.0f) context->SetDensityIndependentPixelRatio(display_scale);
    }
    return reinterpret_cast<ZigCraftRmlUiContext *>(context);
}

void zigcraft_rmlui_context_destroy(ZigCraftRmlUi *rmlui, ZigCraftRmlUiContext *context) {
    if (!rmlui || !context) return;
    Rml::Context *native_context = as_context(context);
    remove_actions_for_context(rmlui, native_context);
    Rml::RemoveContext(native_context->GetName());
}

void zigcraft_rmlui_context_resize(ZigCraftRmlUiContext *context, int width, int height) {
    if (context) as_context(context)->SetDimensions({width, height});
}

bool zigcraft_rmlui_context_update(ZigCraftRmlUiContext *context) {
    return context && as_context(context)->Update();
}

bool zigcraft_rmlui_context_render(ZigCraftRmlUiContext *context) {
    return context && as_context(context)->Render();
}

bool zigcraft_rmlui_load_font_face(const char *path, bool fallback_face) {
    return path && Rml::LoadFontFace(path, fallback_face);
}

ZigCraftRmlUiDocument *zigcraft_rmlui_context_load_document(ZigCraftRmlUiContext *context, const char *path) {
    if (!context || !path) return nullptr;
    return reinterpret_cast<ZigCraftRmlUiDocument *>(as_context(context)->LoadDocument(path));
}

ZigCraftRmlUiDocument *zigcraft_rmlui_context_load_document_memory(
    ZigCraftRmlUiContext *context, const char *rml, const char *source_url) {
    if (!context || !rml) return nullptr;
    return reinterpret_cast<ZigCraftRmlUiDocument *>(
        as_context(context)->LoadDocumentFromMemory(rml, source_url ? source_url : "[ZigCraft RML document]"));
}

void zigcraft_rmlui_document_show(ZigCraftRmlUiDocument *document) {
    if (document) as_document(document)->Show();
}

void zigcraft_rmlui_document_hide(ZigCraftRmlUiDocument *document) {
    if (document) as_document(document)->Hide();
}

void zigcraft_rmlui_document_close(ZigCraftRmlUi *rmlui, ZigCraftRmlUiDocument *document) {
    if (!rmlui || !document) return;
    remove_actions_for_document(rmlui, document);
    as_document(document)->Close();
}

bool zigcraft_rmlui_process_sdl_event(
    ZigCraftRmlUi *rmlui, ZigCraftRmlUiContext *context, SDL_Window *window, const SDL_Event *event) {
    if (!rmlui || !context || !event) return true;
    rmlui->system_interface.set_window(window);
    Rml::Context *native_context = as_context(context);

    switch (event->type) {
    case SDL_EVENT_MOUSE_MOTION: {
        const float pixel_density = window ? SDL_GetWindowPixelDensity(window) : 1.0f;
        return native_context->ProcessMouseMove(
            int(event->motion.x * pixel_density), int(event->motion.y * pixel_density), key_modifiers(SDL_GetModState()));
    }
    case SDL_EVENT_MOUSE_BUTTON_DOWN:
        SDL_CaptureMouse(true);
        return native_context->ProcessMouseButtonDown(mouse_button(event->button.button), key_modifiers(SDL_GetModState()));
    case SDL_EVENT_MOUSE_BUTTON_UP:
        SDL_CaptureMouse(false);
        return native_context->ProcessMouseButtonUp(mouse_button(event->button.button), key_modifiers(SDL_GetModState()));
    case SDL_EVENT_MOUSE_WHEEL:
        return native_context->ProcessMouseWheel({-event->wheel.x, -event->wheel.y}, key_modifiers(SDL_GetModState()));
    case SDL_EVENT_KEY_DOWN: {
        bool result = native_context->ProcessKeyDown(convert_key(event->key.key), key_modifiers(event->key.mod));
        if (event->key.key == SDLK_RETURN || event->key.key == SDLK_KP_ENTER)
            result = native_context->ProcessTextInput('\n') && result;
        return result;
    }
    case SDL_EVENT_KEY_UP:
        return native_context->ProcessKeyUp(convert_key(event->key.key), key_modifiers(event->key.mod));
    case SDL_EVENT_TEXT_INPUT:
        return event->text.text && native_context->ProcessTextInput(event->text.text);
    case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
        native_context->SetDimensions({event->window.data1, event->window.data2});
        return true;
    case SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
        if (window) native_context->SetDensityIndependentPixelRatio(SDL_GetWindowDisplayScale(window));
        return true;
    case SDL_EVENT_WINDOW_MOUSE_LEAVE:
        return native_context->ProcessMouseLeave();
    default:
        return true;
    }
}

ZigCraftRmlUiAction *zigcraft_rmlui_document_add_action(
    ZigCraftRmlUi *rmlui,
    ZigCraftRmlUiDocument *document,
    const char *event_type,
    ZigCraftRmlUiActionCallback callback,
    void *user_data) {
    if (!rmlui || !document || !event_type || !callback) return nullptr;
    auto action = std::make_unique<ZigCraftRmlUiAction>();
    action->document = document;
    action->event_type = event_type;
    action->callback = callback;
    action->user_data = user_data;
    action->attached = true;
    as_document(document)->AddEventListener(action->event_type, action.get());
    ZigCraftRmlUiAction *result = action.get();
    rmlui->actions.push_back(std::move(action));
    return result;
}

void zigcraft_rmlui_action_remove(ZigCraftRmlUi *rmlui, ZigCraftRmlUiAction *action) {
    if (!rmlui || !action) return;
    auto &actions = rmlui->actions;
    const auto found = std::find_if(actions.begin(), actions.end(), [action](const auto &entry) { return entry.get() == action; });
    if (found == actions.end()) return;
    detach_action(found->get());
    actions.erase(found);
}

} // extern "C"
