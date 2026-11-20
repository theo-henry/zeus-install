import Foundation

// Arguments: the test home (with anaconda3/bin/python3, a Python 3.10 or later), a folder whose python3 is a Python 3.9,
// and a folder with python3.12 (a Python 3.10 or later).
let arguments = CommandLine.arguments
let home = arguments[1], old = arguments[2], newer = arguments[3]

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  PASS \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

check("only a Python 3.9 on the fallback PATH: no Python for gcloud",
      GcloudPython.find(folders: [old], path: "\(old):/usr/bin:/bin") == nil)
check("Anaconda of the home folder comes first, also when it is not on the PATH",
      GcloudPython.find(folders: GcloudPython.folders(home: home, system: []), path: "\(old):/usr/bin:/bin") == home + "/anaconda3/bin/python3")
check("without Anaconda, a python3.12 on the PATH", GcloudPython.find(folders: [old], path: "\(old):\(newer):/usr/bin") == newer + "/python3.12")
check("a Python 3.9 is not supported", !GcloudPython.supported(old + "/python3"))
exit(failures == 0 ? 0 : 1)
