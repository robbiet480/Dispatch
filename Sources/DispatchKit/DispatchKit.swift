/// Namespace marker for the DispatchKit core library.
public enum DispatchKitInfo {
    /// The version of the v2 export/backup JSON format (`V2Export` and its
    /// nested DTOs) that this build reads and writes.
    ///
    /// Bump policy: increment on any change that alters how an existing field
    /// is encoded, or that removes/renames a field — such changes break
    /// compatibility with files written by older builds. Purely additive
    /// optional fields (a new `Optional` property that older readers simply
    /// ignore and older writers simply omit) do NOT require a bump.
    public static let schemaVersion = 2
}
