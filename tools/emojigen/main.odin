// Generates assets/emoji/emoji.tsv, the launcher's emoji table, from
// Unicode's emoji-test.txt (names, groups, order, skin-tone variants) and
// emojilib's keyword list. Run it when either source moves to a new version:
//
//   curl -LO https://unicode.org/Public/emoji/15.1/emoji-test.txt
//   curl -L -o emojilib.json https://raw.githubusercontent.com/muan/emojilib/v3.0.12/dist/emoji-en-US.json
//   odin run tools/emojigen -- emoji-test.txt emojilib.json assets/emoji/emoji.tsv
//
// Output: one line per fully-qualified emoji, in Unicode's order:
//   emoji <TAB> name <TAB> group <TAB> keywords (space separated)
// Skin-tone variants keep their own line (name "… : medium skin tone") and
// no keywords; the "Component" group (bare modifiers) is left out.
package emojigen

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

main :: proc() {
	if len(os.args) != 4 {
		fmt.eprintln("usage: emojigen emoji-test.txt emojilib.json out.tsv")
		os.exit(2)
	}
	test, err1 := os.read_entire_file(os.args[1], context.allocator)
	lib_data, err2 := os.read_entire_file(os.args[2], context.allocator)
	if err1 != nil || err2 != nil {
		fmt.eprintln("emojigen: can't read the inputs")
		os.exit(1)
	}
	lib_val, jerr := json.parse(lib_data)
	if jerr != nil {
		fmt.eprintln("emojigen: bad emojilib json:", jerr)
		os.exit(1)
	}
	lib := lib_val.(json.Object)

	// emojilib keys sometimes drop the U+FE0F variation selector.
	keywords :: proc(lib: json.Object, e, name: string) -> string {
		v, ok := lib[e]
		if !ok {
			bare, _ := strings.remove_all(e, "️", context.temp_allocator)
			v, ok = lib[bare]
		}
		if !ok {return ""}
		name_words := strings.fields(name, context.temp_allocator)
		seen: map[string]bool
		seen.allocator = context.temp_allocator
		for w in name_words {seen[w] = true}
		out: [dynamic]string
		out.allocator = context.temp_allocator
		for k, i in v.(json.Array) {
			if i == 0 {continue} // the name, in snake case
			s, _ := strings.replace_all(strings.to_lower(k.(json.String), context.temp_allocator), "_", " ", context.temp_allocator)
			for w in strings.fields(s, context.temp_allocator) {
				if seen[w] || strings.contains_any(w, "\t\n") {continue}
				seen[w] = true
				append(&out, w)
			}
		}
		return strings.join(out[:], " ", context.temp_allocator)
	}

	b := strings.builder_make()
	group := ""
	n := 0
	text := string(test)
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "# group: ") {
			group = strings.trim_space(line[len("# group: "):])
			continue
		}
		if strings.has_prefix(line, "#") || !strings.contains(line, "; fully-qualified") || group == "Component" {continue}
		// "1F600 ; fully-qualified # 😀 E1.0 grinning face"
		hash := strings.index(line, "# ")
		if hash < 0 {continue}
		rest := strings.fields(line[hash + 2:], context.temp_allocator)
		if len(rest) < 3 {continue}
		e := rest[0]
		name := strings.to_lower(strings.join(rest[2:], " ", context.temp_allocator), context.temp_allocator)
		kw := strings.contains(name, "skin tone") ? "" : keywords(lib, e, name)
		fmt.sbprintf(&b, "%s\t%s\t%s\t%s\n", e, name, group, kw)
		n += 1
		free_all(context.temp_allocator)
	}
	if os.write_entire_file(os.args[3], strings.to_string(b)) != nil {
		fmt.eprintln("emojigen: can't write", os.args[3])
		os.exit(1)
	}
	fmt.printfln("emojigen: %d emoji", n)
}
