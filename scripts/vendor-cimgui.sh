#!/usr/bin/env bash
# Copies a pinned cimgui plus the imgui subset the app needs into
# Sources/CImGui/vendor/. The copies are committed; they are never edited in
# place. Local patches belong in Sources/CImGui/backends_shim.cpp.
#
# Usage: scripts/vendor-cimgui.sh [cimgui-sha]
#
# cimgui's tags lag master, so the pin is a commit SHA. imgui comes along as a
# submodule of cimgui at that commit.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Sources/CImGui/vendor"
SHA="${1:-master}"
REPO="${CIMGUI_REPO:-https://github.com/cimgui/cimgui.git}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Cloning $REPO"
git clone --recursive --quiet "$REPO" "$TMP/cimgui"
cd "$TMP/cimgui"
if [[ "$SHA" != "master" ]]; then
  git checkout --quiet "$SHA"
  git submodule update --init --recursive --quiet
fi
RESOLVED="$(git rev-parse HEAD)"
IMGUI_VERSION="$(grep -oE '#define IMGUI_VERSION +"[^"]+"' imgui/imgui.h | head -1 | sed 's/.*"\(.*\)"/\1/')"
cd "$ROOT"

rm -rf "$DEST"
mkdir -p "$DEST/imgui/backends"

# cimgui itself. cimgui.h expects imgui/ as a sibling directory, so the layout
# is preserved exactly.
for file in cimgui.cpp cimgui.h cimgui_impl.h cimgui_impl.cpp LICENSE; do
  [[ -f "$TMP/cimgui/$file" ]] && cp "$TMP/cimgui/$file" "$DEST/"
done

for file in \
  imgui.cpp imgui_draw.cpp imgui_tables.cpp imgui_widgets.cpp imgui_demo.cpp \
  imgui.h imgui_internal.h imconfig.h \
  imstb_rectpack.h imstb_textedit.h imstb_truetype.h LICENSE.txt
do
  cp "$TMP/cimgui/imgui/$file" "$DEST/imgui/"
done

for file in \
  imgui_impl_sdl3.cpp imgui_impl_sdl3.h \
  imgui_impl_sdlgpu3.cpp imgui_impl_sdlgpu3.h imgui_impl_sdlgpu3_shaders.h
do
  cp "$TMP/cimgui/imgui/backends/$file" "$DEST/imgui/backends/"
done

cat > "$DEST/UPSTREAM.md" <<UPSTREAM
# Vendored cimgui and Dear ImGui

Do not edit anything in this directory. It is a verbatim copy, and local
patches belong in \`Sources/CImGui/backends_shim.cpp\`.

| | |
|---|---|
| cimgui | \`$RESOLVED\` |
| Dear ImGui | $IMGUI_VERSION |
| Source | $REPO |
| Copied by | \`scripts/vendor-cimgui.sh $RESOLVED\` |

## Bumping

Run the script with a new SHA. It replaces this directory wholesale. Then
re-check the generated names the Swift code calls against the new
\`cimgui.h\`, because the generator renames overloads as imgui changes:
\`igGetBackgroundDrawList_Nil\`, \`igIsKeyChordPressed_Nil\`, \`igShortcut_Nil\`,
\`igPushFont\`, \`ImGuiStyle_ScaleAllSizes\`, \`ImDrawList_AddLine\`,
\`ImDrawList_AddCircle\`, \`ImDrawList_AddText_Vec2\`,
\`ImDrawList_AddText_FontPtr\`.

Dear ImGui 1.92.9b or newer is required: the SDLGPU3 renderer backend arrived
in 1.91.7 and the dynamic-font API this app uses in 1.92.
UPSTREAM

echo "Vendored cimgui $RESOLVED (Dear ImGui $IMGUI_VERSION) into $DEST"
find "$DEST" -type f | sort | sed "s|$DEST|  vendor|"
