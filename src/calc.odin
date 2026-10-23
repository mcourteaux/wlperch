// Calculator: a small expression language and the number formats it shows.
//
//   1 + 2 * 3          precedence as usual; ^ and ** are powers (right assoc.)
//   7 % 3, 7 mod 3     floored modulo (the result has the divisor's sign)
//   0xff, 0b1010, 0o17, 1_000_000, 1.5e3, 0x1.8p+1 (hex float)
//   & | xor ~ << >>    bitwise, on integers
//   5!, 2pi, 3(4+1)    factorial, implicit multiplication
//   floor ceil round trunc frac abs sign sqrt cbrt exp ln log(x[, base])
//   log2 log10 sin cos tan asin acos atan atan2(y, x) sinh cosh tanh asinh
//   acosh atanh hypot pow min max gcd lcm deg rad gamma
//   pi e tau phi inf nan ans
//
// Integers stay exact (128-bit) through + - * / % ^ and the bitwise operators;
// anything that doesn't fit, or isn't whole, continues as a float.
package main

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

Calc_Value :: struct {
	is_int: bool,
	i:      i128,
	f:      f64,
}

calc_int :: proc(i: i128) -> Calc_Value {return {is_int = true, i = i, f = f64(i)}}
calc_flt :: proc(f: f64) -> Calc_Value {return {f = f}}

@(private = "file")
Parser :: struct {
	s:       string,
	pos:     int,
	err:     string,
	ans:     Calc_Value,
	degrees: bool,
}

// Evaluate `src`; `err` is a short message ("" when it worked).
calc_eval :: proc(src: string, ans := Calc_Value{is_int = true}, degrees := false) -> (v: Calc_Value, err: string) {
	p := Parser{s = src, ans = ans, degrees = degrees}
	skip_space(&p)
	if p.pos >= len(p.s) {return {}, "empty"}
	v = parse_or(&p)
	if p.err == "" {
		skip_space(&p)
		if p.pos < len(p.s) {fail(&p, fmt.tprintf("unexpected %q", rest_token(&p)))}
	}
	return v, p.err
}

@(private = "file")
fail :: proc(p: ^Parser, msg: string) {
	if p.err == "" {p.err = msg}
}

@(private = "file")
rest_token :: proc(p: ^Parser) -> string {
	s := p.s[p.pos:]
	for r, i in s {
		if i > 0 && (r == ' ' || r == '(' || r == ')') {return s[:i]}
	}
	return s
}

@(private = "file")
skip_space :: proc(p: ^Parser) {
	for p.pos < len(p.s) && (p.s[p.pos] == ' ' || p.s[p.pos] == '\t') {p.pos += 1}
}

// Consume `tok` (after spaces) if it's next.
@(private = "file")
eat :: proc(p: ^Parser, tok: string) -> bool {
	skip_space(p)
	if strings.has_prefix(p.s[p.pos:], tok) {
		p.pos += len(tok)
		return true
	}
	return false
}

// Consume the keyword `word` if it's next as a whole identifier.
@(private = "file")
eat_word :: proc(p: ^Parser, word: string) -> bool {
	skip_space(p)
	if !strings.has_prefix(p.s[p.pos:], word) {return false}
	end := p.pos + len(word)
	if end < len(p.s) && is_ident_char(p.s[end]) {return false}
	p.pos = end
	return true
}

@(private = "file")
is_ident_char :: proc(c: u8) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

// Whole numbers as an integer (floats with an exact integer value too).
@(private = "file")
as_int :: proc(p: ^Parser, v: Calc_Value, what: string) -> i128 {
	if v.is_int {return v.i}
	if math.is_nan(v.f) || math.is_inf(v.f) || v.f != math.trunc(v.f) || abs(v.f) >= 1.7e38 {
		fail(p, fmt.tprintf("%s needs integers", what))
		return 0
	}
	return i128(v.f)
}

// ---- Grammar, loosest first --------------------------------------------------

@(private = "file")
parse_or :: proc(p: ^Parser) -> Calc_Value {
	a := parse_xor(p)
	for p.err == "" {
		skip_space(p)
		if p.pos < len(p.s) && p.s[p.pos] == '|' {
			p.pos += 1
			b := parse_xor(p)
			a = calc_int(as_int(p, a, "|") | as_int(p, b, "|"))
		} else {break}
	}
	return a
}

@(private = "file")
parse_xor :: proc(p: ^Parser) -> Calc_Value {
	a := parse_and(p)
	for p.err == "" && eat_word(p, "xor") {
		b := parse_and(p)
		a = calc_int(as_int(p, a, "xor") ~ as_int(p, b, "xor"))
	}
	return a
}

@(private = "file")
parse_and :: proc(p: ^Parser) -> Calc_Value {
	a := parse_shift(p)
	for p.err == "" {
		skip_space(p)
		if p.pos < len(p.s) && p.s[p.pos] == '&' {
			p.pos += 1
			b := parse_shift(p)
			a = calc_int(as_int(p, a, "&") & as_int(p, b, "&"))
		} else {break}
	}
	return a
}

@(private = "file")
parse_shift :: proc(p: ^Parser) -> Calc_Value {
	a := parse_add(p)
	for p.err == "" {
		left := eat(p, "<<")
		if !left && !eat(p, ">>") {break}
		b := parse_add(p)
		x, n := as_int(p, a, "shift"), as_int(p, b, "shift")
		if n < 0 || n > 127 {
			fail(p, "shift out of range")
			break
		}
		if left {
			r := x << uint(n)
			if r >> uint(n) != x {
				fail(p, "shift overflows 128 bits")
				break
			}
			a = calc_int(r)
		} else {
			a = calc_int(x >> uint(n))
		}
	}
	return a
}

@(private = "file")
parse_add :: proc(p: ^Parser) -> Calc_Value {
	a := parse_mul(p)
	for p.err == "" {
		skip_space(p)
		if p.pos >= len(p.s) {break}
		sub := false
		if p.s[p.pos] == '+' {
			p.pos += 1
		} else if p.s[p.pos] == '-' {
			p.pos += 1
			sub = true
		} else if strings.has_prefix(p.s[p.pos:], "−") {
			p.pos += len("−")
			sub = true
		} else {break}
		b := parse_mul(p)
		a = sub ? op_sub(a, b) : op_add(a, b)
	}
	return a
}

@(private = "file")
parse_mul :: proc(p: ^Parser) -> Calc_Value {
	a := parse_unary(p)
	for p.err == "" {
		skip_space(p)
		if p.pos >= len(p.s) {break}
		rest := p.s[p.pos:]
		switch {
		case rest[0] == '*' || strings.has_prefix(rest, "×") || strings.has_prefix(rest, "·"):
			p.pos += rest[0] == '*' ? 1 : (strings.has_prefix(rest, "×") ? len("×") : len("·"))
			a = op_mul(a, parse_unary(p))
		case rest[0] == '/' || strings.has_prefix(rest, "÷"):
			p.pos += rest[0] == '/' ? 1 : len("÷")
			a = op_div(p, a, parse_unary(p))
		case rest[0] == '%':
			p.pos += 1
			a = op_mod(p, a, parse_unary(p))
		case eat_word(p, "mod"):
			a = op_mod(p, a, parse_unary(p))
		case rest[0] == '(' || strings.has_prefix(rest, "π") || strings.has_prefix(rest, "√") ||
		     (is_ident_char(rest[0]) && !(rest[0] >= '0' && rest[0] <= '9') && !starts_with_word(rest, "xor") && !starts_with_word(rest, "mod")):
			// Implicit multiplication: 2pi, 3(4+1), (1+1)(2+2).
			a = op_mul(a, parse_unary(p))
		case:
			return a
		}
	}
	return a
}

@(private = "file")
starts_with_word :: proc(s, word: string) -> bool {
	return strings.has_prefix(s, word) && (len(s) == len(word) || !is_ident_char(s[len(word)]))
}

@(private = "file")
parse_unary :: proc(p: ^Parser) -> Calc_Value {
	skip_space(p)
	if eat(p, "-") || eat(p, "−") {
		v := parse_unary(p)
		if v.is_int && v.i != min(i128) {return calc_int(-v.i)}
		return calc_flt(-v.f)
	}
	if eat(p, "+") {return parse_unary(p)}
	if eat(p, "~") {
		v := parse_unary(p)
		return calc_int(~as_int(p, v, "~"))
	}
	return parse_power(p)
}

@(private = "file")
parse_power :: proc(p: ^Parser) -> Calc_Value {
	base := parse_postfix(p)
	if p.err != "" {return base}
	if eat(p, "**") || eat(p, "^") {
		return op_pow(base, parse_unary(p)) // right associative; 2^-1 works
	}
	return base
}

@(private = "file")
parse_postfix :: proc(p: ^Parser) -> Calc_Value {
	v := parse_primary(p)
	for p.err == "" {
		skip_space(p)
		if p.pos < len(p.s) && p.s[p.pos] == '!' {
			p.pos += 1
			v = fn_fact(p, v)
		} else {break}
	}
	return v
}

@(private = "file")
parse_primary :: proc(p: ^Parser) -> Calc_Value {
	skip_space(p)
	if p.pos >= len(p.s) {
		fail(p, "incomplete")
		return {}
	}
	c := p.s[p.pos]
	switch {
	case c == '(':
		p.pos += 1
		v := parse_or(p)
		if p.err == "" && !eat(p, ")") {fail(p, "missing )")}
		return v
	case (c >= '0' && c <= '9') || c == '.':
		return parse_number(p)
	case strings.has_prefix(p.s[p.pos:], "π"):
		p.pos += len("π")
		return calc_flt(math.PI)
	case strings.has_prefix(p.s[p.pos:], "√"):
		p.pos += len("√")
		return call(p, "sqrt", {parse_postfix(p)})
	case is_ident_char(c):
		start := p.pos
		for p.pos < len(p.s) && is_ident_char(p.s[p.pos]) {p.pos += 1}
		name := p.s[start:p.pos]
		if eat(p, "(") {
			args: [dynamic]Calc_Value
			args.allocator = context.temp_allocator
			if !eat(p, ")") {
				for p.err == "" {
					append(&args, parse_or(p))
					if eat(p, ",") || eat(p, ";") {continue}
					if !eat(p, ")") {fail(p, "missing )")}
					break
				}
			}
			if p.err != "" {return {}}
			return call(p, name, args[:])
		}
		switch strings.to_lower(name, context.temp_allocator) {
		case "pi":  return calc_flt(math.PI)
		case "e":   return calc_flt(math.E)
		case "tau": return calc_flt(math.TAU)
		case "phi": return calc_flt((1 + math.sqrt(f64(5))) / 2)
		case "inf": return calc_flt(math.inf_f64(1))
		case "nan": return calc_flt(math.nan_f64())
		case "ans": return p.ans
		}
		// Unary functions also work without parentheses: sqrt 2, sin pi/2.
		if is_function(name) {return call(p, name, {parse_power(p)})}
		fail(p, fmt.tprintf("unknown name %q", name))
		return {}
	}
	fail(p, fmt.tprintf("unexpected %q", rest_token(p)))
	return {}
}

@(private = "file")
parse_number :: proc(p: ^Parser) -> Calc_Value {
	s := p.s
	start := p.pos
	radix := 10
	if p.pos + 1 < len(s) && s[p.pos] == '0' {
		switch s[p.pos + 1] {
		case 'x', 'X': radix = 16
		case 'b', 'B': radix = 2
		case 'o', 'O': radix = 8
		}
		if radix != 10 {p.pos += 2}
	}
	digit :: proc(c: u8, radix: int) -> int {
		d := -1
		switch c {
		case '0' ..= '9': d = int(c - '0')
		case 'a' ..= 'f': d = int(c - 'a') + 10
		case 'A' ..= 'F': d = int(c - 'A') + 10
		}
		return d < radix ? d : -1
	}
	mant: i128
	exact := true
	fmant: f64
	ndig, frac_digits := 0, 0
	seen_dot := false
	for p.pos < len(s) {
		c := s[p.pos]
		if c == '_' {p.pos += 1; continue}
		if c == '.' && !seen_dot && radix != 2 && radix != 8 {
			seen_dot = true
			p.pos += 1
			continue
		}
		d := digit(c, radix)
		if d < 0 {break}
		ndig += 1
		if seen_dot {frac_digits += 1}
		fmant = fmant * f64(radix) + f64(d)
		if exact {
			m1, o1 := intrinsics.overflow_mul(mant, i128(radix))
			m2, o2 := intrinsics.overflow_add(m1, i128(d))
			if o1 || o2 {exact = false} else {mant = m2}
		}
		p.pos += 1
	}
	if ndig == 0 {
		fail(p, "bad number")
		return {}
	}
	// Exponent: e for decimal, p (binary, power of two) for hex.
	exp := 0
	has_exp := false
	if p.pos < len(s) && ((radix == 10 && (s[p.pos] == 'e' || s[p.pos] == 'E')) || (radix == 16 && (s[p.pos] == 'p' || s[p.pos] == 'P'))) {
		q := p.pos + 1
		neg := false
		if q < len(s) && (s[q] == '+' || s[q] == '-') {neg = s[q] == '-'; q += 1}
		if q < len(s) && s[q] >= '0' && s[q] <= '9' {
			for q < len(s) && s[q] >= '0' && s[q] <= '9' {
				exp = min(exp * 10 + int(s[q] - '0'), 100000)
				q += 1
			}
			if neg {exp = -exp}
			has_exp = true
			p.pos = q
		} else if radix == 16 {
			fail(p, "bad hex float exponent")
			return {}
		}
	}
	if radix == 10 && (seen_dot || has_exp) {
		// Let strconv round correctly instead of accumulating digits.
		txt, _ := strings.remove_all(s[start:p.pos], "_", context.temp_allocator)
		f, ok := strconv.parse_f64(txt)
		if !ok {fail(p, "bad number")}
		return calc_flt(f)
	}
	if radix == 16 && (seen_dot || has_exp) {
		return calc_flt(math.ldexp(fmant, exp - 4 * frac_digits))
	}
	return exact ? calc_int(mant) : calc_flt(fmant)
}

// ---- Arithmetic --------------------------------------------------------------

@(private = "file")
op_add :: proc(a, b: Calc_Value) -> Calc_Value {
	if a.is_int && b.is_int {
		if r, o := intrinsics.overflow_add(a.i, b.i); !o {return calc_int(r)}
	}
	return calc_flt(a.f + b.f)
}

@(private = "file")
op_sub :: proc(a, b: Calc_Value) -> Calc_Value {
	if a.is_int && b.is_int {
		if r, o := intrinsics.overflow_sub(a.i, b.i); !o {return calc_int(r)}
	}
	return calc_flt(a.f - b.f)
}

@(private = "file")
op_mul :: proc(a, b: Calc_Value) -> Calc_Value {
	if a.is_int && b.is_int {
		if r, o := intrinsics.overflow_mul(a.i, b.i); !o {return calc_int(r)}
	}
	return calc_flt(a.f * b.f)
}

@(private = "file")
op_div :: proc(p: ^Parser, a, b: Calc_Value) -> Calc_Value {
	if a.is_int && b.is_int && b.i != 0 && a.i % b.i == 0 && !(a.i == min(i128) && b.i == -1) {
		return calc_int(a.i / b.i)
	}
	return calc_flt(a.f / b.f)
}

@(private = "file")
op_mod :: proc(p: ^Parser, a, b: Calc_Value) -> Calc_Value {
	if a.is_int && b.is_int {
		if b.i == 0 {
			fail(p, "modulo by zero")
			return {}
		}
		r := a.i % b.i
		if r != 0 && (r < 0) != (b.i < 0) {r += b.i}
		return calc_int(r)
	}
	return calc_flt(a.f - b.f * math.floor(a.f / b.f))
}

@(private = "file")
op_pow :: proc(a, b: Calc_Value) -> Calc_Value {
	if a.is_int && b.is_int && b.i >= 0 {
		r, base, e := i128(1), a.i, b.i
		ok := true
		for e > 0 && ok {
			o: bool
			if e & 1 == 1 {
				r, o = intrinsics.overflow_mul(r, base)
				ok = !o
			}
			e >>= 1
			if e > 0 {
				base, o = intrinsics.overflow_mul(base, base)
				ok = ok && !o
			}
		}
		if ok {return calc_int(r)}
	}
	return calc_flt(math.pow(a.f, b.f))
}

@(private = "file")
fn_fact :: proc(p: ^Parser, v: Calc_Value) -> Calc_Value {
	if v.is_int || v.f == math.trunc(v.f) {
		n := v.is_int ? v.i : i128(v.f)
		if n < 0 {
			fail(p, "factorial of a negative number")
			return {}
		}
		r := i128(1)
		for k in i128(2) ..= n {
			m, o := intrinsics.overflow_mul(r, k)
			if o {return calc_flt(math.gamma(f64(n) + 1))}
			r = m
		}
		return calc_int(r)
	}
	return calc_flt(math.gamma(v.f + 1))
}

// Round a float back to an exact integer when it fits.
@(private = "file")
whole :: proc(f: f64) -> Calc_Value {
	if math.is_nan(f) || math.is_inf(f) || abs(f) >= 1.7e38 {return calc_flt(f)}
	return calc_int(i128(f))
}

@(private = "file")
FUNCTIONS := [?]string {
	"floor", "ceil", "round", "trunc", "frac", "abs", "sign", "sqrt", "cbrt", "exp", "ln", "log",
	"log2", "log10", "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh",
	"asinh", "acosh", "atanh", "hypot", "pow", "min", "max", "gcd", "lcm", "deg", "rad", "gamma", "fact",
}

@(private = "file")
is_function :: proc(name: string) -> bool {
	for f in FUNCTIONS {if f == name {return true}}
	return false
}

@(private = "file")
call :: proc(p: ^Parser, name: string, args: []Calc_Value) -> Calc_Value {
	if !is_function(name) {
		fail(p, fmt.tprintf("unknown function %q", name))
		return {}
	}
	arity := 1
	switch name {
	case "atan2", "hypot", "pow": arity = 2
	case "log":                   arity = len(args) == 2 ? 2 : 1
	case "min", "max", "gcd", "lcm":
		if len(args) == 0 {
			fail(p, fmt.tprintf("%s needs arguments", name))
			return {}
		}
		arity = len(args)
	}
	if len(args) != arity {
		fail(p, fmt.tprintf("%s takes %d argument%s", name, arity, arity == 1 ? "" : "s"))
		return {}
	}
	x := args[0]
	// Angles in and out of the trigonometric functions.
	ang_in := p.degrees ? math.RAD_PER_DEG : 1.0
	ang_out := p.degrees ? math.DEG_PER_RAD : 1.0
	switch name {
	case "floor": return x.is_int ? x : whole(math.floor(x.f))
	case "ceil":  return x.is_int ? x : whole(math.ceil(x.f))
	case "round": return x.is_int ? x : whole(math.round(x.f))
	case "trunc": return x.is_int ? x : whole(math.trunc(x.f))
	case "frac":  return x.is_int ? calc_int(0) : calc_flt(x.f - math.trunc(x.f))
	case "abs":   return x.is_int && x.i != min(i128) ? calc_int(abs(x.i)) : calc_flt(abs(x.f))
	case "sign":  return calc_int(x.f > 0 ? 1 : (x.f < 0 ? -1 : 0))
	case "sqrt":
		if x.is_int && x.i >= 0 {
			r := i128(math.sqrt(x.f))
			for r * r > x.i {r -= 1}
			for (r + 1) * (r + 1) <= x.i {r += 1}
			if r * r == x.i {return calc_int(r)}
		}
		return calc_flt(math.sqrt(x.f))
	case "cbrt":  return calc_flt(math.cbrt(x.f))
	case "exp":   return calc_flt(math.exp(x.f))
	case "ln":    return calc_flt(math.ln(x.f))
	case "log":   return arity == 2 ? calc_flt(math.ln(x.f) / math.ln(args[1].f)) : calc_flt(math.log10(x.f))
	case "log2":  return calc_flt(math.log2(x.f))
	case "log10": return calc_flt(math.log10(x.f))
	case "sin":   return calc_flt(math.sin(x.f * ang_in))
	case "cos":   return calc_flt(math.cos(x.f * ang_in))
	case "tan":   return calc_flt(math.tan(x.f * ang_in))
	case "asin":  return calc_flt(math.asin(x.f) * ang_out)
	case "acos":  return calc_flt(math.acos(x.f) * ang_out)
	case "atan":  return calc_flt(math.atan(x.f) * ang_out)
	case "atan2": return calc_flt(math.atan2(x.f, args[1].f) * ang_out)
	case "sinh":  return calc_flt(math.sinh(x.f))
	case "cosh":  return calc_flt(math.cosh(x.f))
	case "tanh":  return calc_flt(math.tanh(x.f))
	case "asinh": return calc_flt(math.asinh(x.f))
	case "acosh": return calc_flt(math.acosh(x.f))
	case "atanh": return calc_flt(math.atanh(x.f))
	case "hypot": return calc_flt(math.hypot(x.f, args[1].f))
	case "pow":   return op_pow(x, args[1])
	case "deg":   return calc_flt(x.f * math.DEG_PER_RAD)
	case "rad":   return calc_flt(x.f * math.RAD_PER_DEG)
	case "gamma": return calc_flt(math.gamma(x.f))
	case "fact":  return fn_fact(p, x)
	case "min", "max":
		best := x
		for a in args[1:] {
			if (name == "min") == (a.f < best.f) && a.f != best.f {best = a}
		}
		return best
	case "gcd", "lcm":
		r := abs(as_int(p, x, name))
		for a in args[1:] {
			b := abs(as_int(p, a, name))
			g, h := r, b
			for h != 0 {g, h = h, g % h}
			if name == "gcd" {
				r = g
			} else if g != 0 {
				m, o := intrinsics.overflow_mul(r / g, b)
				if o {return calc_flt(f64(r / g) * f64(b))}
				r = m
			} else {
				r = 0
			}
		}
		return calc_int(r)
	}
	return {}
}

// ---- Output formats ----------------------------------------------------------

Calc_Format :: struct {
	label: string,
	text:  string, // shown
	copy:  string, // put on the clipboard (no digit grouping)
}

// Shortest decimal that reads back as the same value.
calc_decimal :: proc(v: Calc_Value, allocator := context.temp_allocator) -> string {
	if v.is_int {return fmt.aprintf("%d", v.i, allocator = allocator)}
	f := v.f
	if math.is_nan(f) {return "nan"}
	if math.is_inf(f) {return f > 0 ? "inf" : "-inf"}
	if f == math.trunc(f) && abs(f) < 1e21 {return fmt.aprintf("%.0f", f, allocator = allocator)}
	buf: [64]u8
	s := strconv.write_float(buf[:], f, 'g', -1, 64)
	if s[0] == '+' {s = s[1:]}
	return strings.clone(s, allocator)
}

// C99 "%a": 0x1.8p+1 for 3.
calc_hexfloat :: proc(f: f64, allocator := context.temp_allocator) -> string {
	if math.is_nan(f) {return "nan"}
	if math.is_inf(f) {return f > 0 ? "inf" : "-inf"}
	bits := transmute(u64)f
	sign := bits >> 63 != 0 ? "-" : ""
	e := int((bits >> 52) & 0x7ff)
	m := bits & (1 << 52 - 1)
	if e == 0 && m == 0 {return fmt.aprintf("%s0x0p+0", sign, allocator = allocator)}
	lead := 1
	exp := e - 1023
	if e == 0 {lead, exp = 0, -1022} // subnormal
	digits := fmt.tprintf("%013x", m)
	digits = strings.trim_right(digits, "0")
	dot := len(digits) > 0 ? "." : ""
	return fmt.aprintf("%s0x%d%s%sp%+d", sign, lead, dot, digits, exp, allocator = allocator)
}

// Digits in groups of `n` from the right, separated by spaces.
@(private = "file")
group :: proc(s: string, n: int) -> string {
	if len(s) <= n {return s}
	b := strings.builder_make(context.temp_allocator)
	first := len(s) % n
	if first == 0 {first = n}
	strings.write_string(&b, s[:first])
	for i := first; i < len(s); i += n {
		strings.write_byte(&b, ' ')
		strings.write_string(&b, s[i:i + n])
	}
	return strings.to_string(b)
}

// The value as decimal, hex, octal, binary (for integers) and its IEEE-754
// encodings (hex float literal, f64 and f32 bit patterns). Temp-allocated.
calc_formats :: proc(v: Calc_Value) -> []Calc_Format {
	out: [dynamic]Calc_Format
	out.allocator = context.temp_allocator
	dec := calc_decimal(v)
	dec_grouped := dec
	if v.is_int {
		digits := fmt.tprintf("%d", abs(v.i)) if v.i != min(i128) else dec
		dec_grouped = strings.concatenate({v.i < 0 ? "-" : "", group(digits, 3)}, context.temp_allocator)
	}
	append(&out, Calc_Format{"dec", dec_grouped, dec})

	// Integers (and floats with a whole value) in other bases.
	n: i128
	is_whole := v.is_int
	if v.is_int {
		n = v.i
	} else if !math.is_nan(v.f) && !math.is_inf(v.f) && v.f == math.trunc(v.f) && abs(v.f) < 1.7e38 {
		n = i128(v.f)
		is_whole = true
	}
	if is_whole {
		// Negative numbers that fit show as 64-bit two's complement.
		u: u128
		note := ""
		neg_prefix := ""
		if n >= 0 {
			u = u128(n)
		} else if n >= i128(min(i64)) {
			u = u128(u64(i64(n)))
			note = " (64-bit)"
		} else {
			u = u128(-n)
			neg_prefix = "-"
		}
		hex := fmt.tprintf("%X", u)
		oct := fmt.tprintf("%o", u)
		bin := fmt.tprintf("%b", u)
		append(&out, Calc_Format{strings.concatenate({"hex", note}, context.temp_allocator), fmt.tprintf("%s0x%s", neg_prefix, group(hex, 4)), fmt.tprintf("%s0x%s", neg_prefix, hex)})
		append(&out, Calc_Format{strings.concatenate({"oct", note}, context.temp_allocator), fmt.tprintf("%s0o%s", neg_prefix, oct), fmt.tprintf("%s0o%s", neg_prefix, oct)})
		append(&out, Calc_Format{strings.concatenate({"bin", note}, context.temp_allocator), fmt.tprintf("%s0b%s", neg_prefix, group(bin, 4)), fmt.tprintf("%s0b%s", neg_prefix, bin)})
	}

	f := v.is_int ? f64(v.i) : v.f
	exactf := !v.is_int || (abs(f) < 1.7e38 && i128(f) == v.i)
	b64 := fmt.tprintf("%016X", transmute(u64)f)
	append(&out, Calc_Format{"f64 bits", fmt.tprintf("0x%s", group(b64, 4)), fmt.tprintf("0x%s", b64)})
	f32v := f32(f)
	b32 := fmt.tprintf("%08X", transmute(u32)f32v)
	append(&out, Calc_Format{f64(f32v) == f || math.is_nan(f) ? "f32 bits" : "f32 bits ≈", fmt.tprintf("0x%s", group(b32, 4)), fmt.tprintf("0x%s", b32)})
	hf := calc_hexfloat(f)
	append(&out, Calc_Format{exactf ? "hex float" : "hex float ≈", hf, hf})
	return out[:]
}

// `wlperch calc <expression>`: print the result in every format.
calc_cli :: proc(args: []string) -> int {
	expr := strings.join(args, " ", context.temp_allocator)
	if strings.trim_space(expr) == "" {
		fmt.eprintln("usage: wlperch calc <expression>")
		return 2
	}
	v, err := calc_eval(expr)
	if err != "" {
		fmt.eprintfln("error: %s", err)
		return 1
	}
	for f in calc_formats(v) {fmt.printfln("%-12s %s", f.label, f.copy)}
	return 0
}
