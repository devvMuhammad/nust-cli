"""Logs in to the fake portals with the real OS keychain (no file fallback), renews an
expired token from it, then logs out and checks the entry is gone from `nust status`."""
import sys
sys.path.insert(0, "tests")
sys.argv = ["x"]
import e2e

m, q = e2e.Moodle(), e2e.Qalam()
ls, qs = e2e.serve(e2e.MoodleHandler, m), e2e.serve(e2e.QalamHandler, q)
e = e2e.Env(ls.server_port, qs.server_port)
del e.env["NUST_PASSWORD_STORE"]
import os
e.env["HOME"] = os.environ.get("HOME", e.env["HOME"])
rc, out, err = e.run("login", "--only", "lms", env={"NUST_USERNAME": e2e.USER, "NUST_PASSWORD": e2e.PASSWORD})
print(out, err)
assert rc == 0 and "system keychain" in out, "login did not use the keychain"
assert not (e.dir / "state" / "password.json").exists()
m.tokens.clear()
rc, out, err = e.run("lms", "courses")
print(out, err)
assert rc == 0 and "expired, signed in again" in err, "renewal from keychain failed"
rc, out, err = e.run("logout")
assert rc == 0
rc, out, err = e.run("lms", "courses", env={})
assert rc == 2, "still signed in after logout"
print("keychain round trip ok")
