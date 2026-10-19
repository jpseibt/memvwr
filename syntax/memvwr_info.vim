"============================================================
" Memory Viewer Info Window - syntax file
"============================================================
" Language:    Memvwr Info
" Maintainer:  J. Paulo Seibt <jpseibt@gmail.com>
" Last Change: 2026 Oct 18

" quit when a syntax file was already loaded
if exists('b:current_syntax')
  finish
endif

let s:cpo_save = &cpo
set cpo&vim

syn match memvwrInfoSectionHeader   "^=>.*$"
syn match memvwrInfoEndiannes       "^\s\{2}#.*$"
syn match memvwrInfoInspectedSub    "\s\+\zs|\s\+[a-z0-9]\+\ze:"
syn match memvwrInfoInspectedType   "^\s\{2}\zs[a-zA-Z0-9_]\+\ze:"
syn match memvwrInfoHotkey          "\[[a-zA-Z0-9%]\+\]"

hi def link memvwrInfoSectionHeader Function
hi def link memvwrInfoEndiannes     Special
hi def link memvwrInfoInspectedSub  Identifier
hi def link memvwrInfoInspectedType Type
hi def link memvwrInfoHotkey        Define

let b:current_syntax = 'memvwr_info'

let &cpo = s:cpo_save
unlet s:cpo_save
