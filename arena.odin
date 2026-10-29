package markdown

import "base:runtime"

// A growing arena that keeps its blocks in an intrusive linked list. Unlike
// core:mem's Dynamic_Arena it needs no side arrays, so an allocation failure
// can never lose track of a block, and destroying it never allocates.

@(private)
ARENA_BLOCK_SIZE :: 64 * 1024

@(private)
Arena_Block :: struct {
	next:     ^Arena_Block,
	capacity: int,
	used:     int,
}

@(private)
Arena :: struct {
	backing:   runtime.Allocator,
	// head is the block that new small allocations come from. Older blocks follow it.
	head:      ^Arena_Block,
	// last is the most recent allocation, which can grow in place.
	last:      rawptr,
	last_size: int,
}

@(private)
arena_init :: proc(a: ^Arena, backing: runtime.Allocator) {
	a^ = {backing = backing}
}

@(private)
arena_allocator :: proc(a: ^Arena) -> runtime.Allocator {
	return runtime.Allocator{procedure = arena_allocator_proc, data = a}
}

@(private)
arena_destroy :: proc(a: ^Arena) {
	block := a.head
	for block != nil {
		next := block.next
		runtime.mem_free(block, a.backing)
		block = next
	}
	a.head = nil
	a.last = nil
	a.last_size = 0
}

@(private)
block_data :: #force_inline proc "contextless" (block: ^Arena_Block) -> uintptr {
	return uintptr(block) + size_of(Arena_Block)
}

@(private)
align_up :: #force_inline proc "contextless" (p: uintptr, alignment: int) -> uintptr {
	a := uintptr(alignment)
	return (p + a - 1) & ~(a - 1)
}

@(private)
arena_new_block :: proc(a: ^Arena, capacity: int) -> (block: ^Arena_Block, err: runtime.Allocator_Error) {
	raw := runtime.mem_alloc_non_zeroed(size_of(Arena_Block) + capacity, 16, a.backing) or_return
	block = (^Arena_Block)(raw_data(raw))
	block^ = {capacity = capacity}
	return block, nil
}

@(private)
arena_alloc :: proc(a: ^Arena, size, requested_alignment: int, zero: bool) -> (result: []byte, err: runtime.Allocator_Error) {
	alignment := max(requested_alignment, 1)
	if size == 0 {
		return nil, nil
	}
	if a.head != nil {
		base := block_data(a.head)
		start := align_up(base + uintptr(a.head.used), alignment)
		if int(start - base) + size <= a.head.capacity {
			a.head.used = int(start - base) + size
			result = ([^]byte)(rawptr(start))[:size]
			a.last = rawptr(start)
			a.last_size = size
			if zero {
				runtime.mem_zero(raw_data(result), size)
			}
			return result, nil
		}
	}
	needed := size + alignment
	if needed > ARENA_BLOCK_SIZE / 2 {
		// Large allocations get a block of their own behind the head, so the head keeps its free space.
		block := arena_new_block(a, needed) or_return
		if a.head != nil {
			block.next = a.head.next
			a.head.next = block
		} else {
			a.head = block
		}
		start := align_up(block_data(block), alignment)
		block.used = needed
		result = ([^]byte)(rawptr(start))[:size]
		if zero {
			runtime.mem_zero(raw_data(result), size)
		}
		return result, nil
	}
	block := arena_new_block(a, ARENA_BLOCK_SIZE) or_return
	block.next = a.head
	a.head = block
	return arena_alloc(a, size, alignment, zero)
}

@(private)
arena_resize :: proc(a: ^Arena, old_memory: rawptr, old_size, size, alignment: int, zero: bool) -> (result: []byte, err: runtime.Allocator_Error) {
	if old_memory == nil {
		return arena_alloc(a, size, alignment, zero)
	}
	if size <= old_size {
		if old_memory == a.last {
			a.head.used -= old_size - size
			a.last_size = size
		}
		return ([^]byte)(old_memory)[:size], nil
	}
	// The most recent allocation can grow in place when the head block has room.
	if old_memory == a.last && a.head != nil {
		offset := int(uintptr(old_memory) - block_data(a.head))
		if offset + size <= a.head.capacity {
			a.head.used = offset + size
			a.last_size = size
			result = ([^]byte)(old_memory)[:size]
			if zero {
				runtime.mem_zero(&result[old_size], size - old_size)
			}
			return result, nil
		}
	}
	result = arena_alloc(a, size, alignment, false) or_return
	runtime.mem_copy_non_overlapping(raw_data(result), old_memory, old_size)
	if zero {
		runtime.mem_zero(&result[old_size], size - old_size)
	}
	return result, nil
}

@(private)
arena_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	a := (^Arena)(allocator_data)
	switch mode {
	case .Alloc:
		return arena_alloc(a, size, alignment, true)
	case .Alloc_Non_Zeroed:
		return arena_alloc(a, size, alignment, false)
	case .Resize:
		return arena_resize(a, old_memory, old_size, size, alignment, true)
	case .Resize_Non_Zeroed:
		return arena_resize(a, old_memory, old_size, size, alignment, false)
	case .Free:
		// Individual frees are no-ops; document_destroy releases everything at once.
		return nil, nil
	case .Free_All:
		arena_destroy(a)
		return nil, nil
	case .Query_Features:
		set := (^runtime.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Free, .Free_All, .Query_Features}
		}
		return nil, nil
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, nil
}
