    (push "/usr/local/bin" exec-path)
    (setq make-backup-files nil)
    (setq auto-save-default nil)
    (setq-default tab-width 2)
    (setq-default indent-tabs-mode nil)
    (setq inhibit-startup-message t)
    (fset 'yes-or-no-p 'y-or-n-p)
    (delete-selection-mode t)
    (scroll-bar-mode -1)
    (tool-bar-mode -1)
    (blink-cursor-mode t)
    (show-paren-mode t)
    (column-number-mode t)
    (set-fringe-style -1)
(tooltip-mode -1)



(require 'package)
(add-to-list 'package-archives
             '("marmalade" . "http://marmalade-repo.org/packages/") t)
(package-initialize)
(when (not package-archive-contents)
  (package-refresh-contents))

;; Add in your own as you wish:
(defvar my-packages '(starter-kit starter-kit-lisp starter-kit-bindings)
  "A list of packages to ensure are installed at launch.")

(dolist (p my-packages)
  (when (not (package-installed-p p))
    (package-install p)))

(add-to-list 'load-path "~/.emacs.d/themes")
;;(require 'color-theme)
;;    (color-theme-initialize)
;;(color-theme-robin-hood)
(require 'color-theme-ir-black)
(color-theme-ir-black)

(add-to-list 'load-path "~/.emacs.d/slime/slime-2012-04-24/")
(require 'slime)
(add-hook 'lisp-mode-hook (lambda () (slime-mode t)))
(add-hook 'inferior-lisp-mode-hook (lambda () (inferior-slime-mode t)))
;; Optionally, specify the lisp program you are using. Default is "lisp"
(setq inferior-lisp-program "yourlisp")


;; Load shell variables at emacs start

(defun env-var-from-shell (varname)
  (replace-regexp-in-string
   "[[:space:]\n]*$" ""
   (shell-command-to-string (concat "$SHELL -l -c 'echo $" varname
"'"))))

(defun setenv-from-shell (varname)
  (setenv varname (env-var-from-shell varname)))


(when window-system
  (setenv-from-shell "LEIN_PATH")
  (let ((path-from-shell (env-var-from-shell "PATH")))
    (setenv "PATH" (concat path-from-shell ":" (getenv "PATH")))
    (setq exec-path (append exec-path
                            (split-string path-from-shell path-separator))))) 
