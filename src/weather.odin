// Weather for today via open-meteo.com (no API key needed).
package main

import "core:fmt"
import "core:log"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

WEATHER_REFRESH :: 15 * time.Minute

Weather_Hour :: struct {
	hour:   int,
	temp:   f32,
	code:   int,
	precip: int, // probability %
	is_day: bool,
}

Weather :: struct {
	mu:          sync.Mutex,
	have_loc:    bool,
	lat, lon:    f64,
	place:       string,
	ok:          bool,
	error:       string,
	updated:     time.Time,
	temp:        f32,
	feels:       f32,
	code:        int,
	is_day:      bool,
	wind:        f32,
	humidity:    int,
	hi, lo:      f32,
	precip_prob: int,
	precip_sum:  f32,
	uv:          f32,
	sunrise:     string, // "07:12"
	sunset:      string,
	hours:       [dynamic]Weather_Hour,
	fetching:    bool,
}
weather: Weather

@(private = "file")
trigger: sync.Sema

weather_refresh_async :: proc() {
	sync.sema_post(&trigger)
}

// WMO weather interpretation codes -> (icon, description)
weather_desc :: proc(code: int, is_day: bool) -> (icon: string, desc: string) {
	switch code {
	case 0:          return is_day ? ICON_W_SUNNY : ICON_W_NIGHT, "Clear sky"
	case 1:          return is_day ? ICON_W_SUNNY : ICON_W_NIGHT, "Mainly clear"
	case 2:          return is_day ? ICON_W_PARTLY : ICON_W_NIGHT_PARTLY, "Partly cloudy"
	case 3:          return ICON_W_CLOUDY, "Overcast"
	case 45, 48:     return ICON_W_FOG, "Fog"
	case 51, 53, 55: return ICON_W_RAIN, "Drizzle"
	case 56, 57:     return ICON_W_SLEET, "Freezing drizzle"
	case 61:         return ICON_W_RAIN, "Light rain"
	case 63:         return ICON_W_RAIN, "Rain"
	case 65:         return ICON_W_POURING, "Heavy rain"
	case 66, 67:     return ICON_W_SLEET, "Freezing rain"
	case 71, 73, 75: return ICON_W_SNOW, "Snow"
	case 77:         return ICON_W_SNOW, "Snow grains"
	case 80, 81:     return ICON_W_RAIN, "Rain showers"
	case 82:         return ICON_W_POURING, "Violent showers"
	case 85, 86:     return ICON_W_SNOW, "Snow showers"
	case 95:         return ICON_W_THUNDER, "Thunderstorm"
	case 96, 99:     return ICON_W_THUNDER_RAIN, "Thunderstorm, hail"
	}
	return ICON_W_HAZY, "Unknown"
}

weather_color :: proc(code: int, is_day: bool) -> u32 {
	switch code {
	case 0, 1:       return is_day ? C_YELLOW : C_PURPLE
	case 2:          return is_day ? C_YELLOW : C_PURPLE
	case 3, 45, 48:  return C_MUTED
	case 71 ..= 86:  return 0xc8d3f5
	case 95 ..= 99:  return C_PURPLE
	}
	return C_CYAN
}

@(private = "file")
fetch :: proc(url: string) -> (string, bool) {
	return run({"curl", "-sfL", "--max-time", "10", url}, 12 * time.Second, context.temp_allocator)
}

@(private = "file")
set_error :: proc(msg: string) {
	sync.guard(&weather.mu)
	delete(weather.error)
	weather.error = strings.clone(msg)
	weather.fetching = false
}

@(private = "file")
resolve_location :: proc() -> bool {
	loc := strings.trim_space(config.location)
	lat, lon: f64
	place: string
	if loc == "" || strings.to_lower(loc, context.temp_allocator) == "auto" {
		body, ok := fetch("http://ip-api.com/json/?fields=status,city,countryCode,lat,lon")
		v, _ := jparse(body)
		if ok && jstr(jobj(v, "status")) == "success" {
			lat, lon = jfloat(jobj(v, "lat")), jfloat(jobj(v, "lon"))
			place = fmt.tprintf("%s, %s", jstr(jobj(v, "city")), jstr(jobj(v, "countryCode")))
		} else {
			body, ok = fetch("https://ipapi.co/json/")
			v, _ = jparse(body)
			if !ok || jobj(v, "latitude") == nil {
				set_error("Could not determine location")
				return false
			}
			lat, lon = jfloat(jobj(v, "latitude")), jfloat(jobj(v, "longitude"))
			place = fmt.tprintf("%s, %s", jstr(jobj(v, "city")), jstr(jobj(v, "country_code")))
		}
	} else if parts := strings.split(loc, ",", context.temp_allocator); len(parts) == 2 && is_number(parts[0]) && is_number(parts[1]) {
		lat, _ = strconv.parse_f64(strings.trim_space(parts[0]))
		lon, _ = strconv.parse_f64(strings.trim_space(parts[1]))
		place = fmt.tprintf("%.2f, %.2f", lat, lon)
	} else {
		name := loc
		if c := strings.index_byte(loc, ','); c >= 0 {name = loc[:c]}
		url := fmt.tprintf("https://geocoding-api.open-meteo.com/v1/search?count=1&format=json&name=%s", net.percent_encode(strings.trim_space(name), context.temp_allocator))
		body, ok := fetch(url)
		v, _ := jparse(body)
		results := jarr(jobj(v, "results"))
		if !ok || len(results) == 0 {
			set_error(fmt.tprintf("Unknown location \"%s\"", loc))
			return false
		}
		r := results[0]
		lat, lon = jfloat(jobj(r, "latitude")), jfloat(jobj(r, "longitude"))
		place = fmt.tprintf("%s, %s", jstr(jobj(r, "name")), jstr(jobj(r, "country_code")))
	}
	sync.guard(&weather.mu)
	weather.lat, weather.lon = lat, lon
	delete(weather.place)
	weather.place = strings.clone(place)
	weather.have_loc = true
	return true
}

@(private = "file")
is_number :: proc(s: string) -> bool {
	_, ok := strconv.parse_f64(strings.trim_space(s))
	return ok
}

@(private = "file")
hhmm :: proc(iso: string) -> string {
	// "2026-10-23T07:12" -> "07:12"
	if t := strings.index_byte(iso, 'T'); t >= 0 {return iso[t + 1:]}
	return iso
}

@(private = "file")
update :: proc() {
	{
		sync.guard(&weather.mu)
		weather.fetching = true
	}
	if !weather.have_loc && !resolve_location() {return}
	units := config.units == "imperial" ? "&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch" : ""
	url := fmt.tprintf(
		"https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f" +
		"&current=temperature_2m,apparent_temperature,weather_code,is_day,wind_speed_10m,relative_humidity_2m" +
		"&hourly=temperature_2m,weather_code,precipitation_probability,is_day" +
		"&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,sunrise,sunset,uv_index_max" +
		"&timezone=auto&forecast_days=2%s",
		weather.lat, weather.lon, units,
	)
	body, ok := fetch(url)
	v, pok := jparse(body)
	if !ok || !pok || jobj(v, "current") == nil {
		set_error("Weather service unreachable")
		return
	}
	cur := jobj(v, "current")
	daily := jobj(v, "daily")
	hourly := jobj(v, "hourly")
	cur_time := jstr(jobj(cur, "time")) // "2026-10-23T10:45"

	sync.guard(&weather.mu)
	weather.ok = true
	delete(weather.error)
	weather.error = ""
	weather.updated = time.now()
	weather.fetching = false
	weather.temp = f32(jfloat(jobj(cur, "temperature_2m")))
	weather.feels = f32(jfloat(jobj(cur, "apparent_temperature")))
	weather.code = int(jint(jobj(cur, "weather_code")))
	weather.is_day = jint(jobj(cur, "is_day")) != 0
	weather.wind = f32(jfloat(jobj(cur, "wind_speed_10m")))
	weather.humidity = int(jint(jobj(cur, "relative_humidity_2m")))
	weather.hi = f32(jfloat(jidx(jobj(daily, "temperature_2m_max"), 0)))
	weather.lo = f32(jfloat(jidx(jobj(daily, "temperature_2m_min"), 0)))
	weather.precip_prob = int(jint(jidx(jobj(daily, "precipitation_probability_max"), 0)))
	weather.precip_sum = f32(jfloat(jidx(jobj(daily, "precipitation_sum"), 0)))
	weather.uv = f32(jfloat(jidx(jobj(daily, "uv_index_max"), 0)))
	delete(weather.sunrise)
	delete(weather.sunset)
	weather.sunrise = strings.clone(hhmm(jstr(jidx(jobj(daily, "sunrise"), 0))))
	weather.sunset = strings.clone(hhmm(jstr(jidx(jobj(daily, "sunset"), 0))))

	clear(&weather.hours)
	times := jarr(jobj(hourly, "time"))
	temps := jobj(hourly, "temperature_2m")
	codes := jobj(hourly, "weather_code")
	probs := jobj(hourly, "precipitation_probability")
	days := jobj(hourly, "is_day")
	cur_hour := len(cur_time) >= 13 ? cur_time[:13] : cur_time
	start := 0
	for t, i in times {
		if strings.has_prefix(jstr(t), cur_hour) {
			start = i
			break
		}
	}
	for i in start ..< min(start + 24, len(times)) {
		ts := jstr(jidx(times, i))
		h := 0
		if len(ts) >= 13 {h, _ = strconv.parse_int(ts[11:13])}
		append(&weather.hours, Weather_Hour {
			hour = h,
			temp = f32(jfloat(jidx(temps, i))),
			code = int(jint(jidx(codes, i))),
			precip = int(jint(jidx(probs, i))),
			is_day = jint(jidx(days, i)) != 0,
		})
	}
	log.debugf("weather updated: %.1f° code %d", weather.temp, weather.code)
}

weather_start :: proc() {
	thread.create_and_start(proc() {
		for {
			update()
			wake_ui()
			free_all(context.temp_allocator)
			wait := WEATHER_REFRESH
			if !weather.ok {wait = time.Minute}
			sync.sema_wait_with_timeout(&trigger, wait)
			for sync.sema_wait_with_timeout(&trigger, 0) {}
		}
	})
}

weather_on_show :: proc() {
	sync.guard(&weather.mu)
	if !weather.ok || time.since(weather.updated) > WEATHER_REFRESH {
		sync.sema_post(&trigger)
	}
}
