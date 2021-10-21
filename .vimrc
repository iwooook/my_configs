
"Vundle
set nocompatible              " be iMproved, required
filetype off                  " required

" set the runtime path to include Vundle and initialize
set rtp+=~/.vim/bundle/Vundle.vim
call vundle#begin()
" alternatively, pass a path where Vundle should install plugins
"call vundle#begin('~/some/path/here')

" let Vundle manage Vundle, required
Plugin 'VundleVim/Vundle.vim'

" The following are examples of different formats supported.
" Keep Plugin commands between vundle#begin/end.
" plugin on GitHub repo
"Plugin 'tpope/vim-fugitive'


Plugin 'vim-airline/vim-airline'

Plugin 'scrooloose/nerdtree'

Plugin 'wesleyche/srcexpl'

Plugin 'taglist.vim'

" All of your Plugins must be added before the following line
call vundle#end()            " required
filetype plugin indent on    " required
" To ignore plugin indent changes, instead use:
"filetype plugin on
"
" Brief help
" :PluginList       - lists configured plugins
" :PluginInstall    - installs plugins; append `!` to update or just :PluginUpdate
" :PluginSearch foo - searches for foo; append `!` to refresh local cache
" :PluginClean      - confirms removal of unused plugins; append `!` to auto-approve removal
"
" see :h vundle for more details or wiki for FAQ
" Put your non-Plugin stuff after this line


" line number
set nu
" highlight search
set hlsearch

" tabs
set smartindent
set expandtab "tab to space
set tabstop=2
set shiftwidth=2

if has ("cscope")
  if filereadable("cscope.out")
    cs add cscope.out
  endif
  set cscopeverbose
endif

" map <key> :<cmd>
" nnoremap: normal non-recursive map

""""""""""""""""""""""""""""
" nerdtree
map <F5> :NERDTreeFind<CR>
map <F6> :NERDTreeToggle<CR>
let g:NERDTreeHighlightCursorline = 1

""""""""""""""""""""""""""""
" SrcExpl
" // The switch of the Source Explorer 
nmap <F7> :SrcExplToggle<CR> 

" // Do not let the Source Explorer update the tags file when opening 
let g:SrcExpl_isUpdateTags = 0 

""""""""""""""""""""""""""""
" taglist
map <F8> :TlistToggle<CR>
let Tlist_Use_Right_Window = 1 

""""""""""""""""""""""""""""
" $ find `pwd` -name "*.c" -o -name "*.cpp" -o -name "*.h" -o -name "*.hpp" > cscope.files
" $ cscope -q -R -b -i cscope.files
" $ ctags -R

