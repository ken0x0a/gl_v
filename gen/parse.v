module gen

import os

struct Header {
	enums []Enum

	exports  map[string]string
	defines  map[string]string
	typedefs map[string]FnTypes

	glapis map[string]FnTypes
}

pub fn new_header(path string) ?Header {
	raw := os.read_file(path)?
	lines := raw.replace('\r', '').split('\n')

	enums := parse_enums(lines.filter(is_enum))?

	exports := parse_exports(lines.filter(is_export))?
	defines := parse_defines(lines.filter(is_define))?
	typedefs := parse_typedefs(lines.filter(is_typedef))?

	glapis := parse_glapis(lines.filter(is_glapi))?
	// these could be parallelized!

	return Header{enums, exports, defines, typedefs, glapis}
}

pub fn (header Header) parse() Data {
	fns := header.parse_fns()

	return Data{
		fns: fns
		enums: header.enums
	}
}

fn (header Header) parse_fns() []Fn {
	mut fns := []Fn{cap: header.exports.len + header.glapis.len}

	for name, export_name in header.defines {
		types := header.typedefs[header.exports[export_name]]

		fns << Fn{name, types}
	}

	for name, types in header.glapis {
		fns << Fn{name, types}
	}

	return fns
}

fn is_enum(line string) bool {
	return line.starts_with('#define GL_') || (line.starts_with('#define GLEW_')
		&& !line.contains('('))
}

fn parse_enums(lines []string) ?[]Enum {
	mut res := []Enum{cap: lines.len}

	for raw in lines {
		name_from := 8
		without_define := raw.substr(name_from, raw.len)
		if !without_define.contains(' ') {
			// header definition probably. do something if i fucked something up
			continue
		}
		name_to := without_define.index(' ')? + name_from // add name_from to accommodate for without_define something blah blah
		name := raw.substr(name_from, name_to)

		val_from := name_to + 1
		val_to := raw.len
		val_raw := raw.substr(val_from, val_to)
		val := validify_enum(val_raw)

		if val == 'GLEWAPI' {
			// invalid enum
			continue
		}

		res << Enum{name, val}
	}

	return fix_enums(res)
}

fn fix_enums(enums []Enum) []Enum {
	mut res := []Enum{cap: enums.len}

	for e in enums {
		new_val := if e.val.starts_with('GL_') {
			// enum points to another enum, set copy value to original value
			a := enums.filter(it.name == e.val)
			a[0].val
		} else {
			e.val
		}

		raw := Enum{
			name: e.name
			val: new_val
		}
		if raw !in res {
			res << raw
		} else {
			assert raw.val == res.filter(it.name == raw.name)[0].val
		}
	}

	return res
}

fn is_export(line string) bool {
	return line.starts_with('GLEW_FUN_EXPORT')
}

fn parse_exports(lines []string) ?map[string]string {
	mut res := map[string]string{} // optimize: set cap for res (currently unsupported by V)

	for raw in lines {
		// don't get confused, the syntax for exports is GLEW_FUN_EXPORT <val> <key>
		// i don't know why either

		val_from := 16
		val_to := raw.index('__')? - 1 // we're assuming __ is the start of __glewSomeGlFunction + accommodate for space

		key_from := val_to + 1 // add back space
		key_to := raw.len - 1 // accommodate for the semicolon

		res[raw.substr(key_from, key_to)] = raw.substr(val_from, val_to)
	}

	return res
}

fn is_define(line string) bool {
	return line.starts_with('#define gl') && !line.starts_with('#define glew')
}

fn parse_defines(lines []string) ?map[string]string {
	mut res := map[string]string{}

	for raw in lines {
		key_from := 8
		key_to := raw.index('GLEW_GET_FUN')? - 1

		val_from := raw.index('__')? // we're assuming __ is the start of __glewSomeFunction
		val_to := raw.len - 1 // accommodate for the ending bracket

		res[raw.substr(key_from, key_to)] = raw.substr(val_from, val_to)
	}

	return res
}

fn is_typedef(line string) bool {
	return line.starts_with('typedef') && line.contains('GLAPIENTRY')
}

fn parse_typedefs(lines []string) ?map[string]FnTypes {
	mut res := map[string]FnTypes{}

	for raw in lines {
		// TODO what the fuck do we do with APIENTRY's????
		// syntax: typedef <return> (GLAPIENTRY * PFN<fn ptr name>PROC) <args>

		returns_from := 8
		returns_to := raw.index('(GL')? // we're assuming (GL is the start of (GLAPIENTRY
		returns_raw := raw.substr(returns_from, returns_to).trim(' ')
		returns := parse_type(returns_raw, Implied{})?
		closing_bracket_pos := raw.substr(returns_to, raw.len).index(')')? + returns_to

		name_from := raw.index('APIENTRY *')? + 11
		name_to := closing_bracket_pos // we only check a subset of raw so the return type doesn't fuck up
		name := raw.substr(name_from, name_to)

		args_from := closing_bracket_pos + 3
		args_to := raw.len - 2 // remove semicolon and ending bracket
		args_raw := raw.substr(args_from, args_to).trim(' ')
		args := if args_raw != 'void' { parse_args(args_raw)? } else { []Var{} }

		res[name] = FnTypes{returns, args}
	}

	return res
}

fn is_glapi(line string) bool {
	return line.starts_with('GLAPI') || (line.starts_with('GLEWAPI') && line.contains('(')) // we want to make sure they aren't variables
}

fn parse_glapis(lines []string) ?map[string]FnTypes {
	mut res := map[string]FnTypes{}

	for raw in lines {
		glew := raw.contains('GLEWAPI')

		returns_from := if !glew { 6 } else { 8 }
		returns_to := raw.index(if !glew { 'GLAPIENTRY' } else { 'GLEWAPIENTRY' })?
		returns_raw := raw.substr(returns_from, returns_to).trim(' ')
		returns := parse_type(returns_raw, Implied{})?

		name_from := returns_to + if !glew { 11 } else { 13 }
		name_to := string_index_last(raw, ' (')?
		name := raw.substr(name_from, name_to)

		args_from := name_to + 2
		args_to := string_index_last(raw, ');')?
		args_raw := raw.substr(args_from, args_to)
		args := if args_raw != 'void' { parse_args(args_raw)? } else { []Var{} }

		res[name] = FnTypes{returns, args}
	}

	return res
}

fn parse_args(raw string) ?[]Var {
	if raw.contains('const') {
		return parse_args(raw.replace('const', ''))
	}

	args := raw.split(',').map(it.trim(' '))
	mut res := []Var{cap: args.len}

	for arg in args {
		mut separator := ''
		mut ptr := if arg.contains('*') { 1 } else { 0 }
		len := if arg.contains('[') {
			len_from := arg.index('[')? + 1
			len_to := arg.index(']')?
			len_raw := arg.substr(len_from, len_to)
			if len_raw != '' {
				len_raw.int()
			} else {
				ptr++
				0
			}
		} else {
			0
		}

		if arg.contains(' ') {
			if arg.contains('*') {
				if string_index_last(arg, ' ')? < string_index_last(arg, '*')? {
					// type *name
					separator = ' *'
				} else {
					// type* name
					separator = '* '
				}
			} else {
				// type name
				separator = ' '
			}
		} else {
			if arg.contains('*') {
				// type*name
				separator = '*'
			} else {
				// only type. :|
				res << Var{
					name: 'xyzabc /* no name. */'
					kind: parse_type(arg, ptr: ptr)?
				}
				continue
			}
		}

		kind_from := 0
		kind_to := string_index_last(arg, separator)?
		name_from := kind_to + separator.len
		name_to := if arg.contains('[') {
			a := arg.index('[')?
			a
			// the v compiler is funny sometimes
		} else {
			arg.len
		}

		name_raw := arg.substr(name_from, name_to)
		name_ptrs := string_count(name_raw, `*`) // quick and dirty hack to fix `void **name` situations
		name := if name_ptrs > 0 {
			name_real_from := string_index_last(name_raw, '*')? + 1
			name_real_to := name_raw.len
			name_raw.substr(name_real_from, name_real_to)
		} else {
			name_raw
		}
		ptr += name_ptrs

		kind_raw := arg.substr(kind_from, kind_to)
		kind := parse_type(kind_raw, ptr: ptr, arr_len: len)?

		// name_snake_case := to_snake_case('${name[0].to_lower()}${name[1..]}')
		name_snake_case := to_snake_case(name, true)
		res << Var{name_snake_case, kind}
	}

	return res
}

struct Implied {
	ptr     int
	arr_len int
}

fn (im Implied) is_default() bool {
	return !im.ptr() && !im.arr()
}

fn (im Implied) ptr() bool {
	return im.ptr != 0
}

fn (im Implied) arr() bool {
	return im.arr_len != 0
}

fn parse_type(raw string, im Implied) ?Type {
	if raw.contains('const') {
		return parse_type(raw.replace('const', '').trim(' '), im)
	}
	if raw.contains('*') && !raw.ends_with('*') {
		return parse_type(raw.trim(' '), im)
	}

	if raw.contains('*') {
		return PtrType{
			child: parse_type(raw.substr(0, raw.len - 1), im)?
		}
	}
	if im.ptr() {
		return PtrType{
			child: parse_type(raw, Implied{ ptr: im.ptr - 1, arr_len: im.arr_len })?
		}
	}
	if im.arr() {
		return ArrayType{
			len: im.arr_len
			child: parse_type(raw, Implied{ ptr: im.ptr })?
		}
	}

	assert im.is_default()
	return Type(translate_type(raw.trim(' ')))
}
