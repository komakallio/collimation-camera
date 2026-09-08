#!/usr/bin/env bash
# Fails when a shared module imports a UI or platform framework. Platform code
# lives only in CollimationCore/Platform/ and Mount/SerialPort*.swift, which are
# excluded here. Run from the repository root.
set -uo pipefail

dirs="Sources/CollimationCore"
if [ -d Sources/CollimationUI ]; then
  dirs="$dirs Sources/CollimationUI"
fi

# shellcheck disable=SC2086
if grep -rEn '^import (Combine|Darwin|AppKit|SwiftUI|Metal|MetalKit|ImageIO)' \
     --exclude-dir=Platform --exclude='SerialPort*.swift' $dirs; then
  echo
  echo "A shared module imports a UI or platform framework (see above)."
  echo "Move the code to CollimationCore/Platform/ or behind a protocol."
  exit 1
fi

echo "No platform imports in $dirs."
