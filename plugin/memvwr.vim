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
" [x] strip leading zeros or prefix from addresses (option).
" [ ] width change (option: grouping bytes).
"  ^- NOTE: maybe should keep things simple and focus on having all aspects
"           of individual bytes representation and operations predictable.
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
" [x] create memvwr from file.
" [ ] save to file.
" [ ] poke memory of debuggee (termdebug).
" [ ] add more information about analysed dump: expression, timestamp, ... (termdebug).
" [x] inspector for byte combinations (uint32_t, double, etc.), maybe with floating
"     windows, like :Eval command from termdebug. (look into `eval()`)
" [x] maybe an inspector field or window, if it is proven to not slow down cursor
"     movements and highlight matches.(?)
" [x] command to print byte number under the cursor, could also use floating win.
" [x] command to jump cursor to N'th byte: from start byte, from byte under the
"     cursor, N'th byte of current row, etc.
" [ ] maybe add a decimal representation style for addresses (byte count).
" [ ] visual mode could match-highlight the bytes selected.
" [x] select endianness.
" [ ] clean integration with termdebug.
" [ ] be aware of the bits used by Vim's Number type (see `:help v:numbersize` and `:help Number`)
"  ^- NOTE: Without checking this, the inspector is half broken on systems where Number is a
"           32-bit signed int (the current inspector is assuming 64-bit).

let s:memvwr_name          = '(MEMVWR)'
let s:memvwr_bufnr         = 0
let s:memvwr_winid         = 0
let s:memvwr_blob          = 0z
let s:memvwr_blob_len      = 0
let s:memvwr_start_addr    = 0x0
let s:memvwr_bytes_per_row = 16
let s:memvwr_fmt           = 'hex'
let s:memvwr_fmt_width     = 2 "ff a8 8b " (width without separator ' ')

"------------------------------
" UI & Layout
"
" winbar is used to display the header on Neovim, but the statusline is used on Vim (so it's a footer -_-)
let s:memvwr_addr_style       = 2
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
let s:memvwr_column_bytes     = 21
let s:memvwr_column_ascii     = 70
let s:memvwr_format_str_addr  = '0x%16x'
let s:memvwr_format_str_bytes = '%02x'
let s:memvwr_cursor_line      = line('.')
let s:memvwr_cursor_col       = col('.')
let s:memvwr_cursor_is_valid  = 0
let s:memvwr_cursor_blob_idx  = -1
let s:memvwr_cursor_match_col = -1
let s:memvwr_cursor_match_len = -1

"------------------------------
" Data visualization & Pop-up Windows
"
let s:memvwr_is_little_endian = 1
let s:memvwr_endianness_label = ['Big-Endian', 'Little-Endian']

let s:memvwr_win_info_name  = '(MEMVWR -INFO WINDOW-)'
let s:memvwr_win_info_bufnr = 0
let s:memvwr_win_info_winid = 0

let s:memvwr_popup_info_name  = '(MEMVWR -INFO-)'
let s:memvwr_popup_info_bufnr = 0
let s:memvwr_popup_info_winid = 0

let s:memvwr_popup_inspector_name  = '(MEMVWR -INSPECTOR-)'
let s:memvwr_popup_inspector_bufnr = 0
let s:memvwr_popup_inspector_winid = 0

let s:f32_sign     = 0
let s:f32_exponent = 0
let s:f32_mantissa = 0
let s:f32_type     = '_' " [Normal, Infinity, NaN, Zero, Subnormal]
let s:f64_sign     = 0
let s:f64_exponent = 0
let s:f64_mantissa = 0
let s:f64_type     = '_' " [Normal, Infinity, NaN, Zero, Subnormal]

" Return a dictionary containing all state and config variables, similar
" to `getwininfo()`, or return them individually.
" NOTE: The returned dictionary is a new allocation, but s:memvwr_blob
"       is passed by reference in both cases. See `:help blob-modification`
function! MemvwrGetInfo(key='all')
  let l:result = {}

  if a:key != 'all'
    if a:key == 'name'
      let l:result = s:memvwr_name
    elseif a:key == 'bufnr'
      let l:result = s:memvwr_bufnr
    elseif a:key == 'winid'
      let l:result = s:memvwr_winid
    elseif a:key == 'blob'
      let l:result = s:memvwr_blob
    elseif a:key == 'blob_len'
      let l:result = s:memvwr_blob_len
    elseif a:key == 'start_addr'
      let l:result = s:memvwr_start_addr
    elseif a:key == 'bytes_per_row'
      let l:result = s:memvwr_bytes_per_row
    elseif a:key == 'fmt'
      let l:result = s:memvwr_fmt
    elseif a:key == 'fmt_width'
      let l:result = s:memvwr_fmt_width
    elseif a:key == 'addr_style'
      let l:result = s:memvwr_addr_style
    elseif a:key == 'addr_label_cache'
      let l:result = s:memvwr_addr_label_cache
    elseif a:key == 'header_str'
      let l:result = s:memvwr_header_str
    elseif a:key == 'column_bytes'
      let l:result = s:memvwr_column_bytes
    elseif a:key == 'column_ascii'
      let l:result = s:memvwr_column_ascii
    elseif a:key == 'format_str_addr'
      let l:result = s:memvwr_format_str_addr
    elseif a:key == 'format_str_bytes'
      let l:result = s:memvwr_format_str_bytes
    elseif a:key == 'cursor_line'
      let l:result = s:memvwr_cursor_line
    elseif a:key == 'cursor_col'
      let l:result = s:memvwr_cursor_col
    elseif a:key == 'cursor_is_valid'
      let l:result = s:memvwr_cursor_is_valid
    elseif a:key == 'cursor_blob_idx'
      let l:result = s:memvwr_cursor_blob_idx
    elseif a:key == 'cursor_match_col'
      let l:result = s:memvwr_cursor_match_col
    elseif a:key == 'cursor_match_len'
      let l:result = s:memvwr_cursor_match_len
    elseif a:key == 'is_little_endian'
      let l:result = s:memvwr_is_little_endian
    elseif a:key == 'win_info_name'
      let l:result = s:memvwr_win_info_name
    elseif a:key == 'win_info_bufnr'
      let l:result = s:memvwr_win_info_bufnr
    elseif a:key == 'win_info_winid'
      let l:result = s:memvwr_win_info_winid
    elseif a:key == 'popup_info_name'
      let l:result = s:memvwr_popup_info_name
    elseif a:key == 'popup_info_bufnr'
      let l:result = s:memvwr_popup_info_bufnr
    elseif a:key == 'popup_info_winid'
      let l:result = s:memvwr_popup_info_winid
    elseif a:key == 'popup_inspector_name'
      let l:result = s:memvwr_popup_inspector_name
    elseif a:key == 'popup_inspector_bufnr'
      let l:result = s:memvwr_popup_inspector_bufnr
    elseif a:key == 'f32_sign'
      let l:result = s:f32_sign
    elseif a:key == 'f32_exponent'
      let l:result = s:f32_exponent
    elseif a:key == 'f32_mantissa'
      let l:result = s:f32_mantissa
    elseif a:key == 'f32_type'
      let l:result = s:f32_type
    elseif a:key == 'f64_sign'
      let l:result = s:f64_sign
    elseif a:key == 'f64_exponent'
      let l:result = s:f64_exponent
    elseif a:key == 'f64_mantissa'
      let l:result = s:f64_mantissa
    elseif a:key == 'f64_type'
      let l:result = s:f64_type
    else
      echomsg '[MemvwrGetInfo] Invalid key argument "' . a:key . '".'
    endif

  else
    let l:result = {
          \   'name': s:memvwr_name
          \ , 'bufnr': s:memvwr_bufnr
          \ , 'winid': s:memvwr_winid
          \ , 'blob': s:memvwr_blob
          \ , 'blob_len': s:memvwr_blob_len
          \ , 'start_addr': s:memvwr_start_addr
          \ , 'bytes_per_row': s:memvwr_bytes_per_row
          \ , 'fmt': s:memvwr_fmt
          \ , 'fmt_width': s:memvwr_fmt_width
          \ , 'addr_style': s:memvwr_addr_style
          \ , 'addr_label_cache': s:memvwr_addr_label_cache
          \ , 'header_str': s:memvwr_header_str
          \ , 'column_bytes': s:memvwr_column_bytes
          \ , 'column_ascii': s:memvwr_column_ascii
          \ , 'format_str_addr': s:memvwr_format_str_addr
          \ , 'format_str_bytes': s:memvwr_format_str_bytes
          \ , 'cursor_line': s:memvwr_cursor_line
          \ , 'cursor_col': s:memvwr_cursor_col
          \ , 'cursor_is_valid': s:memvwr_cursor_is_valid
          \ , 'cursor_blob_idx': s:memvwr_cursor_blob_idx
          \ , 'cursor_match_col': s:memvwr_cursor_match_col
          \ , 'cursor_match_len': s:memvwr_cursor_match_len
          \ , 'is_little_endian': s:memvwr_is_little_endian
          \ , 'win_info_name': s:memvwr_win_info_name
          \ , 'win_info_bufnr': s:memvwr_win_info_bufnr
          \ , 'win_info_winid': s:memvwr_win_info_winid
          \ , 'popup_info_name': s:memvwr_popup_info_name
          \ , 'popup_info_bufnr': s:memvwr_popup_info_bufnr
          \ , 'popup_info_winid': s:memvwr_popup_info_winid
          \ , 'popup_inspector_name': s:memvwr_popup_inspector_name
          \ , 'popup_inspector_bufnr': s:memvwr_popup_inspector_bufnr
          \ , 'popup_inspector_winid': s:memvwr_popup_inspector_winid
          \ , 'f32_sign': s:f32_sign
          \ , 'f32_exponent': s:f32_exponent
          \ , 'f32_mantissa': s:f32_mantissa
          \ , 'f32_type': s:f32_type
          \ , 'f64_sign': s:f64_sign
          \ , 'f64_exponent': s:f64_exponent
          \ , 'f64_mantissa': s:f64_mantissa
          \ , 'f64_type': s:f64_type
          \ }
  endif

  return l:result
endfunction

" Return blob index for a byte and coordinates in a list [blob_idx, line, bytes col, ascii col]
" Modes:
"   0: Absolute | byte at blob index N (0 is the first byte)
"   1: Relative | offset N bytes from current byte under cursor (supports negative N)
"   2: Row Byte | row byte N of the cursor line (0 to bytes_per_row - 1)
function! MemvwrGetByteInfo(number, mode=0)
  let l:result = []
  let l:blob_idx = -1

  if a:mode == 0
    let l:blob_idx = a:number

  elseif win_getid() == s:memvwr_winid
    if a:mode == 1 && s:memvwr_cursor_is_valid
      let l:blob_idx = s:memvwr_cursor_blob_idx + a:number

    elseif a:mode == 2 && a:number >= 0 && a:number < s:memvwr_bytes_per_row
      let l:blob_idx = (s:memvwr_cursor_line - 1) * s:memvwr_bytes_per_row + a:number

    endif
  endif

  if l:blob_idx >= 0 && l:blob_idx < s:memvwr_blob_len
    let l:line = l:blob_idx / s:memvwr_bytes_per_row + 1
    let l:row_byte_number = l:blob_idx % s:memvwr_bytes_per_row

    let l:bytes_col = s:memvwr_column_bytes + l:row_byte_number * (s:memvwr_fmt_width + 1)
    let l:ascii_col = s:memvwr_column_ascii + l:row_byte_number
    let l:result = [l:blob_idx, l:line, l:bytes_col, l:ascii_col]
  endif

  return l:result
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
    setlocal undolevels=-1
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

" Format field column headers. Example of 16 bytes per row in 'hex' format, style 0:
"MEMVWR     Address   0  1  2  3  4  5  6  7  8  9  A  B  C  D  E  F             ASCII
"0x0000555555556004: 62 72 65 61 6b 00 63 61 73 65 00 63 68 61 72 00  break.case.char.
" TODO: consider moving to the UpdateLayout() body, if it ends up staying with this
"       simple and straight forward format, since the cache is already being constructed
"       there, along with the BPR update, and this function depends on both.
function! s:MemvwrUpdateHeaderString()
  let l:header_str = s:memvwr_addr_label_cache . ' '

  for l:byte_field in range(s:memvwr_bytes_per_row)
    let l:header_str .= printf(" %*X", s:memvwr_fmt_width, l:byte_field)
  endfor

  let l:header_str .= printf('  %*s', s:memvwr_bytes_per_row, 'ASCII')

  let s:memvwr_header_str = l:header_str
endfunction

" NOTE: look `:help statusline`, `:help winbar`, `:help winsaveview()`,
"       `:help winwidth()`, and `:help getwininfo()`.
" Evaluate padding required for line numbers, folds, etc., and slice viewport
" horizontal scroll offset.
function! MemvwrHeaderSlice()
  if win_id2win(s:memvwr_winid) <= 0 | return '' | endif
  let l:wininfo = getwininfo(s:memvwr_winid)
  let l:leftcol = l:wininfo[0].leftcol
  let l:textoff = l:wininfo[0].textoff
  let l:padding = repeat(' ', l:textoff)
  let l:header_slice_normal = l:padding . s:memvwr_header_str[l:leftcol:]
  " Append `%<` to truncate the line at the end if too long
  return l:header_slice_normal . '%<'
endfunction

" Construct format and header strings, and update the start columns for the
" bytes and ASCII fields, based on the address style and byte representation fmt.
function! s:MemvwrUpdateLayout()
  let l:addr_format_str  = ''
  let l:bytes_format_str = ''

  "------------------------------
  " Address format string and address label cache
  " (see -UI & Layout- for address style reference)
  "
  if s:memvwr_addr_style > 3
    echomsg '[s:MemvwrUpdateLayout] Invalid ADDR_STYLE "' . s:memvwr_addr_style . '". Using default 0.'
    let s:memvwr_addr_style = 0
  endif

  if s:memvwr_addr_style == 0
    let l:addr_format_str = '0x%016x:'
  elseif s:memvwr_addr_style == 1
    let l:addr_format_str = '%016x:'
  else " style 2 or 3
    let l:len_stop_addr  = strlen(printf("%x", s:memvwr_start_addr + s:memvwr_blob_len))
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
    echomsg '[s:MemvwrUpdateLayout] Invalid FMT "' . s:memvwr_fmt . '". Using fallback.'
    let s:memvwr_fmt = 'fallback'
    let l:bytes_format_str = '0x%02x'
    let s:memvwr_fmt_width = 4
  endif

  " Update format strings, bytes and ASCII preview start column
  let s:memvwr_column_bytes = strlen(printf(l:addr_format_str, ' ')) + 2 " plus ': ' length
  let s:memvwr_column_ascii = s:memvwr_column_bytes + s:memvwr_bytes_per_row * (s:memvwr_fmt_width + 1) + 1
  let s:memvwr_format_str_addr  = l:addr_format_str
  let s:memvwr_format_str_bytes = l:bytes_format_str

  call s:MemvwrUpdateHeaderString()
endfunction

function! MemvwrFromBlob(blob, start_addr, bytes_per_row=16, fmt='x', addr_style=0)
  let l:blob_len = len(a:blob)
  if l:blob_len < 1
    echomsg '[MemvwrFromBlob] Empty blob argument. Aborting...'
    return
  endif

  " Save (and normalize) arguments
  let s:memvwr_blob          = a:blob
  let s:memvwr_blob_len      = l:blob_len
  let s:memvwr_start_addr    = a:start_addr
  let s:memvwr_bytes_per_row = (a:bytes_per_row > 0) ? a:bytes_per_row : 1
  let s:memvwr_fmt           = a:fmt
  let s:memvwr_addr_style    = a:addr_style

  " Update format and header strings, and the bytes and ASCII fields start column
  call s:MemvwrUpdateLayout()

  "------------------------------
  " Generate rows iterating over blob
  " (byte index = i + j).
  "
  let l:mem_lines  = []
  let i = 0
  while i < s:memvwr_blob_len
    let l:bytes_str = ''
    let l:ascii_str  = ''

    let j = 0
    while j < s:memvwr_bytes_per_row
      if j + i < s:memvwr_blob_len
        let l:byte_val    = s:memvwr_blob[i+j]
        let l:bytes_str .= printf(' ' . s:memvwr_format_str_bytes, l:byte_val)

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
    call add(l:mem_lines, printf(s:memvwr_format_str_addr . "%s  %s", s:memvwr_start_addr+i, l:bytes_str, l:ascii_str))
    let i += j
  endwhile

  " Add info line at the end
  call add(l:mem_lines, printf("End of memory dump. START:0x%x | BYTES:%d | BPR:%d | FMT:%s | ADDR_STYLE:%s",
                             \ s:memvwr_start_addr, s:memvwr_blob_len, s:memvwr_bytes_per_row, s:memvwr_fmt, s:memvwr_addr_style))

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
  call MemvwrFromBlob(l:blob, 0, a:bytes_per_row, a:fmt, a:addr_style)
endfunction


"============================================================
" UI & Dynamic state
"============================================================
function! s:MemvwrUIUpdate()
  if win_getid() == s:memvwr_winid
    call s:MemvwrUpdateCursorState()
    call s:MemvwrCursorMatchByteAndASCII()
    call s:MemvwrWinInfoUpdate()
    call s:MemvwrPopupInspectorUpdate()
  endif
endfunction

" Invalid cursor positions: - the last line in the buffer
"                           - between the address field columns
"                           - separator column
function! s:MemvwrUpdateCursorState()
  let s:memvwr_cursor_line      = line('.')
  let s:memvwr_cursor_col       = col('.')
  let s:memvwr_cursor_is_valid  = 0
  let s:memvwr_cursor_blob_idx  = -1
  let s:memvwr_cursor_match_col = -1
  let s:memvwr_cursor_match_len = -1

  if   s:memvwr_blob_len > 0
  \ && s:memvwr_cursor_line != line('$')
  \ && s:memvwr_cursor_col >= s:memvwr_column_bytes
  \ && s:memvwr_cursor_col != s:memvwr_column_ascii - 1

    " Real width of bytes -> format width plus separator len (23.69.6e.)
    let l:fmt_width_plus_sep = s:memvwr_fmt_width + 1
    if s:memvwr_cursor_col < s:memvwr_column_ascii
      " Cursor inside the bytes field
      let x = s:memvwr_cursor_col - s:memvwr_column_bytes
      let l:row_byte_number = x / l:fmt_width_plus_sep

      " Check if the cursor didn't land on a separator
      if (x + 1) / l:fmt_width_plus_sep == l:row_byte_number
        let l:blob_idx = s:memvwr_bytes_per_row * (s:memvwr_cursor_line - 1) + l:row_byte_number
        if l:blob_idx < s:memvwr_blob_len
          let s:memvwr_cursor_is_valid  = 1
          let s:memvwr_cursor_blob_idx  = l:blob_idx
          let s:memvwr_cursor_match_col = s:memvwr_column_ascii + l:row_byte_number
          let s:memvwr_cursor_match_len = 1
        endif
      endif
    else
      " Cursor inside the ASCII preview field
      let l:row_byte_number = s:memvwr_cursor_col - s:memvwr_column_ascii
      let l:blob_idx = s:memvwr_bytes_per_row * (s:memvwr_cursor_line - 1) + l:row_byte_number
      if l:blob_idx < s:memvwr_blob_len
        let s:memvwr_cursor_is_valid  = 1
        let s:memvwr_cursor_blob_idx  = l:blob_idx
        let s:memvwr_cursor_match_col = s:memvwr_column_bytes + l:row_byte_number * l:fmt_width_plus_sep
        let s:memvwr_cursor_match_len = s:memvwr_fmt_width
      endif
    endif
  endif
endfunction

" NOTE: see `:help matchaddpos()`
function! s:MemvwrCursorMatchByteAndASCII()
  call clearmatches()
  if s:memvwr_cursor_is_valid
    call matchaddpos('MatchParen', [[s:memvwr_cursor_line, s:memvwr_cursor_match_col, s:memvwr_cursor_match_len]])
  endif
endfunction

function! s:MemvwrSetCursorToMatch()
  if win_getid() == s:memvwr_winid && s:memvwr_cursor_is_valid
    call cursor(s:memvwr_cursor_line, s:memvwr_cursor_match_col)
  endif
endfunction

function! s:MemvwrSetCursorToByte(cmd_str)
  if empty(a:cmd_str) || !win_gotoid(s:memvwr_winid) | return | endif

  let l:mode    = 0
  let l:sign    = 1
  let l:num_str = a:cmd_str

  if a:cmd_str[0] == '+' || a:cmd_str[0] == '-'
    let l:mode    = 1
    let l:sign    = (a:cmd_str[0] == '-') ? -1 : 1
    let l:num_str = a:cmd_str[1:]
  elseif a:cmd_str[0] == '|'
    let l:mode   = 2
    let l:num_str = a:cmd_str[1:]
  endif

  let l:base = 10
  if strlen(l:num_str) > 1 && l:num_str[0] == '0'
    let l:ch = l:num_str[1]
    let l:base = (l:ch ==? 'x') ? 16
             \ : (l:ch ==? 'b') ? 2
             \ :                  8
  endif

  let l:number = str2nr(l:num_str, l:base) * l:sign

  let l:byte_info = MemvwrGetByteInfo(l:number, l:mode)
  if !empty(l:byte_info) | call cursor(l:byte_info[1], l:byte_info[2]) | endif
endfunction


"------------------------------
" Data visualization & Pop-up windows
" TODO: be smarter about popup position when there's no
"       room for it on the window
"

" Create and setup buffer/window variables, or goto Memvwr's info window
function! s:MemvwrWinInfoOpen()
  if !win_gotoid(s:memvwr_win_info_winid)
    call s:MemvwrOpen()
    setlocal splitright

    execute 'vert new | vert resize 68'
    let s:memvwr_win_info_winid = win_getid()

    setlocal filetype=memvwr_info
    setlocal syntax=memvwr_info
    setlocal nowrap
    setlocal nonumber
    setlocal norelativenumber
    setlocal noswapfile
    setlocal buftype=nofile
    setlocal signcolumn=no
    setlocal modifiable

    if s:memvwr_win_info_bufnr > 0 && bufexists(s:memvwr_win_info_bufnr)
      execute 'buffer ' . s:memvwr_win_info_bufnr
    else
      execute 'silent file ' . s:memvwr_win_info_name
      let s:memvwr_win_info_bufnr = bufnr(s:memvwr_win_info_name)
      echomsg '[s:MemvwrWinInfo] New buffer [' . s:memvwr_win_info_bufnr . '] assigned to ' . s:memvwr_win_info_name
    endif

    call s:MemvwrOpen()
    call s:MemvwrWinInfoUpdate()
  endif
endfunction

function! s:MemvwrWinInfoUpdate()
  if s:memvwr_win_info_bufnr > 0
    let l:lines = []

    if s:memvwr_cursor_is_valid
      " TODO: consider doing this only when CursorHold (see `:help CursorHold`)
      let l:byte = s:memvwr_blob[s:memvwr_cursor_blob_idx]
      let l:ascii_char = (l:byte >= 32 && l:byte <= 126) ? printf("'%c'", l:byte) : 'N/P'

      " 32-bit floating point number string parsing
      let l:float32_str = printf("%f", s:InspectFloat32(s:memvwr_cursor_blob_idx, s:memvwr_is_little_endian))

      if s:f32_type != 'Normal'
        if s:f32_type == 'Subnormal' || s:f32_type == 'Zero'
          let l:float32_str .= ' (' . s:f32_type . ')'
        else
          if s:f32_type == 'Infinity'
            let l:float32_str = (s:f32_sign > 0) ? '-' : '+'
          else
            let l:float32_str = ''
          endif
          let l:float32_str .= s:f32_type
        endif
      endif

      " 64-bit floating point number string parsing
      let l:float64_str = printf("%f", s:InspectFloat64(s:memvwr_cursor_blob_idx, s:memvwr_is_little_endian))

      if s:f64_type != 'Normal'
        if s:f64_type == 'Subnormal' || s:f64_type == 'Zero'
          let l:float64_str .= ' (' . s:f64_type . ')'
        else
          if s:f64_type == 'Infinity'
            let l:float64_str = (s:f64_sign > 0) ? '-' : '+'
          else
            let l:float64_str = ''
          endif
          let l:float64_str .= s:f64_type
        endif
      endif

      call extend(l:lines, [
             \   printf("=> Byte @ 0x%x (idx: %d)", s:memvwr_start_addr + s:memvwr_cursor_blob_idx, s:memvwr_cursor_blob_idx)
             \ , printf("  hex: %2X | oct: %3o | dec: %3d | bin: %08b | ascii: %3s", l:byte, l:byte, l:byte, l:byte, l:ascii_char)
             \ ,        '  # ' . s:memvwr_endianness_label[s:memvwr_is_little_endian] . ' [S: swap endianness]'
             \ , printf("  uint8:  %u", s:InspectUint8(s:memvwr_cursor_blob_idx))
             \ , printf("  int8:   %d", s:InspectInt8(s:memvwr_cursor_blob_idx))
             \ , printf("  uint16: %u", s:InspectUint16(s:memvwr_cursor_blob_idx, s:memvwr_is_little_endian))
             \ , printf("  int16:  %d", s:InspectInt16(s:memvwr_cursor_blob_idx, s:memvwr_is_little_endian))
             \ , printf("  uint32: %u", s:InspectUint32(s:memvwr_cursor_blob_idx, s:memvwr_is_little_endian))
             \ , printf("  int32:  %d", s:InspectInt32(s:memvwr_cursor_blob_idx, s:memvwr_is_little_endian))
             \ , printf("  uint64: %u", s:InspectUint64(s:memvwr_cursor_blob_idx, s:memvwr_is_little_endian))
             \ , printf("  int64:  %d", s:InspectInt64(s:memvwr_cursor_blob_idx, s:memvwr_is_little_endian))
             \ , printf("  f32:    %s", l:float32_str)
             \ , printf("  |  sign:     %s", s:f32_sign)
             \ , printf("  |  exponent: %08b (0x%02X)", s:f32_exponent, s:f32_exponent)
             \ , printf("  |  mantissa: %023b (0x%06X)", s:f32_mantissa, s:f32_mantissa)
             \ , printf("  |  type:     %s", s:f32_type)
             \ , printf("  f64:    %s", l:float64_str)
             \ , printf("  |  sign:     %s", s:f64_sign)
             \ , printf("  |  exponent: %011b (0x%03X)", s:f64_exponent, s:f64_exponent)
             \ , printf("  |  mantissa: %052b (0x%013X)", s:f64_mantissa, s:f64_mantissa)
             \ , printf("  |  type:     %s", s:f64_type)
             \ ])
    endif

    call extend(l:lines, [
           \          '=> Layout'
           \ , printf("  START:      %s", s:memvwr_start_addr)
           \ , printf("  BYTES:      %d", s:memvwr_blob_len)
           \ , printf("  BPR:        %d", s:memvwr_bytes_per_row)
           \ , printf("  FMT:        %s", s:memvwr_fmt)
           \ , printf("  ADDR_STYLE: %d", s:memvwr_addr_style)
           \ ,        '=> Hotkeys'
           \ ,        '  [%] jump to cursor match'
           \ ,        '  [i] toggle inspector pop-up'
           \ ,        '  [I] open info pop-up'
           \ ,        '  [K] open this window (info)'
           \ ,        '  [S] swap endianness'
           \ ,        '=> Debug State'
           \ ])

    call extend(l:lines, s:MemvwrStateStr())

    " Need to use win_execute() because winsaveview() and winrestview() only target the current window
    call win_execute(s:memvwr_win_info_winid
           \ , 'let l:win_view = winsaveview() | '
           \ . 'call deletebufline(s:memvwr_win_info_bufnr, 1, ''$'') | '
           \ . 'call setbufline(s:memvwr_win_info_bufnr, 1, ' . string(l:lines) . ') | '
           \ . 'call winrestview(l:win_view)'
           \ )
  endif
endfunction

" Relevant highlight groups:
" Vim:
"      hi Pmenu
"      hi PmenuSel
" Nvim: (see `:help nvim_open_win()` > Parameters)
"      hi NormalFloat
"      hi FloatBorder
"      hi FloatTitle

" See `:help popup_create-arguments`
function! s:MemvwrPopupOpenInfo()
  if s:memvwr_popup_info_winid > 0
    echomsg '[s:MemvwrPopupOpenInfo] A buffer [' . s:memvwr_popup_info_bufnr . '] assigned to ' . s:memvwr_popup_info_name . ' already exists'
    return
  endif

  let s:memvwr_popup_info_bufnr = bufadd(s:memvwr_popup_info_name)
  call bufload(s:memvwr_popup_info_bufnr)
  call setbufvar(s:memvwr_popup_info_bufnr, '&buftype', 'nofile')
  call setbufvar(s:memvwr_popup_info_bufnr, '&bufhidden', 'hide')
  call setbufvar(s:memvwr_popup_info_bufnr, '&swapfile', 0)
  call setbufvar(s:memvwr_popup_info_bufnr, '&undolevels', -1)

  " See `:help list` and `:help extend()`
  let l:info_lines = []

  if s:memvwr_cursor_is_valid
    let l:byte = s:memvwr_blob[s:memvwr_cursor_blob_idx]
    let l:ascii_char  = '       '
    let l:ascii_char .= (l:byte >= 32 && l:byte <= 126) ? printf("'%c'", l:byte) : 'N/P'

    call extend(l:info_lines, [
           \   printf("=> Byte @ 0x%x", s:memvwr_start_addr + s:memvwr_cursor_blob_idx)
           \ , printf("    idx: %12d", s:memvwr_cursor_blob_idx)
           \ , printf("    hex: %12X", l:byte)
           \ , printf("    oct: %12o", l:byte)
           \ , printf("    dec: %12d", l:byte)
           \ , printf("    bin: %12b", l:byte)
           \ ,        '    ascii: ' . l:ascii_char
           \ ])
  endif

  call extend(l:info_lines, [
         \          '=> Layout'
         \ , printf("    START: %10s", s:memvwr_start_addr)
         \ , printf("    BYTES: %10d", s:memvwr_blob_len)
         \ , printf("    BPR: %12d", s:memvwr_bytes_per_row)
         \ , printf("    FMT: %12s", s:memvwr_fmt)
         \ , printf("    ADDR_STYLE: %5d", s:memvwr_addr_style)
         \ ])

  silent call deletebufline(s:memvwr_popup_info_bufnr, 1, '$')
  call setbufline(s:memvwr_popup_info_bufnr, 1, l:info_lines)

  let l:popup_title = printf("[%d]%s", s:memvwr_popup_info_bufnr, s:memvwr_popup_info_name)

  if has('nvim')
    let l:win_width  = 22
    let l:win_height = len(l:info_lines) 
    let l:options = #{
          \   relative: 'cursor'
          \ , row: 1
          \ , col: 1
          \ , width: l:win_width
          \ , height: l:win_height
          \ , anchor: 'NW'
          \ , title: l:popup_title
          \ , border: [ "╔", "═" ,"╗", "║", "╝", "═", "╚", "║" ]
          \ , style: 'minimal'
          \ }
    let s:memvwr_popup_info_winid = nvim_open_win(s:memvwr_popup_info_bufnr, 0, l:options)

    " Hack something similar to Vim's `moved: 'any'` (see `:help autocmd-define`)
    augroup MemvwrNvimPopupMovedAny
      autocmd!
      autocmd CursorMoved,InsertEnter,WinLeave <buffer> ++once call MemvwrPopupCloseInfo()
    augroup END
  else
    let l:options = #{
          \   line: 'cursor+1'
          \ , col: 'cursor+1'
          \ , pos: 'topleft'
          \ , title: l:popup_title
          \ , padding: [0, 1, 0, 1]
          \ , border: []
          \ , moved: 'any'
          \ , callback: 'MemvwrPopupCloseInfo'
          \ }
    let s:memvwr_popup_info_winid = popup_create(s:memvwr_popup_info_bufnr, l:options)
  endif

  echomsg '[s:MemvwrPopupOpenInfo] New buffer [' . s:memvwr_popup_info_bufnr . '] assigned to ' . s:memvwr_popup_info_name
endfunction

" Also used as the callback
function! MemvwrPopupCloseInfo(id=0, result=-1)
  if s:memvwr_popup_info_bufnr > 0
    " Only call popup_close() if wasn't called via 'callback'
    if a:id == 0
      if has('nvim')
        call nvim_win_close(s:memvwr_popup_info_winid, 1)
        silent! autocmd! MemvwrNvimPopupMovedAny
      else
        call popup_close(s:memvwr_popup_info_winid)
      endif
    endif

    execute 'silent! bw! ' . s:memvwr_popup_info_bufnr
    let s:memvwr_popup_info_winid = 0
    let s:memvwr_popup_info_bufnr = 0
    echomsg '[MemvwrPopupCloseInfo] Closed buffer assigned to ' . s:memvwr_popup_info_name
  endif
endfunction

function! s:MemvwrPopupInspectorToggle()
  if s:memvwr_popup_inspector_bufnr > 0
    if has('nvim')
      call nvim_win_close(s:memvwr_popup_inspector_winid, 1)
    else
      call popup_close(s:memvwr_popup_inspector_winid)
    endif

    silent! autocmd! MemvwrPopupInspectorAutoClose
    execute 'silent! bw! ' . s:memvwr_popup_inspector_bufnr
    let s:memvwr_popup_inspector_winid = 0
    let s:memvwr_popup_inspector_bufnr = 0
    echomsg '[s:MemvwrPopupInspectorToggle] Closed buffer assigned to ' . s:memvwr_popup_inspector_name

  else
    let s:memvwr_popup_inspector_bufnr = bufadd(s:memvwr_popup_inspector_name)
    call bufload(s:memvwr_popup_inspector_bufnr)
    call setbufvar(s:memvwr_popup_inspector_bufnr, '&buftype', 'nofile')
    call setbufvar(s:memvwr_popup_inspector_bufnr, '&bufhidden', 'hide')
    call setbufvar(s:memvwr_popup_inspector_bufnr, '&swapfile', 0)
    call setbufvar(s:memvwr_popup_inspector_bufnr, '&undolevels', -1)

    let l:popup_title = printf("[%d]%s", s:memvwr_popup_inspector_bufnr, s:memvwr_popup_inspector_name)

    if has('nvim')
      let l:win_width  = 34
      let l:win_height = 12
      let l:options = #{
            \   relative: 'cursor'
            \ , row: 1
            \ , col: 1
            \ , width: l:win_width
            \ , height: l:win_height
            \ , anchor: 'NW'
            \ , title: l:popup_title
            \ , border: [ "╔", "═" ,"╗", "║", "╝", "═", "╚", "║" ]
            \ , style: 'minimal'
            \ }
      let s:memvwr_popup_inspector_winid = nvim_open_win(s:memvwr_popup_inspector_bufnr, 0, l:options)
    else
      let l:options = #{
            \   line: 'cursor+1'
            \ , col: 'cursor+1'
            \ , pos: 'topleft'
            \ , title: l:popup_title
            \ , padding: [0, 1, 0, 1]
            \ , border: []
            \ }
      let s:memvwr_popup_inspector_winid = popup_create(s:memvwr_popup_inspector_bufnr, l:options)
    endif

    augroup MemvwrPopupInspectorAutoClose
      autocmd!
      autocmd InsertEnter,WinClosed <buffer> ++once call s:MemvwrPopupInspectorToggle()
    augroup END

    echomsg '[s:MemvwrPopupInspectorToggle] New buffer [' . s:memvwr_popup_inspector_bufnr . '] assigned to ' . s:memvwr_popup_inspector_name
    call s:MemvwrPopupInspectorUpdate()
  endif
endfunction

function! s:MemvwrPopupInspectorUpdate()
  if s:memvwr_popup_inspector_bufnr > 0 && win_getid() == s:memvwr_winid
    if has('nvim')
      call nvim_win_set_config(s:memvwr_popup_inspector_winid, #{relative: 'cursor', row: 2, col: s:memvwr_fmt_width})
    else
      call popup_move(s:memvwr_popup_inspector_winid, #{line: 'cursor+2', col: 'cursor+'.s:memvwr_fmt_width})
    endif

    if s:memvwr_cursor_is_valid
      " TODO: consider doing this only when CursorHold (see `:help CursorHold`)
      let l:inspector_lines = []

      call extend(l:inspector_lines, [
             \   s:memvwr_endianness_label[s:memvwr_is_little_endian] . ' [S: swap endianness]'
             \ , printf("-> 0x%x", s:memvwr_start_addr + s:memvwr_cursor_blob_idx)
             \ , printf(" uint8:  %u", s:InspectUint8(s:memvwr_cursor_blob_idx))
             \ , printf(" int8:   %d", s:InspectInt8(s:memvwr_cursor_blob_idx))
             \ , printf(" uint16: %u", s:InspectUint16(s:memvwr_cursor_blob_idx, s:memvwr_is_little_endian))
             \ , printf(" int16:  %d", s:InspectInt16(s:memvwr_cursor_blob_idx, s:memvwr_is_little_endian))
             \ , printf(" uint32: %u", s:InspectUint32(s:memvwr_cursor_blob_idx, s:memvwr_is_little_endian))
             \ , printf(" int32:  %d", s:InspectInt32(s:memvwr_cursor_blob_idx, s:memvwr_is_little_endian))
             \ , printf(" uint64: %u", s:InspectUint64(s:memvwr_cursor_blob_idx, s:memvwr_is_little_endian))
             \ , printf(" int64:  %d", s:InspectInt64(s:memvwr_cursor_blob_idx, s:memvwr_is_little_endian))
             \ , printf(" f32:    %+1f", s:InspectFloat32(s:memvwr_cursor_blob_idx, s:memvwr_is_little_endian))
             \ , printf(" f64:    %+1f", s:InspectFloat64(s:memvwr_cursor_blob_idx, s:memvwr_is_little_endian))
             \ ])
      call setbufline(s:memvwr_popup_inspector_bufnr, 1, l:inspector_lines)
    endif
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
command!          MemvwrDI      call s:MemvwrWinInfoOpen()

command! -nargs=1 -complete=file MemvwrFopen call s:MemvwrOpen() | call MemvwrFromFile(<q-args>, s:memvwr_bytes_per_row, s:memvwr_fmt, s:memvwr_addr_style)

command! -nargs=1 ByteJump call s:MemvwrSetCursorToByte(<q-args>)
command! -nargs=1 B        call s:MemvwrSetCursorToByte(<q-args>)

command! MemvwrPopinfo            call s:MemvwrPopupOpenInfo()
command! MemvwrPopinspectorToggle call s:MemvwrPopupInspectorToggle()
command! MemvwrSwapEndianness     let s:memvwr_is_little_endian = (s:memvwr_is_little_endian) ? 0 : 1 | call s:MemvwrUIUpdate()

augroup MemvwrAUG
  autocmd!
  autocmd FileType memvwr autocmd CursorMoved <buffer> call s:MemvwrUIUpdate()
  autocmd FileType memvwr nnoremap   <silent> <buffer> % :call <SID>MemvwrSetCursorToMatch()<CR>
  autocmd FileType memvwr nnoremap   <silent> <buffer> I :MemvwrPopinfo<CR>
  autocmd FileType memvwr nnoremap   <silent> <buffer> i :MemvwrPopinspectorToggle<CR>
  autocmd FileType memvwr nnoremap   <silent> <buffer> K :MemvwrDI<CR>
  autocmd FileType memvwr nnoremap   <silent> <buffer> S :MemvwrSwapEndianness<CR>
augroup END


"============================================================
" Utils
"============================================================
" NOTE: Inspect...() functions assume the idx argument will not be less than 0
function! s:InspectUint8(idx)
  if a:idx + 1 > s:memvwr_blob_len | return -1 | endif

  return s:memvwr_blob[a:idx]
endfunction

function! s:InspectUint16(idx, little_endian)
  if a:idx + 2 > s:memvwr_blob_len | return -1 | endif

  let l:result = 0
  let l:byte0  = s:memvwr_blob[a:idx]
  let l:byte1  = s:memvwr_blob[a:idx + 1]

  if a:little_endian
    let l:result = l:byte0
    let l:result = or(l:result, s:ShiftLeft(l:byte1, 8))
  else
    let l:result = s:ShiftLeft(l:byte0, 8)
    let l:result = or(l:result, l:byte1)
  endif

  return l:result
endfunction

function! s:InspectUint32(idx, little_endian)
  if a:idx + 4 > s:memvwr_blob_len | return -1 | endif

  let l:result = 0
  let l:byte0  = s:memvwr_blob[a:idx]
  let l:byte1  = s:memvwr_blob[a:idx + 1]
  let l:byte2  = s:memvwr_blob[a:idx + 2]
  let l:byte3  = s:memvwr_blob[a:idx + 3]

  if a:little_endian
    let l:result = l:byte0
    let l:result = or(l:result, s:ShiftLeft(l:byte1, 8))
    let l:result = or(l:result, s:ShiftLeft(l:byte2, 16))
    let l:result = or(l:result, s:ShiftLeft(l:byte3, 24))
  else
    let l:result = s:ShiftLeft(l:byte0, 24)
    let l:result = or(l:result, s:ShiftLeft(l:byte1, 16))
    let l:result = or(l:result, s:ShiftLeft(l:byte2, 8))
    let l:result = or(l:result, l:byte3)
  endif

  return l:result
endfunction

function! s:InspectUint64(idx, little_endian)
  if a:idx + 8 > s:memvwr_blob_len | return -1 | endif

  " Separate into two 32-bit words
  let l:word0 = s:InspectUint32(a:idx, a:little_endian)
  let l:word1 = s:InspectUint32(a:idx + 4, a:little_endian)

  let l:lsb = 0
  let l:msb = 0
  if a:little_endian
    let l:lsb = l:word0
    let l:msb = l:word1
  else
    let l:lsb = l:word1
    let l:msb = l:word0
  endif

  return or(s:ShiftLeft(l:msb, 32), l:lsb)
endfunction

"------------------------------
" NOTE: see Hacker's Delight:
" -> Chapter 2-6 Sign Extension
"    ... assuming Vim's Number type is 64-bit signed

function! s:InspectInt8(idx)
  let l:result = s:InspectUint8(a:idx)
  if l:result == -1 | return -1 | endif

  return xor(l:result, 0x80) - 0x80
endfunction

function! s:InspectInt16(idx, little_endian)
  let l:result = s:InspectUint16(a:idx, a:little_endian)
  if l:result == -1 | return -1 | endif

  return xor(l:result, 0x8000) - 0x8000
endfunction

function! s:InspectInt32(idx, little_endian)
  let l:result = s:InspectUint32(a:idx, a:little_endian)
  if l:result == -1 | return -1 | endif

  return xor(l:result, 0x80000000) - 0x80000000
endfunction

function! s:InspectInt64(idx, little_endian)
  let l:result = s:InspectUint64(a:idx, a:little_endian)
  if l:result == -1 | return -1 | endif

  return l:result
endfunction

"------------------------------
" Floating point numbers
"
function! s:InspectFloat32(idx, little_endian)
  if a:idx + 4 > s:memvwr_blob_len | return -1 | endif

  let l:result  = 0
  let l:u32_val = s:InspectUint32(a:idx, a:little_endian)

  let l:sign     = and(0x80000000, l:u32_val)
  let l:exponent = and(0x7F800000, l:u32_val)
  let l:mantissa = and(0x7FFFFF, l:u32_val)

  let s:f32_sign     = (l:sign != 0) ? 1 : 0
  let s:f32_exponent = s:ShiftRight(l:exponent, 23)
  let s:f32_mantissa = l:mantissa

  let l:unbiased_exponent = 0
  let l:actual_mantissa   = 1.0

  " Check for reserved values (Infinity, NaN)
  if s:f32_exponent == 255
    if s:f32_mantissa == 0
      let s:f32_type = 'Infinity'
      let l:result = str2float('inf')
    else
      let s:f32_type = 'NaN'
      let l:result = str2float('nan')
    endif

  elseif s:f32_exponent == 0
    if s:f32_mantissa == 0
      let s:f32_type = 'Zero'
      let l:result = 0.0
    else
      let s:f32_type = 'Subnormal'
      let l:unbiased_exponent = -126
      let l:actual_mantissa   = 0.0
    endif

  else
    let s:f32_type = 'Normal'
    let l:unbiased_exponent = s:f32_exponent - 127
    let l:actual_mantissa   = 1.0
  endif

  " Calculate the floating point value for Normal and Subnormal numbers
  if s:f32_type == 'Normal' || s:f32_type == 'Subnormal'
    let l:shift_amt = 0.5
    let l:bit_idx = 22

    while l:bit_idx >= 0
      let l:mask = s:ShiftLeft(1, l:bit_idx)
      if and(l:mask, s:f32_mantissa)
        let l:actual_mantissa += l:shift_amt
      endif

      let l:shift_amt = l:shift_amt / 2.0
      let l:bit_idx -= 1
    endwhile

    let l:result = l:actual_mantissa * pow(2.0, l:unbiased_exponent)
  endif

  if s:f32_sign == 1 && s:f32_type != 'NaN'
    let l:result = -l:result
  endif

  return l:result
endfunction

function! s:InspectFloat64(idx, little_endian)
  if a:idx + 8 > s:memvwr_blob_len | return -1 | endif

  let l:result  = 0
  let l:u64_val = s:InspectUint64(a:idx, a:little_endian)

  " NOTE: l:sign -> check for negative signed 64-bit Number type (assumed)
  let l:sign     = (l:u64_val < 0) ? 1 : 0
  let l:exponent = and(0x7FF0000000000000, l:u64_val)
  let l:mantissa = and(0x0FFFFFFFFFFFFF, l:u64_val)

  let s:f64_sign     = l:sign
  let s:f64_exponent = s:ShiftRight(l:exponent, 52)
  let s:f64_mantissa = l:mantissa

  let l:unbiased_exponent = 0
  let l:actual_mantissa   = 1.0

  " Check for reserved values (Infinity, NaN)
  if s:f64_exponent == 2047
    if s:f64_mantissa == 0
      let s:f64_type = 'Infinity'
      let l:result = str2float('inf')
    else
      let s:f64_type = 'NaN'
      let l:result = str2float('nan')
    endif

  elseif s:f64_exponent == 0
    if s:f64_mantissa == 0
      let s:f64_type = 'Zero'
      let l:result = 0.0
    else
      let s:f64_type = 'Subnormal'
      let l:unbiased_exponent = -1022
      let l:actual_mantissa   = 0.0
    endif

  else
    let s:f64_type = 'Normal'
    let l:unbiased_exponent = s:f64_exponent - 1023
    let l:actual_mantissa   = 1.0
  endif

  " Calculate the floating point value for Normal and Subnormal numbers
  if s:f64_type == 'Normal' || s:f64_type == 'Subnormal'
    let l:shift_amt = 0.5
    let l:bit_idx = 51

    while l:bit_idx >= 0
      let l:mask = s:ShiftLeft(1, l:bit_idx)
      if and(l:mask, s:f64_mantissa)
        let l:actual_mantissa += l:shift_amt
      endif

      let l:shift_amt = l:shift_amt / 2.0
      let l:bit_idx -= 1
    endwhile

    let l:result = l:actual_mantissa * pow(2.0, l:unbiased_exponent)
  endif

  if s:f64_sign == 1 && s:f64_type != 'NaN'
    let l:result = -l:result
  endif

  return l:result
endfunction


"------------------------------
" Bit-shift ops
"
function! s:ShiftLeft(lhs, rhs)
  " NOTE: can't use bit shifts on Neovim. Using 256 multiplier instead.
  if has('nvim')
    let l:result    = a:lhs
    let l:shift_amt = a:rhs

    while l:shift_amt >= 8
      let l:result    *= 256
      let l:shift_amt -= 8
    endwhile

    while l:shift_amt > 0
      let l:result    *= 2
      let l:shift_amt -= 1
    endwhile

    return l:result
  else
    return a:lhs << a:rhs
  endif
endfunction

function! s:ShiftRight(lhs, rhs)
  if has('nvim')
    let l:result    = a:lhs
    let l:shift_amt = a:rhs

    while l:shift_amt >= 8
      let l:result    /= 256
      let l:shift_amt -= 8
    endwhile

    while l:shift_amt > 0
      let l:result    /= 2
      let l:shift_amt -= 1
    endwhile

    return l:result
  else
    return a:lhs >> a:rhs
  endif
endfunction

"------------------------------
" Debug & State
"
function! s:MemvwrStateStr()
  let l:lines = []

  call extend(l:lines, [
         \   printf("%-*s", 32, 's:memvwr_name:')                  . s:memvwr_name
         \ , printf("%-*s", 32, 's:memvwr_bufnr:')                 . s:memvwr_bufnr
         \ , printf("%-*s", 32, 's:memvwr_winid:')                 . s:memvwr_winid
         \ , printf("%-*s", 32, 's:memvwr_blob:')                  . string(s:memvwr_blob)
         \ , printf("%-*s", 32, 's:memvwr_blob_len:')              . s:memvwr_blob_len
         \ , printf("%-*s", 32, 's:memvwr_start_addr:')            . s:memvwr_start_addr
         \ , printf("%-*s", 32, 's:memvwr_bytes_per_row:')         . s:memvwr_bytes_per_row
         \ , printf("%-*s", 32, 's:memvwr_fmt:')                   . s:memvwr_fmt
         \ , printf("%-*s", 32, 's:memvwr_fmt_width:')             . s:memvwr_fmt_width
         \ , printf("%-*s", 32, 's:memvwr_addr_style:')            . s:memvwr_addr_style
         \ , printf("%-*s", 32, 's:memvwr_header_str:')            . s:memvwr_header_str
         \ , printf("%-*s", 32, 's:memvwr_addr_label_cache:')      . s:memvwr_addr_label_cache
         \ , printf("%-*s", 32, 's:memvwr_column_bytes:')          . s:memvwr_column_bytes
         \ , printf("%-*s", 32, 's:memvwr_column_ascii:')          . s:memvwr_column_ascii
         \ , printf("%-*s", 32, 's:memvwr_format_str_addr:')       . s:memvwr_format_str_addr
         \ , printf("%-*s", 32, 's:memvwr_format_str_bytes:')      . s:memvwr_format_str_bytes
         \ , printf("%-*s", 32, 's:memvwr_cursor_line:')           . s:memvwr_cursor_line
         \ , printf("%-*s", 32, 's:memvwr_cursor_col:')            . s:memvwr_cursor_col
         \ , printf("%-*s", 32, 's:memvwr_cursor_is_valid:')       . s:memvwr_cursor_is_valid
         \ , printf("%-*s", 32, 's:memvwr_cursor_blob_idx:')       . s:memvwr_cursor_blob_idx
         \ , printf("%-*s", 32, 's:memvwr_cursor_match_col:')      . s:memvwr_cursor_match_col
         \ , printf("%-*s", 32, 's:memvwr_cursor_match_len:')      . s:memvwr_cursor_match_len
         \ , printf("%-*s", 32, 's:memvwr_is_little_endian:')      . s:memvwr_is_little_endian
         \ , printf("%-*s", 32, 's:memvwr_win_info_name:')         . s:memvwr_win_info_name
         \ , printf("%-*s", 32, 's:memvwr_win_info_bufnr:')        . s:memvwr_win_info_bufnr
         \ , printf("%-*s", 32, 's:memvwr_win_info_winid:')        . s:memvwr_win_info_winid
         \ , printf("%-*s", 32, 's:memvwr_popup_info_name:')       . s:memvwr_popup_info_name
         \ , printf("%-*s", 32, 's:memvwr_popup_info_bufnr:')      . s:memvwr_popup_info_bufnr
         \ , printf("%-*s", 32, 's:memvwr_popup_info_winid:')      . s:memvwr_popup_info_winid
         \ , printf("%-*s", 32, 's:memvwr_popup_inspector_name:')  . s:memvwr_popup_inspector_name
         \ , printf("%-*s", 32, 's:memvwr_popup_inspector_bufnr:') . s:memvwr_popup_inspector_bufnr
         \ , printf("%-*s", 32, 's:memvwr_popup_inspector_winid:') . s:memvwr_popup_inspector_winid
         \ , printf("%-*s", 32, 's:f32_sign:')                     . s:f32_sign
         \ , printf("%-*s", 32, 's:f32_exponent:')                 . s:f32_exponent
         \ , printf("%-*s", 32, 's:f32_mantissa:')                 . s:f32_mantissa
         \ , printf("%-*s", 32, 's:f32_type:')                     . s:f32_type
         \ , printf("%-*s", 32, 's:f64_sign:')                     . s:f64_sign
         \ , printf("%-*s", 32, 's:f64_exponent:')                 . s:f64_exponent
         \ , printf("%-*s", 32, 's:f64_mantissa:')                 . s:f64_mantissa
         \ , printf("%-*s", 32, 's:f64_type:')                     . s:f64_type
         \ ])

  return l:lines
endfunction

"------------------------------
" Temp - remove later
"
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
    if l:idx >= 0 | let l:arg = l:arg[1:] | endif

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

let s:memvwr_test_blob = 0z00000000.80000000.3F800000.BF800000.7F800000.FF800000.7FC00000.00000001.40490FDB.00000000.00000000.80000000.00000000.3FF00000.00000000.BFF00000.00000000.7FF00000.00000000.FFF00000.00000000.7FF80000.00000000.400921FB.54442D18.40000000.00000000.0000007F.FFFFFFFF.FFFFFFFF
let s:memvwr_test_blob_len = len(s:memvwr_test_blob)

command! MemvwrTest call s:MemvwrOpen() | call MemvwrFromBlob(s:memvwr_test_blob, 0, 4, 'x', 3) | call s:MemvwrWinInfoOpen()

" Test blob (Big-Endian 32-bit float):
" -----------------------------------------------------------------------
" Offset | Description          | Hex Value  | Sign | Exponent | Mantissa
" -----------------------------------------------------------------------
"  0     | Positive Zero (+0.0) | 0x00000000 | '+'  | 0x00     | 0x000000
"  4     | Negative Zero (-0.0) | 0x80000000 | '-'  | 0x00     | 0x000000
"  8     | Positive One (+1.0)  | 0x3F800000 | '+'  | 0x7F     | 0x000000
" 12     | Negative One (-1.0)  | 0xBF800000 | '-'  | 0x7F     | 0x000000
" 16     | +Infinity            | 0x7F800000 | '+'  | 0xFF     | 0x000000
" 20     | -Infinity            | 0xFF800000 | '-'  | 0xFF     | 0x000000
" 24     | NaN                  | 0x7FC00000 | '+'  | 0xFF     | 0x400000
" 28     | Smallest Subnormal   | 0x00000001 | '+'  | 0x00     | 0x000001
" 32     | Pi Approx (+3.14159) | 0x40490FDB | '+'  | 0x80     | 0x490FDB

" Test blob (Big-Endian 64-bit float):
" --------------------------------------------------------------------------------
" Offset | Description          | Hex Value           | Sign | Exponent | Mantissa
" --------------------------------------------------------------------------------
" 36     | Positive Zero (+0.0) | 0x00000000 00000000 | '+'  | 0x000    | 0x0000000000000
" 44     | Negative Zero (-0.0) | 0x80000000 00000000 | '-'  | 0x000    | 0x0000000000000
" 52     | Positive One (+1.0)  | 0x3FF00000 00000000 | '+'  | 0x3FF    | 0x0000000000000
" 60     | Negative One (-1.0)  | 0xBFF00000 00000000 | '-'  | 0x3FF    | 0x0000000000000
" 68     | +Infinity            | 0x7FF00000 00000000 | '+'  | 0x7FF    | 0x0000000000000
" 76     | -Infinity            | 0xFFF00000 00000000 | '-'  | 0x7FF    | 0x0000000000000
" 84     | NaN                  | 0x7FF80000 00000000 | '+'  | 0x7FF    | 0x8000000000000
" 92     | Pi Approx (+3.14159) | 0x400921FB 54442D18 | '+'  | 0x400    | 0x921FB54442D18
