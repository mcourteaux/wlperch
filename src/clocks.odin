// World clocks for the configured IANA time zones.
package main

import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

Clock :: struct {
	label:  string,
	region: ^datetime.TZ_Region, // nil = local
	ok:     bool,
}

clocks: [dynamic]Clock
local_region: ^datetime.TZ_Region
local_tz_name: string

clocks_init :: proc() {
	if reg, ok := timezone.region_load("local"); ok {
		local_region = reg
		if reg != nil {local_tz_name = reg.name}
	}
	for e in config.clocks {
		c := Clock{ok = true}
		if e.tz == "" {
			c.region = local_region
			c.label = e.label != "" ? e.label : city_from_tz(local_tz_name)
		} else {
			reg, rok := timezone.region_load(e.tz)
			if !rok {
				log.warnf("unknown time zone %q", e.tz)
				c.ok = false
			}
			c.region = reg
			c.label = e.label != "" ? e.label : city_from_tz(e.tz)
		}
		append(&clocks, c)
	}
}

// "America/New_York" -> "New York"
city_from_tz :: proc(tz: string) -> string {
	if tz == "" {return "Local"}
	city := tz
	if i := strings.last_index_byte(tz, '/'); i >= 0 {city = tz[i + 1:]}
	s, _ := strings.replace_all(city, "_", " ")
	return s
}

Clock_Reading :: struct {
	dt:         datetime.DateTime,
	offset_min: int, // UTC offset in minutes
	abbrev:     string,
}

clock_read :: proc(region: ^datetime.TZ_Region, now: time.Time) -> (r: Clock_Reading, ok: bool) {
	utc, uok := time.time_to_datetime(now)
	if !uok {return}
	if region == nil {
		return {dt = utc, abbrev = "UTC"}, true
	}
	local, lok := timezone.datetime_to_tz(utc, region)
	if !lok {return}
	r.dt = local
	// UTC offset = local wall clock - UTC wall clock.
	lo, _ := datetime.date_to_ordinal(local.date)
	uo, _ := datetime.date_to_ordinal(utc.date)
	r.offset_min = int(lo - uo) * 1440 + (int(local.hour) * 60 + int(local.minute)) - (int(utc.hour) * 60 + int(utc.minute))
	r.abbrev = timezone.shortname_unsafe(local)
	return r, true
}

format_offset :: proc(minutes: int) -> string {
	sign := minutes < 0 ? "−" : "+"
	m := abs(minutes)
	if m % 60 == 0 {return fmt.tprintf("UTC%s%d", sign, m / 60)}
	return fmt.tprintf("UTC%s%d:%02d", sign, m / 60, m % 60)
}

WEEKDAYS := [7]string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}
MONTHS := [12]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}

weekday_of :: proc(dt: datetime.DateTime) -> int {
	ord, _ := datetime.date_to_ordinal(dt.date)
	return int(datetime.day_of_week(ord))
}
