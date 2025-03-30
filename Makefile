build:
	@zig cc cati.c -o cati

test: build
	@./cati --test
