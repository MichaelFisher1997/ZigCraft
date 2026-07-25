# Player UI Architecture

ZigCraft uses three deliberately separate UI layers:

- **RmlUi** is the opt-in player-facing layout and widget system. It is enabled
  with `-Drmlui=true` and owns the complete player menu flow.
- **`engine-ui` / `UIRenderer`** remains the render abstraction. RmlUi submits
  indexed geometry, generated textures, and scissors through the existing RHI;
  it does not own a Vulkan instance, device, swapchain, or command buffer.
- **Dear ImGui** remains developer-only UI for diagnostics and tooling.

## Dependency boundary

RmlUi 6.2 is pinned in `devenv.nix`. `libs/rmlui_bridge` contains the only C++
integration code and exposes a narrow C ABI to Zig. Feature-off builds do not
link the bridge or allocate the retained-geometry Vulkan buffers and pipelines.

## Lifetime and input

`UISystemManager` owns a heap-stable `RmlUi` backend. Screens own documents and
event listeners, while the backend owns compiled geometry and generated texture
handles until RmlUi releases them. Raw SDL events carry an explicit callback
context; when an active Rml document consumes an event, game input does not see
the same event.

## Player menu flow

With `-Drmlui=true`, normal menu startup and menu screenshot startup use
`RmlHomeScreen`. It retains the deterministic world preview and provides World
Library, Resource Packs, Sky & Lighting, Settings, and Exit actions. World
Library is the entry point for loading saves and opening the three-step Details,
Terrain, and Review creation wizard. If RmlUi fails to initialize, startup falls
back to the immediate-mode home screen with the same navigation model.

World Library, Create World, Settings, Resource Packs, Sky & Lighting, Pause,
and their modals use documents in `assets/ui/rmlui/` and the shared
`menu.rcss` design system. `rml_page.zig` owns common document and action
lifecycle, while `rml_markup.zig` safely builds escaped dynamic document
fragments. The immediate-mode implementations remain as the `-Drmlui=false`
fallback.

`ScreenManager.drawBackgroundFor` finds the nearest background provider below a
menu without redrawing intermediate pages. Home provides the deterministic
world preview and Pause provides the active world, keeping nested pages visually
continuous beneath the shared 75% black tint.

## Migration sequence

1. Validate every migrated menu at supported window sizes on windowed Vulkan.
2. Repair deterministic offscreen capture and replace the invalid menu golden.
3. Move inventory and HUD components that benefit from responsive layout.
4. Remove superseded fallback presentation code only after RmlUi becomes the
   default build mode.
5. Keep specialized low-level overlays and ImGui diagnostics separate.

Each migrated screen must support mouse, keyboard/controller focus, resize and
HiDPI, clean document teardown, and visual regression captures at 1280x720,
1920x1080, and a high-DPI resolution.

## Known limitation

The tracked menu golden is invalid because it is black. The comparison script
now rejects black inputs. A new golden must not be promoted until the headless
capture visibly contains the final player UI and is deterministic under the
`graphics` devenv profile.
