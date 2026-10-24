"""Trims saved Qalam pages to their #page_content and strips identifiers, for parser tests.
Usage: python3 -I tests/trim_qalam_pages.py <saved-pages-dir> <out-dir> ["Your Full Name"]"""
import re, sys, pathlib
src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
name = sys.argv[3] if len(sys.argv) > 3 else None
out.mkdir(parents=True, exist_ok=True)
for f in sorted(src.glob("*.html")):
    s = f.read_text(errors="replace")
    s = re.sub(r"<script\b.*?</script>", "", s, flags=re.S | re.I)
    s = re.sub(r"<style\b.*?</style>", "", s, flags=re.S | re.I)
    s = re.sub(r'src="data:[^"]*"', 'src=""', s)
    m = re.search(r'<div id="page_content"', s)
    if m:
        body = s[m.start():]
        body = re.split(r'<footer|<div id="sidebar_secondary"', body)[0]
        s = ('<html><head><title>Odoo</title></head><body>\n'
             '<a href="/student/dashboard">Dashboard</a><a href="/web/session/logout?redirect=/">Logout</a>\n'
             + body + '\n</body></html>\n')
    if name:
        s = s.replace(name, "Test Student")
    s = re.sub(r'name="student_id" value="\d+"', 'name="student_id" type="hidden" value="1"', s)
    s = re.sub(r'value="\d+" name="student_id"', 'value="1" name="student_id"', s)
    s = re.sub(r'name="csrf_token" value="[^"]*"', 'name="csrf_token" value="testcsrf123"', s)
    s = re.sub(r'value="[0-9a-f]{40}o\d+"', 'value="testcsrf123"', s)
    s = re.sub(r"<td>\s*0[0-9]{6}\s*</td>", lambda m: "<td> 0000" + str(abs(hash(m.group())) % 1000).zfill(3) + " </td>", s)
    (out / f.name.replace("student_", "")).write_text(s)
    print(f.name, len(s))
