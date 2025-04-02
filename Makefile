build:
	@zig cc cati.c -o cati

clean:
	@rm cati

run-test:
	@./cati --test

test: build run-test clean
	@echo "______ completed ______"
