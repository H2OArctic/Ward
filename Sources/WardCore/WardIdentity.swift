public enum WardIdentity {
    public static let applicationID = WardBuildIdentity.applicationID
    public static let browserHostID = applicationID + ".browser-host"
    public static let commandHelperID = applicationID + ".cli"
}
