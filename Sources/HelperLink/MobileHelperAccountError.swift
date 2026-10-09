/// LAN-only account authentication failures are service errors, not device
/// authorization failures. The fixed header is readable before a streaming body;
/// neither the header nor the message contains upstream account details.
public enum MobileHelperAccountError {
    public static let signInRequiredStatus = 503
    public static let headerName = "X-LangTools-Account-Error"
    public static let signInRequiredCode = "sign_in_required"
    public static let signInRequiredMessage = "Sign in to the account on the paired Mac, then retry. This phone is still paired."
}
