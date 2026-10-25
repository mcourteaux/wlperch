// GitHub at a glance through the gh CLI: what `gh status` shows (review
// requests, your pull requests, assigned issues, unread notifications) plus,
// optionally, one repository's checks, workflow runs and latest release.
// Read-only: nothing is ever marked read or changed on GitHub.
package main

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

GH_Check :: enum {None, Pending, Success, Failure}

GH_Review :: enum {None, Required, Approved, Changes}

GH_Item :: struct {
	kind:   enum {Pull, Issue, Other},
	number: i64,
	title:  string,
	url:    string,
	repo:   string,
	author: string,
	at:     f64, // last update, unix seconds
	draft:  bool,
	checks: GH_Check,
	review: GH_Review,
}

GH_Notif :: struct {
	reason: string, // mention, review_requested, comment, ci_activity…
	type:   string, // PullRequest, Issue, CheckSuite, Release…
	title:  string,
	url:    string, // web page (the API gives api.github.com links)
	repo:   string,
	at:     f64,
	unread: bool,
}

GH_Run :: struct {
	workflow: string,
	title:    string,
	branch:   string,
	checks:   GH_Check,
	url:      string,
	at:       f64,
}

GH_Repo :: struct {
	name:         string,
	url:          string,
	stars:        i64,
	open_issues:  i64,
	open_prs:     i64,
	branch:       string,
	head_title:   string,
	head_url:     string,
	head_at:      f64,
	head_checks:  GH_Check,
	release:      string,
	release_url:  string,
	release_at:   f64,
	runs:         []GH_Run,
}

// One refresh's results; every string lives in its arena.
GH_Snapshot :: struct {
	arena:       virtual.Arena,
	login:       string,
	reviews:     []GH_Item,
	review_count: i64,
	mine:        []GH_Item,
	mine_count:  i64,
	issues:      []GH_Item,
	issue_count: i64,
	notifs:      []GH_Notif, // recent, read ones included, newest first
	unread:      int, // unread notifications (at most 50), which can be older than notifs
	have_repo:   bool,
	repo:        GH_Repo,
}

Github :: struct {
	mu:       sync.Mutex,
	snap:     ^GH_Snapshot, // nil until the first successful refresh
	error:    string,
	updated:  time.Time,
	fetching: bool,
}
github: Github

@(private = "file")
trigger: sync.Sema

// Search queries mirror `gh status`; reviewDecision and the head commit's
// check rollup make "your pull requests" a status list.
@(private = "file")
QUERY :: `query($owner: String!, $name: String!, $withRepo: Boolean!) {
  viewer { login }
  mine: search(type: ISSUE, first: 10, query: "is:pr is:open author:@me archived:false sort:updated-desc") {
    issueCount
    nodes { ... on PullRequest { number title url isDraft updatedAt repository { nameWithOwner } reviewDecision
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } }
  }
  reviews: search(type: ISSUE, first: 10, query: "is:pr is:open review-requested:@me archived:false sort:updated-desc") {
    issueCount
    nodes { ... on PullRequest { number title url isDraft updatedAt author { login } repository { nameWithOwner } } }
  }
  issues: search(type: ISSUE, first: 10, query: "is:issue is:open assignee:@me archived:false sort:updated-desc") {
    issueCount
    nodes { ... on Issue { number title url updatedAt author { login } repository { nameWithOwner } } }
  }
  repo: repository(owner: $owner, name: $name) @include(if: $withRepo) {
    nameWithOwner url stargazerCount
    issues(states: OPEN) { totalCount }
    pullRequests(states: OPEN) { totalCount }
    latestRelease { tagName publishedAt url }
    defaultBranchRef { name target { ... on Commit { messageHeadline committedDate url statusCheckRollup { state } } } }
  }
}`

github_refresh_async :: proc() {sync.sema_post(&trigger)}

github_start :: proc() {
	if !config.github {return}
	thread.create_and_start(proc() {
		for {
			update()
			request_redraw()
			free_all(context.temp_allocator)
			wait := config.github_refresh
			if github.snap == nil {wait = min(wait, time.Minute)}
			sync.sema_wait_with_timeout(&trigger, wait)
			for sync.sema_wait_with_timeout(&trigger, 0) {}
		}
	})
}

github_on_show :: proc() {
	if !config.github {return}
	sync.guard(&github.mu)
	if !github.fetching && time.since(github.updated) > config.github_refresh {sync.sema_post(&trigger)}
}

// "owner/name" -> owner, name (ok = false when it isn't of that form).
github_split_repo :: proc(s: string) -> (owner, name: string, ok: bool) {
	s := strings.trim_space(s)
	s = strings.trim_prefix(s, "https://github.com/")
	s = strings.trim_suffix(strings.trim_suffix(s, "/"), ".git")
	i := strings.index_byte(s, '/')
	if i <= 0 || i == len(s) - 1 || strings.index_byte(s[i + 1:], '/') >= 0 {return}
	return s[:i], s[i + 1:], true
}

@(private = "file")
set_error :: proc(msg: string) {
	sync.guard(&github.mu)
	delete(github.error)
	github.error = strings.clone(msg)
	github.fetching = false
	github.updated = time.now()
}

@(private = "file")
update :: proc() {
	{
		sync.guard(&github.mu)
		github.fetching = true
	}
	owner, name, with_repo := github_split_repo(config.github_repo)
	if config.github_repo != "" && !with_repo {
		log.warnf("[github] repo = %q is not owner/name; ignored", config.github_repo)
	}
	out, code := run_code({
		"gh", "api", "graphql", "-f", strings.concatenate({"query=", QUERY}, context.temp_allocator),
		"-f", strings.concatenate({"owner=", owner}, context.temp_allocator),
		"-f", strings.concatenate({"name=", name}, context.temp_allocator),
		"-F", with_repo ? "withRepo=true" : "withRepo=false",
	}, 45 * time.Second, context.temp_allocator)
	v, pok := jparse(out)
	data := jobj(v, "data")
	if code != 0 && data == nil {
		switch code {
		case -1: set_error(gh_installed() ? "GitHub did not answer" : "The gh command is not installed")
		case 4:  set_error("Not logged in: run \"gh auth login\"")
		case:    set_error("gh could not reach GitHub")
		}
		return
	}
	if !pok || data == nil {
		set_error("Unexpected answer from gh")
		return
	}

	// Recent notifications, read ones included (all=true), newest first;
	// never marked read from here.
	nout, nok := run({"gh", "api", "notifications?all=true&per_page=50"}, 30 * time.Second, context.temp_allocator)
	nv, _ := jparse(nout)
	// The unread count separately: unread ones are often older than the 50
	// most recent.
	uout, uok := run({"gh", "api", "notifications?per_page=50", "--jq", "length"}, 30 * time.Second, context.temp_allocator)
	unread_count := uok ? strconv.parse_int(strings.trim_space(uout)) or_else 0 : 0
	runs_v: json.Value
	if with_repo {
		rout, rok := run({
			"gh", "run", "list", "-R", fmt.tprintf("%s/%s", owner, name), "-L", "5",
			"--json", "workflowName,displayTitle,headBranch,status,conclusion,url,createdAt",
		}, 30 * time.Second, context.temp_allocator)
		if rok {runs_v, _ = jparse(rout)}
	}

	snap := new(GH_Snapshot)
	if err := virtual.arena_init_growing(&snap.arena); err != nil {
		free(snap)
		set_error("out of memory")
		return
	}
	{
		context.allocator = virtual.arena_allocator(&snap.arena)
		snapshot_fill(snap, data, nok ? nv : nil, runs_v)
		snap.unread = unread_count
	}

	sync.guard(&github.mu)
	if old := github.snap; old != nil {
		virtual.arena_destroy(&old.arena)
		free(old)
	}
	github.snap = snap
	delete(github.error)
	github.error = ""
	github.updated = time.now()
	github.fetching = false
	log.debugf("github: %d review requests, %d own PRs, %d issues, %d unread", snap.review_count, snap.mine_count, snap.issue_count, github_unread(snap))
}

@(private = "file")
gh_installed :: proc() -> bool {
	_, ok := run({"gh", "--version"}, 5 * time.Second, context.temp_allocator)
	return ok
}

// Fills the snapshot from parsed JSON; allocates with context.allocator.
@(private = "file")
snapshot_fill :: proc(s: ^GH_Snapshot, data, notifs, runs: json.Value) {
	s.login = strings.clone(jstr(jobj(jobj(data, "viewer"), "login")))
	s.reviews, s.review_count = items(jobj(data, "reviews"))
	s.mine, s.mine_count = items(jobj(data, "mine"))
	s.issues, s.issue_count = items(jobj(data, "issues"))

	ns: [dynamic]GH_Notif
	for n in jarr(notifs) {
		subj := jobj(n, "subject")
		repo := jstr(jobj(jobj(n, "repository"), "full_name"))
		append(&ns, GH_Notif {
			reason = strings.clone(jstr(jobj(n, "reason"))),
			type   = strings.clone(jstr(jobj(subj, "type"))),
			title  = strings.clone(jstr(jobj(subj, "title"))),
			url    = github_web_url(jstr(jobj(subj, "url")), jstr(jobj(subj, "type")), repo),
			repo   = strings.clone(repo),
			at     = iso_unix(jstr(jobj(n, "updated_at"))),
			unread = jbool(jobj(n, "unread")),
		})
	}
	// Newest first.
	slice.stable_sort_by(ns[:], proc(a, b: GH_Notif) -> bool {return a.at > b.at})
	s.notifs = ns[:]

	r := jobj(data, "repo")
	if r == nil {return}
	s.have_repo = true
	head := jobj(jobj(r, "defaultBranchRef"), "target")
	rel := jobj(r, "latestRelease")
	s.repo = GH_Repo {
		name        = strings.clone(jstr(jobj(r, "nameWithOwner"))),
		url         = strings.clone(jstr(jobj(r, "url"))),
		stars       = jint(jobj(r, "stargazerCount")),
		open_issues = jint(jobj(jobj(r, "issues"), "totalCount")),
		open_prs    = jint(jobj(jobj(r, "pullRequests"), "totalCount")),
		branch      = strings.clone(jstr(jobj(jobj(r, "defaultBranchRef"), "name"))),
		head_title  = strings.clone(jstr(jobj(head, "messageHeadline"))),
		head_url    = strings.clone(jstr(jobj(head, "url"))),
		head_at     = iso_unix(jstr(jobj(head, "committedDate"))),
		head_checks = rollup(jstr(jobj(jobj(head, "statusCheckRollup"), "state"))),
		release     = strings.clone(jstr(jobj(rel, "tagName"))),
		release_url = strings.clone(jstr(jobj(rel, "url"))),
		release_at  = iso_unix(jstr(jobj(rel, "publishedAt"))),
	}
	rs: [dynamic]GH_Run
	for x in jarr(runs) {
		c := GH_Check.Pending
		if jstr(jobj(x, "status")) == "completed" {
			switch jstr(jobj(x, "conclusion")) {
			case "success":           c = .Success
			case "skipped", "neutral": c = .None
			case:                     c = .Failure // failure, cancelled, timed_out…
			}
		}
		append(&rs, GH_Run {
			workflow = strings.clone(jstr(jobj(x, "workflowName"))),
			title    = strings.clone(jstr(jobj(x, "displayTitle"))),
			branch   = strings.clone(jstr(jobj(x, "headBranch"))),
			checks   = c,
			url      = strings.clone(jstr(jobj(x, "url"))),
			at       = iso_unix(jstr(jobj(x, "createdAt"))),
		})
	}
	s.repo.runs = rs[:]
}

@(private = "file")
items :: proc(search: json.Value) -> ([]GH_Item, i64) {
	out: [dynamic]GH_Item
	for n in jarr(jobj(search, "nodes")) {
		if jobj(n, "number") == nil {continue}
		it := GH_Item {
			kind   = strings.contains(jstr(jobj(n, "url")), "/pull/") ? .Pull : .Issue,
			number = jint(jobj(n, "number")),
			title  = strings.clone(jstr(jobj(n, "title"))),
			url    = strings.clone(jstr(jobj(n, "url"))),
			repo   = strings.clone(jstr(jobj(jobj(n, "repository"), "nameWithOwner"))),
			author = strings.clone(jstr(jobj(jobj(n, "author"), "login"))),
			at     = iso_unix(jstr(jobj(n, "updatedAt"))),
			draft  = jbool(jobj(n, "isDraft")),
		}
		switch jstr(jobj(n, "reviewDecision")) {
		case "APPROVED":          it.review = .Approved
		case "CHANGES_REQUESTED": it.review = .Changes
		case "REVIEW_REQUIRED":   it.review = .Required
		}
		commit := jobj(jidx(jobj(jobj(n, "commits"), "nodes"), 0), "commit")
		it.checks = rollup(jstr(jobj(jobj(commit, "statusCheckRollup"), "state")))
		append(&out, it)
	}
	return out[:], jint(jobj(search, "issueCount"))
}

// Notifications about you (rather than threads you merely watch).
github_unread :: proc(s: ^GH_Snapshot) -> int {return s.unread}

notif_direct :: proc(reason: string) -> bool {
	switch reason {
	case "mention", "team_mention", "review_requested", "assign", "author", "comment", "approval_requested", "security_alert":
		return true
	}
	return false
}

@(private = "file")
rollup :: proc(state: string) -> GH_Check {
	switch state {
	case "SUCCESS":                     return .Success
	case "FAILURE", "ERROR":            return .Failure
	case "PENDING", "EXPECTED":         return .Pending
	}
	return .None
}

@(private = "file")
iso_unix :: proc(s: string) -> f64 {
	if s == "" {return 0}
	t, n := time.rfc3339_to_time_utc(s)
	if n == 0 {return 0}
	return f64(time.to_unix_seconds(t))
}

// api.github.com/repos/o/r/pulls/7 -> github.com/o/r/pull/7 (allocates).
github_web_url :: proc(api_url, type, repo: string) -> string {
	PREFIX :: "https://api.github.com/repos/"
	if strings.has_prefix(api_url, PREFIX) {
		rest := api_url[len(PREFIX):]
		rest, _ = strings.replace(rest, "/pulls/", "/pull/", 1, context.temp_allocator)
		rest, _ = strings.replace(rest, "/commits/", "/commit/", 1, context.temp_allocator)
		if type == "Release" {
			if i := strings.index(rest, "/releases/"); i >= 0 {rest = fmt.tprintf("%s/releases", rest[:i])}
		}
		return strings.concatenate({"https://github.com/", rest})
	}
	if repo == "" {return strings.clone("https://github.com/notifications")}
	if type == "CheckSuite" {return strings.concatenate({"https://github.com/", repo, "/actions"})}
	return strings.concatenate({"https://github.com/", repo})
}
