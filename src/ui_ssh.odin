// The SSH keys card (module "ssh", its own panel) and its quick settings
// tile. State and actions: ssh.odin.
package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

import im "third_party:odin-imgui"

@(private = "file")
Ssh_Click :: struct {
	act:     Ssh_Action,
	key, fp: string,
	setup:   bool, // open the setup window
	set:     bool,
}

draw_ssh :: proc(w: f32) {
	ck := draw_ssh_locked(w)
	if ck.setup {
		setup_launch("components")
		hide_requested = true
	}
	if !ck.set {return}
	if ssh_start_action(ck.act, ck.key, ck.fp) {
		// The passphrase popup takes the keyboard: out of its way.
		if ck.act == .Unlock || ck.act == .Lock || ck.act == .Unlock_Agent {hide_requested = true}
	}
	request_redraw(2)
}

// "SHA256:R0fzH5wA…": enough to tell keys apart.
@(private = "file")
short_fp :: proc(fp: string) -> string {
	if len(fp) <= 19 {return fp}
	return strings.concatenate({fp[:19], "…"}, context.temp_allocator)
}

@(private = "file")
draw_ssh_locked :: proc(w: f32) -> (ck: Ssh_Click) {
	sync.guard(&ssh.mu)
	card_begin("ssh", w)
	defer card_end()
	right := ""
	switch ssh.agent {
	case .Running: right = ssh_agent_kind(ssh.sock)
	case .Locked:  right = "agent locked"
	case .None:
	}
	card_title(ICON_KEY, "SSH keys", C_YELLOW, right)
	inner := im.GetContentRegionAvail().x
	if !ssh.checked {
		label(fonts.ui, SZ_SMALL, col32(C_MUTED), "Looking…")
		return
	}
	if !ssh.available {
		label(fonts.ui, SZ_BODY, col32(C_TEXT, 0.85), "ssh-add isn't installed")
		label(fonts.ui, SZ_SMALL, col32(C_MUTED), "Install the OpenSSH clients (openssh-clients).")
		return
	}
	if ssh.agent == .None {
		p := im.GetCursorScreenPos()
		draw_text(fonts.ui, 20, {p.x, p.y + 4}, col32(C_MUTED), ICON_KEY_REMOVE)
		draw_text(fonts.bold, SZ_BODY, {p.x + 30, p.y + 2}, col32(C_TEXT), "No SSH agent running")
		draw_text(fonts.ui, SZ_SMALL, {p.x + 30, p.y + 21}, col32(C_MUTED), "wlperch setup can start OpenSSH's own agent.")
		lbl := "Set up the agent"
		im.SetCursorScreenPos({p.x + inner - measure(fonts.bold, SZ_SMALL + 1, lbl).x - 24, p.y + 5})
		if pill_button("##ssh:setup", lbl, C_YELLOW, true) {ck.setup = true}
		im.SetCursorScreenPos(p)
		im.Dummy({inner, 42})
	}
	now := time.to_unix_seconds(time.now())
	locked := ssh.agent == .Locked
	busy := ssh.busy != ""
	row :: proc(k: Ssh_Key, inner: f32, now: i64, locked, busy, agent: bool, busy_key, msg_key, msg: string, msg_ok: bool, ck: ^Ssh_Click) {
		p := im.GetCursorScreenPos()
		h: f32 = 44
		d := dl()
		on := k.loaded
		if on {im.DrawList_AddRectFilled(d, {p.x - 6, p.y - 2}, {p.x + inner + 6, p.y + h - 2}, col32(C_GREEN, 0.08), 8)}
		draw_text(fonts.ui, 19, {p.x + 2, p.y + 10}, col32(on ? C_GREEN : C_MUTED), on ? ICON_LOCK_OPEN : ICON_KEY)
		x := p.x + 32
		// Right side first: the state and a button; the name is clipped to what's left.
		rx := p.x + inner
		id := k.path != "" ? k.path : k.fingerprint
		lbl := ""
		primary := false
		act := Ssh_Action.Forget
		state, scol := "", C_MUTED
		switch {
		case busy_key == id:
			state, scol = on ? "forgetting…" : "waiting for the passphrase…", C_ORANGE
		case on:
			lbl, act = "Forget", .Forget
			state, scol = k.expires > 0 ? fmt.tprintf("%s left", ssh_left_text(k.expires - now)) : "unlocked", C_GREEN
		case locked:
			state = "agent locked"
		case k.path != "" && agent:
			lbl, act, primary = "Unlock", .Unlock, true
			state = "locked"
		case:
			state = "locked"
		}
		if lbl != "" {
			bw := measure(fonts.bold, SZ_SMALL + 1, lbl).x + 24
			rx -= bw
			if !busy {
				im.SetCursorScreenPos({rx, p.y + 6})
				if pill_button(fmt.tprintf("##ssh:%s", id), lbl, primary ? C_YELLOW : C_GREEN, primary) {
					ck^ = {act = act, key = strings.clone(k.path != "" ? k.path : k.fingerprint, context.temp_allocator), fp = strings.clone(k.fingerprint, context.temp_allocator), set = true}
				}
			} else {
				draw_text(fonts.bold, SZ_SMALL + 1, {rx + 12, p.y + 12}, col32(C_FAINT), lbl)
			}
			rx -= 10
		}
		ssz := measure(fonts.ui, SZ_SMALL, state)
		draw_text(fonts.ui, SZ_SMALL, {rx - ssz.x, p.y + 12}, col32(scol), state)
		rx -= ssz.x + 12
		if busy_key == id {request_redraw(2)}
		im.DrawList_PushClipRect(d, {x, p.y}, {max(rx, x + 40), p.y + h}, true)
		draw_text(fonts.bold, SZ_BODY, {x, p.y + 3}, col32(C_TEXT), k.name)
		sub := fmt.tprintf("%s %d · %s", k.kind, k.bits, short_fp(k.fingerprint))
		if k.comment != "" && k.comment != k.name {sub = fmt.tprintf("%s · %s", sub, k.comment)}
		draw_text(fonts.ui, SZ_SMALL, {x, p.y + 22}, col32(C_MUTED), sub)
		im.DrawList_PopClipRect(d)
		im.SetCursorScreenPos(p)
		im.Dummy({inner, h - 4})
		if msg_key == id && msg != "" {
			im.SetCursorPosX(im.GetCursorPosX() + 32)
			label(fonts.ui, SZ_SMALL, col32(msg_ok ? C_GREEN : C_RED), fmt.tprintf("%s %s", msg_ok ? ICON_CHECK : ICON_ALERT, msg))
		}
	}
	agent := ssh.agent != .None
	for k in ssh.keys {row(k, inner, now, locked, busy, agent, ssh.busy, ssh.msg_key, ssh.msg, ssh.msg_ok, &ck)}
	if len(ssh.keys) == 0 {
		label(fonts.ui, SZ_BODY, col32(C_TEXT, 0.8), len(config.ssh_keys) > 0 ? "None of the keys in [ssh] keys was found" : "No private keys in ~/.ssh")
		label(fonts.ui, SZ_SMALL, col32(C_MUTED), "Make one with: ssh-keygen -t ed25519")
	}
	if len(ssh.others) > 0 {
		sub_heading("Other keys in the agent")
		for k in ssh.others {row(k, inner, now, locked, busy, agent, ssh.busy, ssh.msg_key, ssh.msg, ssh.msg_ok, &ck)}
	}

	if !agent {return}
	// When keys leave the agent again.
	im.Dummy({1, 2})
	rules := make([dynamic]string, context.temp_allocator)
	append(&rules, config.ssh_lifetime > 0 ? fmt.tprintf("Unlock adds a key for %s", ssh_left_text(i64(config.ssh_lifetime) * 60)) : "Unlocked keys stay until forgotten")
	if config.ssh_forget_on_lock {append(&rules, "forgotten when the screen locks")}
	if config.ssh_forget_on_idle > 0 {append(&rules, fmt.tprintf("after %d min idle", config.ssh_forget_on_idle))}
	im.PushTextWrapPos(im.GetCursorPosX() + inner)
	label(fonts.ui, SZ_SMALL, col32(C_FAINT), strings.join(rules[:], " · ", context.temp_allocator))
	im.PopTextWrapPos()

	any_loaded := len(ssh.others) > 0
	for k in ssh.keys {if k.loaded {any_loaded = true}}
	acts := make([dynamic]struct {label: string, act: Ssh_Action, accent: u32}, context.temp_allocator)
	if any_loaded {append(&acts, struct {label: string, act: Ssh_Action, accent: u32}{"Forget all", .Forget_All, C_RED})}
	if locked {
		append(&acts, struct {label: string, act: Ssh_Action, accent: u32}{"Unlock agent", .Unlock_Agent, C_YELLOW})
	} else {
		append(&acts, struct {label: string, act: Ssh_Action, accent: u32}{"Lock agent", .Lock, C_BLUE})
	}
	im.Dummy({1, 2})
	fp := im.GetCursorScreenPos()
	ax := fp.x
	for a in acts {
		im.SetCursorScreenPos({ax, fp.y})
		if busy {
			draw_text(fonts.bold, SZ_SMALL + 1, {ax + 12, fp.y + 6}, col32(C_FAINT), a.label)
		} else if pill_button(fmt.tprintf("##ssh:%v", a.act), a.label, a.accent) {
			ck = {act = a.act, set = true}
		}
		ax += measure(fonts.bold, SZ_SMALL + 1, a.label).x + 24 + 8
	}
	if ssh.busy == "*" {
		draw_text(fonts.ui, SZ_SMALL, {ax + 4, fp.y + 7}, col32(C_ORANGE), "working…")
		request_redraw(2)
	}
	im.SetCursorScreenPos(fp)
	im.Dummy({inner, 28})
	if ssh.msg_key == "" && ssh.msg != "" {
		label(fonts.ui, SZ_SMALL, col32(ssh.msg_ok ? C_GREEN : C_RED), fmt.tprintf("%s %s", ssh.msg_ok ? ICON_CHECK : ICON_ALERT, ssh.msg))
	}
	return
}

// The quick settings tile: how many keys are unlocked; it opens the panel.
ssh_quick_tile :: proc() -> (t: Tile_Def, ok: bool) {
	sync.guard(&ssh.mu)
	if !ssh.checked || !ssh.available || (len(ssh.keys) == 0 && ssh.agent == .None) {return}
	n := len(ssh.others)
	next: i64 = 0
	for k in ssh.keys {
		if !k.loaded {continue}
		n += 1
		if k.expires > 0 && (next == 0 || k.expires < next) {next = k.expires}
	}
	state := "Locked"
	switch {
	case ssh.agent == .None:   state = "No agent"
	case ssh.agent == .Locked: state = "Agent locked"
	case n > 0 && next > 0:    state = fmt.tprintf("%d unlocked · %s", n, ssh_left_text(next - time.to_unix_seconds(time.now())))
	case n > 0:                state = n == 1 ? "1 unlocked" : fmt.tprintf("%d unlocked", n)
	}
	return Tile_Def{"##q:ssh", n > 0 ? ICON_LOCK_OPEN : ICON_KEY, "SSH keys", state, n > 0, true, C_YELLOW,
		"Unlock, forget and lock your SSH keys", proc(on: bool) {
			if i := panel_find("ssh"); i >= 0 {switch_panel(i)}
		}}, true
}
