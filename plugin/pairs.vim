" Load check {{{
if exists('g:loaded_pairs')
    finish
endif
let g:loaded_pairs = 1
" }}}

" Options and default values {{{
if !exists('g:pairs_class_semicolon')
    let g:pairs_class_semicolon = 1
endif

if !exists('g:pairs_close_nextline')
    let g:pairs_close_nextline = 1
endif

if !exists('g:pairs_latex_interval')
    let g:pairs_latex_interval = 1
endif

if !exists('g:pairs_cpp_angle')
    let g:pairs_cpp_angle = 1
endif
" }}}

" Constants {{{
if has('patch-7.4.849')
    let s:left  = "\<C-G>U\<Left>"
    let s:right = "\<C-G>U\<Right>"
else
    let s:left  = "\<Left>"
    let s:right = "\<Right>"
endif
let s:undo  = "\<C-G>u"
let s:abbr  = "\<C-]>"

let s:class_ins = '\<\(struct\|class\|enum\|union\)\>[^{]*$'
let s:class_del = '\<\(struct\|class\|enum\|union\)\>'
let s:cpp = '^\(c\|cpp\)$'
" }}}

function! s:GetChar(offset, ...) " {{{
    let column = col('.') + a:offset
    let length = a:0 > 0 ? a:1 : 1

    " if starting before first column, adjust to a valid column and length
    if column < 1
        let length += column - 1
        let column = 1

        if length < 1
            return ''
        endif
    endif

    return matchstr(getline('.'), '\%' . column . 'c.\{,' . length . '}')
endfunction " }}}

function! s:InSyntax(...) " {{{
    let pattern = a:0 > 0 ? a:1 : '^\(String\|Character\)$'

    for id in synstack(line('.'), col('.'))
        let name = synIDattr(id, 'name')
        if name =~ pattern
            return 1
        endif
        let name = synIDattr(synIDtrans(id), 'name')
        if name =~ pattern
            return 1
        endif
    endfor

    return 0
endfunction " }}}

function! s:IsPair(left, right) " {{{
    if a:left[0] == '\'
        " backslash pair
        return has_key(b:pairs, a:left[1]) &&
                    \ b:pairs[a:left[1]] == a:right[1] &&
                    \ a:right[0] == '\'
    else
        return has_key(b:pairs, a:left[-1:]) &&
                    \ b:pairs[a:left[-1:]] == a:right[0]
    endif
endfunction " }}}

function! s:InPair(...) " {{{
    " TODO: this logic / arguments are a hell of mess

    let dist      = a:0 > 0 ? a:1 : 0
    let quote     = a:0 > 1 ? a:2 : 0
    let backslash = a:0 > 2 ? a:3 : 0

    let left  = s:GetChar(-1 - dist)
    let right = s:GetChar(0 + dist + backslash)

    if quote && index(b:quotes, left) >= 0 && left == right
        return 1
    endif

    return has_key(b:pairs, left) && b:pairs[left] == right &&
                \ (!backslash ||
                \ s:GetChar(-2 - dist) == '\' && s:GetChar(0 + dist) == '\')
endfunction " }}}

function! s:Open(key) " {{{
    let key = a:key
    let right = s:GetChar(0)

    if mode() ==# 'R'
        " ignore in replace mode, since they would be overwritten anyways
    elseif s:InSyntax()
        " skip inside strings
    elseif right =~ '\h' || has_key(b:pairs, right)
        " don't complete before identifiers / open pairs
    elseif s:GetChar(-1) == '\' && s:GetChar(-2) != '\'
        " backslash pairs
        let key = a:key . '\' . b:pairs[a:key] . repeat(s:left, 2)
        call add(b:pendings, b:pairs[a:key])
    elseif g:pairs_class_semicolon && &filetype =~ s:cpp && a:key == '{' &&
                \ (getline('.') =~ s:class_ins ||
                \ (getline(line('.') - 1) =~ s:class_ins &&
                \ getline('.') =~ '^\s*[^{]*$'))
        " auto insert semicolon for struct / class
        let key = a:key . b:pairs[a:key] . ';' . repeat(s:left, 2)
        call add(b:pendings, b:pairs[a:key])
    elseif &filetype =~ s:cpp && a:key == '<'
        " if on an #include line
        if g:pairs_cpp_angle && getline('.') =~ '^\s*\(#include\|template\)\s*$'
            " complete angle brackets
            let key = '<>' . s:left
            call add(b:pendings, '>')
        endif
        " else, don't complete
    elseif &filetype == 'markdown' && s:InSyntax('^markdownHighlight') &&
                \ a:key == '<'
        " skip inside fenced code block
    elseif &filetype == 'html' && s:InSyntax('^javaScript$') && a:key == '<'
        " skip inside js
    else
        " auto complete pair
        let key = a:key . b:pairs[a:key] . s:left
        call add(b:pendings, b:pairs[a:key])
    endif

    return s:abbr . key
endfunction " }}}

function! s:Close(key) " {{{
    let key = a:key
    let left = s:GetChar(-1)
    let right = s:GetChar(0)
    let nextline = getline(line('.') + 1)

    if mode() ==# 'R'
        " ignore in replace mode
    elseif empty(b:pendings)
        " ignore when opening is not inserted
    elseif g:pairs_latex_interval && &filetype == 'tex' &&
                \ s:InSyntax('^texMathZone') && a:key =~ ')\|]' &&
                \ b:pendings[-1] =~ ')\|]'
        " in math mode, parentheses and brackets are often paired
        let key = "\<Del>" . a:key
        call remove(b:pendings, -1)
    elseif g:pairs_cpp_angle && &filetype =~ s:cpp &&
                \ a:key == '>' &&
                \ right == '>' &&
                \ getline('.') =~ '^\s*\(#include\|template\)'
        " close #include
        let key = "\<Del>" . a:key
        call remove(b:pendings, -1)
    elseif b:pendings[-1] != a:key
        " ignore when not closing the right thing
    elseif s:InSyntax()
        " skip inside strings
    elseif a:key == right
        " delete and close (this preserves auto indent behavior)
        let key = "\<Del>" . a:key
        call remove(b:pendings, -1)
    elseif s:GetChar(0, 3) =~ '^ \?\\\?' . a:key
        " space and / or backslash before the closing pair
        let del = 0
        let bs  = 0

        " find how many characters to backspace and delete
        if s:GetChar(0, 2) == ' \'
            let del = 2

            if s:GetChar(-2, 2) == ' \'
                let bs = 2
            elseif left == '\' || left == ' '
                let bs = 1
            endif
        elseif right == ' ' || right == '\'
            let del = 1

            if left == right
                let bs = 1
            endif
        endif

        " delete duplicate characters and close pair
        let key = repeat("\<BS>", bs) . repeat(s:right, del) . "\<Del>" . a:key
        call remove(b:pendings, -1)
    elseif g:pairs_close_nextline && right == '' &&
                \ nextline =~ '^\s*\\\?' . a:key
        " closing bracket at end of line, with closing pair next line
        " TODO: detect while in comment as well

        let thisline = getline('.')

        if nextline =~ '^\s*\\' . a:key
            " backslash close
            if thisline =~ '^\s*\\\?$'
                " current line empty / only backslash,
                " delete and move past matched pair
                let key = " \<C-U>\<BS>\<C-Right>\<Right>\<Right>"
            elseif left == '\'
                " non-empty with backslash, backspace and move to next line
                let key = "\<BS>\<C-Right>\<Right>\<Right>"
            else
                " non-empty without backslash, just move to next line
                let key = "\<C-Right>\<Right>\<Right>"
            endif
        else
            if thisline =~ '^\s*$'
                " empty line, delete and jump
                let key = " \<C-U>\<BS>\<C-Right>\<Right>"
            else
                " none-empty, just jump
                let key = "\<C-Right>\<Right>"
            endif
        endif

        let key .= s:undo
        call remove(b:pendings, -1)
    endif

    return s:abbr . key
endfunction " }}}

function! s:Quote(key) " {{{
    let key = a:key
    let left = s:GetChar(-1)
    let right = s:GetChar(0)
    let ins = s:InSyntax()
    let pending = !empty(b:pendings) && b:pendings[-1] == a:key

    if mode() == 'r'
        " ignore in replace mode
    elseif left == '\' && s:GetChar(-2) != '\'
        " ignore backslash escapes
        " TODO: recognize more than 2 backslashes
    elseif &filetype == 'tex' && s:InSyntax('^texZone$') && a:key == '$'
        " ignore '$' in LaTeX verbatim
    elseif !ins && s:GetChar(-2, 2) == repeat(a:key, 2) &&
                \ a:key != s:GetChar(-3)
        " 3 consecutive quotes
        let del = right == a:key ? "\<Del>" : ''

        if getline(line('.') + 1) =~ '^\s*' . repeat(a:key, 3) &&
                    \ !empty(b:pendings) && b:pendings[-1] == repeat(a:key, 3)
            " only closing quotes next line
            if getline('.') =~ '^\s*' . repeat(a:key, 2) . '$'
                " current line empty, delete this line
                let key = "\<End>\<C-U>\<BS>\<Down>\<End>"
            else
                " non-empty line, jump to next line
                let key = repeat("\<BS>", 2) . del . "\<Down>\<End>"
            endif

            let key .= s:undo
            call remove(b:pendings, -1)
        else
            " complete all closing quotes
            let key = del . repeat(a:key, 4) . repeat(s:left, 3)
            call add(b:pendings, repeat(a:key, 3))
        endif
    elseif pending && a:key == right
        " delete and insert closing quote
        let key = "\<Del>" . a:key
        call remove(b:pendings, -1)
    elseif ins
        " inside string, don't insert closing quote
    elseif right =~ '\h'
        " ignore when inserting before identifiers
    elseif left =~ '\h' && (&filetype != 'python' || left =~ '[^rf]')
        " ignore after identifiers, but not after raw or formatted strings
    elseif s:GetChar(-2) =~ '\h' && left == a:key
        " don't complete pair when left is quote immediately after identifier,
        " otherwise this breaks triple quote line jump
    elseif &filetype == 'vim' && a:key == '"' && getline('.') =~ '^\s*$'
        " ignore double quote for vim comments at start of line
    else
        " complete quote pair
        let key = repeat(a:key, 2) . s:left
        call add(b:pendings, a:key)
    endif

    return s:abbr . key
endfunction " }}}

function! s:Enter() " {{{
    let key = ''
    let prevline = getline(line('.') - 1)

    " TODO: html tag / latex begin and end
    if s:IsPair(prevline[-2:], s:GetChar(0, 2))
        if &filetype == 'vim' && !s:InSyntax('^Comment$')
            let key .= "\\ \<Up>\<End>\<CR>\\ "
        else
            let key .= "\<Up>\<End>\<CR>"
        endif
    elseif &filetype == 'markdown' &&
                \ prevline =~ '^`\{3}' &&
                \ s:GetChar(0, 4) == '```' " length 4 to make sure nothing after
        let key .= "\<Up>\<End>\<CR>"
    endif

    return key
endfunction " }}}

function! s:Space() " {{{
    let key = ''

    if s:IsPair(s:GetChar(-3, 2), s:GetChar(0, 2))
        let key .= ' ' . s:left
    endif

    return key
endfunction " }}}

function! s:Backspace() " {{{
    let key = "\<BS>"

    if s:InPair(0, 1) ||
                \ g:pairs_cpp_angle && &filetype =~ s:cpp &&
                \ getline('.') =~ '^\s*\(#include\|template\)\s*<>\s*$' &&
                \ s:GetChar(-1, 2) == '<>'
        " normal pair or quote

        if !empty(b:pendings) && b:pendings[-1] == s:GetChar(0)
            let key .= "\<Del>"

            " FIXME: this sometimes delete the wrong stuff
            if g:pairs_class_semicolon && s:GetChar(1) == ';' &&
                        \ (getline('.') =~ s:class_del ||
                        \ getline(line('.') - 1) =~ s:class_del)
                " delete semicolon for class
                let key .= "\<Del>"
            endif

            call remove(b:pendings, -1)
        endif
    elseif s:InPair(0, 0, 1)
        " backslash pair

        if !empty(b:pendings) && b:pendings[-1] == s:GetChar(0)
            " delete pair and right backslash
            let key .= repeat("\<Del>", 2)

            call remove(b:pendings, -1)
        endif
    elseif s:GetChar(-1, 2) == '  ' &&
                \ (s:InPair(1, 1) || s:InPair(1, 0, 1))
        " spaced pair, delete spaces inside
        let key .= "\<Del>"
    endif

    " TODO: implement deletion of all special insertions :(

    return key
endfunction " }}}

function! s:Remap() " {{{
    if exists('b:pairs')
        for left in keys(b:pairs)
            let right = b:pairs[left]
            exe 'iunmap <buffer> ' . left
            exe 'iunmap <buffer> ' . right
        endfor

        for item in b:quotes
            exe 'iunmap <buffer> ' . item
        endfor
    endif

    let b:pairs = {}
    " TODO: use better logic to get the pairs
    for pair in split(&l:matchpairs, ',')
        let b:pairs[pair[0]] = pair[2]
    endfor

    let b:quotes = ["'", '"']
    if !has_key(b:pairs, '`')
        call add(b:quotes, '`')
    endif
    if &filetype == 'tex'
        call add(b:quotes, '$')
    endif

    let map = 'inoremap <silent> <buffer> <expr> '

    " initialize pairs
    for left in keys(b:pairs)
        let right = b:pairs[left]
        exe map . left . ' <SID>Open("' . left . '")'
        exe map . right . ' <SID>Close("' . right . '")'
    endfor

    " initialize quotes
    for item in b:quotes
        let key = escape(item, '"')
        exe map . item . ' <SID>Quote("' . key . '")'
    endfor

    if g:pairs_cpp_angle && &filetype =~ s:cpp
        exe map . '< <SID>Open("<")'
        exe map . '> <SID>Close(">")'
    endif

    call s:Clear()
endfunction " }}}

function! s:Clear() " {{{
    let b:pendings = []
endfunction " }}}

function! s:Map(key, rhs) " {{{
    let info = maparg(a:key, 'i', 0, 1)

    if empty(info)
        " by default, expand abbreviations and insert that key
        let map = s:abbr . a:key
    else
        " add to existing mapping for plugin compatibility
        let map = info['rhs']

        " expand <Plug>
        let map = substitute(map,
                    \ '\(<Plug>\w\+\)',
                    \ '\=maparg(submatch(1), "i")',
                    \ 'g')
        " expand <SID>
        let map = substitute(map,
                    \ '<SID>',
                    \ '<SNR>' . info['sid'] . '_',
                    \ 'g')
    endif

    exe 'imap <script> ' . a:key . ' ' . map . '<SID>' . a:rhs
endfunction " }}}

augroup pairs " {{{
    autocmd!

    autocmd BufWinEnter * call <SID>Remap()
    autocmd InsertLeave * call <SID>Clear()

    if has('patch-7.4.786')
        autocmd OptionSet matchpairs call <SID>Remap()
    endif
augroup END " }}}

" Setup mappings {{{
inoremap <silent> <SID>Enter <C-R>=<SID>Enter()<CR>
inoremap <silent> <SID>Space <C-R>=<SID>Space()<CR>
inoremap <silent> <SID>Backspace <C-R>=<SID>Backspace()<CR>

call s:Map('<CR>', 'Enter')
call s:Map('<Space>', 'Space')

" compatibility for backspace is impossible,
" since we need to check before deleting anything
imap <script> <BS> <SID>Backspace
" }}}
