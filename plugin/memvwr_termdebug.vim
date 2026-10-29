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
" [x] add cursor area evaluation.
" [ ] add hotkeys with `setup/teardown` approach.
"  ^- NOTE: maybe it could be an option like `g:termdebug_config['map_K']`.
" [_] memvwr update solution, aware of current address space. Currently, there is a refresh command that
"  ^  should work even in different stack frames, as the start and stop addressess are normalized.
" NOTE: maybe an option to re-TdbgSetMemvwr() on each breakpoint.
" [ ] look into GDB/MI interface (https://sourceware.org/gdb/current/onlinedocs/gdb.html/GDB_002fMI.html).

let s:gdb_dump_is_little_endian = 1
let s:last_byte_count = 0
let s:last_start_addr_hex_str = ''
let s:last_stop_addr_hex_str  = ''

" Uses GDB's `dump binary ...` and read it from disk
function! s:MemvwrTdbgSetView(start_addr, byte_count)
  "------------------------------
  " Normalize START and STOP address
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

    " Try to read binary dump file written by GDB
    let l:counter     = 0
    let l:counter_max = 10
    while getfsize(l:temp_file_start_addr_dump) <= 0 && l:counter < l:counter_max
      let l:counter += 1
      sleep 10
    endwhile

    sleep 10
    let l:start_addr_blob = readblob(l:temp_file_start_addr_dump)
    if empty(l:start_addr_blob)
      echomsg '[s:MemvwrTdbgSetView] Empty blob from readblob("' . l:temp_file_start_addr_dump . '"). Aborting...'
      echomsg "\t GDB Command: " . l:gdb_cmd
      call delete(l:temp_file_start_addr_dump)
      return
    endif

    let l:start_addr_value = MemvwrParseUint64(l:start_addr_blob, s:gdb_dump_is_little_endian)
    call delete(l:temp_file_start_addr_dump)
  endif

  let l:start_addr_hex_str = printf("0x%x", l:start_addr_value)
  let l:stop_addr_hex_str  = printf("0x%x", l:start_addr_value + a:byte_count)

  "------------------------------
  " Setup Memvwr from GDB memory dump
  "
  let l:temp_file_mem_dump = tempname()
  let l:gdb_cmd = printf("dump binary memory %s %s (char*)%s", l:temp_file_mem_dump, l:start_addr_hex_str, l:stop_addr_hex_str)
  call TermDebugSendCommand(l:gdb_cmd)

   " Try to read binary dump file written by GDB
  let l:counter     = 0
  let l:counter_max = 10
  while getfsize(l:temp_file_mem_dump) <= 0 && l:counter < l:counter_max
    let l:counter += 1
    sleep 10
  endwhile

  sleep 10
  let l:mem_blob = readblob(l:temp_file_mem_dump)
  if empty(l:mem_blob)
    echomsg '[s:MemvwrTdbgSetView] Empty blob from readblob("' . l:temp_file_mem_dump . '"). Aborting...'
    echomsg "\t GDB Command: " . l:gdb_cmd
    call delete(l:temp_file_mem_dump)
    return
  endif

  call MemvwrFromBlob(l:temp_file_mem_dump, l:start_addr_value)
  call delete(l:temp_file_mem_dump)

  " Save it for refresh
  let s:last_byte_count         = a:byte_count
  let s:last_start_addr_hex_str = l:start_addr_hex_str
  let s:last_stop_addr_hex_str  = l:stop_addr_hex_str
endfunction

"==================================================
" Termdebug's GDB/MI Hook
"==================================================
" $VIMRUNTIME/pack/dist/opt/termdebug/plugin/termdebug.vim:
" ` ...
" #ADD
" func TermDebugSendCommandInternal(cmd)
"   call s:SendCommand(a:cmd)
" endfunc
" #END
"
" func TermDebugSendCommand(cmd)
"  ...
"
" func s:CommOutput(job_id, msgs, event)
"  ...
"  elseif msg =~ '^\^done,variables='
"  call s:HandleVariablesMsg(msg)
" #ADD
"  elseif msg =~ '^\^done,memory='
"    call MemvwrTdbgGDBCommOutput(msg)
" #END
"  endif
"  ... `
"
" Example msg_str from GDB/MI:
"   ^done,memory=[{begin="0xbffff154",offset="0x00000000",end="0xbffff15e",contents="01000000020000000300"}]
"

" NOTE: for now, this function is only called from `termdebug.vim -> CommOutput()`
function! MemvwrTdbgGDBCommOutput(msg_str)
  " Parse the MI output into a dict
  let l:dict = {}

  let l:begin_idx_start = matchend(a:msg_str, 'begin="')
  let l:begin_idx_end   = matchend(a:msg_str, '"', l:begin_idx_start) - 2
  let l:dict['begin']   = a:msg_str[l:begin_idx_start : l:begin_idx_end]

  let l:offset_idx_start = matchend(a:msg_str, 'offset="', l:begin_idx_end)
  let l:offset_idx_end   = matchend(a:msg_str, '"', l:offset_idx_start) - 2
  let l:dict['offset']   = a:msg_str[l:offset_idx_start : l:offset_idx_end]

  let l:end_idx_start = matchend(a:msg_str, 'end="', l:offset_idx_end)
  let l:end_idx_end   = matchend(a:msg_str, '"', l:end_idx_start) - 2
  let l:dict['end']   = a:msg_str[l:end_idx_start : l:end_idx_end]

  let l:contents_idx_start = matchend(a:msg_str, 'contents="', l:end_idx_end)
  let l:contents_idx_end   = matchend(a:msg_str, '"', l:contents_idx_start) - 2
  let l:dict['contents']   = a:msg_str[l:contents_idx_start : l:contents_idx_end]

  let l:blob = eval('0z' . l:dict['contents'])
  "echomsg string(l:dict)

  let l:start_addr_value = str2nr(l:dict['begin'], 16)
  let l:stop_addr_value  = str2nr(l:dict['end'], 16)

  call MemvwrFromBlob(l:blob, l:start_addr_value)

  " Save it for refresh
  let s:last_byte_count         = l:stop_addr_value - l:start_addr_value
  let s:last_start_addr_hex_str = l:dict['begin']
  let s:last_stop_addr_hex_str  = l:dict['end']
endfunction

function! s:MemvwrTdbgSetViewComm(start_addr, bytes)
  let l:gdb_cmd = printf("interpreter-exec mi \"-data-read-memory-bytes %s %d\"", a:start_addr, a:bytes)
  call TermDebugSendCommandInternal(l:gdb_cmd)
  " if the command succeeds, termdebug should forward the output msg from GDB/MI using MemvwrTdbgGDBCommOutput()
endfunction


"------------------------------
" Commands and maps
"
function! s:MemvwrTdbgSetup()
  command! -nargs=+ MemvwrTdbg            call s:MemvwrTdbgSetView(<f-args>)
  command! -range=0 MemvwrTdbgThis        call s:MemvwrTdbgSetView(s:GetVisualOrCursorArea(<range>), '1024')
  command! -range=0 MemvwrTdbgAround      call s:MemvwrTdbgSetView(s:GetVisualOrCursorArea(<range>) . '-512', '1024')
  command!          MemvwrTdbgRefresh     if !empty(s:last_start_addr_hex_str) | call s:MemvwrTdbgSetView(s:last_start_addr_hex_str, s:last_byte_count) | endif

  " Check if it is possible to hook into the termdebug GDB/MI communication setup
  if exists('*TermDebugSendCommandInternal')
    command! -nargs=+ MemvwrTdbgComm        call s:MemvwrTdbgSetViewComm(<f-args>)
    command! -range=0 MemvwrTdbgCommThis    call s:MemvwrTdbgSetViewComm(s:GetVisualOrCursorArea(<range>), '1024')
    command! -range=0 MemvwrTdbgCommAround  call s:MemvwrTdbgSetViewComm(s:GetVisualOrCursorArea(<range>) . '-512', '1024')
    command!          MemvwrTdbgCommRefresh if !empty(s:last_start_addr_hex_str) | call s:MemvwrTdbgSetViewComm(s:last_start_addr_hex_str, s:last_byte_count) | endif
  endif

  if exists('#User#MemvwrTdbgSetup')
    doautocmd <nomodeline> User MemvwrTdbgSetup
  endif
endfunction

function! s:MemvwrTdbgTearDown()
  delcommand MemvwrTdbg
  delcommand MemvwrTdbgThis
  delcommand MemvwrTdbgAround
  delcommand MemvwrTdbgRefresh

  if exists(':MemvwrTdbgComm')
    delcommand MemvwrTdbgComm
    delcommand MemvwrTdbgCommThis
    delcommand MemvwrTdbgCommAround
    delcommand MemvwrTdbgCommRefresh
  endif

  if exists('#User#MemvwrTdbgTearDown')
    doautocmd <nomodeline> User MemvwrTdbgTearDown
  endif
endfunction

augroup MemvwrTdbgAUG
  autocmd!
  autocmd User TermdebugStartPost call s:MemvwrTdbgSetup()
  autocmd User TermdebugStopPre   call s:MemvwrTdbgTearDown()
augroup END


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
