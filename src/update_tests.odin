// The update check: version order and picking the release for this CPU.
package main

import "core:strings"
import "core:testing"

@(test)
test_version_newer :: proc(t: ^testing.T) {
	testing.expect(t, version_newer("0.1.2", "0.1.1"))
	testing.expect(t, version_newer("v0.1.10", "0.1.9"))
	testing.expect(t, version_newer("0.2", "0.1.9"))
	testing.expect(t, version_newer("1.0.0", "0.99.99"))
	testing.expect(t, !version_newer("0.1.1", "0.1.1"))
	testing.expect(t, !version_newer("0.1.0", "0.1.1"))
	testing.expect(t, version_newer("0.2.0", "0.2.0-rc1"))
	testing.expect(t, !version_newer("0.2.0-rc1", "0.2.0"))
}

@(test)
test_update_pick :: proc(t: ^testing.T) {
	RELEASES :: `[
	 {"tag_name":"v0.1.3","draft":true,"assets":[
	   {"name":"wlperch-0.1.3-x86_64-linux.tar.gz","browser_download_url":"https://x/d3"},
	   {"name":"SHA256SUMS","browser_download_url":"https://x/s3"}]},
	 {"tag_name":"v0.1.2","draft":false,"assets":[
	   {"name":"wlperch-0.1.2-x86_64-linux.tar.gz","browser_download_url":"https://x/t2"},
	   {"name":"wlperch-0.1.2-aarch64-linux.tar.gz","browser_download_url":"https://x/a2"},
	   {"name":"SHA256SUMS","browser_download_url":"https://x/s2"}]},
	 {"tag_name":"v0.1.1","draft":false,"assets":[
	   {"name":"wlperch-0.1.1-x86_64-linux.tar.gz","browser_download_url":"https://x/t1"},
	   {"name":"SHA256SUMS","browser_download_url":"https://x/s1"}]}
	]`
	v, tar, sums, ok := update_pick(RELEASES, "0.1.1", "x86_64")
	testing.expect(t, ok)
	testing.expect_value(t, v, "0.1.2") // the draft 0.1.3 doesn't count
	testing.expect_value(t, tar, "https://x/t2")
	testing.expect_value(t, sums, "https://x/s2")
	v, tar, _, ok = update_pick(RELEASES, "0.1.1", "aarch64")
	testing.expect(t, ok)
	testing.expect_value(t, tar, "https://x/a2")
	_, _, _, ok = update_pick(RELEASES, "0.1.2", "x86_64")
	testing.expect(t, !ok, "nothing newer")
	_, _, _, ok = update_pick(RELEASES, "0.1.1", "riscv64")
	testing.expect(t, !ok, "no build for this CPU")
	_, _, _, ok = update_pick("not json", "0.1.1", "x86_64")
	testing.expect(t, !ok)
}

// A build from a checkout is never replaced by a release, even with one waiting.
@(test)
test_update_never_over_dev_build :: proc(t: ^testing.T) {
	when RELEASE_BUILD {return}
	update.state = .Available
	update.latest = "9.9.9"
	defer update.state = .Idle
	testing.expect(t, !update_available())
	msg, ok := update_install_now()
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(msg, "development build"))
	testing.expect_value(t, update.state, Update_State.Available) // untouched, nothing downloaded
}
