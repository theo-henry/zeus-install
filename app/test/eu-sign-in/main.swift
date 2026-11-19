import Foundation

// The terminal output of the EU sign-in: `gcloud auth application-default login`, then
// `gcloud auth application-default set-quota-project <EU project>`. The gcloud lines are the words of
// googlecloudsdk/command_lib/auth/auth_util.py and of a 403 of the project permission check.
let login = """
Your browser has been opened to visit:

    https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com

Credentials saved to file: [/Users/someone/.config/gcloud/application_default_credentials.json]

These credentials will be used by any library that requests Application Default Credentials (ADC).
"""
let project = "project-4bf0bacd-fec4-406b-a99"

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  PASS \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

let missingPermission = login + """

ERROR: (gcloud.auth.application-default.set-quota-project) Cannot add the project "\(project)" to application default \
credentials (ADC) as a quota project because the account in ADC does not have the "serviceusage.services.use" permission on this project.
"""
check("a missing serviceusage.services.use permission is a denial, without an account",
      QuotaProjectDenial(output: missingPermission).map { $0.account == nil } == true)

let forbidden = login + """

ERROR: (gcloud.auth.application-default.set-quota-project) User [someone@example.com] does not have permission to access \
projects instance [\(project)] (or it may not exist): The caller does not have permission
"""
check("a refused project check is a denial, with the account that gcloud names",
      QuotaProjectDenial(output: forbidden)?.account == "someone@example.com")

let http403 = login + """

ERROR: (gcloud.auth.application-default.set-quota-project) HttpError accessing <https://cloudresourcemanager.googleapis.com/\
v1/projects/\(project):testIamPermissions>: response: <{'status': '403'}>, content <{
  "error": {
    "code": 403,
    "status": "PERMISSION_DENIED"
  }
}>
"""
check("an HTTP 403 PERMISSION_DENIED of the step is a denial", QuotaProjectDenial(output: http403) != nil)

let notUser = login + """

ERROR: (gcloud.auth.application-default.set-quota-project) The application default credentials are not user credentials, quota project cannot be added.
"""
check("another error of the step is not a denial", QuotaProjectDenial(output: notUser) == nil)

let network = login + """

ERROR: (gcloud.auth.application-default.set-quota-project) There was a problem refreshing your current auth tokens: \
('Connection aborted.', RemoteDisconnected('Remote end closed connection without response'))
"""
check("a network error of the step is not a denial", QuotaProjectDenial(output: network) == nil)

let project403 = login + """

ERROR: (gcloud.auth.application-default.set-quota-project) Project [zeus-403-eu] not found.
"""
check("403 in a project name is not a denial", QuotaProjectDenial(output: project403) == nil)

let loginDenied = """
Your browser has been opened to visit:

ERROR: (gcloud.auth.application-default.login) There was a problem with web authentication. PERMISSION_DENIED 403 someone@example.com
"""
check("a failed login (the first step) is not a denial", QuotaProjectDenial(output: loginDenied) == nil)

let success = login + """

Credentials saved to file: [/Users/someone/.config/gcloud/application_default_credentials.json]

Quota project "\(project)" was added to ADC which can be used by Google client libraries for billing and quota.
"""
check("a completed sign-in is not a denial", QuotaProjectDenial(output: success) == nil)
check("no output is not a denial", QuotaProjectDenial(output: "") == nil)

if failures > 0 {
    print("\(failures) check(s) failed.")
    exit(1)
}
print("All checks passed.")
