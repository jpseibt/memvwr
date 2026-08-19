"============================================================
" Memory Viewer - syntax file
"============================================================
" Language:    Memvwr
" Maintainer:  J. Paulo Seibt <jpseibt@gmail.com>
" Last Change: 2026 Aug 15

" quit when a syntax file was already loaded
if exists('b:current_syntax')
  finish
endif

let s:cpo_save = &cpo
set cpo&vim

syn match memvwrAddr           "^[a-z0-9]\{4,16}\>:"
syn match memvwrAddrWithPrefix "^0x[a-z0-9]\{4,16}\>:"
syn match memvwrByteDecOct     " \zs[ 0-9]\{2}[0-9]\>\ze "
syn match memvwrByteHex        " \zs\<[a-f0-9]\{2}\>\ze "
syn match memvwrByteBin        " \zs\<[0-1]\{8}\>\ze "
syn match memvwrByteFall       " \zs\<0x[a-f0-9]\{2}\>\ze "
syn match memvwrAsciiPreview   "  \zs\S\+\s*$"

hi def link memvwrAddr           Number
hi def link memvwrAddrWithPrefix Number
hi def link memvwrByteDecOct     CursorLine
hi def link memvwrByteHex        CursorLine
hi def link memvwrByteBin        CursorLine
hi def link memvwrByteFall       CursorLine
hi def link memvwrAsciiPreview   Character

let b:current_syntax = 'memvwr'

let &cpo = s:cpo_save
unlet s:cpo_save
