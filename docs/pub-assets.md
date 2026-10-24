# Pub package assets

How a `flutter.pub` spoke turns a pub package's `flutter.assets` entries
into bundle inputs, matching `flutter_tools` (`asset.dart`, `flutter_manifest.dart`).

## What the bundle keeps

- A file entry (for example `img/logo.png`) bundles the main file plus
  every same-named file in a sibling resolution directory (`img/2.0x/logo.png`,
  `img/3.0x/logo.png`, any directory name flutter_tools accepts as a variant).
  Each variant inherits the entry's `platforms` and `flavors`, and the bundle
  groups the variants under the main key with their `dpr`, as for an app's
  own variants.
- An entry whose main file is absent is accepted as long as a variant exists.
  An entry with neither a main file nor a variant fails the fetch, naming the
  package and the entry.
- A directory entry (for example `assets/icons/`) bundles the directory's own
  files plus each one's variants. Files in deeper subdirectories are not
  bundled.
- Asset walks are bounded; a walk that reaches its bound fails the fetch,
  naming the package and the directory, instead of bundling part of the tree.

## Walk bounds

Every pub spoke directory walk shares one bound, `PUB_WALK_BOUND`
(1000000 directories): asset listing, plugin source detection, and
path-package linking. A walk that reaches it fails the fetch naming the
package, the directory, and the bound, instead of bundling or reporting
part of the tree. Overlay heredoc rewriting fails the same way, naming
the package, the template, and the bound.

## What the fetch refuses

- A `platforms` or `flavors` value that is not a list of strings (for example
  a scalar `platforms: web`) fails the fetch, naming the package, the entry
  and the key, as flutter_tools does.
- An asset entry with a `transformers` key fails the fetch, naming the package
  and the entry: asset transformers are not supported by rules_flutter.
- Any other unknown key in an entry mapping is ignored, the way flutter_tools
  ignores it.
