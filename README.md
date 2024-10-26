# huge_alloc

Memory allocator for allocating (huge) pages of memory. Designed for use cases like web servers, databases and data tools.

WARNING: This library is intended to only work on linux.

## Features
- Transparent huge page friendly allocation pattern.
- Easy way to allocate explicit huge pages with 2MB or 1GB size.
- Option to specify how pages are freed based on total allocation size.
- Very simple behavior, simple and easy to debug code.
- No libc dependency.

## Why is it good?
This allocator allocates very large sized pages of memory, tries to minimize page faults and TLB cache mises. 
This means that applications that are memory bottlenecked run more efficiently.

It is common for page faults to be a big bottleneck on applications that handle a lot of data but don't do a lot complex computation like aggregations, for example a storage engine that loads a lot of data from disk and does some filtering then returns the data to the caller. Another example is a web server that loads a large amount of data from a database and sends it over to the client.

With this allocator, the server or the storage engine can allocate memory in large increments and free all of the allocated memory at once. With standard allocators this means very likely that the memory will be returned to OS and it will be reallocated when the next requests come in. Also standard allocators don't minimize page faults by using explicit huge pages or calling mmmap with POPULATE flag. This allocator doesn't free underlying pages it got from the OS unless it reached some user defined threshold of memory usage to maximize reuse of pages. Also it calls mmap with POPULATE flag and tries to enable transparent huge pages or uses explicit huge pages (if the user choses so) to minimize page faults and TLB cache misses.

## Usage

Regular usage:
```zig
var huge_allocator = huge_alloc.HugePageAlloc.init(std.heap.page_allocator, huge_alloc.thp_alloc_vtable);
defer huge_allocator.deinit();
const my_alloc: std.mem.Allocator = huge_allocator.make_allocator();
```

With explicit 1GB huge pages:
```zig
var huge_allocator_1gb = huge_alloc.HugePageAlloc.init(std.heap.page_allocator, huge_alloc.huge_page_1gb_alloc_vtable);
defer huge_allocator_1gb.deinit();
const huge_1gb_alloc = huge_allocator_1gb.make_allocator();
```

Only difference is `huge_alloc.thp_alloc_vtable` => `huge_alloc.huge_page_1gb_alloc_vtable`. So the vtable can be chosen based on some env vars or other 
configuration based on the application.

NOTE: Using explicit huge pages requires enabling them via kernel parameters or some other method. But using `huge_alloc.thp_alloc_vtable` (transparent huge pages) is very likely good enough, it is recommended to benchmark the end application via both options and check if it is worth it to use explicit huge pages. 

WARNING: This allocator doesn't return unused pages back to the OS by default. It is recommended to set a free threshold if it is expected to have some large spikes in memory usage. This will make the allocator try to give some pages to the OS if memory usage hits the treshold.

Example of setting a free threshold of 1GB. The allocator will start freeing empty pages if total memory allocation size reaches 1GB.
```zig
var huge_allocator = huge_alloc.HugePageAlloc.init_with_config(std.heap.page_allocator, huge_alloc.thp_alloc_vtable, .{free_after=1*1024*1024*1024});
defer huge_allocator.deinit();
const huge_alloc_alloc = huge_allocator.make_allocator();
```

## Benchmarks

This repository has some benchmarks that can be run with `zig build runbench -Doptimize=ReleaseSafe`.
The benchmark allocates some arrays and fills them with random numbers. Then compresses/decompresses these arrays and does some vertical and horizontal summation on them. This is intended to simulate some worload like loading some columnar data (like Apache Arrow) from some files (like Parquet) from disk, decompressing them then doing some light computation.

This benchmark shows a big improvement compared to standard allocators. The difference is bigger if individual allocations are smaller and there are a large amount of allocations. The difference goes down as individual allocations are bigger and the amount of allocations are smaller.

Example output:
```
Running huge_alloc with buf_size = 128
Median running time was 91536μs
Running page_alloc with buf_size = 128
Median running time was 310504μs
Running general_purpose_alloc with buf_size = 128
Median running time was 248211μs
Running huge_2mb_alloc with buf_size = 128
Median running time was 91238μs
Running huge_1gb_alloc with buf_size = 128
Median running time was 91673μs
Running huge_alloc with buf_size = 131072
Median running time was 12503μs
Running page_alloc with buf_size = 131072
Median running time was 24153μs
Running general_purpose_alloc with buf_size = 131072
Median running time was 24110μs
Running huge_2mb_alloc with buf_size = 131072
Median running time was 12515μs
Running huge_1gb_alloc with buf_size = 131072
Median running time was 12620μs
Running huge_alloc with buf_size = 1048576
Median running time was 13177μs
Running page_alloc with buf_size = 1048576
Median running time was 14536μs
Running general_purpose_alloc with buf_size = 1048576
Median running time was 14706μs
Running huge_2mb_alloc with buf_size = 1048576
Median running time was 13093μs
Running huge_1gb_alloc with buf_size = 1048576
Median running time was 13317μs
Running huge_alloc with buf_size = 4194304
Median running time was 1514μs
Running page_alloc with buf_size = 4194304
Median running time was 2318μs
Running general_purpose_alloc with buf_size = 4194304
Median running time was 2271μs
Running huge_2mb_alloc with buf_size = 4194304
Median running time was 1394μs
Running huge_1gb_alloc with buf_size = 4194304
Median running time was 1648μs
Running huge_alloc with buf_size = 10485760
Median running time was 7765μs
Running page_alloc with buf_size = 10485760
Median running time was 11076μs
Running general_purpose_alloc with buf_size = 10485760
Median running time was 11041μs
Running huge_2mb_alloc with buf_size = 10485760
Median running time was 7794μs
Running huge_1gb_alloc with buf_size = 10485760
Median running time was 8260μs
Running huge_alloc with buf_size = 12582912
Median running time was 10018μs
Running page_alloc with buf_size = 12582912
Median running time was 13784μs
Running general_purpose_alloc with buf_size = 12582912
Median running time was 13769μs
Running huge_2mb_alloc with buf_size = 12582912
Median running time was 9984μs
Running huge_1gb_alloc with buf_size = 12582912
Median running time was 10505μs
```
