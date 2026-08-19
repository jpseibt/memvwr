" Plugin:      Memvwr
" Author:      J. Paulo Seibt <jpseibt@gmail.com>
" Created:     2026 Aug 10
" License:     MIT (https://opensource.org/license/mit/)
" Last Change: 2026 Aug 18

" ~ naz: started as part of my personal vimrc to be used as a dedicated
"        memory viewer window for termdebug, inspired by the one present
"        in the raddbg and the termdebug disassembly window.
"        First draft and commits for reference:
"        [2026-08-10] First: github.com/jpseibt/nazfig_repo/commits/2fe1eac
"        [2026-08-18] Last:  github.com/jpseibt/nazfig_repo/commits/547a72b

if exists('g:loaded_memvwr') | finish | endif
let g:loaded_memvwr = 1

"============================================================
" Memory Viewer (Memvwr)
"============================================================
" TODO notes:
" [ ] consider changing namespace style variables (s:memvwr_bufnr) for
"     a s:memvwr dict, maybe one for "private" state and other for config.
" [x] strip leading zeros or prefix from addresses (option).
" [ ] width change (option: grouping bytes).
" [ ] make reformat commands/function smarter, without redoing all the work
"     or generating all the fields again, based on the option. Like changing
"     the address style by editing the buffer lines, but only acting on the
"     columns up to the bytes start column.
" [ ] maybe each field could be stored in a List (address, byte, ascii), their
"  ^  strings, that is, and track the cursor position and current byte number.
" NOTE: This could make it possible to go crazy like opening one window for each
"       field and keep track of the match highlight without relying on offsets
"       or exact column numbers (a coordinates struct?).
"    -> One possibility would be to allow the user to rearrange the field windows
"       as they see fit, or even customize the "master" window layout by removing
"       a field or having them split into different byte representations. The problem
"       is guaranteeing that the syntax highlighting would work as expected.
"    -> It would be nice to update or highlight only bytes that changed from a
"       previous visualization (step). Even crazier, diffing two views, or whatever.
" [ ] reformat commands should save the cursor location (byte number under cursor)
" [ ] edit values, both from bytes field or ascii preview.
" [ ] create memvwr from file.
" [ ] save to file.
" [ ] poke memory of debuggee (termdebug).
" [ ] add more information about analysed dump: expression, timestamp, ... (termdebug).
" [ ] inspector for byte combinations (uint32_t, double, etc.), maybe with floating
"     windows, like :Eval command from termdebug. (look into `eval()`)
" [ ] maybe an inspector field or window, if it is proven to not slow down cursor
"     movements and highlight matches.(?)
" [ ] command to print byte number under the cursor, could also use floating win.
" [ ] command to jump cursor to N'th byte: from start byte, from byte under the
"     cursor, N'th byte of current row, etc.
" [ ] maybe add a decimal representation style for addresses (byte count).
" [ ] visual mode could match-highlight the bytes selected.
" [ ] select endianness.

if !exists('s:memvwr_name')
  let s:memvwr_name          = '(MEMVWR)'
  let s:memvwr_bufnr         = 0
  let s:memvwr_winid         = 0
  let s:memvwr_blob          = 0z
  let s:memvwr_start_addr    = 0x0
  let s:memvwr_bytes_per_row = 16
  let s:memvwr_fmt           = 'hex'
  let s:memvwr_fmt_width     = 2 "ff a8 8b " (width without separator ' ')
  let s:memvwr_addr_style    = 0

  "------------------------------
  " UI & Layout
  "
  " winbar is used to display the header on Neovim, but the statusline is used on Vim (so it's a footer -_-)
  let s:memvwr_addr_label_cache = 'MEMVWR     Address'
  let s:memvwr_header_str       = 'MEMVWR     Address   0  1  2  3  4  5  6  7  8  9  A  B  C  D  E  F            ASCII'
                                  "0x0000555555556004: 62 72 65 61 6b 00 63 61 73 65 00 63 68 61 72 00  break.case.char.
                                  "BPR:16              |                                                |
                                  "FMT:hex        col:21                                           col:70
                                  "ADDR_STYLE:0
                                  "           0: full 8 bytes, with '0x' prefix
                                  "           1: full 8 bytes, without prefix
                                  "           2: strip leading zeros (from stop address), always with '0x' prefix
                                  "           3: strip leading zeros (from stop address), without prefix (len > 2)
                                  "           NOTE: a minimum of 4 digits will be used for both styles 2 and 3, but
                                  "                 if the stop address is <= 2 digits long, it will have the prefix.
  let s:memvwr_column_bytes   = 21
  let s:memvwr_column_ascii   = 70
  let s:memvwr_format_strings = {'addr': '0x%16x:', 'bytes': '%02x'}
  let s:memvwr_cursor_match   = [] " [line, column, highlight len]
endif

" TODO: Return config dict, similar to `getwininfo()`
function! MemvwrGetInfo(key='all')
  echomsg '[MemvwrGetInfo()] Not yet ready'
  if a:key == 'bpr'
    return s:memvwr_bytes_per_row
  elseif a:key == 'fmt'
    return s:memvwr_fmt
  elseif a:key == 'addr_style'
    return s:memvwr_addr_style
  else
    return {'bpr': s:memvwr_bytes_per_row, 'fmt': s:memvwr_fmt, 'addr_style': s:memvwr_addr_style, 'format_strings': s:memvwr_format_strings}
  endif
endfunction

" Create and setup buffer/window variables, or goto Memvwr window
function! s:MemvwrOpen()
  if !win_gotoid(s:memvwr_winid)
    execute 'rightbelow new'
    let s:memvwr_winid = win_getid()

    setlocal filetype=memvwr
    setlocal syntax=memvwr
    setlocal nowrap
    setlocal number
    setlocal norelativenumber
    setlocal noswapfile
    setlocal buftype=nofile
    setlocal signcolumn=no
    setlocal modifiable
    if has('nvim')
      setlocal winbar=%!MemvwrHeaderSlice()
    else
      setlocal statusline=%!MemvwrHeaderSlice()
    endif

    if s:memvwr_bufnr > 0 && bufexists(s:memvwr_bufnr)
      execute 'buffer ' . s:memvwr_bufnr
    else
      execute 'silent file ' . s:memvwr_name
      let s:memvwr_bufnr = bufnr(s:memvwr_name)
      echomsg '[s:MemvwrOpen] New buffer [' . s:memvwr_bufnr . '] assigned to ' . s:memvwr_name
    endif
  endif
endfunction

" Format field column headers. Example of 16 bytes per row in 'hex' format:
"           Address   0  1  2  3  4  5  6  7  8  9  A  B  C  D  E  F             ASCII
"0x0000555555556004: 62 72 65 61 6b 00 63 61 73 65 00 63 68 61 72 00  break.case.char.
function! s:MemvwrUpdateHeaderString()
  let l:header_str = s:memvwr_addr_label_cache . ' '

  for l:byte_field in range(s:memvwr_bytes_per_row)
    let l:header_str .= printf(" %*X", s:memvwr_fmt_width, l:byte_field)
  endfor

  let l:header_str .= printf('  %*s', s:memvwr_bytes_per_row, 'ASCII')

  " Save header string
  let s:memvwr_header_str = l:header_str
endfunction

" NOTE: look `:help statusline`, `:help winbar`, `:help winsaveview()`, `:help winwidth()`, and `:help getwininfo()`
" Evaluate padding required for line numbers, folds, etc., and slice viewport horizontal scroll offset
function! MemvwrHeaderSlice()
  if win_id2win(s:memvwr_winid) <= 0 | return '' | endif
  let l:wininfo = getwininfo(s:memvwr_winid)
  let l:leftcol = l:wininfo[0].leftcol
  let l:textoff = l:wininfo[0].textoff
  let l:padding = repeat(' ', l:textoff)
  let l:header_slice_normal = l:padding . slice(s:memvwr_header_str, l:leftcol)
  " Append `%<` to truncate the line at the end if too long
  return l:header_slice_normal . '%<'
endfunction

" Update format strings, and header string caches, bytes / ASCII start column, 
function! s:MemvwrUpdateLayout()
  let l:addr_format_str  = ''
  let l:bytes_format_str = ''

  "------------------------------
  " Address format string and address label cache
  " (see -UI & Layout- for address style reference)
  "
  if s:memvwr_addr_style > 3
    echomsg '[MemvwrFromBlob] Invalid ADDR_STYLE "' . s:memvwr_addr_style . '". Using default 0.'
    let s:memvwr_addr_style = 0
  endif

  if s:memvwr_addr_style == 0
    let l:addr_format_str = '0x%016x:'
  elseif s:memvwr_addr_style == 1
    let l:addr_format_str = '%016x:'
  else " style 2 or 3
    let l:len_stop_addr  = strlen(printf("%x", s:memvwr_start_addr + len(s:memvwr_blob)))
    if s:memvwr_addr_style == 2
      if l:len_stop_addr < 2 | let l:len_stop_addr = 2 | endif
      let l:addr_format_str = '0x'
    elseif l:len_stop_addr < 4
      " style 3
      let l:len_stop_addr = 4
    endif
    let l:addr_format_str .= '%0' . l:len_stop_addr . 'x:'
  endif

  " Pick address label based on available columns
  " 18+: 'MEMVR      Address', 16+: 'MEMVWR   Address', 7+: 'Address', 4+: 'Addr', or nothing
  let l:len_addr_label = strlen(printf(l:addr_format_str, ' ')) - 1 " minus ':'
  let l:addr_label = (l:len_addr_label >= 18) ? 'MEMVR      Address'
                 \ : (l:len_addr_label >= 16) ? 'MEMVWR   Address'
                 \ : (l:len_addr_label >= 7)  ? 'Address'
                 \ : (l:len_addr_label >= 4)  ? 'Addr'
                 \ :                            ' '
  let s:memvwr_addr_label_cache = printf("%*s", l:len_addr_label, l:addr_label)

  "------------------------------
  " Bytes format string
  "
  if s:memvwr_fmt == 'x' || s:memvwr_fmt == 'hex'
    let l:bytes_format_str = '%02x'
    let s:memvwr_fmt_width = 2
  elseif s:memvwr_fmt == 'b' || s:memvwr_fmt == 'bin'
    let l:bytes_format_str = '%08b'
    let s:memvwr_fmt_width = 8
  elseif s:memvwr_fmt == 'd' || s:memvwr_fmt == 'dec'
    let l:bytes_format_str = '%3d'
    let s:memvwr_fmt_width = 3
  elseif s:memvwr_fmt == 'o' || s:memvwr_fmt == 'oct'
    let l:bytes_format_str = '%3o'
    let s:memvwr_fmt_width = 3
  else
    echomsg '[MemvwrFromBlob] Invalid FMT "' . s:memvwr_fmt . '". Using fallback.'
    let s:memvwr_fmt = 'fallback'
    let l:bytes_format_str = '0x%02x'
    let s:memvwr_fmt_width = 4
  endif

  " Update format strings dict, bytes and ASCII preview start column
  let s:memvwr_column_bytes = strlen(printf(l:addr_format_str, ' ')) + 2 " plus ': ' length
  let s:memvwr_column_ascii = s:memvwr_column_bytes + s:memvwr_bytes_per_row * (s:memvwr_fmt_width + 1) + 1
  let s:memvwr_format_strings['addr']  = l:addr_format_str
  let s:memvwr_format_strings['bytes'] = l:bytes_format_str
endfunction

function! MemvwrFromBlob(blob, start_addr, bytes_per_row=16, fmt='x', addr_style=0)
  let l:blob_len = len(a:blob)
  if l:blob_len < 1
    " TODO: echomsg here or handle this
    return
  endif

  " Save (and normalize) arguments
  let s:memvwr_blob          = a:blob
  let s:memvwr_start_addr    = a:start_addr
  let s:memvwr_bytes_per_row = (a:bytes_per_row > 0) ? a:bytes_per_row : 1
  let s:memvwr_fmt           = a:fmt
  let s:memvwr_addr_style    = a:addr_style

  " Construct format strings, and update bytes / ASCII start column and header string caches
  call s:MemvwrUpdateLayout()
  call s:MemvwrUpdateHeaderString()

  let l:bytes_format_str = s:memvwr_format_strings['bytes']
  let l:addr_format_str  = s:memvwr_format_strings['addr']

  "------------------------------
  " Generate rows iterating over blob
  " (byte index = i + j).
  "
  let l:mem_lines  = []
  let i = 0
  while i < l:blob_len
    let l:bytes_str = ''
    let l:ascii_str  = ''

    let j = 0
    while j < s:memvwr_bytes_per_row
      if j + i < l:blob_len
        let l:byte_val    = s:memvwr_blob[i+j]
        let l:bytes_str .= printf(' ' . l:bytes_format_str, l:byte_val)

        if l:byte_val >= 33 && l:byte_val <= 126
          let l:ascii_str .= nr2char(l:byte_val)
        else
          let l:ascii_str .= '.'
        endif
      else
        " Pad with spaces
        let l:bytes_str .= printf(" %*s", s:memvwr_fmt_width, ' ')
        let l:ascii_str .= ' '
      endif
      let j += 1
    endwhile

    " Append row to lines list: [address:][ bytes]  [ASCII]
    call add(l:mem_lines, printf(l:addr_format_str . "%s  %s", s:memvwr_start_addr+i, l:bytes_str, l:ascii_str))
    let i += j
  endwhile

  " Add info line at the end
  call add(l:mem_lines, printf("End of memory dump. START:0x%x | BYTES:%d | BPR:%d | FMT:%s | ADDR_STYLE:%s",
                             \ a:start_addr, l:blob_len, s:memvwr_bytes_per_row, s:memvwr_fmt, s:memvwr_addr_style))

  " Clear entire buffer and write l:mem_lines to it
  silent call deletebufline(s:memvwr_bufnr, 1, '$')
  call setbufline(s:memvwr_bufnr, 1, l:mem_lines)
endfunction

function! MemvwrFromFile(fname, bytes_per_row=16, fmt='x', addr_style=0)
  let l:blob = readblob(a:fname)
  if empty(l:blob)
    echomsg '[MemvwrFromFile] Empty blob from readblob("' . a:fname . '"). Aborting...'
    return
  endif
  call MemvwrFromBlob(l:blob, 0, s:memvwr_bytes_per_row, s:memvwr_fmt, s:memvwr_addr_style)
endfunction

" NOTE: see `:help matchaddpos()`
function! s:MemvwrCursorMatchByteAndASCII()
  call clearmatches()
  let s:memvwr_cursor_match = []

  if win_getid() != s:memvwr_winid | return | endif
  let l:cursor_col = col('.')
  if l:cursor_col < s:memvwr_column_bytes || l:cursor_col == s:memvwr_column_ascii - 1 | return | endif

  " Real field width of byte values with separator (0a.0b.0c.)
  let l:fmt_width_plus_sep = s:memvwr_fmt_width + 1

  if l:cursor_col < s:memvwr_column_ascii
    " Byte values to ASCII preview
    let x = l:cursor_col - s:memvwr_column_bytes
    let l:byte_number = x / l:fmt_width_plus_sep

    " Check if the cursor didn't land on a separator
    if (x + 1) / l:fmt_width_plus_sep != l:byte_number | return | endif

    let s:memvwr_cursor_match = [line('.'), col('$') - s:memvwr_bytes_per_row + l:byte_number, 1]
    call matchaddpos('MatchParen', [s:memvwr_cursor_match])
  else
    " ASCII preview to bytes values
    let l:byte_number = l:cursor_col - s:memvwr_column_ascii
    let s:memvwr_cursor_match = [line('.'), s:memvwr_column_bytes + l:byte_number * l:fmt_width_plus_sep, s:memvwr_fmt_width]
    call matchaddpos('MatchParen', [s:memvwr_cursor_match])
  endif
endfunction

function! s:MemvwrJumpCursorMatch()
  if win_getid() == s:memvwr_winid && !empty(s:memvwr_cursor_match)
    call cursor(s:memvwr_cursor_match[0], s:memvwr_cursor_match[1])
  endif
endfunction

"------------------------------
" Commands and maps
"
command!          Memvwr        call s:MemvwrOpen()
command!          MemvwrReset   call s:MemvwrOpen() | call MemvwrFromBlob(s:memvwr_blob, s:memvwr_start_addr)
command!          MemvwrRegen   call s:MemvwrOpen() | call MemvwrFromBlob(s:memvwr_blob, s:memvwr_start_addr, s:memvwr_bytes_per_row, s:memvwr_fmt, s:memvwr_addr_style)
command! -nargs=1 MemvwrReblob  call s:MemvwrOpen() | call MemvwrFromBlob(<args>, s:memvwr_start_addr, s:memvwr_bytes_per_row, s:memvwr_fmt, s:memvwr_addr_style)
command! -nargs=1 MemvwrReaddr  call s:MemvwrOpen() | call MemvwrFromBlob(s:memvwr_blob, <args>, s:memvwr_bytes_per_row, s:memvwr_fmt, s:memvwr_addr_style)
command! -nargs=1 MemvwrRebpr   call s:MemvwrOpen() | call MemvwrFromBlob(s:memvwr_blob, s:memvwr_start_addr, <args>, s:memvwr_fmt, s:memvwr_addr_style)
command! -nargs=1 MemvwrRefmt   call s:MemvwrOpen() | call MemvwrFromBlob(s:memvwr_blob, s:memvwr_start_addr, s:memvwr_bytes_per_row, <q-args>, s:memvwr_addr_style)
command! -nargs=1 MemvwrRestyle call s:MemvwrOpen() | call MemvwrFromBlob(s:memvwr_blob, s:memvwr_start_addr, s:memvwr_bytes_per_row, s:memvwr_fmt, <args>)

command! -nargs=1 -complete=file MemvwrFopen call s:MemvwrOpen() | call MemvwrFromFile(<q-args>, s:memvwr_bytes_per_row, s:memvwr_fmt, s:memvwr_addr_style)

augroup MemvwrAUG
  autocmd!
  autocmd FileType memvwr autocmd CursorMoved <buffer> call s:MemvwrCursorMatchByteAndASCII()
  autocmd FileType memvwr nnoremap   <silent> <buffer> % :call <SID>MemvwrJumpCursorMatch()<CR>
augroup END

"------------------------------
" Temp / Debug - remove later
"
func! DebugMemvwr()
  echomsg '----------------'
  echomsg printf("%-*s", 28, 's:memvwr_name:')              . s:memvwr_name
  echomsg printf("%-*s", 28, 's:memvwr_bufnr:')             . s:memvwr_bufnr
  echomsg printf("%-*s", 28, 's:memvwr_winid:')             . s:memvwr_winid
  echomsg printf("%-*s", 28, 's:memvwr_blob:')              . string(s:memvwr_blob)
  echomsg printf("%-*s", 28, 's:memvwr_start_addr:')        . s:memvwr_start_addr
  echomsg printf("%-*s", 28, 's:memvwr_bytes_per_row:')     . s:memvwr_bytes_per_row
  echomsg printf("%-*s", 28, 's:memvwr_fmt:')               . s:memvwr_fmt
  echomsg printf("%-*s", 28, 's:memvwr_fmt_width:')         . s:memvwr_fmt_width
  echomsg printf("%-*s", 28, 's:memvwr_addr_style:')        . s:memvwr_addr_style
  echomsg printf("%-*s", 28, 's:memvwr_header_str:')        . s:memvwr_header_str
  echomsg printf("%-*s", 28, 's:memvwr_addr_label_cache:')  . s:memvwr_addr_label_cache
  echomsg printf("%-*s", 28, 's:memvwr_column_bytes:')      . s:memvwr_column_bytes
  echomsg printf("%-*s", 28, 's:memvwr_column_ascii:')      . s:memvwr_column_ascii
  echomsg printf("%-*s", 28, 's:memvwr_format_strings:')    . string(s:memvwr_format_strings)
  echomsg printf("%-*s", 28, 's:memvwr_cursor_match:')      . string(s:memvwr_cursor_match)
  echomsg '----------------'
endfunc

" NOTE: see `:help type()` and `:help a:000` (only string args)
func! s:Mem(...)
  let l:start_addr    = s:memvwr_start_addr    " flag:'s' idx:0
  let l:bytes_per_row = s:memvwr_bytes_per_row " flag:'n' idx:1
  let l:fmt           = s:memvwr_fmt           " flag:'f' idx:2
  let l:addr_style    = s:memvwr_addr_style    " flag:'a' idx:3
  let l:flags = [0, 1, 2, 3]
  let l:idx   = -1

  for l:arg in a:000
    if l:arg[0] == 's'
      let l:idx = 0
    elseif l:arg[0] == 'n'
      let l:idx = 1
    elseif l:arg[0] == 'f'
      let l:idx = 2
    elseif l:arg[0] == 'a'
      let l:idx = 3
    endif
    if l:idx >= 0 | let l:arg = slice(l:arg, 1) | endif

    let x = str2nr(l:arg, 10)

    if l:idx == 0
      let l:start_addr = x
    elseif l:idx == 1
      let l:bytes_per_row = x
    elseif l:idx == 2
      let l:fmt = l:arg
    elseif l:idx == 3
      let l:addr_style = x
    else
      if x > 0
        let l:bytes_per_row = x
      else
        let l:fmt = l:arg
      endif
    endif
  endfor

  echo printf("%-*s", 18, 'l:start_addr:')    . l:start_addr
  echo printf("%-*s", 18, 'l:bytes_per_row:') . l:bytes_per_row
  echo printf("%-*s", 18, 'l:fmt:')           . l:fmt
  echo printf("%-*s", 18, 'l:addr_style:')    . l:addr_style
  call MemvwrFromBlob(s:memvwr_blob, l:start_addr, l:bytes_per_row, l:fmt, l:addr_style)
endfunc
command! -nargs=* Mem call s:MemvwrOpen() | call s:Mem(<f-args>)
