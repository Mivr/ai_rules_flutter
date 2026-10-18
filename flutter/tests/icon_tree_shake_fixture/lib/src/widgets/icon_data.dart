class IconData {
  const IconData(
    this.codePoint, {
    this.fontFamily,
    this.fontPackage,
    this.matchTextDirection = false,
  });

  final int codePoint;
  final String? fontFamily;
  final String? fontPackage;
  final bool matchTextDirection;
}

class _StaticIconProvider {
  const _StaticIconProvider();
}

const Object staticIconProvider = _StaticIconProvider();
