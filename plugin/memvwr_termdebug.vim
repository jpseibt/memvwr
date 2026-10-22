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
" [ ] remove `sleep` calls (maybe GDB/MI solve this).
" [x] add cursor area evaluation.
" [ ] add hotkeys with `setup/teardown` approach.
"  ^- NOTE: maybe it could be an option like `g:termdebug_config['map_K']`.
" [_] memvwr update solution, aware of current address space. Currently, there is a refresh command that
"  ^  should work even in different stack frames, as the start and stop addressess are normalized.
" NOTE: maybe an option to re-TdbgSetMemvwr() on each breakpoint.
" [ ] look into GDB/MI interface (https://sourceware.org/gdb/current/onlinedocs/gdb.html/GDB_002fMI.html).

let s:gdb_dump_is_little_endian = 1
let s:last_start_addr = ''
let s:last_stop_addr  = ''

function! MemvwrTdbgSetView(start_addr, stop_addr)
  "------------------------------
  " Normalize START address
  "
  let l:start_addr_value = -1

  " Check if START is already a hex literal string
  if type(a:start_addr) == v:t_string && a:start_addr =~? '^0x[0-9a-f]\+$'
    let l:start_addr_value = str2nr(a:start_addr, 16)
  endif

  " If START is an expression, evaluate start address from GDB value dump
  if l:start_addr_value == -1
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
    call delete(l:temp_file_start_addr_dump)
  endif

  let l:start_addr_hex_str = printf("0x%x", l:start_addr_value)

  "------------------------------
  " Normalize STOP address
  "
  let l:stop_addr_normal = ''

  if type(a:stop_addr) == v:t_string
    if a:stop_addr[0] == '+'
      let l:stop_addr_normal = l:start_addr_hex_str . a:stop_addr
    elseif a:stop_addr =~? '^0x[0-9a-f]\+$'
      let l:stop_addr_normal = a:stop_addr
    else
      " Evaluate stop address expression from GDB value dump
      let l:temp_file_stop_addr_dump = tempname()
      let l:gdb_cmd = printf("dump binary value %s (unsigned long long)%s", l:temp_file_stop_addr_dump, a:stop_addr)
      call TermDebugSendCommand(l:gdb_cmd)
      sleep 100m

      let l:stop_addr_blob = readblob(l:temp_file_stop_addr_dump)
      if empty(l:stop_addr_blob)
        echomsg '[MemvwrTdbgSetView] Empty blob from readblob("' . l:temp_file_stop_addr_dump . '"). Aborting...'
        call delete(l:temp_file_stop_addr_dump)
        return
      endif

      let l:stop_addr_value  = MemvwrParseUint64(l:stop_addr_blob, s:gdb_dump_is_little_endian)
      let l:stop_addr_normal = printf("0x%x", l:stop_addr_value)
      call delete(l:temp_file_stop_addr_dump)
    endif
  else
    let l:stop_addr_normal = printf("0x%x", l:stop_addr)
  endif

  if empty(l:stop_addr_normal) | let l:stop_addr_normal = l:start_addr_hex_str . '+1' | endif

  "------------------------------
  " Setup Memvwr from GDB memory dump
  "
  let l:temp_file_mem_dump = tempname()

  let l:gdb_cmd = printf("dump binary memory %s %s (char*)%s", l:temp_file_mem_dump, l:start_addr_hex_str, l:stop_addr_normal)
  call TermDebugSendCommand(l:gdb_cmd)
  sleep 100m

  execute 'Memvwr'
  call MemvwrFromFile(l:temp_file_mem_dump, l:start_addr_value)
  call delete(l:temp_file_mem_dump)

  let s:last_start_addr = l:start_addr_hex_str
  let s:last_stop_addr  = l:stop_addr_normal
endfunction

" Return a string with the last visual selection or the under-the-cursor area.
" Example command using <range> to dynamically pass an expression to a function:
"   > command! -range=0 ThisExpr call FuncExpectingExpr(GetVisualOrCursorArea(<range>))
"   > :ThisExpr        | under the cursor
"   > :'<,'>ThisExpr   | last visual selection
"   > :64ThisExpr      | also last visual selection (the default -range=0 is used like a flag)
" NOTE: see `:help gv` - the unnamed register (@") is used to store the visual selection area.
function! s:GetVisualOrCursorArea(range)
  let l:area = ''
  if a:range == 0
    " Assume Normal mode
    let l:area = expand('<cword>')
  else
    " Assume Visual mode
    silent normal! gv""y
    let l:area = trim(@")
  endif
  return tr(l:area, "\n", ' ')
endfunction

"------------------------------
" Commands and maps
"
command! -nargs=+ MemvwrTdbg        call MemvwrTdbgSetView(<f-args>)
command! -range=0 MemvwrTdbgThis    call MemvwrTdbgSetView(s:GetVisualOrCursorArea(<range>), '+1024')
command! -range=0 MemvwrTdbgAround  call MemvwrTdbgSetView(s:GetVisualOrCursorArea(<range>) . '-512', '+1024')
command!          MemvwrTdbgRefresh if !empty(s:last_start_addr) | call MemvwrTdbgSetView(s:last_start_addr, s:last_stop_addr) | endif
