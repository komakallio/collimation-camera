#pragma once

/* The macros that turn cimgui.h into a C API live here, not in the target's
 * cxxSettings: SwiftPM does not pass a target's defines to dependents, and the
 * C++ translation units must NOT see CIMGUI_DEFINE_ENUMS_AND_STRUCTS, because
 * they include imgui.h first and cimgui.h would then redeclare ImVec2, ImGuiIO
 * and every flag enum as C types in the same translation unit.
 *
 * The file name matches the target so SwiftPM emits `umbrella header` rather
 * than an umbrella directory, which would parse cimgui.h without these macros
 * and fail. */
#define CIMGUI_DEFINE_ENUMS_AND_STRUCTS 1
#define CIMGUI_USE_SDL3 1
#define CIMGUI_NO_EXPORT 1

#include <SDL3/SDL.h>
#include "../vendor/cimgui.h"
#include "../vendor/cimgui_impl.h"

/* Implemented in backends_shim.cpp. imgui_impl_sdlgpu3.h is C++, so it is
 * deliberately not included here. */
#ifdef __cplusplus
extern "C" {
#endif

bool cimgui_sdlgpu3_init(SDL_GPUDevice *device, SDL_GPUTextureFormat color_format);
void cimgui_sdlgpu3_new_frame(void);
void cimgui_sdlgpu3_prepare_draw_data(ImDrawData *draw_data, SDL_GPUCommandBuffer *cmd);
void cimgui_sdlgpu3_render_draw_data(ImDrawData *draw_data, SDL_GPUCommandBuffer *cmd, SDL_GPURenderPass *pass);
void cimgui_sdlgpu3_shutdown(void);

#ifdef __cplusplus
}
#endif
