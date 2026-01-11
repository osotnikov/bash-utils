dlog () 
{ 
    docker logs $1 | sed 's/\\n/\n/g; s/\\t/\t/g' | batcat --language=java
}


alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'
alias dcd='docker compose down -v'
alias dcu='docker compose up -d'
alias dpsv='viddy "docker ps --format \"{{.ID}}\t{{.Names}}\t{{.Status}}\""'
alias egrep='egrep --color=auto'
alias emacs='emacsclient -c -a '\''emacs'\'''
alias fgrep='fgrep --color=auto'
alias grep='grep --color=auto'
alias l='ls -CF'
alias la='ls -A'
alias ll='ls -alF'
alias ls='ls --color=auto'
alias psql_x='psql -h localhost -p 5432 -U username -d database'
