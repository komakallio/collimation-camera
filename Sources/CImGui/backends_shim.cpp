// C-linkage wrappers for the SDLGPU3 renderer backend.
//
// cimgui's committed cimgui_impl.h wraps the SDL3 platform backend but not
// SDLGPU3, so these five functions are the whole bridge. Nothing in
// vendor/ is edited; local patches belong here.
#include "imgui.h"
#include "imgui_impl_sdlgpu3.h"
#include <SDL3/SDL.h>

extern "C" {

bool cimgui_sdlgpu3_init(SDL_GPUDevice *device, SDL_GPUTextureFormat color_format)
{
    ImGui_ImplSDLGPU3_InitInfo info = {};
    info.Device = device;
    info.ColorTargetFormat = color_format;
    info.MSAASamples = SDL_GPU_SAMPLECOUNT_1;
    info.SwapchainComposition = SDL_GPU_SWAPCHAINCOMPOSITION_SDR;
    info.PresentMode = SDL_GPU_PRESENTMODE_VSYNC;
    return ImGui_ImplSDLGPU3_Init(&info);
}

void cimgui_sdlgpu3_new_frame(void)
{
    ImGui_ImplSDLGPU3_NewFrame();
}

// Mandatory before the render pass: it uploads the vertex and index buffers.
void cimgui_sdlgpu3_prepare_draw_data(ImDrawData *draw_data, SDL_GPUCommandBuffer *cmd)
{
    ImGui_ImplSDLGPU3_PrepareDrawData(draw_data, cmd);
}

void cimgui_sdlgpu3_render_draw_data(ImDrawData *draw_data,
                                     SDL_GPUCommandBuffer *cmd,
                                     SDL_GPURenderPass *pass)
{
    ImGui_ImplSDLGPU3_RenderDrawData(draw_data, cmd, pass, nullptr);
}

void cimgui_sdlgpu3_shutdown(void)
{
    ImGui_ImplSDLGPU3_Shutdown();
}

}
