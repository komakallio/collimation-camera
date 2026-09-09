#pragma once
#include <SDL3/SDL.h>

/* SDL spells the window and init flags with the function-like macro
 * SDL_UINT64_C(...), which Swift's importer cannot evaluate, so the flags the
 * app uses are redefined here as plain literals. The values are from
 * SDL3/SDL_video.h; they are ABI, not implementation detail. */

#undef SDL_WINDOW_FULLSCREEN
#define SDL_WINDOW_FULLSCREEN 0x0000000000000001ull
#undef SDL_WINDOW_OPENGL
#define SDL_WINDOW_OPENGL 0x0000000000000002ull
#undef SDL_WINDOW_OCCLUDED
#define SDL_WINDOW_OCCLUDED 0x0000000000000004ull
#undef SDL_WINDOW_HIDDEN
#define SDL_WINDOW_HIDDEN 0x0000000000000008ull
#undef SDL_WINDOW_BORDERLESS
#define SDL_WINDOW_BORDERLESS 0x0000000000000010ull
#undef SDL_WINDOW_RESIZABLE
#define SDL_WINDOW_RESIZABLE 0x0000000000000020ull
#undef SDL_WINDOW_MINIMIZED
#define SDL_WINDOW_MINIMIZED 0x0000000000000040ull
#undef SDL_WINDOW_MAXIMIZED
#define SDL_WINDOW_MAXIMIZED 0x0000000000000080ull
#undef SDL_WINDOW_MOUSE_GRABBED
#define SDL_WINDOW_MOUSE_GRABBED 0x0000000000000100ull
#undef SDL_WINDOW_INPUT_FOCUS
#define SDL_WINDOW_INPUT_FOCUS 0x0000000000000200ull
#undef SDL_WINDOW_MOUSE_FOCUS
#define SDL_WINDOW_MOUSE_FOCUS 0x0000000000000400ull
#undef SDL_WINDOW_HIGH_PIXEL_DENSITY
#define SDL_WINDOW_HIGH_PIXEL_DENSITY 0x0000000000002000ull
#undef SDL_WINDOW_ALWAYS_ON_TOP
#define SDL_WINDOW_ALWAYS_ON_TOP 0x0000000000008000ull

/* SDL_GPUTextureFormat's constants vanish from Swift's view of this module in
 * a whole-module-optimized build that also imports WinSDK.DirectX: the type
 * still resolves, every SDL_GPU_TEXTUREFORMAT_* name does not. The formats the
 * app names are re-exported here as typed constants, which the Clang importer
 * carries through unchanged. */
static const SDL_GPUTextureFormat CSDL3_TEXTUREFORMAT_R16_UINT = SDL_GPU_TEXTUREFORMAT_R16_UINT;
static const SDL_GPUTextureFormat CSDL3_TEXTUREFORMAT_R16_UNORM = SDL_GPU_TEXTUREFORMAT_R16_UNORM;
static const SDL_GPUTextureFormat CSDL3_TEXTUREFORMAT_R32_FLOAT = SDL_GPU_TEXTUREFORMAT_R32_FLOAT;
