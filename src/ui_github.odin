// GitHub cards. Modules: github (counters, review requests, your pull
// requests with their checks, assigned issues), github-inbox (unread
// notifications) and github-repo (the configured repository). Everything
// opens in the browser.
package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

import im "third_party:odin-imgui"

@(private = "file") MAX_MINE :: 8
@(private = "file") MAX_ISSUES :: 5
@(private = "file") MAX_NOTIFS :: 6

draw_github :: proc(w: f32) {draw_locked(draw_summary, w)}
draw_github_inbox :: proc(w: f32) {draw_locked(draw_inbox, w)}
draw_github_repo :: proc(w: f32) {draw_locked(draw_repo, w)}

// Draws under github.mu; `draw` returns a URL to open (in the snapshot).
@(private = "file")
draw_locked :: proc(draw: proc(w: f32) -> string, w: f32) {
	open: string
	{
		sync.guard(&github.mu)
		// The snapshot may be replaced as soon as the lock is released.
		open = strings.clone(draw(w), context.temp_allocator)
	}
	if open != "" {
		run_async({"xdg-open", open})
		hide_requested = true
	}
}

@(private = "file")
check_icon :: proc(c: GH_Check) -> (string, u32) {
	switch c {
	case .Success: return ICON_CHECK_CIRCLE, C_GREEN
	case .Failure: return ICON_CLOSE_CIRCLE, C_RED
	case .Pending: return ICON_PROGRESS_CLOCK, C_ORANGE
	case .None:
	}
	return ICON_CIRCLE_MEDIUM, C_FAINT
}

@(private = "file")
check_text :: proc(c: GH_Check) -> string {
	switch c {
	case .Success: return "checks passed"
	case .Failure: return "checks failing"
	case .Pending: return "checks running"
	case .None:
	}
	return "no checks"
}

// Counter tile; returns true when clicked.
@(private = "file")
stat_tile :: proc(id: string, value: string, caption, note: string, accent: u32, hot: bool, w: f32) -> bool {
	H :: 58
	p := im.GetCursorScreenPos()
	clicked := im.InvisibleButton(cstr(id), {w, H})
	hovered := im.IsItemHovered()
	if hovered {im.SetMouseCursor(.Hand)}
	d := dl()
	im.DrawList_AddRectFilled(d, p, {p.x + w, p.y + H}, col32(hot ? accent : 0xffffff, hot ? (hovered ? 0.2 : 0.13) : (hovered ? 0.07 : 0.04)), 10)
	draw_text(fonts.bold, SZ_BIG - 2, {p.x + 12, p.y + 5}, col32(hot ? accent : C_TEXT, hot ? 1 : 0.85), value)
	draw_text(fonts.ui, SZ_SMALL, {p.x + 12, p.y + 37}, col32(C_MUTED), caption)
	if note != "" {
		nsz := measure(fonts.ui, SZ_SMALL, note)
		draw_text(fonts.ui, SZ_SMALL, {p.x + w - nsz.x - 10, p.y + 12}, col32(C_RED), note)
	}
	return clicked
}

// Tiles in one row, filling the width.
@(private = "file")
tile_row_width :: proc(n: int) -> f32 {
	gap: f32 = 8
	return (im.GetContentRegionAvail().x - gap * f32(n - 1)) / f32(n)
}

@(private = "file")
tile_next :: proc() {im.SameLine(0, 8)}

// Item row: colored status icon, title, muted subline and an optional badge.
@(private = "file")
gh_row :: proc(id: string, icon: string, icon_col: u32, title, sub: string, badge := "", badge_col: u32 = C_MUTED) -> bool {
	w := im.GetContentRegionAvail().x
	h: f32 = 40
	p := im.GetCursorScreenPos()
	clicked := im.InvisibleButton(cstr(id), {w, h})
	hovered := im.IsItemHovered()
	if hovered {
		im.SetMouseCursor(.Hand)
		if measure(fonts.ui, SZ_BODY, title).x > w - 60 {tip(title)}
	}
	d := dl()
	if hovered {im.DrawList_AddRectFilled(d, p, {p.x + w, p.y + h}, col32(0xffffff, 0.05), 8)}
	draw_text(fonts.ui, 18, {p.x + 10, p.y + h / 2 - 10}, col32(icon_col), icon)
	tx := p.x + 38
	right := p.x + w - 8
	if badge != "" {
		bsz := measure(fonts.ui, SZ_SMALL, badge)
		bx := right - bsz.x - 12
		im.DrawList_AddRectFilled(d, {bx, p.y + 11}, {right, p.y + 29}, col32(badge_col, 0.15), 9)
		draw_text(fonts.ui, SZ_SMALL, {bx + 6, p.y + 12}, col32(badge_col), badge)
		right = bx - 8
	}
	im.DrawList_PushClipRect(d, p, {right, p.y + h}, true)
	draw_text(fonts.ui, SZ_BODY, {tx, p.y + 4}, col32(C_TEXT), title)
	draw_text(fonts.ui, SZ_SMALL, {tx, p.y + 22}, col32(C_MUTED), sub)
	im.DrawList_PopClipRect(d)
	return clicked
}

@(private = "file")
heading :: proc(s: string, count: i64, shown: int) {
	if count > i64(shown) {
		sub_heading(fmt.tprintf("%s · %d (latest %d)", s, count, shown))
	} else {
		sub_heading(fmt.tprintf("%s · %d", s, count))
	}
}

@(private = "file")
short_repo :: proc(repo: string) -> string {
	// The configured repository is implied; others keep owner/name.
	if strings.equal_fold(repo, strings.trim_space(config.github_repo)) {
		if i := strings.index_byte(repo, '/'); i >= 0 {return repo[i + 1:]}
	}
	return repo
}

@(private = "file")
notif_icon :: proc(n: GH_Notif) -> (string, u32) {
	switch n.reason {
	case "mention", "team_mention":            return ICON_AT, C_ORANGE
	case "review_requested":                   return ICON_EYE, C_ORANGE
	case "ci_activity":
		if strings.contains(n.title, "failed") {return ICON_CLOSE_CIRCLE, C_RED}
		return ICON_CHECK_CIRCLE, C_GREEN
	}
	switch n.type {
	case "PullRequest": return ICON_SOURCE_PULL, C_BLUE
	case "Issue":       return ICON_ALERT, C_GREEN
	case "Release":     return ICON_TAG, C_PURPLE
	case "Discussion":  return ICON_COMMENT, C_CYAN
	}
	return ICON_INBOX, C_MUTED
}

@(private = "file")
notif_reason :: proc(r: string) -> string {
	switch r {
	case "mention":            return "mentioned you"
	case "team_mention":       return "team mentioned"
	case "review_requested":   return "review requested"
	case "assign":             return "assigned"
	case "author":             return "your thread"
	case "comment":            return "you commented"
	case "state_change":       return "state changed"
	case "ci_activity":        return "CI"
	case "subscribed":         return "watching"
	case "manual":             return "subscribed"
	case "approval_requested": return "approval requested"
	case "security_alert":     return "security alert"
	}
	return r
}

@(private = "file")
draw_summary :: proc(w: f32) -> (open: string) {
	s := github.snap
	card_begin("github", w)
	login := ""
	if s != nil {login = fmt.tprintf("@%s", s.login)}
	card_title(ICON_GITHUB, "Your work", C_PURPLE, github.fetching ? "updating…" : login)

	if s == nil {
		msg := github.error != "" ? github.error : "Loading…"
		label(fonts.ui, SZ_BODY, col32(github.error != "" ? C_ORANGE : C_MUTED), msg)
		card_end()
		return
	}

	// Counters, like the four corners of `gh status`.
	failing := 0
	for it in s.mine {if it.checks == .Failure {failing += 1}}
	tw := tile_row_width(4)
	if stat_tile("##gh-reviews", fmt.tprint(s.review_count), "Review requests", "", C_ORANGE, s.review_count > 0, tw) {open = "https://github.com/pulls/review-requested"}
	tile_next()
	if stat_tile("##gh-mine", fmt.tprint(s.mine_count), "Your pull requests", failing > 0 ? fmt.tprintf("%d failing", failing) : "", C_BLUE, false, tw) {open = "https://github.com/pulls"}
	tile_next()
	if stat_tile("##gh-issues", fmt.tprint(s.issue_count), "Assigned issues", "", C_GREEN, s.issue_count > 0, tw) {open = "https://github.com/issues/assigned"}
	tile_next()
	unread := len(s.notifs)
	if stat_tile("##gh-unread", unread >= 50 ? "50+" : fmt.tprint(unread), "Unread", "", C_PURPLE, unread > 0, tw) {open = "https://github.com/notifications"}

	if len(s.reviews) > 0 {
		heading("Review requests", s.review_count, len(s.reviews))
		for it, i in s.reviews {
			sub := fmt.tprintf("%s#%d · %s · %s", short_repo(it.repo), it.number, it.author, age_text(it.at))
			if gh_row(fmt.tprintf("##gh-r%d", i), ICON_EYE, C_ORANGE, it.title, sub, it.draft ? "Draft" : "", C_FAINT) {open = it.url}
		}
	}

	if len(s.mine) > 0 {
		n := min(len(s.mine), MAX_MINE)
		heading("Your pull requests", s.mine_count, n)
		for it, i in s.mine[:n] {
			icon, col := check_icon(it.checks)
			if it.checks == .None {icon, col = ICON_SOURCE_PULL, C_MUTED}
			sub := fmt.tprintf("%s#%d · %s · %s", short_repo(it.repo), it.number, check_text(it.checks), age_text(it.at))
			badge, bcol := "", u32(C_MUTED)
			switch {
			case it.draft:              badge, bcol = "Draft", C_FAINT
			case it.review == .Approved: badge, bcol = "Approved", C_GREEN
			case it.review == .Changes:  badge, bcol = "Changes requested", C_RED
			case it.review == .Required: badge, bcol = "Awaiting review", C_MUTED
			}
			if gh_row(fmt.tprintf("##gh-m%d", i), icon, col, it.title, sub, badge, bcol) {open = it.url}
		}
	}

	if len(s.issues) > 0 {
		n := min(len(s.issues), MAX_ISSUES)
		heading("Assigned issues", s.issue_count, n)
		for it, i in s.issues[:n] {
			sub := fmt.tprintf("%s#%d · %s", short_repo(it.repo), it.number, age_text(it.at))
			if gh_row(fmt.tprintf("##gh-i%d", i), ICON_ALERT, C_GREEN, it.title, sub) {open = it.url}
		}
	}

	if len(s.reviews) + len(s.mine) + len(s.issues) == 0 {
		im.Dummy({1, 4})
		label(fonts.ui, SZ_BODY, col32(C_MUTED), "Nothing needs your attention.")
	}

	// Footer: freshness, errors since the last good refresh, manual refresh.
	im.Dummy({1, 2})
	foot := fmt.tprintf("Updated %s", age_text(f64(time.to_unix_seconds(github.updated))))
	if github.error != "" {foot = fmt.tprintf("%s · %s", foot, github.error)}
	fp := im.GetCursorScreenPos()
	inner := im.GetContentRegionAvail().x
	draw_text(fonts.ui, SZ_SMALL, {fp.x, fp.y + 6}, col32(github.error != "" ? C_ORANGE : C_FAINT), foot)
	im.SetCursorScreenPos({fp.x + inner - 26, fp.y})
	if icon_button("##gh-refresh", ICON_REFRESH, C_MUTED, 26, tooltip = "Refresh now") {github_refresh_async()}
	card_end()
	return
}

@(private = "file")
draw_inbox :: proc(w: f32) -> (open: string) {
	s := github.snap
	if s == nil {return}
	card_begin("github-inbox", w)
	defer card_end()
	unread := len(s.notifs)
	card_title(ICON_INBOX, "Inbox", C_PURPLE, unread == 0 ? "" : unread >= 50 ? "50+ unread" : fmt.tprintf("%d unread", unread))
	if unread == 0 {
		label(fonts.ui, SZ_BODY, col32(C_MUTED), "No unread notifications.")
		return
	}
	n := min(unread, MAX_NOTIFS)
	for it, i in s.notifs[:n] {
		icon, col := notif_icon(it)
		sub := fmt.tprintf("%s · %s · %s", short_repo(it.repo), notif_reason(it.reason), age_text(it.at))
		if gh_row(fmt.tprintf("##gh-n%d", i), icon, col, it.title, sub) {open = it.url}
	}
	if unread > n {
		if gh_row("##gh-nmore", ICON_INBOX, C_MUTED, fmt.tprintf("%d more", unread - n), "github.com/notifications") {open = "https://github.com/notifications"}
	}
	return
}

@(private = "file")
draw_repo :: proc(w: f32) -> (open: string) {
	if github.snap == nil || !github.snap.have_repo {return}
	r := &github.snap.repo
	card_begin("github-repo", w)
	defer card_end()
	stars := r.stars >= 1000 ? fmt.tprintf("%s %.1fk", ICON_STAR, f64(r.stars) / 1000) : fmt.tprintf("%s %d", ICON_STAR, r.stars)
	card_title(ICON_SOURCE_BRANCH, r.name, C_BLUE, stars)

	icon, col := check_icon(r.head_checks)
	if gh_row("##gh-head", icon, col, r.head_title, fmt.tprintf("%s · %s · %s", r.branch, check_text(r.head_checks), age_text(r.head_at))) {open = r.head_url}

	tw := tile_row_width(3)
	if stat_tile("##gh-rprs", fmt.tprint(r.open_prs), "Open pull requests", "", C_BLUE, false, tw) {open = fmt.tprintf("%s/pulls", r.url)}
	tile_next()
	if stat_tile("##gh-riss", fmt.tprint(r.open_issues), "Open issues", "", C_GREEN, false, tw) {open = fmt.tprintf("%s/issues", r.url)}
	tile_next()
	rel := r.release != "" ? r.release : "—"
	rel_caption := r.release != "" ? fmt.tprintf("Latest release · %s", age_text(r.release_at)) : "No releases"
	if stat_tile("##gh-rrel", rel, rel_caption, "", C_PURPLE, false, tw) {open = r.release_url != "" ? r.release_url : fmt.tprintf("%s/releases", r.url)}

	if len(r.runs) > 0 {
		sub_heading("Workflow runs")
		for run, i in r.runs {
			ricon, rcol := check_icon(run.checks)
			title := run.workflow
			if run.title != "" && run.title != run.workflow {title = fmt.tprintf("%s · %s", run.workflow, run.title)}
			if gh_row(fmt.tprintf("##gh-run%d", i), ricon, rcol, title, fmt.tprintf("%s · %s", run.branch, age_text(run.at))) {open = run.url}
		}
	}
	return
}
