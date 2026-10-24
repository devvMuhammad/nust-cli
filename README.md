# nust

Check Qalam and the NUST LMS from your terminal. One small program, about 1 MB.

## Install

macOS and Linux:

```
curl -fsSL https://raw.githubusercontent.com/devvMuhammad/nust-cli/main/install.sh | sh
```

Windows (PowerShell):

```
irm https://raw.githubusercontent.com/devvMuhammad/nust-cli/main/install.ps1 | iex
```

Open a new terminal afterwards. Run the same line again to update.

## Use

Sign in once with your NUST username and password:

```
nust login
```

Then:

```
nust qalam attendance        # attendance per course, lecture and lab
nust qalam grades CS-405     # your marks and the class average
nust qalam results           # SGPA, CGPA and grades for past terms
nust qalam timetable
nust qalam invoices

nust lms deadlines           # what's due
nust lms assignments         # every assignment, submitted or not
nust lms files deep --download ~/Downloads/DL
nust lms submit "lab 6" main.c
```

You can name a course by its code (`CS-405`) or part of its name (`deep`). Run `nust --help` to see every command.

## Submitting

`nust lms submit` shows you what it will send and which old files it will replace, then asks before sending anything. After it submits, it checks the LMS and tells you if your files didn't arrive. Add `-y` to skip the question.

## Your password

Your password is saved in your system's keychain, or in a private file if there isn't one. When a session runs out, `nust` signs you in again by itself. `nust logout` deletes everything it saved.

This is a personal project, not made by NUST. If Qalam or the LMS changes its pages, some commands may stop working until they're updated.

## Building it yourself

With [Zig 0.17](https://ziglang.org/download/): `zig build -Doptimize=ReleaseSmall`, and the program is in `zig-out/bin/`.
