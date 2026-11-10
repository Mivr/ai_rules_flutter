import BigInt

/// Lives in a second target of the plugin, which reaches BigInt through a
/// by-name dependency (`"BigInt"`) rather than `.product(name:package:)`.
public enum SpmBigintHelper {
  public static func negativeZero() -> BigInt {
    return BigInt("-0", radix: 10)!
  }
}
