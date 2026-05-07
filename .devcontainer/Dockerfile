FROM Zillaforge/terraform:0.0.1-alpha

RUN apk add zsh-vcs tmux less && \
    sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v1.2.1/zsh-in-docker.sh)" -- \
    -t agnoster \
    -p git \
    -p z \
    -p terraform \
    -p https://github.com/zsh-users/zsh-autosuggestions \
    -a 'export TERM=xterm-256color' \
    -a 'export PAGER="less -FRX"' \
    -a 'export GIT_PAGER="less -FRX"' \
    -a 'export LESS="FRX"' \
    -a 'ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=2"' \
    -a 'AGNOSTER_CONTEXT_BG=52' \
    -a 'AGNOSTER_CONTEXT_FG=white' \
    -a 'AGNOSTER_DIR_BG=cyan' \
    -a 'AGNOSTER_DIR_FG=black' \
    -p https://github.com/zsh-users/zsh-completions

RUN sed -i '/## Main/i prompt_newline() { \n\
 if [[ -n $CURRENT_BG ]]; then\n\
   echo -n " %{%k%F{$CURRENT_BG}%}$SEGMENT_SEPARATOR\n\
%{%k%F{$CURRENT_BG}%}$SEGMENT_SEPARATOR"\n\
 else\n\
   echo -n " %{%k%}"\n\
 fi\n\
 echo -n " %{%f%}"\n\
 CURRENT_BG=''\n\
}' /root/.oh-my-zsh/themes/agnoster.zsh-theme && \
    sed -i 's/  prompt_hg/  prompt_hg\n  prompt_newline/' /root/.oh-my-zsh/themes/agnoster.zsh-theme
