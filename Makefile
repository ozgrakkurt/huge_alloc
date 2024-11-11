ALLOCATORS = huge_alloc page_alloc general_purpose_alloc huge_2mb_alloc huge_1gb_alloc

fuzz:
	zig build test --fuzz --port 1337 -Doptimize=ReleaseFast
install_bench:
	zig build install -Doptimize=ReleaseFast
run_bench: install_bench
	for alloc in $(ALLOCATORS); do \
		/usr/bin/time -v ./zig-out/bin/bench $$alloc 100000 10123123123 1; \
	done

