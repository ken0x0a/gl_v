module main

import gen

fn main() {
	// gen.new_header('/usr/include/GL/glew.h') ?.parse().write(
	gen.new_header('/usr/local/Cellar/glew/2.2.0_1/include/GL/glew.h')?.parse().write(
		root: './sys'
		fns_file: 'fns.v'
		enums_file: 'enums.v'
		bindings_file: 'bindings.v'
	)?
}
