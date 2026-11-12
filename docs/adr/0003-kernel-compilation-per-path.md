---
status: accepted
unenforceable: "No registered metric measures which kernel path a target takes."
---

# 0003. Modular test closures with fallback; apps gate modular compiles

## Decision

A `flutter_test` closure compiles each `DartInfo` dependency once, into a
`<name>.flutter.kmod` module, and links the modules. The aspect is
`flutter_kernel_module_aspect`
(`flutter/private/flutter_kernel_module.bzl:1-14`). When the closure is not
eligible, the test falls back to one whole-program compile
(`flutter/private/flutter_test.bzl:209-240`). Eligibility needs an enabled mode,
modular dependencies, consistent packages, no code assets, no own defines, no
duplicate source and the same SDK
(`flutter/private/flutter_kernel_module.bzl:1135-1147`).

An application compiles its kernel through `flutter_compile_kernel`
(`flutter/private/common.bzl:979`). The standalone `flutter_kernel_target` and
`flutter_aot_target` call the same function. The modular path is taken only for
a non-AOT, non-profile compile with no native-assets manifest, recorded uses,
extra frontend flags, defines or define files (`_use_modular_kernel` in
`flutter/private/common.bzl`). A registrant or staged agent is allowed only
for a debug `flutter_kernel_target` (no asset bundle) whose closure holds the
registrant twin of the SDK `flutter` module: the entry module then compiles the
agent, the native agent and the registrant under their constant URIs, and the
link swaps the twin in for the plain module (`swap_flutter_registrant_twin`).
Every other compile is whole-program, among them any define (attribute or
global), AOT, profile, web, a closure with no twin, and `flutter_application`
unless the opt-in below applies.

An application takes the modular path only behind the private flag
`//flutter/private:debug_modular_app` (default off, outside the documented
surface; it exists for the bench that compares this path with the warm
frontend_server worker, and the default is decided after it). With the flag
on, a debug non-AOT `flutter_application` with no define of any kind
(attribute, global, define file, flavor), no native asset, no recorded use and
no widget-creation tracking links per-package modules like the debug
`flutter_kernel_target`: the module aspect on its `deps` registers nothing
unless the flag is on in a debug build, so every other application keeps its
single `FlutterKernelCompile`. The native-asset condition reads the resolved
asset list, not the always-present manifest file. The aspect lives in
`flutter/private/flutter_kernel_module.bzl` and the selection in
`flutter/private/common.bzl`.

A custom kernel built from `flutter_modular_test_kernel` or
`flutter_modular_app_kernel` has no fallback and fails instead
(`flutter/private/flutter_kernel_module.bzl:1302-1333`).

## Alternatives ruled out

- **Whole-program compiles for every test.** Each test binary recompiles every
  dependency. The `.flutter.kmod` split exists to avoid that.
- **Modular compiles for applications in every mode.** AOT, profile, registrant,
  native assets, defines and recorded uses need the whole-program inputs. The
  gate in `flutter/private/common.bzl:892-900` keeps them out of the modular
  path.
- **A silent fallback in custom kernels.** A user who wrote a custom kernel
  would get a different compile without being told. Failing is the chosen
  behaviour.

## Consequence

A new kernel input such as a define, a registrant or a native asset must be
added to the eligibility conditions in both
`flutter/private/flutter_kernel_module.bzl` and `flutter/private/common.bzl`. An
input that is missing from them takes the modular path without the input.
