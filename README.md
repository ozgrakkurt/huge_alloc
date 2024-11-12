# huge_alloc

Memory allocator for allocating (huge) pages of memory.

This is a library that provides two allocators:
- HugePageAlloc is designed to minimize page faults and TLB cache misses.
- BumpAlloc is a simple bump allocator that can be used to group allocations together and to optionally impose an allocation budget.

## Use case

Intended use case is to create an HugePageAlloc per thread in a thread-per-core application to be used as the base allocator.
Then create BumpAlloc instances per operation to limit memory usage, group small allocations together and reduce alloc/free call overhead.

## Benchmarks

This repository has some benchmarks that can be run with `make run_bench`.

The benchmark allocates some arrays and fills them with random numbers. Then compresses/decompresses these arrays and does some vertical and horizontal summation on them. This is intended to simulate some workload like loading some columnar data (like Apache Arrow) from some files (like Parquet) from disk, decompressing them then doing some light computation.

The goal of this library is to minimize page faults and benchmarks demonstrate that it does.

Example result with ~8GB memory budget and randomly sized individual buffer allocations.

| allocator | user_time | system_time | wall_time | page_faults | voluntary context switches | involuntary context switches |
| --------- | --------- | ----------- | --------- | ----------- | -------------------------- | ---------------------------- |
| HugeAlloc + BumpAlloc | 180.27 | 1.36 | 0:16.13 | 8233 | 372 | 10022 |
| HugeAlloc (1GB Huge Pages) + BumpAlloc | 174.96 | 1.51 | 0:16.38 | 3216 | 2818 | 27215 |
| std.heap.page_allocator + std.heap.ArenaAllocator | 177.80 | 82.90 | 0:22.65 | 403162 | 3002 | 11303 |
| std.heap.GeneralPurposeAllocator + std.heap.ArenaAllocator | 181.99 | 82.80 | 0:22.59 | 407992 | 97 | 22968 |

## License

Licensed under either of

 * Apache License, Version 2.0
   ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
 * MIT license
   ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)

at your option.

## Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, as defined in the Apache-2.0 license, shall be
dual licensed as above, without any additional terms or conditions.

