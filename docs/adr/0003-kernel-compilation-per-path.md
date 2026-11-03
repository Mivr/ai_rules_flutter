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
a non-AOT, non-profile compile with no registrant, agent, native-assets
manifest, recorded uses, extra frontend flags or defines
(`flutter/private/common.bzl:892-900`). Every other compile is whole-program
(`flutter/private/flutter_compile.bzl:602`).

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
