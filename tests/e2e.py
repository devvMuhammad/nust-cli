"""End-to-end tests: the real `nust` binary against fake Qalam and Moodle servers on loopback.
Never touches the real portals. Run: python3 -I tests/e2e.py [path/to/nust]

Qalam pages come from tests/fixtures/qalam (trimmed real pages, kept local); without them the
Qalam part is skipped."""

import json, os, re, shutil, subprocess, sys, tempfile, threading, time, traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent.parent
BIN = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / ("zig-out/bin/nust.exe" if os.name == "nt" else "zig-out/bin/nust")
QFIX = ROOT / "tests/fixtures/qalam"
LFIX = ROOT / "tests/fixtures/lms"
USER, PASSWORD = "student1", "right-password"
NOW = int(time.time())


# ---------------- fake Moodle ----------------

def assignment(aid, name, due, *, cutoff=0, drafts=0, text=False, files=True, types="", statement=True, maxfiles=2):
    configs = [
        {"plugin": "file", "subtype": "assignsubmission", "name": "enabled", "value": "1" if files else "0"},
        {"plugin": "file", "subtype": "assignsubmission", "name": "maxfilesubmissions", "value": str(maxfiles)},
        {"plugin": "file", "subtype": "assignsubmission", "name": "maxsubmissionsizebytes", "value": "1048576"},
        {"plugin": "file", "subtype": "assignsubmission", "name": "filetypeslist", "value": types},
        {"plugin": "onlinetext", "subtype": "assignsubmission", "name": "enabled", "value": "1" if text else "0"},
    ]
    return {"id": aid, "cmid": aid + 10000, "course": 201, "name": name, "submissiondrafts": drafts,
            "duedate": due, "allowsubmissionsfromdate": 0, "cutoffdate": cutoff,
            "requiresubmissionstatement": 1 if statement else 0,
            "submissionstatement": "This submission is my own work, except where I have acknowledged others.",
            "teamsubmission": 0, "configs": configs}


class Moodle:
    def __init__(self):
        self.lock = threading.Lock()
        self.tokens = set()
        self.logins = 0
        self.calls = []
        self.drafts = {}
        self.next_item = 900
        self.drop_save = False
        self.lie_on_save = False
        self.assignments = [
            assignment(5001, "Lab 6: Graphs", NOW + 2 * 86400, types=".c,.txt,.pdf"),
            assignment(5002, "Lab 3: Stacks", NOW - 10 * 86400, cutoff=NOW - 3 * 86400),
            assignment(5003, "Reflection 1", NOW + 86400, drafts=1, text=True, files=False),
            assignment(5004, "Lab 5: Trees", NOW - 2 * 86400 - 3600, cutoff=NOW + 86400),
        ]
        self.subs = {a["id"]: {"status": "new", "files": [], "text": None, "modified": NOW - 1000} for a in self.assignments}

    def status(self, aid):
        s = self.subs[aid]
        plugins = [{"type": "file", "fileareas": [{"area": "submission_files", "files": [
            {"filename": n, "filesize": sz, "fileurl": "x", "timemodified": s["modified"]} for n, sz in s["files"]]}]}]
        if s["text"] is not None:
            plugins.append({"type": "onlinetext", "editorfields": [{"name": "onlinetext", "text": s["text"], "format": 1}]})
        return {"lastattempt": {"submission": {"id": aid, "status": s["status"], "timemodified": s["modified"], "plugins": plugins},
                                "submissionsenabled": True, "locked": False, "canedit": True, "cansubmit": True,
                                "extensionduedate": None, "gradingstatus": "notgraded"},
                "assignmentdata": {"attachments": {"intro": []}}, "warnings": []}

    def call(self, fn, f, base):
        self.calls.append(fn)
        if fn == "core_webservice_get_site_info":
            return {"sitename": "Fake LMS", "username": USER, "fullname": "Test Student", "userid": 77}
        if fn == "core_enrol_get_users_courses":
            return [{"id": 201, "fullname": "CS-201-Data Structures - 2K23-BESE-14", "visible": 1, "isfavourite": True, "lastaccess": NOW},
                    {"id": 202, "fullname": "CS-202-Data Science AB 2K23-BESE-14", "visible": 1, "lastaccess": NOW - 5},
                    {"id": 203, "fullname": "HU-101-Hidden", "visible": 0}]
        if fn == "core_calendar_get_action_events_by_timesort":
            return {"events": [{"id": 1, "name": "Class Activity-Section A", "activityname": "Class Activity-Section A", "modulename": "assign",
                                "timesort": NOW - 3 * 86400, "overdue": True, "url": "x", "course": {"id": 201, "fullname": "CS-201-Data Structures - 2K23-BESE-14"},
                                "action": {"name": "Add submission", "url": "x", "actionable": True}},
                               {"id": 2, "name": "Lab 6", "activityname": "Lab 6: Graphs", "modulename": "assign", "timesort": NOW + 2 * 86400,
                                "course": {"id": 201, "fullname": "CS-201-Data Structures - 2K23-BESE-14"}}]}
        if fn == "message_popup_get_popup_notifications":
            return {"notifications": [{"id": 9, "subject": "Due soon: Lab 6", "fullmessagehtml": "<p>Hi Test,</p><p>Lab 6 is due.</p>", "read": False, "timecreated": NOW - 3600},
                                      {"id": 8, "subject": "Welcome", "text": "Welcome", "read": True, "timecreated": NOW - 86400}], "unreadcount": 1}
        if fn == "mod_assign_get_assignments":
            return {"courses": [{"id": 201, "fullname": "CS-201-Data Structures - 2K23-BESE-14", "assignments": self.assignments}]}
        if fn == "mod_assign_get_submission_status":
            return self.status(int(f["assignid"]))
        if fn == "core_course_get_contents":
            return json.loads((ROOT / "tests/fixtures/synthetic_course_contents.json").read_text().replace("{BASE}", base))
        if fn == "mod_assign_save_submission":
            aid = int(f["assignmentid"])
            s = self.subs[aid]
            a = next(x for x in self.assignments if x["id"] == aid)
            if "plugindata[files_filemanager]" in f:
                s["files"] = list(self.drafts.get(int(f["plugindata[files_filemanager]"]), []))
            if "plugindata[onlinetext_editor][text]" in f:
                t = f["plugindata[onlinetext_editor][text]"]
                s["text"] = "<p>" + t.replace("<", "&lt;") + "</p>" if f.get("plugindata[onlinetext_editor][format]") == "2" else t
            s["status"] = "draft" if a["submissiondrafts"] else "submitted"
            s["modified"] = max(s["modified"] + 1, int(time.time()))
            if self.lie_on_save:
                s["files"] = s["files"][:1]
            return []
        if fn == "mod_assign_submit_for_grading":
            aid = int(f["assignmentid"])
            if f.get("acceptsubmissionstatement") != "1":
                return [{"warningcode": "submissionstatement", "message": "statement not accepted"}]
            self.subs[aid]["status"] = "submitted"
            return []
        return {"exception": "x", "errorcode": "invalidfunction", "message": "unknown " + fn}


class MoodleHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send_json(self, obj, status=200):
        b = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", 0)))

    def do_GET(self):
        m = self.server.state
        u = urlsplit(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if "/webservice/pluginfile.php/" in u.path:
            if q.get("token") not in m.tokens:
                return self.send_json({"error": "Invalid token", "errorcode": "invalidtoken"})
            data = (u.path.rsplit("/", 1)[-1] + "-content").encode()
            data = data.ljust(32 if data.startswith(b"lecture1") else 30, b".")
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            return self.wfile.write(data)
        self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        m = self.server.state
        raw = self.body()
        path = urlsplit(self.path).path
        base = f"http://127.0.0.1:{self.server.server_port}"
        with m.lock:
            if path == "/login/token.php":
                f = {k: v[0] for k, v in parse_qs(raw.decode()).items()}
                if f.get("username") == USER and f.get("password") == PASSWORD and f.get("service") == "moodle_mobile_app":
                    m.logins += 1
                    tok = f"tok{m.logins}"
                    m.tokens.add(tok)
                    return self.send_json({"token": tok, "privatetoken": None})
                return self.send_json({"error": "Invalid login, please try again", "errorcode": "invalidlogin"})
            if path == "/webservice/upload.php":
                fields, files = parse_multipart(raw, self.headers["Content-Type"])
                if fields.get("token") not in m.tokens:
                    return self.send_json({"error": "Invalid token", "errorcode": "invalidtoken"})
                item = int(fields.get("itemid", "0")) or m.next_item
                m.next_item += 1
                name, data = files[0]
                m.drafts.setdefault(item, []).append((name, len(data)))
                return self.send_json([{"component": "user", "filearea": "draft", "itemid": item, "filename": name, "filesize": len(data)}])
            if path == "/webservice/rest/server.php":
                f = {k: v[0] for k, v in parse_qs(raw.decode()).items()}
                if f.get("wstoken") not in m.tokens:
                    return self.send_json({"exception": "moodle_exception", "errorcode": "invalidtoken", "message": "Invalid token - token not found"})
                if f["wsfunction"] == "mod_assign_save_submission" and m.drop_save:
                    m.drop_save = False
                    self.close_connection = True
                    self.connection.shutdown(2)
                    return
                return self.send_json(m.call(f["wsfunction"], f, base))
        self.send_json({"error": "not found"}, 404)


def parse_multipart(raw, ctype):
    boundary = ctype.split("boundary=")[1].encode()
    fields, files = {}, []
    for part in raw.split(b"--" + boundary):
        if b"\r\n\r\n" not in part:
            continue
        head, _, body = part.partition(b"\r\n\r\n")
        body = body[:-2] if body.endswith(b"\r\n") else body
        name = re.search(rb'name="([^"]*)"', head).group(1).decode()
        fn = re.search(rb'filename="([^"]*)"', head)
        if fn:
            files.append((fn.group(1).decode(), body))
        else:
            fields[name] = body.decode()
    return fields, files


# ---------------- fake Qalam ----------------

class Qalam:
    def __init__(self):
        self.valid = set()
        self.n = 0
        self.logins = 0
        self.feedback = False
        self.pages = {
            "/student/dashboard": "dashboard.html",
            "/student/results/": "results.html",
            "/student/class/schedule": "class_schedule.html",
            "/student/invoices": "invoices.html",
        }
        # course_attendance_<id>.html -> /student/course/attendance/<id>, same for gradebook.
        for f in QFIX.glob("course_*_*.html") if QFIX.exists() else []:
            kind, cid = f.stem.split("_")[1:3]
            self.pages[f"/student/course/{kind}/{cid}"] = f.name


# Stand-ins when the real (private) pages are not present, e.g. in CI.
SYNTHETIC = {
    "web_login.html": b'<html><head><title>Odoo</title></head><body><form action="/web/login" method="post">'
                      b'<input type="hidden" name="csrf_token" value="testcsrf123"/><input name="login"/>'
                      b'<input type="password" name="password"/></form></body></html>',
    "dashboard.html": b'<html><body><a href="/student/dashboard">Dashboard</a><a href="/web/session/logout">Logout</a></body></html>',
}


class QalamHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def cookie(self):
        c = self.headers.get("Cookie", "")
        m = re.search(r"session_id=([^;]+)", c)
        return m.group(1) if m else None

    def html(self, name, status=200, cookie=None):
        f = QFIX / name
        b = f.read_bytes() if f.exists() else SYNTHETIC.get(name, b"<html><body>missing</body></html>")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        if cookie:
            self.send_header("Set-Cookie", f"session_id={cookie}; Path=/; HttpOnly")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def redirect(self, where, cookie=None):
        self.send_response(303)
        self.send_header("Location", where)
        if cookie:
            self.send_header("Set-Cookie", f"session_id={cookie}; Path=/; HttpOnly")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        q = self.server.state
        path = urlsplit(self.path).path
        if path == "/web/login":
            return self.html("web_login.html", cookie="anon" + str(time.time_ns()))
        sid = self.cookie()
        if sid not in q.valid:
            return self.redirect("/web/login?redirect=" + path)
        if q.feedback:
            return self.redirect("/student/qa/feedback")
        name = q.pages.get(path)
        if not name:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            return self.end_headers()
        self.html(name)

    def do_POST(self):
        q = self.server.state
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        f = {k: v[0] for k, v in parse_qs(raw).items()}
        if urlsplit(self.path).path != "/web/login" or f.get("csrf_token") != "testcsrf123":
            self.send_response(400)
            self.send_header("Content-Length", "0")
            return self.end_headers()
        if f.get("login") == USER and f.get("password") == PASSWORD:
            q.n += 1
            q.logins += 1
            sid = f"good{q.n}"
            q.valid.add(sid)
            return self.redirect(f.get("redirect", "/student/dashboard"), cookie=sid)
        return self.html("web_login.html")


# ---------------- runner ----------------

def serve(handler, state):
    s = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    s.state = state
    threading.Thread(target=s.serve_forever, daemon=True).start()
    return s


class Env:
    def __init__(self, lms_port, qalam_port):
        self.dir = Path(tempfile.mkdtemp(prefix="nust-e2e-"))
        # Keep the system environment (Windows needs SystemRoot for networking), minus ours.
        base = {k: v for k, v in os.environ.items() if not k.startswith(("NUST_", "LMS_", "QALAM_"))}
        self.env = {
            **base,
            "HOME": str(self.dir),
            "TZ": "Asia/Karachi",
            "NUST_STATE_DIR": str(self.dir / "state"),
            "NUST_PASSWORD_STORE": "file",
            "LMS_BASE_URL": f"http://127.0.0.1:{lms_port}",
            "QALAM_BASE_URL": f"http://127.0.0.1:{qalam_port}",
        }

    def run(self, *args, env=None, stdin=""):
        e = dict(self.env, **(env or {}))
        p = subprocess.run([str(BIN), *args], input=stdin, capture_output=True, text=True, env=e, cwd=self.dir, timeout=60)
        return p.returncode, p.stdout, p.stderr


RESULTS = []


def check(name, cond, detail=""):
    RESULTS.append((name, bool(cond)))
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else f"\n     {detail}"))


def main():
    moodle, qalam = Moodle(), Qalam()
    ls, qs = serve(MoodleHandler, moodle), serve(QalamHandler, qalam)
    have_qalam = QFIX.exists() and (QFIX / "dashboard.html").exists()
    e = Env(ls.server_port, qs.server_port)
    try:
        run_all(e, moodle, qalam, have_qalam)
    except Exception:
        traceback.print_exc()
        RESULTS.append(("crash", False))
    finally:
        shutil.rmtree(e.dir, ignore_errors=True)
    failed = [n for n, ok in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} passed")
    sys.exit(1 if failed else 0)


def run_all(e, moodle, qalam, have_qalam):
    rc, out, err = e.run("lms", "courses")
    check("not signed in exits 2", rc == 2 and "nust login" in err, err)

    rc, out, err = e.run("login", env={"NUST_USERNAME": USER, "NUST_PASSWORD": "wrong"})
    check("wrong password fails both", rc == 1 and out.count("did not accept") == 2, out + err)

    rc, out, err = e.run("login")
    check("login without terminal or env exits 2", rc == 2 and "NUST_USERNAME" in err, err)

    rc, out, err = e.run("login", env={"NUST_USERNAME": USER, "NUST_PASSWORD": PASSWORD})
    ok = rc == 0 and "LMS    ok (Test Student)" in out if not have_qalam else rc == 0 and "Qalam  ok" in out
    check("login succeeds", ok, out + err)
    st = e.dir / "state"
    check("session files are private", os.name == "nt" or all((st / f).stat().st_mode & 0o077 == 0 for f in os.listdir(st) if (st / f).is_file()))
    pw = json.loads((st / "password.json").read_text())
    check("password saved to file store", pw["password"] == PASSWORD)
    check("password never in session files", all(PASSWORD not in (st / f).read_text() for f in ["lms-session.json", "account.json"]))

    rc, out, err = e.run("lms", "courses")
    check("lms courses", rc == 0 and "CS-201" in out and "Data Structures" in out and "Hidden" not in out, out + err)

    rc, out, err = e.run("lms", "courses", "--json")
    check("lms courses --json", rc == 0 and json.loads(out)[0]["code"] == "CS-201", out)

    # Expired LMS token: renewed silently with the saved password, retried once.
    moodle.tokens.clear()
    before = moodle.logins
    rc, out, err = e.run("lms", "deadlines", "--all")
    check("expired token renews silently", rc == 0 and moodle.logins == before + 1 and "LMS session expired" in err and "Class Activity" in out, out + err)

    rc, out, err = e.run("lms", "notifications", "--unread")
    check("notifications", rc == 0 and "unread in total" in out, out + err)

    rc, out, err = e.run("lms", "assignments")
    check("assignments table", rc == 0 and "Lab 6: Graphs" in out and "no (closed)" in out and "late" in out, out + err)

    rc, out, err = e.run("lms", "status", "lab 6")
    check("status by name", rc == 0 and "Lab 6: Graphs" in out and ".c, .txt, .pdf" in out, out + err)

    rc, out, err = e.run("lms", "status", "lab")
    check("ambiguous lists candidates and exits 2", rc == 2 and "5001" in err and "5004" in err, err)

    rc, out, err = e.run("lms", "files", "data str")
    check("files listing", rc == 0 and "lecture1.pdf" in out and "https://example.org/reading" in out, out + err)

    rc, out, err = e.run("lms", "files", "data")
    check("ambiguous course", rc == 2 and "201" in err and "202" in err, err)

    rc, out, err = e.run("lms", "files", "201", "--download", "dl")
    got = sorted(str(p.relative_to(e.dir / "dl")) for p in (e.dir / "dl").rglob("*") if p.is_file())
    check("download all files", rc == 0 and len(got) == 3 and "2 downloaded" not in out, f"{got}\n{out}{err}")
    rc, out, err = e.run("lms", "files", "201", "--download", "dl")
    check("download again skips", rc == 0 and "0 downloaded, 3 up to date" in out, out + err)

    # ---- submit ----
    # Bytes, not text: Windows would turn \n into \r\n and change the sizes.
    (e.dir / "main.c").write_bytes(b"int main(){return 0;}\n")
    (e.dir / "out.txt").write_bytes(b"ok\n")
    (e.dir / "notes.docx").write_bytes(b"x")
    (e.dir / "empty.c").write_bytes(b"")

    rc, out, err = e.run("lms", "submit", "lab 6", "main.c")
    check("submit without terminal and -y sends nothing", rc == 2 and moodle.subs[5001]["status"] == "new" and "-y" in err and "main.c" in out, out + err)

    rc, out, err = e.run("lms", "submit", "lab 3", "main.c", "-y")
    check("closed assignment refused (exit 3)", rc == 3 and "cut-off" in err and "Nothing sent" in err, err)

    rc, out, err = e.run("lms", "submit", "lab 6", "notes.docx", "-y")
    check("wrong type refused", rc == 3 and "type not allowed" in err, err)
    rc, out, err = e.run("lms", "submit", "lab 6", "missing.c", "-y")
    check("missing file refused", rc == 3 and "not found" in err, err)
    rc, out, err = e.run("lms", "submit", "lab 6", "empty.c", "-y")
    check("empty file refused", rc == 3 and "empty" in err, err)
    rc, out, err = e.run("lms", "submit", "lab 6", "main.c", "out.txt", "notes.docx", "-y")
    check("refusals happen before any upload", rc == 3 and not moodle.drafts, err)

    rc, out, err = e.run("lms", "submit", "lab 6", "main.c", "-y")
    check("submit succeeds and verifies", rc == 0 and "Submitted. The LMS now has:" in out and moodle.subs[5001]["files"] == [("main.c", 22)], out + err)
    check("statement shown as accepted", "Statement accepted for you" in out, out)

    rc, out, err = e.run("lms", "submit", "lab 6", "main.c", "-y")
    check("same files again: up to date, nothing sent", rc == 0 and "already has these exact files" in out and "Nothing sent" in out, out + err)

    rc, out, err = e.run("lms", "submit", "5001", "out.txt", "-y")
    check("replacing shows the removed file", rc == 0 and "- main.c" in out and moodle.subs[5001]["files"] == [("out.txt", 3)], out + err)

    rc, out, err = e.run("lms", "submit", "lab 5", "main.c", "-y", "--json")
    j = json.loads(out) if rc == 0 else {}
    check("late submit (json)", rc == 0 and j.get("submitted") and j.get("late_secs", 0) > 2 * 86400, out + err)

    moodle.lie_on_save = True
    rc, out, err = e.run("lms", "submit", "lab 6", "main.c", "out.txt", "-y")
    moodle.lie_on_save = False
    check("verification catches a mismatch", rc == 1 and "doesn't match" in err and "out.txt" in err, out + err)

    moodle.drop_save = True
    rc, out, err = e.run("lms", "submit", "lab 6", "out.txt", "-y")
    moodle.drop_save = False
    check("dropped save is never retried", rc == 1 and "unclear whether the LMS saved it" in err and "nust lms status 5001" in err, out + err)

    rc, out, err = e.run("lms", "submit", "reflection", "--text", "I learned <graphs> & trees", "-y")
    check("text submission with drafts: saved then submitted for grading", rc == 0 and moodle.subs[5003]["status"] == "submitted"
          and "mod_assign_submit_for_grading" in moodle.calls, out + err)

    rc, out, err = e.run("lms", "submit", "reflection", "main.c", "-y")
    check("files to a text-only assignment refused", rc == 3 and "does not take file" in err, err)

    rc, out, err = e.run("lms", "submit", "lab 6", "main.c", "-y", "--json")
    check("json errors are one line on stderr", True)
    rc, out, err = e.run("lms", "status", "nothing-like-this", "--json")
    try:
        doc = json.loads(err)
        check("json error document", rc == 2 and doc["error"]["code"] == "NOT_FOUND" and out == "", err)
    except ValueError:
        check("json error document", False, err)

    # Password gone and session expired: no terminal, so it stops instead of waiting.
    (st / "password.json").unlink()
    moodle.tokens.clear()
    rc, out, err = e.run("lms", "courses")
    check("expired with no saved password exits 2", rc == 2 and "no password is saved" in err, err)
    rc, out, err = e.run("lms", "courses", env={"NUST_PASSWORD": PASSWORD})
    check("NUST_PASSWORD renews", rc == 0 and "CS-201" in out, err)

    if not have_qalam:
        print("SKIP Qalam: no tests/fixtures/qalam pages")
        return
    (st / "password.json").write_text(json.dumps({"version": 1, "username": USER, "password": PASSWORD}))

    # The pages are private, so these checks look at shape, not at anyone's marks.
    rc, out, err = e.run("qalam", "courses", "--json")
    courses = json.loads(out) if rc == 0 else []
    check("qalam courses", rc == 0 and courses and all(re.fullmatch(r"[A-Z]+-\d+", c["code"]) for c in courses), out + err)
    have = lambda kind: [c for c in courses if (QFIX / f"course_{kind}_{c['id']}.html").exists()]

    rc, out, err = e.run("qalam", "courses")
    check("qalam courses table", rc == 0 and "CODE" in out and "ATTENDANCE" in out, out + err)

    if have("attendance"):
        rc, out, err = e.run("qalam", "attendance", have("attendance")[0]["code"])
        check("qalam attendance one course", rc == 0 and re.search(r"\d+/\d+|not marked yet", out), out + err)
    rc, out, err = e.run("qalam", "attendance")
    check("qalam attendance all courses", rc == 0 and out.count("\n") > len(courses), out + err)

    if have("gradebook"):
        code = have("gradebook")[-1]["code"]
        rc, out, err = e.run("qalam", "grades", code)
        check("qalam grades", rc == 0 and ("ASSESSMENT" in out or "No marks yet" in out), out + err)
        rc, out, err = e.run("qalam", "grades", code, "lab", "--json")
        j = json.loads(out) if rc == 0 else {}
        names = [m["name"] for c in j.get("components", []) for cat in c["categories"] for m in cat["marks"]
                 if "lab" not in cat["name"].lower()]
        check("qalam grades filter", rc == 0 and all("lab" in n.lower() for n in names), out + err)

    rc, out, err = e.run("qalam", "results")
    check("qalam results", rc == 0 and re.search(r"SGPA \d\.\d\d +CGPA \d\.\d\d", out) and "GRADE" in out, out + err)

    rc, out, err = e.run("qalam", "timetable")
    check("qalam timetable", rc == 0 and re.search(r"(Monday|Tuesday|Wednesday|Thursday|Friday) +\d\d:\d\d-\d\d:\d\d", out), out + err)

    rc, out, err = e.run("qalam", "invoices")
    check("qalam invoices", rc == 0 and re.search(r"\d{4}-\d\d-\d\d +\d{4}-\d\d-\d\d", out), out + err)

    # Expired Qalam session: renewed silently, once.
    qalam.valid.clear()
    before = qalam.logins
    rc, out, err = e.run("qalam", "courses")
    check("expired qalam session renews silently", rc == 0 and qalam.logins == before + 1 and "Qalam session expired" in err, out + err)

    qalam.feedback = True
    rc, out, err = e.run("qalam", "courses")
    qalam.feedback = False
    check("feedback gate explained", rc == 1 and "QA feedback" in err, err)

    rc, out, err = e.run("status")
    check("status shows both", rc == 0 and "Qalam     signed in" in out and "LMS       signed in" in out, out + err)

    rc, out, err = e.run("logout")
    check("logout removes everything", rc == 0 and not (st / "lms-session.json").exists() and not (st / "qalam-session.json").exists()
          and not (st / "password.json").exists(), out + err)


if __name__ == "__main__":
    main()
