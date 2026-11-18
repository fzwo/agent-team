#!/usr/bin/env python3
"""watch-github: poll a GitHub repo for input addressed to one agent role, and wake a session.

Costs no tokens while waiting. Each tick makes two API calls through `gh`
(issues updated since the cursor, comments created or updated since the
cursor), keeps what is addressed to this role, writes a summary file, and runs
the wake command with that file's path as its only argument.

    watch-github.py --role engineering [--repo owner/name] [--interval 120]
                    [--slow-after 4] [--slow-interval 1800] [--idle-hours 168]
                    [--wake "<command>"] [--once] [--state-dir .agent-team]
                    [--catch-up-hours 24]

The schedule (the owner's, 2026-11-04): a check every --interval seconds until
--slow-after hours have passed without activity, then every --slow-interval
seconds, and after --idle-hours without activity it stops and the session tells
the owner. Activity is any input for this role, or a start with --fresh (the
owner or the session was just active). Polling costs nothing; the schedule is
about how fast a quiet agent notices the other one waking up.

Addressed to role R means: a comment or issue whose first line is not R's own
tag (so the other agent's tag, or no tag, which is the owner). A pull request is
listed when it appears or carries R's label; the other role's PRs only when
labelled for R; an item R itself bumped last is not listed again, nor one R
routed to the other role (R's comment newest in the tick, the other role's label on
it, not R's; a label edit a tick later than the comment is listed, since the comment
is behind the cursor by then). Agent comments on
issues labelled `idea` are skipped; the owner's are not. Inline review comments
on PR diffs are included. The cursor and the seen ids live in the state
directory, so a restart does not replay old items; a start without a cursor (a
first run, a fresh container) lists the last --catch-up-hours, so the previous
shift's handled items reappear once and are to be skipped, not answered again.

Wake examples (the command gets the summary path as $1):
  tmux:     --wake 'tmux send-keys -t eng -l "$(cat "$1")"; tmux send-keys -t eng Enter'
  headless: --wake 'claude -p "$(cat "$1")" --resume "$(cat .agent-team/session-id)"'
With no --wake the summary is printed and, with --once, the script exits.

For a session that runs the watcher itself as a background command and is woken
when that command ends (Cowork, or Claude Code without tmux), use
--exit-on-input: the script prints the summary and exits 0 at the first input.
--max-minutes N makes it exit 3 after N minutes with nothing new, before the
host's limit on background commands kills it mid-check; the cursor is kept, so
starting it again misses nothing; the activity stamp is kept across restarts, so
the slow tier and the stop count from the last real activity, not from the last
restart. Start with --fresh after the owner or the session was active, so the
clock counts from then. The idle stop exits 2 (a 4-hour stop once ended a watch
mid-shift while builders ran; the week-long default is what makes the kept stamp
safe). A state write that fails also exits 3.
So: 0 = handle the input and restart, 3 = restart (if it exits 3 at once twice in a
row, look at the state directory), 2 = stop and tell the owner.
"""
import argparse, glob, json, os, re, subprocess, sys, time
from datetime import datetime, timezone, timedelta

TAGS = {"engineering": "[engineering]", "design": "[design]"}


def gh(args):
    out = subprocess.run(["gh", "api", "--paginate", *args], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip())
    # --paginate concatenates JSON arrays; join them.
    items = []
    dec = json.JSONDecoder()
    s = out.stdout.strip()
    i = 0
    while i < len(s):
        obj, j = dec.raw_decode(s, i)
        items.extend(obj if isinstance(obj, list) else [obj])
        i = j
        while i < len(s) and s[i] in " \n\r\t,":
            i += 1
    return items


def first_line_tag(body):
    first = (body or "").strip().split("\n", 1)[0].strip().lower()
    for tag in TAGS.values():
        if first.startswith(tag):
            return tag
    return None


def who(body):
    tag = first_line_tag(body)
    if tag is None:
        return "owner"
    return tag.strip("[]")


def iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _version_tuple(v):
    try:
        return tuple(int(p) for p in v.split("."))
    except ValueError:
        return None

def plugin_note():
    """One line when a newer plugin is installed than the copy this watcher belongs to, else ''.

    A session keeps the plugin copy it started with (the first project's shift 10 ran 0.4.13 through two more shifts), so the
    watcher, which wakes the session anyway, is where the session learns that a newer copy is installed. The line
    repeats on every wake and exit while the gap exists, on purpose: like "Waiting on you" in the reports, a standing
    condition is repeated until it is resolved, and the resolution is a new shift."""
    # Nothing here may raise: this runs after the cursor is written and before the wake, and a watcher that dies
    # every tick on a malformed manifest would lose each tick's items. A manifest that is not an object, or a
    # version that is not a string, counts as no version.
    def manifest_version(path):
        try:
            data = json.load(open(path))
        except Exception:   # missing, unreadable, not JSON, truncated by an update in progress, absurdly nested: all "no version"
            return None, None
        v = data.get("version") if isinstance(data, dict) else None
        return _version_tuple(v) if isinstance(v, str) else None, v
    here = os.path.dirname(os.path.abspath(__file__))
    own_t, own = manifest_version(os.path.join(here, "..", ".claude-plugin", "plugin.json"))
    if own_t is None:
        return ""
    newest, newest_t = own, own_t
    for f in glob.glob(os.path.join(os.path.expanduser("~"), ".claude", "plugins", "cache", "*", "agent-team", "*", ".claude-plugin", "plugin.json")):
        t, v = manifest_version(f)
        if t is not None and t > newest_t:
            newest, newest_t = v, t
    if newest_t > own_t:
        return (f"[watcher] This session runs plugin {own}; {newest} is installed. A session keeps the copy it started with, "
                f"so the newer rules and fixes reach the next shift, not this one: say so in your next report.\n")
    return ""

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--role", required=True, choices=list(TAGS))
    ap.add_argument("--repo", default=None)
    ap.add_argument("--interval", type=int, default=120, help="seconds between checks while active (default 120)")
    ap.add_argument("--slow-after", type=float, default=4, help="hours without activity after which checks slow down (default 4)")
    ap.add_argument("--slow-interval", type=int, default=1800, help="seconds between checks once slowed down (default 1800)")
    ap.add_argument("--idle-hours", type=float, default=168, help="stop after this long without activity (default a week; 0 stops at the first tick without input)")
    ap.add_argument("--wake", default=None)
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--exit-on-input", action="store_true")
    ap.add_argument("--max-minutes", type=float, default=None)
    ap.add_argument("--fresh", action="store_true", help="count idle time from now (after the owner or the session was active)")
    ap.add_argument("--state-dir", default=".agent-team")
    ap.add_argument("--catch-up-hours", type=float, default=24, help="with no cursor file, list what changed in the last N hours (default 24): a fresh container or a lost state dir must not skip what arrived in the gap")
    a = ap.parse_args()

    repo = a.repo
    if not repo:
        r = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True, text=True)
        url = r.stdout.strip()
        m = re.search(r"github\.com(?::\d+)?[:/]([^/]+/[^/]+?)(?:\.git)?/?$", url)
        if not m:
            sys.exit("watch-github: no --repo and origin is not a GitHub remote")
        repo = m.group(1)

    a.state_dir = os.path.abspath(a.state_dir)   # the cwd may vanish (a removed worktree)
    os.makedirs(a.state_dir, exist_ok=True)
    cursor_file = os.path.join(a.state_dir, f"watch-{a.role}.cursor")
    seen_file = os.path.join(a.state_dir, f"watch-{a.role}.seen")
    summary_file = os.path.join(a.state_dir, f"watch-{a.role}.summary")
    ideas_file = os.path.join(a.state_dir, f"watch-{a.role}.ideas")   # idea issue numbers seen so far
    my_tag = TAGS[a.role]

    if os.path.exists(cursor_file):
        since = open(cursor_file).read().strip()
    else:
        # No cursor: a first run, or a fresh container (the state dir lives in the checkout and is not committed). A
        # design agent's questions arrived in such a gap and were never seen; start a day back, not five minutes.
        since = iso(datetime.now(timezone.utc) - timedelta(hours=a.catch_up_hours))
    seen = set()
    if os.path.exists(seen_file):
        seen = set(open(seen_file).read().split())
    ideas = set()
    if os.path.exists(ideas_file):
        ideas = {int(x) for x in open(ideas_file).read().split() if x.isdigit()}

    started = time.time()
    # Idle time survives restarts (--max-minutes restarts often): kept in the state dir.
    active_file = os.path.join(a.state_dir, f"watch-{a.role}.active")
    # The stamp survives the session's own restarts (--max-minutes), so the slow tier and the stop
    # measure real quiet, not time since the last restart; --fresh resets it.
    try:
        if a.fresh:
            raise ValueError
        last_activity = float(open(active_file).read().strip())
    except (OSError, ValueError):
        last_activity = started
        open(active_file, "w").write(str(last_activity))
    while True:
        try:
            issues = gh([f"repos/{repo}/issues?since={since}&state=all&sort=updated&direction=asc&per_page=100"])
            comments = gh([f"repos/{repo}/issues/comments?since={since}&sort=updated&direction=asc&per_page=100"])
            # Inline review comments on PR diffs live on a different endpoint.
            for rc in gh([f"repos/{repo}/pulls/comments?since={since}&sort=updated&direction=asc&per_page=100"]):
                rc["issue_url"] = rc.get("pull_request_url", "")
                # The body stays as written, so the tag check sees the author; the location goes on the summary line only.
                rc["_where"] = f"(on {rc.get('path','?')}:{rc.get('line') or rc.get('original_line') or '?'}) "
                comments.append(rc)
        except RuntimeError as e:
            print(f"watch-github: API error, will retry: {e}", file=sys.stderr)
            issues, comments = [], []

        # Idea numbers are remembered across ticks: a comment on an idea whose issue did not change this tick
        # still needs the label. An issue seen without the label leaves the set.
        for i in issues:
            if any(l["name"] == "idea" for l in i.get("labels", [])):
                ideas.add(i["number"])
            else:
                ideas.discard(i["number"])
        idea = ideas
        items = []
        newest = since
        # Issues whose newest comment this tick is our own: the agent's comment bumped them, not the owner.
        own_bumped = {}
        for c in comments:
            number = c["issue_url"].rsplit("/", 1)[-1]
            if number.isdigit() and c["updated_at"] >= own_bumped.get(int(number), ("", False))[0]:
                own_bumped[int(number)] = (c["updated_at"], first_line_tag(c.get("body")) == my_tag)
        for i in issues:
            newest = max(newest, i["updated_at"])
            key = f"issue:{i['id']}:{i['updated_at']}"
            if key in seen:
                continue
            known = any(k.startswith(f"issue:{i['id']}:") for k in seen)   # seen before, under an older timestamp
            seen.add(key)
            if first_line_tag(i.get("body")) == my_tag:
                continue
            # Parked ideas do not wake anyone: an idea's issue line is listed only when the owner
            # has just opened it; later updates are carried by its comments, where agent ones are skipped.
            if i["number"] in idea and (first_line_tag(i.get("body")) is not None or i.get("created_at", "") < since):
                continue
            labels = ",".join(l["name"] for l in i.get("labels", []))
            kind = "PR" if "pull_request" in i else "issue"
            # A PR is listed when it appears or when it carries the role's label. Every push updates it, and
            # both agents work under the owner's account, so those updates cannot be told from the owner's;
            # they are the agents' own work and wake nobody. Comments on the PR carry the rest.
            if kind == "PR" and (known or i.get("created_at", "") < since) and f"for-{a.role}" not in labels.split(","):
                continue
            # The other role's own PRs (its housekeeping, its docs) are its work; they wake this role only when
            # labelled for it. The owner's PRs (no tag) wake as before.
            if kind == "PR" and first_line_tag(i.get("body")) not in (None, my_tag) and f"for-{a.role}" not in labels.split(","):
                continue
            # An issue or PR we saw before, bumped by our own comment and by nothing since (its updated_at is not
            # later than that comment): nothing new for us in it (about half of a shift's wake-ups were these). The
            # owner's or the other role's comments on it wake through the comment list; a label or a close after our
            # comment moves updated_at past it and wakes here.
            ob = own_bumped.get(i["number"])
            if (known or i.get("created_at", "") < since) and ob and ob[1] and i["updated_at"] <= ob[0]:
                continue
            # Our own routing: the newest comment is ours and the issue carries the other role's label and not ours (we
            # labelled it after commenting, which bumped it past our comment). The other role's answer wakes us through
            # the comment list; the owner relabelling it for us puts our label on it. A session once woke on its own label edit.
            other = [r for r in TAGS if r != a.role][0]
            if (known or i.get("created_at", "") < since) and ob and ob[1] and f"for-{other}" in labels.split(",") and f"for-{a.role}" not in labels.split(","):
                continue
            items.append(f"- #{i['number']} {kind} by {who(i.get('body'))}, {i['state']}, labels: {labels or '-'}: {i['title']}")
        for c in comments:
            newest = max(newest, c["updated_at"])
            key = f"comment:{c['id']}:{c['updated_at']}"
            if key in seen:
                continue
            seen.add(key)
            if first_line_tag(c.get("body")) == my_tag:
                continue
            number = c["issue_url"].rsplit("/", 1)[-1]
            if number.isdigit() and int(number) in idea and first_line_tag(c.get("body")) is not None:
                continue
            body = " ".join((c.get("body") or "").split())
            if body.lower().startswith(("[engineering]", "[design]")):
                body = body.split("]", 1)[1].strip()
            body = c.get("_where", "") + body
            items.append(f"- #{number} comment by {who(c.get('body'))} at {c['updated_at'][11:16]}Z: {body[:240]}")

        since = newest
        # Seen keys carry their timestamp; keep those at or after the cursor (since is inclusive), no count cap.
        seen = {k for k in seen if k.split(":", 2)[-1] >= since}   # key = kind:id:timestamp; the timestamp has colons
        try:
            open(cursor_file, "w").write(since)
            open(seen_file, "w").write("\n".join(sorted(seen)))
            open(ideas_file, "w").write("\n".join(str(n) for n in sorted(ideas)))
        except OSError as e:
            print(f"watch-github: cannot write state in {a.state_dir}: {e}", file=sys.stderr)
            sys.exit(3)

        if items:
            last_activity = time.time()
            open(active_file, "w").write(str(last_activity))
            text = (f"[watcher] New GitHub input for {a.role} in {repo} ({len(items)} items). "
                    f"Handle them per the team-process skill, then check again before the next step.\n"
                    + "\n".join(items) + "\n" + plugin_note())
            open(summary_file, "w").write(text)
            if a.wake:
                subprocess.run(["bash", "-c", a.wake, "wake", summary_file])
            else:
                print(text, end="")
            if a.exit_on_input:
                sys.stdout.flush()
                sys.exit(0)
        elif a.once:
            print(f"watch-github: nothing new for {a.role} since {since}")
            print(plugin_note(), end="")

        if a.once:
            return
        quiet = time.time() - last_activity
        if quiet > a.idle_hours * 3600:
            print(f"watch-github: no activity for {a.idle_hours:g} h, stopping")
            print(plugin_note(), end="")
            if a.exit_on_input:
                sys.stdout.flush()
                sys.exit(2)
            return
        interval = a.slow_interval if quiet > a.slow_after * 3600 else a.interval
        if a.max_minutes is not None and time.time() + interval > started + a.max_minutes * 60:
            print(f"watch-github: nothing new for {a.max_minutes:g} min (checking every {interval} s, quiet for {quiet / 3600:.1f} h); start again to keep watching")
            print(plugin_note(), end="")
            sys.stdout.flush()
            sys.exit(3)
        time.sleep(interval)


if __name__ == "__main__":
    main()
