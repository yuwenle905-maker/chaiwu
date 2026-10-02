#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
import pathlib, sys
destination = pathlib.Path(sys.argv[1])
model = pathlib.Path('iOS/ChaiWu/Models/Transaction.swift').read_text()
model = model.replace('import UIKit', 'import Combine\nstruct UIDevice { static let current = UIDevice(); let name = "Regression" }')
entry = pathlib.Path('iOS/ChaiWu/Views/Entry/EntryView.swift').read_text()
settings = entry[entry.index('final class CategorySettings:'):entry.index('struct SettingsView:')]
(destination / 'Transaction.swift').write_text(model + '\n' + settings)
PY
swiftc -o "$test_dir/regression" \
  "$test_dir/Transaction.swift" \
  iOS/ChaiWu/Database/DatabaseManager.swift \
  iOS/ChaiWu/Sync/XlsxManager.swift \
  iOS/ChaiWu/Sync/XlsReader.swift \
  iOS/ChaiWu/Sync/ZipArchiveBuilder.swift \
  tests/iOSDataRegression.swift
"$test_dir/regression"
