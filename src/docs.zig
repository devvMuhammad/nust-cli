//! Every help screen, the agents guide and the shell completion scripts.
const std = @import("std");

pub const usage =
    \\nust - Qalam and the NUST LMS from the terminal
    \\
    \\Sign in once:
    \\  nust login [--only qalam|lms] [--lms-username <u>]
    \\  nust logout [--only qalam|lms]
    \\  nust status                          are both sign-ins still good?
    \\
    \\Qalam:
    \\  nust qalam courses
    \\  nust qalam attendance [<course>]     lecture and lab separately
    \\  nust qalam grades <course> [<filter>]   filter: quiz, "Quiz 2", midterm
    \\  nust qalam results                   SGPA, CGPA and grades per term
    \\  nust qalam timetable
    \\  nust qalam invoices
    \\
    \\LMS:
    \\  nust lms whoami
    \\  nust lms courses
    \\  nust lms deadlines [--all]
    \\  nust lms notifications [--unread]
    \\  nust lms assignments [<course>]
    \\  nust lms status <assignment>
    \\  nust lms files <course> [--download <dir>]
    \\  nust lms submit <assignment> <file>... [--text "..."] [-y]
    \\
    \\Other:
    \\  nust completions <bash|zsh|fish|powershell>
    \\  nust help agents                     guide for AI agents and scripts
    \\  nust version
    \\
    \\Every command takes --json. <course> is an id, a code like CS-405, or part of the
    \\name. <assignment> is an id, part of the name, or course/name like "CS-405/lab 6".
    \\
    \\Exit codes: 0 ok, 1 failed, 2 usage error or no terminal for a prompt,
    \\3 refused by a safety check (nothing was sent).
    \\
    \\Environment: NUST_USERNAME, NUST_PASSWORD (skip the prompts), NUST_STATE_DIR
    \\(where sessions are kept), NUST_PASSWORD_STORE=file (skip the keychain).
    \\
;

pub const lms_help =
    \\nust lms - the NUST LMS (Moodle)
    \\
    \\  nust lms whoami                      who the saved session belongs to
    \\  nust lms courses                     your courses, favourites first
    \\  nust lms deadlines [--all]           two weeks back to three months ahead
    \\  nust lms notifications [--unread]
    \\  nust lms assignments [<course>]      due dates, submitted or not, still open
    \\  nust lms status <assignment>         files on record, limits, grading
    \\  nust lms files <course> [--download <dir>]
    \\                                       list course files, or save them all as
    \\                                       <dir>/<section>/<file> (skips ones you have)
    \\  nust lms submit <assignment> <file>... [--text "..."] [-y]
    \\
    \\Submitting:
    \\  It shows what will be sent, the files it replaces and whether it is late,
    \\  then asks "Submit? [y/N]". -y skips the question (for scripts). A submission
    \\  is always final, and the submission statement is accepted for you. After
    \\  saving it reloads the assignment and checks the LMS has exactly your files.
    \\  It refuses (exit 3, nothing sent) when the assignment is closed, a file is
    \\  missing, empty, too large or of a type the assignment does not allow.
    \\
    \\Examples:
    \\  nust lms submit "assignment 2" report.pdf
    \\  nust lms submit CS-405/lab3 main.c output.txt
    \\  nust lms submit "reflection 1" --text "This week I learned that..."
    \\  nust lms files deep --download ~/Downloads/DL
    \\
;

pub const qalam_help =
    \\nust qalam - the Qalam portal (read only)
    \\
    \\  nust qalam courses                   this term's courses with attendance
    \\  nust qalam attendance [<course>]     attended/conducted for lecture and lab;
    \\                                       with a course, the dates you were absent
    \\  nust qalam grades <course> [<filter>]
    \\                                       marks per assessment with class average
    \\  nust qalam results                   SGPA, CGPA and grades for past terms
    \\  nust qalam timetable                 this term's weekly classes
    \\  nust qalam invoices                  fee challans and whether they are paid
    \\
    \\Marks Qalam shows as 0 with a 0 class average are shown as - (not marked yet).
    \\If Qalam asks for the QA feedback forms, fill them in on the website first.
    \\
;

pub fn helpFor(path: []const []const u8) []const u8 {
    if (path.len == 0) return usage;
    if (std.mem.eql(u8, path[0], "lms")) return lms_help;
    if (std.mem.eql(u8, path[0], "qalam")) return qalam_help;
    return usage;
}

pub const agents =
    \\nust for AI agents and scripts
    \\
    \\Use --json on every command. Output is one JSON document on stdout. On failure,
    \\stdout is empty and stderr has exactly one line:
    \\  {"error":{"code":"AUTH_REQUIRED","message":"...","exit":2}}
    \\
    \\Exit codes:
    \\  0  ok
    \\  1  failed (network, portal error, verification failed)
    \\  2  usage error, or a prompt was needed and there is no terminal
    \\  3  refused by a safety check; nothing was sent
    \\
    \\Signing in: run `nust login` once in a terminal, or set NUST_USERNAME and
    \\NUST_PASSWORD. Expired sessions renew by themselves with the saved password.
    \\If no password is saved, commands exit 2 with AUTH_REQUIRED instead of waiting.
    \\
    \\Reading (safe to call any time):
    \\  nust status --json
    \\  nust qalam courses|attendance|grades|results|timetable|invoices --json
    \\  nust lms courses|deadlines|notifications|assignments|status|files --json
    \\
    \\Submitting changes the LMS and is usually final at once:
    \\  1. Preview: `nust lms submit <assignment> <file>... --json` without -y.
    \\     With no terminal it sends nothing, prints {"submitted":false,"plan":...}
    \\     (files, files it removes, late_secs) and exits 2. Show that to the user.
    \\  2. Only after the user says yes for this assignment, run the same command
    \\     with -y.
    \\  3. Exit 0 with "submitted": true means the LMS was re-read and holds exactly
    \\     the files sent. Exit 3 means refused (closed, bad file); nothing was sent.
    \\     WRITE_UNKNOWN means the connection dropped mid-save: do NOT retry; run
    \\     `nust lms status <assignment>` and show the user.
    \\
    \\Useful error codes: AUTH_REQUIRED, LOGIN_FAILED, NOT_FOUND, AMBIGUOUS (the
    \\message lists the candidates; ask the user or use an id), REFUSED,
    \\FEEDBACK_REQUIRED (the user must fill Qalam's QA forms in a browser),
    \\BROWSER_CHECK (Cloudflare; the user must open Qalam in a browser), PORTAL_CHANGED,
    \\NETWORK, WRITE_UNKNOWN, VERIFY_FAILED.
    \\
    \\Numbers are what the portals show. Nothing is estimated: no GPA predictions, no
    \\attendance cut-offs. A Qalam mark of 0 with a 0 class average has
    \\"likely_unmarked": true.
    \\
;

const bash =
    \\_nust() {
    \\  local cur=${COMP_WORDS[COMP_CWORD]} w1=${COMP_WORDS[1]}
    \\  case $COMP_CWORD in
    \\    1) COMPREPLY=($(compgen -W "login logout status qalam lms completions help version" -- "$cur")) ;;
    \\    2) case $w1 in
    \\         qalam) COMPREPLY=($(compgen -W "courses attendance grades results timetable invoices" -- "$cur")) ;;
    \\         lms) COMPREPLY=($(compgen -W "whoami courses deadlines notifications assignments status files submit" -- "$cur")) ;;
    \\         completions) COMPREPLY=($(compgen -W "bash zsh fish powershell" -- "$cur")) ;;
    \\         login|logout) COMPREPLY=($(compgen -W "--only --lms-username --json" -- "$cur")) ;;
    \\       esac ;;
    \\    *) COMPREPLY=($(compgen -f -W "--json -y --text --download --all --unread" -- "$cur")) ;;
    \\  esac
    \\}
    \\complete -o default -F _nust nust
    \\
;

const zsh =
    \\#compdef nust
    \\_nust() {
    \\  case $CURRENT in
    \\    2) _values command login logout status qalam lms completions help version ;;
    \\    3) case $words[2] in
    \\         qalam) _values command courses attendance grades results timetable invoices ;;
    \\         lms) _values command whoami courses deadlines notifications assignments status files submit ;;
    \\         completions) _values shell bash zsh fish powershell ;;
    \\       esac ;;
    \\    *) _files ;;
    \\  esac
    \\}
    \\_nust "$@"
    \\
;

const fish =
    \\complete -c nust -f -n __fish_use_subcommand -a "login logout status qalam lms completions help version"
    \\complete -c nust -f -n "__fish_seen_subcommand_from qalam" -a "courses attendance grades results timetable invoices"
    \\complete -c nust -f -n "__fish_seen_subcommand_from lms" -a "whoami courses deadlines notifications assignments status files submit"
    \\complete -c nust -n "__fish_seen_subcommand_from submit" -F
    \\complete -c nust -l json -d "JSON output"
    \\complete -c nust -s y -d "Do not ask"
    \\
;

const powershell =
    \\Register-ArgumentCompleter -Native -CommandName nust -ScriptBlock {
    \\  param($word, $ast, $pos)
    \\  $w = $ast.CommandElements | ForEach-Object { $_.ToString() }
    \\  $opts = switch ($w.Count) {
    \\    { $_ -le 2 } { 'login','logout','status','qalam','lms','completions','help','version' }
    \\    default {
    \\      switch ($w[1]) {
    \\        'qalam' { 'courses','attendance','grades','results','timetable','invoices' }
    \\        'lms' { 'whoami','courses','deadlines','notifications','assignments','status','files','submit' }
    \\        'completions' { 'bash','zsh','fish','powershell' }
    \\      }
    \\    }
    \\  }
    \\  $opts | Where-Object { $_ -like "$word*" } | ForEach-Object { [System.Management.Automation.CompletionResult]::new($_) }
    \\}
    \\
;

pub fn completion(shell: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, shell, "bash")) return bash;
    if (std.mem.eql(u8, shell, "zsh")) return zsh;
    if (std.mem.eql(u8, shell, "fish")) return fish;
    if (std.mem.eql(u8, shell, "powershell")) return powershell;
    return null;
}
