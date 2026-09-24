# Vendored cimgui and Dear ImGui

Do not edit anything in this directory. It is a verbatim copy, and local
patches belong in `Sources/CImGui/backends_shim.cpp`.

| | |
|---|---|
| cimgui | `700140771a12e61f4bb851fb4e2d885f04b32dd9` |
| Dear ImGui | 1.92.9b |
| Source | https://github.com/cimgui/cimgui.git |
| Copied by | `scripts/vendor-cimgui.sh 700140771a12e61f4bb851fb4e2d885f04b32dd9` |

## Bumping

Run the script with a new SHA. It replaces this directory wholesale. Then
re-check the generated names the Swift code calls against the new
`cimgui.h`, because the generator renames overloads as imgui changes:
`igGetBackgroundDrawList_Nil`, `igIsKeyChordPressed_Nil`, `igShortcut_Nil`,
`igPushFont`, `ImGuiStyle_ScaleAllSizes`, `ImDrawList_AddLine`,
`ImDrawList_AddCircle`, `ImDrawList_AddText_Vec2`,
`ImDrawList_AddText_FontPtr`.

Dear ImGui 1.92.9b or newer is required: the SDLGPU3 renderer backend arrived
in 1.91.7 and the dynamic-font API this app uses in 1.92.
