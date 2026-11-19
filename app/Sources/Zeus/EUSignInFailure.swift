import Foundation

/// The second step of the EU sign-in (`gcloud auth application-default set-quota-project <EU project>`) was refused
/// for a missing permission, from the terminal output of the sign-in. gcloud refuses the step when the signed-in account
/// does not have `serviceusage.services.use` on the EU project (the Service Usage Consumer role), or when the project
/// check itself gets HTTP 403. The app then shows the access words of the EU start check (`VertexError`, 403) in place
/// of the raw gcloud error. Other failures, and a failed login (the first step), give nil.
struct QuotaProjectDenial: Equatable {
    /// The Google account, when gcloud names it in its error.
    let account: String?

    /// The gcloud error prefix of the step: everything from its last occurrence to the end of the output is its error.
    static let errorPrefix = "ERROR: (gcloud.auth.application-default.set-quota-project)"

    init?(output: String) {
        guard let start = output.range(of: Self.errorPrefix, options: .backwards) else { return nil }
        let error = String(output[start.lowerBound...])
        let denied = ["serviceusage.services.use", "PERMISSION_DENIED", "does not have permission"]
            .contains { error.range(of: $0, options: .caseInsensitive) != nil }
            || error.range(of: #"(^|[^0-9A-Za-z.-])403([^0-9A-Za-z.-]|$)"#, options: .regularExpression) != nil
        guard denied else { return nil }
        account = error.range(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#, options: .regularExpression)
            .map { String(error[$0]) }
    }
}
