" Plugin:      Memvwr - termdebug integration
" Author:      J. Paulo Seibt <jpseibt@gmail.com>
" Created:     2026 Oct 20
" License:     MIT (https://opensource.org/license/mit/)
" Last Change: 2026 Oct 20

if exists('g:loaded_memvwr_termdebug') | finish | endif
let g:loaded_memvwr_termdebug = 1

"============================================================
" Memvwr integration with termdebug
"============================================================
"TODO notes:
" [ ] remove `sleep` calls.
" [ ] add cursor area evaluation.
" [ ] add hotkeys with `setup/teardown` approach.
"  ^- NOTE: maybe it could be an option like `g:termdebug_config['map_K']`.
" [ ] memvwr update solution, aware of current address space.
"  ^- NOTE: maybe an option to re-TdbgSetMemvwr() on each breakpoint.
" [ ] look into GDB/MI interface (https://sourceware.org/gdb/current/onlinedocs/gdb.html/GDB_002fMI.html)

let s:gdb_dump_is_little_endian = 1
let s:last_start_addr = ''
let s:last_stop_addr  = ''

function! MemvwrTdbgSetView(start_addr, stop_addr)
  " Evaluate start address expression from GDB value dump
  let l:temp_file_start_addr_dump = tempname()
  let l:gdb_cmd = printf("dump binary value %s (unsigned long long)%s", l:temp_file_start_addr_dump, a:start_addr)
  call TermDebugSendCommand(l:gdb_cmd)
  sleep 100m

  let l:start_addr_blob = readblob(l:temp_file_start_addr_dump)
  if empty(l:start_addr_blob)
    echomsg '[MemvwrTdbgSetView] Empty blob from readblob("' . l:temp_file_start_addr_dump . '"). Aborting...'
    call delete(l:temp_file_start_addr_dump)
    return
  endif

  let l:start_addr_value = MemvwrParseUint64(l:start_addr_blob, s:gdb_dump_is_little_endian)

  " Setup Memvwr from GDB memory dump
  let l:temp_file_mem_dump = tempname()

  let l:stop_addr_normal = a:stop_addr
  if a:stop_addr[0] == '+'
    let l:stop_addr_normal = a:start_addr . a:stop_addr
  endif

  let l:gdb_cmd = printf("dump binary memory %s %s (char*)%s", l:temp_file_mem_dump, a:start_addr, l:stop_addr_normal)
  call TermDebugSendCommand(l:gdb_cmd)
  sleep 100m

  execute 'Memvwr'
  call MemvwrFromFile(l:temp_file_mem_dump, l:start_addr_value)

  let s:last_start_addr = a:start_addr
  let s:last_stop_addr  = a:stop_addr
  call delete(l:temp_file_start_addr_dump)
  call delete(l:temp_file_mem_dump)
endfunction


"------------------------------
" Commands and maps
"
command! -nargs=+ MemvwrTdbg        call MemvwrTdbgSetView(<f-args>)
command!          MemvwrTdbgRefresh if !empty(s:last_start_addr) | call MemvwrTdbgSetView(s:last_start_addr, s:last_stop_addr) | endif
