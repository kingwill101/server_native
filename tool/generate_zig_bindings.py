"""Generate bindings from exported signatures without traversing protocol code.

The ABI generator only needs exported types. Isolating the declarations avoids
requiring the HTTP libraries' generated C headers during ABI discovery.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
tool_root = root / "tool/zig_bindings"
# Use the pinned Zig 0.16 generator without adding a Git dependency to consumers.
subprocess.run(["dart", "pub", "get"], cwd=tool_root, check=True)
source = (root / "zig/src/lib.zig").read_text()
# Optional many-item pointers have the same C ABI as optional single-item
# pointers. The current generator otherwise mistakes ?[*]T for an opaque value.
# This does not apply to slices ([]T), which have a different ABI.
signatures = re.findall(r"export fn [^{]+(?=\{)", source)
assert len(signatures) == source.count("export fn "), "Unrecognized export syntax"
(root / ".dart_tool").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="zig-abi-", dir=root / ".dart_tool") as tmp:
    directory = Path(tmp)
    header = (root / "zig/include/dart_api_dl.h").as_posix()
    (directory / "lib.zig").write_text(
        f'const c = @cImport({{ @cInclude("{header}"); }});\n'
        + "\n".join(signature.replace("?[*]", "?*") + "{ unreachable; }" for signature in signatures)
    )
    subprocess.run([
        "dart", "run", "native_toolchain_zig:zig", "bindings",
        "--package-root", str(root), "--zig-dir", str(directory),
        "--root-source-file", "lib.zig", "--output", "lib/src/zig_ffi.g.dart",
        "--asset-id", "package:server_native/src/zig_ffi.g.dart", "--link-libc",
    ], cwd=tool_root, check=True)
subprocess.run(["dart", "format", "lib/src/zig_ffi.g.dart"], cwd=root, check=True)
