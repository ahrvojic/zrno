# Files

There is one name tree. `/` is the initramfs the loader handed over, and it is read-only. `/tmp` is a block device, and it is the only place a program can create, rename, or remove a name. Pipes and the console are file descriptors in the same table, but they are not names in the tree.

## The tree

`kernel/src/fs/vfs.zig` is a linked tree of nodes. A node has a name, a parent, a sibling, a child, and a reference count. A path that starts with `/` walks from the root. Any other path walks from the process's current directory, which is a retained node. `spawn` takes another reference. Exit drops it. `chdir` (`0x3b`) swaps it. `getcwd` (`0x3c`) walks parent links and writes the path. The root's path is `/`.

Names are at most 100 bytes, which is the ustar limit. A full path is at most 512 bytes. The kernel copies a path in with a pointer and a length. It does not take a C string.

The initramfs is mounted from `boot.init`, before the heap exists. Its nodes are static, and a file's bytes are a slice of the archive. The archive stays mapped for the life of the boot. The tree holds at most 32 files. Nothing under `/` can be created, removed, or written. `mkdir` of `/tmp` fails because it already exists. `mkdir` anywhere else, and `rmdir` of `/tmp`, fail because the parent is read-only.

## `/tmp` on disk

`kernel/src/fs/zrfs.zig` is the on-disk format. Blocks are 4096 bytes, little-endian.

- Block 0 is the superblock. The magic is `zrs1` (`0x3173727a`) and the next word is how many blocks the filesystem uses.
- Block 1 is a free bitmap. A set bit means the block is used. One block of bits covers 32768 blocks, which is 128 MiB, and that is the largest disk.
- Block 2 is the root directory's inode.

An inode is one block. It holds a kind (file or directory), a count of direct blocks, a byte size, and up to 1020 block numbers. A file is therefore at most about 4 MiB. Block 0 is never a data block, because it is the superblock. A write past the end of a file fails. The format has no holes.

A directory's bytes are 128-byte records: an inode number, a kind, a name length, and 100 bytes of name. Inode 0 in a record means the slot is empty. Records do not cross a block.

The running tree does not use those records as its index. `/tmp` names live in the heap sibling list. `create`, `unlink`, `mkdir`, `rmdir`, and `rename` edit that list. File bytes are written immediately. A write allocates blocks, stores them through the cache, and updates the inode's block count and size so a short write cannot truncate a longer file.

`sync` is what makes names durable. It walks `/tmp`, packs the live sibling list into 128-byte records, and writes each directory block once, with the leftover tail of the block zeroed. Inodes unlinked since the previous sync are freed after that write. A crash before sync comes back as the previous directory and drops the unsynced names. The bytes of files that were written are already on the device.

`reboot` and `poweroff` close every live file descriptor and drop every current directory before they sync. An unlinked file can then be freed, because nothing still holds it. `/init` is still running when this happens.

With no virtio device, `/tmp` is a 256-block RAM image, allocated after the heap exists, and it is gone at power off. `make run` attaches `zrno.dsk` (8 MiB) as a virtio disk, and that image keeps `/tmp` across power off. An 8 MiB disk is well under the bitmap's 128 MiB ceiling. The 4 MiB file limit is the one a program hits first.

## The block cache

`kernel/src/fs/blk.zig` caches 32 blocks. On the kernel a cached block is a physical page from [Memory](memory.md). Callers `get` a block, edit the bytes, `commit` or `put` it, and the cache writes dirty blocks back.

A miss reuses a slot. The scan starts at the slot after the last choice and walks forward, skipping a slot that someone still holds. An empty slot is preferred, so a block that was just dropped is reused before a dirty one is written back. A commit that the device refuses drops the slot. The next `get` reads the device again.

`map_file` does not pin these slots. It copies the bytes into private pages at the call, so a program can map as many pages as it wants without evicting the cache. See [Memory](memory.md).

## virtio-blk

`kernel/src/dev/virtio_blk.zig` drives the legacy device only. PCI config space is mechanism 1, ports `0xCF8` and `0xCFC`. The scan looks for vendor `0x1AF4`, device `0x1001`. The BAR is an I/O port range, there is one queue, and the descriptor ring holds guest-physical addresses.

A request is polled. Syscalls run with interrupts off, so there is no completion interrupt to take. The device is kicked, and the driver spins until the used ring catches up. A timeout resets the device and republishes the queue before returning an I/O error. If the reset itself does not finish, the device is marked dead and later transfers fail without touching the ring.

`main` tries virtio first. A missing device, or a mount that fails, falls back to the RAM image.

## Descriptors, reads, and writes

A process has 16 descriptors. `open` (`0x30`) reserves a free descriptor and a file object before it walks the path. If the open fails, both are released. Flags are a bitmask:

- no bits: read
- write (`1`): truncate an existing file
- create (`2`): create the final component, and it requires write
- keep (`4`): write without truncating, and it requires write

`read` (`0x32`) and `write` (`0x33`) copy through one page on the kernel stack, in a loop. A transfer longer than a page is several trips, not an error. A zero length returns zero before the descriptor is looked up. After any bytes have moved, a later fault or I/O error returns the short count, because the file position has already moved. The first failure returns the errno.

A file read stops at the end. A pipe or console read returns whatever is already queued, and does not sleep again to fill the rest of the buffer. A write that starts past the end of a `/tmp` file fails, and the file is left as it was.

`lseek` (`0x34`) takes an offset and a whence of set, current, or end. A directory refuses it. A pipe or the console refuses it with a different errno.

`unlink` (`0x37`) removes a file name. `mkdir` (`0x38`) and `rmdir` (`0x39`) create and remove an empty directory under `/tmp`. `rename` (`0x3a`) moves a name inside `/tmp`. An open directory can be removed. The node stays until the last reference is dropped, and a path walked from it can still succeed. `getdents` (`0x36`) fills the caller's buffer, at most a page, with directory entries.

## Pipes

`pipe` (`0x35`) returns two descriptors onto one ring in `kernel/src/fs/pipe.zig`. The ring is one page. `head == tail` means empty, so one byte is left unused and a pipe holds 4095 bytes. A full pipe is the point where a write blocks. A round trip that tries to push a whole page in both directions at once will deadlock, because neither side can accept the rest.

A reader with an empty ring waits until a writer puts a byte or the last writer closes. A writer with a full ring waits until a reader consumes a byte or the last reader closes. Closing the last writer wakes readers, and they see end of file. Closing the last reader wakes writers, and a write that copies nothing returns a broken-pipe error. The ring is freed when both reference counts hit zero.

While the read or write is waiting, the thread holds a reference to the file, and exit releases it. A thread killed during the wait does not return from the syscall, so the usual cleanup there would not run.

## Poll

`poll` (`0x3d`) waits until one of several descriptors is ready. It is level-triggered and has no timeout. Each slot is a descriptor, the events of interest, and the events found. The events a caller can ask for are readable and writable. A closed end is reported even when the caller did not ask for it. An events word of zero skips the slot.

A regular file or a directory is always ready. A console write is always ready. A console read is ready when a cooked line is queued. A pipe read is ready when bytes are queued or every writer is gone. A pipe write is ready when the ring has room or every reader is gone. A direction that can never happen, such as writing the read end, is reported as invalid so the caller does not spin.

The thread is marked polling and sleeps on the file table. A close, a pipe wake, or a console wake broadcasts, and every polling thread wakes up and checks its slots again.

## Where to read

- `kernel/src/fs/vfs.zig`, `kernel/src/fs/ustar.zig`, `kernel/src/fs/zrfs.zig`
- `kernel/src/fs/blk.zig`, `kernel/src/fs/file.zig`, `kernel/src/fs/pipe.zig`
- `kernel/src/dev/virtio_blk.zig`, `kernel/src/dev/pci.zig`
- The syscall bodies are in `kernel/src/sys/syscall.zig`
