;;; openclaw-sessions.el --- Monitor OpenClaw sessions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Federico Stilman

;; Author: Federico Stilman <fstilman@gmail.com>
;; Maintainer: Federico Stilman <fstilman@gmail.com>
;; URL: https://github.com/fstilman/openclaw-sessions
;; Version: 0.3.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, processes, terminals
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Assisted-by: Codex:GPT-5

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Start named OpenClaw TUI sessions in an Emacs terminal and monitor them
;; from a `tabulated-list-mode' dashboard.  Session state comes from the
;; supported `openclaw sessions --json' CLI rather than from terminal output.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'tabulated-list)

(declare-function notifications-notify "notifications" (&rest params))
(declare-function notifications-close-notification "notifications" (id &optional bus))
(declare-function eat-char-mode "eat")
(declare-function eat-make "eat" (name program &optional startfile &rest switches))
(declare-function make-term "term" (name program &optional startfile &rest switches))
(declare-function term-char-mode "term")
(declare-function term-mode "term")
(declare-function vterm "vterm" (&optional buffer-name))
(autoload 'openclaw-sessions-context-resolve-buffer
  "openclaw-sessions-context")
(autoload 'openclaw-sessions-context-session-keys
  "openclaw-sessions-context")
(autoload 'openclaw-sessions-context-source-label-for-key
  "openclaw-sessions-context")
(autoload 'openclaw-sessions-start-at-point
  "openclaw-sessions-context" nil t)
(autoload 'openclaw-sessions-visit-source
  "openclaw-sessions-context" nil t)
(autoload 'openclaw-sessions-forget-context
  "openclaw-sessions-context" nil t)

(defvar vterm-shell)

(defgroup openclaw-sessions nil
  "Start and monitor OpenClaw sessions."
  :group 'tools
  :prefix "openclaw-sessions-")

(defcustom openclaw-sessions-executable "openclaw"
  "OpenClaw executable name or absolute path."
  :type 'string)

(defcustom openclaw-sessions-terminal-backend 'auto
  "Terminal backend used to run OpenClaw TUI sessions.

`auto' selects the first available backend in this order: vterm, Eat, then
the built-in Term.  The values `vterm', `eat', and `term' select a backend
explicitly.

A function value is called with SESSION-NAME, EXECUTABLE, ARGUMENTS, and
DIRECTORY.  It must launch the TUI and return its live Emacs buffer."
  :type '(choice (const :tag "Automatic" auto)
                 (const :tag "VTerm" vterm)
                 (const :tag "Eat" eat)
                 (const :tag "Built-in Term" term)
                 (function :tag "Custom launcher")))

(defcustom openclaw-sessions-refresh-interval 10
  "Seconds between asynchronous session refreshes.

Set this to nil to disable automatic refreshes."
  :type '(choice (const :tag "Manual refresh only" nil)
                 (number :tag "Seconds")))

(defcustom openclaw-sessions-active-minutes 1440
  "Only request sessions active within this many minutes."
  :type 'integer)

(defcustom openclaw-sessions-limit 100
  "Maximum number of sessions requested from OpenClaw."
  :type 'integer)

(defcustom openclaw-sessions-all-agents t
  "When non-nil, request sessions belonging to every configured agent."
  :type 'boolean)

(defcustom openclaw-sessions-agent-cache-seconds 60
  "Seconds to cache configured agent completion candidates."
  :type 'number)

(defcustom openclaw-sessions-dashboard-scope 'managed
  "Sessions shown in the dashboard and summarized in the mode line.

`managed' shows sessions launched or attached by this package.
`direct' shows every recent direct session.  `all' includes channel,
cron, and other session kinds."
  :type '(choice (const managed) (const direct) (const all)))

(defcustom openclaw-sessions-mode-line-prefix "   "
  "Text inserted before the OpenClaw mode-line indicator."
  :type 'string)

(defcustom openclaw-sessions-launch-directory nil
  "Directory from which to launch `openclaw tui'.

Nil preserves the current buffer's `default-directory'.  This directory does
not become the OpenClaw agent workspace.  It matters only because OpenClaw can
infer an agent when the process starts inside that agent's configured
workspace.  A directory value makes launches deterministic.  A function value
is called without arguments and must return a directory."
  :type '(choice (const :tag "Inherit default-directory" nil)
                 (directory :tag "Fixed directory")
                 (function :tag "Directory function")))

(defcustom openclaw-sessions-default-agent nil
  "Agent used for new sessions, or nil to let OpenClaw select it.

When non-nil, the launcher passes a full `agent:ID:SESSION' key.  When nil,
OpenClaw uses its native selection rules, including CWD-based agent inference."
  :type '(choice (const :tag "OpenClaw decides" nil)
                 (string :tag "Agent ID")))

(defcustom openclaw-sessions-notify-on-completion t
  "When non-nil, notify when a managed session stops running."
  :type 'boolean)

(defface openclaw-sessions-running-face
  '((t :inherit warning :weight bold))
  "Face used for running sessions."
  :group 'openclaw-sessions)

(defface openclaw-sessions-done-face
  '((t :inherit success))
  "Face used for successfully completed sessions."
  :group 'openclaw-sessions)

(defface openclaw-sessions-failed-face
  '((t :inherit error :weight bold))
  "Face used for failed, killed, or timed-out sessions."
  :group 'openclaw-sessions)

(defface openclaw-sessions-unknown-face
  '((t :inherit shadow))
  "Face used when session state is not available."
  :group 'openclaw-sessions)

(defface openclaw-sessions-unseen-face
  '((t :inherit warning))
  "Face used for completions that have not been reviewed."
  :group 'openclaw-sessions)

(defvar-local openclaw-sessions--session-name nil)
(defvar-local openclaw-sessions--session-agent nil)
(defvar-local openclaw-sessions--session-key nil)
(defvar-local openclaw-sessions--launched-at nil)
(defvar-local openclaw-sessions--context-source-id nil)
(defvar-local openclaw-sessions--context-source-label nil)

(defvar openclaw-sessions--sessions nil)
(defvar openclaw-sessions--refresh-process nil)
(defvar openclaw-sessions--refresh-timer nil)
(defvar openclaw-sessions--last-error nil)
(defvar openclaw-sessions--statuses (make-hash-table :test #'equal))
(defvar openclaw-sessions--unseen-completions
  (make-hash-table :test #'equal))
(defvar openclaw-sessions--notification-ids
  (make-hash-table :test #'equal))
(defvar openclaw-sessions--agent-candidates nil)
(defvar openclaw-sessions--agent-candidates-at nil)

(defvar openclaw-sessions-mode-line
  '(:eval (openclaw-sessions-mode-line-string))
  "Mode-line construct showing managed OpenClaw session counts.")

(put 'openclaw-sessions-mode-line 'risky-local-variable t)

(defconst openclaw-sessions--terminal-statuses
  '("done" "timeout" "killed" "failed"))

(defun openclaw-sessions--executable ()
  "Return the resolved OpenClaw executable, or nil."
  (if (file-name-absolute-p openclaw-sessions-executable)
      (and (file-executable-p openclaw-sessions-executable)
           openclaw-sessions-executable)
    (executable-find openclaw-sessions-executable)))

(defun openclaw-sessions--session-agent-candidates ()
  "Return agent IDs found in the current session cache."
  (delete-dups
   (delq nil
         (mapcar (lambda (session)
                   (car (openclaw-sessions--session-parts
                         (openclaw-sessions--session-key session))))
                 openclaw-sessions--sessions))))

(defun openclaw-sessions--load-agent-candidates ()
  "Load configured agent IDs from OpenClaw."
  (let ((executable (openclaw-sessions--executable)))
    (if (not executable)
        (openclaw-sessions--session-agent-candidates)
      (let ((stderr-file (make-temp-file "openclaw-agents-stderr-"))
            (default-directory temporary-file-directory))
        (unwind-protect
            (with-temp-buffer
              (if (zerop (process-file executable nil
                                       (list (current-buffer) stderr-file)
                                       nil "agents" "list" "--json"))
                  (let ((agents
                         (progn
                           (goto-char (point-min))
                           (json-parse-buffer :object-type 'alist
                                              :array-type 'list
                                              :null-object nil
                                              :false-object nil))))
                    (delete-dups
                     (delq nil
                           (mapcar (lambda (agent) (alist-get 'id agent))
                                   agents))))
                (openclaw-sessions--session-agent-candidates)))
          (when (file-exists-p stderr-file)
            (delete-file stderr-file)))))))

(defun openclaw-sessions--agent-candidates ()
  "Return fresh configured agent completion candidates."
  (when (or (null openclaw-sessions--agent-candidates-at)
            (> (- (float-time) openclaw-sessions--agent-candidates-at)
               openclaw-sessions-agent-cache-seconds))
    (condition-case nil
        (setq openclaw-sessions--agent-candidates
              (openclaw-sessions--load-agent-candidates)
              openclaw-sessions--agent-candidates-at (float-time))
      (error
       (setq openclaw-sessions--agent-candidates
             (openclaw-sessions--session-agent-candidates)
             openclaw-sessions--agent-candidates-at (float-time)))))
  openclaw-sessions--agent-candidates)

(defun openclaw-sessions-read-agent ()
  "Read an agent ID with completion, returning nil for automatic selection."
  (let ((agent
         (completing-read "OpenClaw agent (blank = automatic): "
                          (openclaw-sessions--agent-candidates)
                          nil nil nil nil openclaw-sessions-default-agent)))
    (unless (string-empty-p agent)
      agent)))

(defun openclaw-sessions--session-parts (key)
  "Return (AGENT NAME) parsed from OpenClaw session KEY."
  (when (and (stringp key)
             (string-match "\\`agent:\\([^:]+\\):\\(.+\\)\\'" key))
    (list (match-string 1 key) (match-string 2 key))))

(defun openclaw-sessions--session-key (session)
  "Return SESSION's key."
  (alist-get 'key session))

(defun openclaw-sessions--session-status (session)
  "Return normalized status for SESSION."
  (or (alist-get 'status session) "unknown"))

(defun openclaw-sessions--managed-buffers ()
  "Return live buffers managed by this package."
  (cl-remove-if-not
   (lambda (buffer)
     (buffer-local-value 'openclaw-sessions--session-name buffer))
   (buffer-list)))

(defun openclaw-sessions--buffer-for-key (key)
  "Return the managed buffer attached to KEY."
  (cl-find-if
   (lambda (buffer)
     (equal key (buffer-local-value 'openclaw-sessions--session-key buffer)))
   (openclaw-sessions--managed-buffers)))

(defun openclaw-sessions--review-current-buffer-completion ()
  "Mark the current managed buffer's completion as reviewed."
  (when (and openclaw-sessions--session-key
             (openclaw-sessions--unseen-p
              openclaw-sessions--session-key))
    (openclaw-sessions--set-unseen openclaw-sessions--session-key nil)))

(defun openclaw-sessions--prepare-managed-buffer ()
  "Install package-local behavior in the current managed buffer."
  (add-hook 'post-command-hook
            #'openclaw-sessions--review-current-buffer-completion nil t))

(defun openclaw-sessions--find-session (key)
  "Return the cached session with KEY."
  (cl-find key openclaw-sessions--sessions
           :key #'openclaw-sessions--session-key :test #'equal))

(defun openclaw-sessions--resolve-buffer-keys ()
  "Associate newly launched buffers with their canonical session keys."
  (dolist (buffer (openclaw-sessions--managed-buffers))
    (with-current-buffer buffer
      (openclaw-sessions--prepare-managed-buffer))
    (unless (buffer-local-value 'openclaw-sessions--session-key buffer)
      (let* ((name (buffer-local-value
                    'openclaw-sessions--session-name buffer))
             (agent (buffer-local-value
                     'openclaw-sessions--session-agent buffer))
             (candidates
              (cl-remove-if-not
               (lambda (session)
                 (pcase (openclaw-sessions--session-parts
                         (openclaw-sessions--session-key session))
                   (`(,candidate-agent ,candidate-name)
                    (and (equal candidate-name (downcase name))
                         (or (null agent)
                             (equal candidate-agent (downcase agent)))))))
               openclaw-sessions--sessions))
             (session
              (car (sort candidates
                         (lambda (left right)
                           (> (or (alist-get 'updatedAt left) 0)
                              (or (alist-get 'updatedAt right) 0)))))))
        (when session
          (with-current-buffer buffer
            (setq openclaw-sessions--session-key
                  (openclaw-sessions--session-key session))
            (when (fboundp 'openclaw-sessions-context-resolve-buffer)
              (openclaw-sessions-context-resolve-buffer buffer))))))))

(defun openclaw-sessions--notify (session status)
  "Notify that SESSION reached terminal STATUS."
  (let* ((key (openclaw-sessions--session-key session))
         (parts (openclaw-sessions--session-parts key))
         (name (or (cadr parts) key)))
    (if (require 'notifications nil t)
        (progn
          (openclaw-sessions--close-notification key)
          (let ((id
                 (notifications-notify
                  :title "OpenClaw session finished"
                  :body (format "%s: %s" name status)
                  :app-name "Emacs"
                  :timeout 0
                  :on-close
                  (lambda (id _reason)
                    (when (equal id (gethash key
                                             openclaw-sessions--notification-ids))
                      (remhash key openclaw-sessions--notification-ids))))))
            (when id
              (puthash key id openclaw-sessions--notification-ids))))
      (message "OpenClaw session finished: %s (%s)" name status))))

(defun openclaw-sessions--record-status-transitions ()
  "Record current statuses and handle completion transitions."
  (dolist (session openclaw-sessions--sessions)
    (let* ((key (openclaw-sessions--session-key session))
           (status (openclaw-sessions--session-status session))
           (previous (gethash key openclaw-sessions--statuses)))
      (when (and (equal previous "running")
                 (member status openclaw-sessions--terminal-statuses))
        ;; Only direct agent sessions can be reviewed from this dashboard.
        (when (openclaw-sessions--session-parts key)
          (puthash key status openclaw-sessions--unseen-completions))
        (when (and openclaw-sessions-notify-on-completion
                   (openclaw-sessions--buffer-for-key key))
          (openclaw-sessions--notify session status)))
      (puthash key status openclaw-sessions--statuses))))

(defun openclaw-sessions--parse-json-buffer ()
  "Parse an OpenClaw JSON response in the current buffer."
  (goto-char (point-min))
  ;; Be tolerant of diagnostic lines emitted before the JSON document.
  (unless (search-forward "{" nil t)
    (error "OpenClaw returned no JSON object"))
  (backward-char)
  (let ((payload (json-parse-buffer :object-type 'alist
                                    :array-type 'list
                                    :null-object nil
                                    :false-object nil)))
    (or (alist-get 'sessions payload) '())))

(defun openclaw-sessions--finish-refresh (process _event)
  "Handle completion of asynchronous refresh PROCESS."
  (when (memq (process-status process) '(exit signal))
    (let ((buffer (process-buffer process)))
      (unwind-protect
          (if (zerop (process-exit-status process))
              (condition-case error-data
                  (progn
                    (with-current-buffer buffer
                      (setq openclaw-sessions--sessions
                            (openclaw-sessions--parse-json-buffer)))
                    (setq openclaw-sessions--last-error nil)
                    (openclaw-sessions--resolve-buffer-keys)
                    (openclaw-sessions--record-status-transitions))
                (error
                 (setq openclaw-sessions--last-error
                       (error-message-string error-data))))
            (setq openclaw-sessions--last-error
                  (with-current-buffer buffer
                    (string-trim (buffer-string)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))
        (when (eq process openclaw-sessions--refresh-process)
          (setq openclaw-sessions--refresh-process nil))
        (openclaw-sessions--update-dashboard)
        (force-mode-line-update t)))))

;;;###autoload
(defun openclaw-sessions-refresh ()
  "Refresh the OpenClaw session cache asynchronously."
  (interactive)
  (unless (process-live-p openclaw-sessions--refresh-process)
    (let ((executable (openclaw-sessions--executable)))
      (if (not executable)
          (setq openclaw-sessions--last-error
                (format "Executable not found: %s"
                        openclaw-sessions-executable))
        (let ((arguments
               (append (list "sessions" "--json"
                             "--active"
                             (number-to-string
                              openclaw-sessions-active-minutes)
                             "--limit"
                             (number-to-string openclaw-sessions-limit))
                       (when openclaw-sessions-all-agents
                         '("--all-agents"))))
              (buffer (generate-new-buffer " *openclaw-sessions-json*")))
          (setq openclaw-sessions--refresh-process
                (make-process
                 :name "openclaw-sessions-refresh"
                 :buffer buffer
                 :command (cons executable arguments)
                 :connection-type 'pipe
                 :noquery t
                 :sentinel #'openclaw-sessions--finish-refresh)))))))

(defun openclaw-sessions--start-monitor ()
  "Start the refresh timer if automatic refresh is enabled."
  (when (and openclaw-sessions-refresh-interval
             (not (timerp openclaw-sessions--refresh-timer)))
    (setq openclaw-sessions--refresh-timer
          (run-at-time 0 openclaw-sessions-refresh-interval
                       #'openclaw-sessions-refresh))))

(defun openclaw-sessions--stop-monitor ()
  "Stop the refresh timer and any in-flight refresh."
  (when (timerp openclaw-sessions--refresh-timer)
    (cancel-timer openclaw-sessions--refresh-timer))
  (setq openclaw-sessions--refresh-timer nil)
  (when (process-live-p openclaw-sessions--refresh-process)
    (delete-process openclaw-sessions--refresh-process))
  (setq openclaw-sessions--refresh-process nil))

(defun openclaw-sessions--managed-session-keys ()
  "Return canonical keys for sessions managed by this package."
  (delete-dups
   (append
    (delq nil
          (mapcar
           (lambda (buffer)
             (buffer-local-value 'openclaw-sessions--session-key buffer))
           (openclaw-sessions--managed-buffers)))
    (when (fboundp 'openclaw-sessions-context-session-keys)
      (openclaw-sessions-context-session-keys)))))

(defun openclaw-sessions--sessions-for-scope (&optional scope)
  "Return cached sessions selected by SCOPE.

SCOPE defaults to `openclaw-sessions-dashboard-scope'."
  (pcase (or scope openclaw-sessions-dashboard-scope)
    ('all openclaw-sessions--sessions)
    ('direct
     (cl-remove-if-not
      (lambda (session)
        (equal (alist-get 'kind session) "direct"))
      openclaw-sessions--sessions))
    (_
     (let ((keys (openclaw-sessions--managed-session-keys)))
       (cl-remove-if-not
        (lambda (session)
          (member (openclaw-sessions--session-key session) keys))
        openclaw-sessions--sessions)))))

(defun openclaw-sessions--unseen-p (key)
  "Return non-nil when KEY has an unreviewed completion."
  (and (stringp key)
       (gethash key openclaw-sessions--unseen-completions)))

(defun openclaw-sessions--close-notification (key)
  "Close and forget the completion notification for session KEY."
  (when-let ((id (gethash key openclaw-sessions--notification-ids)))
    (remhash key openclaw-sessions--notification-ids)
    (when (require 'notifications nil t)
      (notifications-close-notification id))))

(defun openclaw-sessions--set-unseen (key unseen)
  "Set whether session KEY has an UNSEEN completion."
  (if unseen
      (puthash key t openclaw-sessions--unseen-completions)
    (remhash key openclaw-sessions--unseen-completions)
    (openclaw-sessions--close-notification key))
  (openclaw-sessions--update-dashboard)
  (force-mode-line-update t))

(defun openclaw-sessions-mode-line-string ()
  "Return a compact mode-line summary for the active session scope."
  (let ((running 0)
        (done 0)
        (failed 0)
        (unseen 0))
    (dolist (session (openclaw-sessions--sessions-for-scope))
      (let ((status (openclaw-sessions--session-status session))
            (key (openclaw-sessions--session-key session)))
        (when (openclaw-sessions--unseen-p key)
          (cl-incf unseen))
        (cond ((equal status "running") (cl-incf running))
              ((equal status "done") (cl-incf done))
              ((member status '("timeout" "killed" "failed"))
               (cl-incf failed)))))
    (when (or (> running 0) (> done 0) (> failed 0))
      (concat
       openclaw-sessions-mode-line-prefix
       "OC:"
       (propertize (format "%d▶" running)
                   'face 'openclaw-sessions-running-face)
       " "
       (propertize (format "%d✓" done)
                   'face 'openclaw-sessions-done-face)
       (when (> unseen 0)
         (concat " "
                 (propertize (format "%d●" unseen)
                             'face 'openclaw-sessions-unseen-face)))
       (when (> failed 0)
         (concat " "
                 (propertize (format "%d!" failed)
                             'face 'openclaw-sessions-failed-face)))))))

;;;###autoload
(define-minor-mode openclaw-sessions-monitor-mode
  "Globally monitor OpenClaw sessions in the active scope."
  :global t
  :group 'openclaw-sessions
  (if openclaw-sessions-monitor-mode
      (progn
        (unless (memq 'openclaw-sessions-mode-line global-mode-string)
          (setq global-mode-string
                (append global-mode-string
                        '(openclaw-sessions-mode-line))))
        (openclaw-sessions--start-monitor)
        (openclaw-sessions-refresh))
    (openclaw-sessions--stop-monitor)
    (setq global-mode-string
          (delete 'openclaw-sessions-mode-line global-mode-string))
    (force-mode-line-update t)))

(defun openclaw-sessions--launch-directory ()
  "Return the directory from which a TUI should be launched."
  (let ((directory
         (cond ((functionp openclaw-sessions-launch-directory)
                (funcall openclaw-sessions-launch-directory))
               (openclaw-sessions-launch-directory
                openclaw-sessions-launch-directory)
               (t default-directory))))
    (unless (and (stringp directory) (file-directory-p directory))
      (user-error "Invalid OpenClaw launch directory: %S" directory))
    (when (file-remote-p directory)
      (user-error "OpenClaw TUI launch directory must be local: %s" directory))
    (file-name-as-directory (expand-file-name directory))))

(defun openclaw-sessions--existing-buffer (name agent)
  "Return an existing managed buffer for session NAME and AGENT."
  (cl-find-if
   (lambda (buffer)
     (and (equal name (buffer-local-value
                       'openclaw-sessions--session-name buffer))
          (equal agent (buffer-local-value
                        'openclaw-sessions--session-agent buffer))))
   (openclaw-sessions--managed-buffers)))

(defun openclaw-sessions--terminal-name (name agent)
  "Return a display name for session NAME and AGENT."
  (if agent (format "%s/%s" agent name) name))

(defun openclaw-sessions--terminal-buffer-name (session-name)
  "Return the conventional terminal buffer name for SESSION-NAME."
  (format "*openclaw:%s*" session-name))

(defun openclaw-sessions--backend-available-p (backend)
  "Return non-nil when terminal BACKEND appears available."
  (pcase backend
    ('vterm (and module-file-suffix
                 (locate-library "vterm")
                 (locate-library "vterm-module")))
    ('eat (locate-library "eat"))
    ('term t)
    (_ nil)))

(defun openclaw-sessions--resolved-terminal-backend ()
  "Return the configured terminal backend, resolving `auto'."
  (let ((backend openclaw-sessions-terminal-backend))
    (cond
     ((eq backend 'auto)
      (or (cl-find-if #'openclaw-sessions--backend-available-p
                      '(vterm eat term))
          (user-error "No supported terminal backend is available")))
     ((memq backend '(vterm eat term)) backend)
     ((functionp backend) backend)
     (t (user-error "Invalid terminal backend: %S" backend)))))

(defun openclaw-sessions--launch-vterm
    (session-name executable arguments directory)
  "Launch SESSION-NAME with EXECUTABLE and ARGUMENTS in VTerm at DIRECTORY."
  (unless (require 'vterm nil t)
    (user-error "VTerm backend selected, but the vterm package is unavailable"))
  (let* ((default-directory directory)
         (buffer-name (openclaw-sessions--terminal-buffer-name session-name))
         (command (mapconcat #'shell-quote-argument
                             (cons executable arguments) " "))
         (vterm-shell command)
         (buffer (vterm buffer-name)))
    (setq buffer (or (and (bufferp buffer) buffer)
                     (get-buffer buffer-name)))
    buffer))

(defun openclaw-sessions--launch-eat
    (session-name executable arguments directory)
  "Launch SESSION-NAME with EXECUTABLE and ARGUMENTS in Eat at DIRECTORY."
  (unless (require 'eat nil t)
    (user-error "Eat backend selected, but the eat package is unavailable"))
  (let* ((default-directory directory)
         (buffer (apply #'eat-make (format "openclaw:%s" session-name)
                        executable nil arguments)))
    (with-current-buffer buffer
      (eat-char-mode))
    (pop-to-buffer buffer)
    buffer))

(defun openclaw-sessions--launch-term
    (session-name executable arguments directory)
  "Launch SESSION-NAME with EXECUTABLE and ARGUMENTS in Term at DIRECTORY."
  (require 'term)
  (let* ((default-directory directory)
         (buffer (apply #'make-term (format "openclaw:%s" session-name)
                        executable nil arguments)))
    (with-current-buffer buffer
      (term-mode)
      (term-char-mode))
    (pop-to-buffer buffer)
    buffer))

(defun openclaw-sessions--launch-terminal
    (session-name executable arguments directory)
  "Launch a terminal for SESSION-NAME and return its buffer.

EXECUTABLE and ARGUMENTS form the command, and DIRECTORY is its working
directory."
  (let* ((backend (openclaw-sessions--resolved-terminal-backend))
         (buffer
          (if (memq backend '(vterm eat term))
              (funcall
             (pcase backend
               ('vterm #'openclaw-sessions--launch-vterm)
               ('eat #'openclaw-sessions--launch-eat)
               ('term #'openclaw-sessions--launch-term))
             session-name executable arguments directory)
            (funcall backend session-name executable arguments directory))))
    (unless (buffer-live-p buffer)
      (user-error "Terminal backend %S did not return a live buffer" backend))
    buffer))

;;;###autoload
(defun openclaw-sessions-start (session-name &optional agent initial-message)
  "Start or visit an OpenClaw TUI for SESSION-NAME.

AGENT defaults to `openclaw-sessions-default-agent'.  Interactively, a prefix
argument prompts for an agent ID.  Without an explicit agent, OpenClaw retains
its native selection rules, including inference from the launch directory.
When INITIAL-MESSAGE is non-nil, send it after the new TUI connects.  It is
never sent when merely visiting an existing managed buffer."
  (interactive
   (list (read-string "OpenClaw session name: ")
         (when current-prefix-arg
           (openclaw-sessions-read-agent))))
  (setq session-name (string-trim session-name)
        agent (or agent openclaw-sessions-default-agent))
  (when (string-empty-p session-name)
    (user-error "Session name cannot be empty"))
  (if-let ((buffer (openclaw-sessions--existing-buffer session-name agent)))
      (progn
        (with-current-buffer buffer
          (openclaw-sessions--prepare-managed-buffer))
        (pop-to-buffer buffer))
    (unless (openclaw-sessions--executable)
      (user-error "Executable not found: %s" openclaw-sessions-executable))
    (let* ((default-directory (openclaw-sessions--launch-directory))
           (executable (openclaw-sessions--executable))
           (target (if agent
                       (format "agent:%s:%s" agent session-name)
                     session-name))
           (arguments (append (list "tui" "--session" target)
                              (when initial-message
                                (list "--message" initial-message))))
           (terminal-name
            (openclaw-sessions--terminal-name session-name agent))
           (buffer (openclaw-sessions--launch-terminal
                    terminal-name executable arguments default-directory)))
      (pop-to-buffer buffer)
      (with-current-buffer buffer
        (setq-local openclaw-sessions--session-name session-name
                    openclaw-sessions--session-agent agent
                    openclaw-sessions--session-key
                    (and agent (downcase target))
                    openclaw-sessions--launched-at (float-time))
        (openclaw-sessions--prepare-managed-buffer))
      (openclaw-sessions-monitor-mode 1)
      buffer)))

(defun openclaw-sessions--format-age (session)
  "Format the age of SESSION's last update."
  (let* ((age-ms
          (or (alist-get 'ageMs session)
              (when-let ((updated-at (alist-get 'updatedAt session)))
                (- (* 1000 (float-time)) updated-at))))
         (seconds (and age-ms (max 0 (/ age-ms 1000)))))
    (cond ((null seconds) "—")
          ((< seconds 60) (format "%ds" seconds))
          ((< seconds 3600) (format "%dm" (/ seconds 60)))
          ((< seconds 86400) (format "%dh" (/ seconds 3600)))
          (t (format "%dd" (/ seconds 86400))))))

(defun openclaw-sessions--status-cell (status)
  "Return a propertized dashboard cell for STATUS."
  (propertize
   (upcase status)
   'face (cond ((equal status "running")
                'openclaw-sessions-running-face)
               ((equal status "done")
                'openclaw-sessions-done-face)
               ((member status '("timeout" "killed" "failed"))
                'openclaw-sessions-failed-face)
               (t 'openclaw-sessions-unknown-face))))

(defun openclaw-sessions--unseen-cell (key)
  "Return the dashboard attention marker for session KEY."
  (if (openclaw-sessions--unseen-p key)
      (propertize "●" 'face 'openclaw-sessions-unseen-face
                  'help-echo "Completion not yet reviewed")
    ""))

(defun openclaw-sessions--format-tokens (session)
  "Format token usage for SESSION."
  (let ((total (alist-get 'totalTokens session))
        (context (alist-get 'contextTokens session)))
    (cond ((and (numberp total) (numberp context) (> context 0))
           (format "%.0fk/%.0fk (%d%%)"
                   (/ total 1000.0) (/ context 1000.0)
                   (round (* 100.0 (/ total (float context))))))
          ((numberp total) (format "%.0fk" (/ total 1000.0)))
          (t "—"))))

(defun openclaw-sessions--session-row (session)
  "Build a tabulated-list row for SESSION."
  (let* ((key (openclaw-sessions--session-key session))
         (parts (openclaw-sessions--session-parts key))
         (agent (or (car parts) (alist-get 'agentId session) "—"))
         (name (or (cadr parts) (alist-get 'label session) key "—"))
         (status (openclaw-sessions--session-status session))
         (buffer (openclaw-sessions--buffer-for-key key))
         (source
          (when (fboundp 'openclaw-sessions-context-source-label-for-key)
            (openclaw-sessions-context-source-label-for-key key))))
    (list key
          (vector (openclaw-sessions--unseen-cell key)
                  (openclaw-sessions--status-cell status)
                  name
                  agent
                  (openclaw-sessions--format-age session)
                  (or (alist-get 'model session) "—")
                  (openclaw-sessions--format-tokens session)
                  (if buffer "yes" "")
                  (or source "")))))

(defun openclaw-sessions--placeholder-row (buffer)
  "Build a placeholder row for unresolved managed BUFFER."
  (let ((name (buffer-local-value
               'openclaw-sessions--session-name buffer))
        (agent (buffer-local-value
                'openclaw-sessions--session-agent buffer)))
    (list (cons 'buffer buffer)
          (vector "" (openclaw-sessions--status-cell "unknown")
                  name (or agent "auto") "—" "—" "—" "yes"
                  (or (buffer-local-value
                       'openclaw-sessions--context-source-label buffer)
                      "")))))

(defun openclaw-sessions--dashboard-entries ()
  "Return entries for `openclaw-sessions-dashboard-scope'."
  (let* ((scope openclaw-sessions-dashboard-scope)
         (sessions (openclaw-sessions--sessions-for-scope scope))
         (rows (mapcar #'openclaw-sessions--session-row sessions)))
    (when (eq scope 'managed)
      (dolist (buffer (openclaw-sessions--managed-buffers))
        (unless (buffer-local-value 'openclaw-sessions--session-key buffer)
          (push (openclaw-sessions--placeholder-row buffer) rows))))
    rows))

(defun openclaw-sessions--update-dashboard ()
  "Update every visible OpenClaw dashboard."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'openclaw-sessions-mode)
        (setq tabulated-list-entries
              (openclaw-sessions--dashboard-entries)
              header-line-format
              (format " Scope: %s" openclaw-sessions-dashboard-scope))
        (tabulated-list-print t)))))

(defun openclaw-sessions-visit ()
  "Visit or attach to the session on the current dashboard row.

Visiting a session marks its latest completion as reviewed."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (cond
     ((and (consp id) (eq (car id) 'buffer)
           (buffer-live-p (cdr id)))
      (pop-to-buffer (cdr id)))
     ((stringp id)
      (if-let ((buffer (openclaw-sessions--buffer-for-key id)))
          (pop-to-buffer buffer)
        (pcase (openclaw-sessions--session-parts id)
          (`(,agent ,name) (openclaw-sessions-start name agent))
          (_ (user-error "Cannot attach to session: %s" id))))
      (openclaw-sessions--set-unseen id nil))
     (t (user-error "No session on this row")))))

(defun openclaw-sessions-mark-reviewed ()
  "Mark the session on the current dashboard row as reviewed."
  (interactive)
  (let ((key (tabulated-list-get-id)))
    (unless (stringp key)
      (user-error "Session key has not been resolved yet"))
    (openclaw-sessions--set-unseen key nil)
    (message "OpenClaw completion marked as reviewed")))

(defun openclaw-sessions-mark-unreviewed ()
  "Mark the session on the current dashboard row as unreviewed."
  (interactive)
  (let ((key (tabulated-list-get-id)))
    (unless (stringp key)
      (user-error "Session key has not been resolved yet"))
    (openclaw-sessions--set-unseen key t)
    (message "OpenClaw completion marked as unreviewed")))

(defun openclaw-sessions-tail ()
  "Show recent trajectory events for the session on the current row."
  (interactive)
  (let ((key (tabulated-list-get-id))
        (executable (openclaw-sessions--executable)))
    (unless (stringp key)
      (user-error "Session key has not been resolved yet"))
    (unless executable
      (user-error "Executable not found: %s" openclaw-sessions-executable))
    (let ((buffer (get-buffer-create "*OpenClaw session tail*")))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (special-mode)))
      (make-process
       :name "openclaw-sessions-tail"
       :buffer buffer
       :command (list executable "sessions" "tail"
                      "--session-key" key "--tail" "80")
       :connection-type 'pipe
       :noquery t)
      (display-buffer buffer)
      (openclaw-sessions--set-unseen key nil))))

(defun openclaw-sessions-cycle-scope ()
  "Cycle the dashboard and mode-line scope globally."
  (interactive)
  (setq openclaw-sessions-dashboard-scope
        (pcase openclaw-sessions-dashboard-scope
          ('managed 'direct)
          ('direct 'all)
          (_ 'managed)))
  (openclaw-sessions--update-dashboard)
  (force-mode-line-update t))

(defvar openclaw-sessions-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'openclaw-sessions-visit)
    (define-key map (kbd "m") #'openclaw-sessions-mark-reviewed)
    (define-key map (kbd "u") #'openclaw-sessions-mark-unreviewed)
    (define-key map (kbd "n") #'openclaw-sessions-start)
    (define-key map (kbd "g") #'openclaw-sessions-refresh)
    (define-key map (kbd "s") #'openclaw-sessions-cycle-scope)
    (define-key map (kbd "t") #'openclaw-sessions-tail)
    (define-key map (kbd "o") #'openclaw-sessions-visit-source)
    (define-key map (kbd "D") #'openclaw-sessions-forget-context)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `openclaw-sessions-mode'.")

;;;###autoload
(define-derived-mode openclaw-sessions-mode tabulated-list-mode
  "OpenClaw-Sessions"
  "Major mode for monitoring OpenClaw sessions."
  (setq tabulated-list-format
        [("New" 4 nil)
         ("Status" 10 t)
         ("Session" 38 t)
         ("Agent" 12 t)
         ("Updated" 10 nil)
         ("Model" 18 t)
         ("Tokens" 18 nil)
         ("Buffer" 7 nil)
         ("Source" 24 t)])
  (setq tabulated-list-padding 2
        tabulated-list-sort-key '("Status" . nil)
        tabulated-list-entries (openclaw-sessions--dashboard-entries)
        header-line-format
        (format " Scope: %s" openclaw-sessions-dashboard-scope))
  (tabulated-list-init-header)
  (tabulated-list-print)
  (openclaw-sessions-monitor-mode 1))

;;;###autoload
(defun openclaw-sessions ()
  "Display the OpenClaw sessions dashboard."
  (interactive)
  (let ((buffer (get-buffer-create "*OpenClaw Sessions*")))
    (with-current-buffer buffer
      (openclaw-sessions-mode))
    (pop-to-buffer buffer)
    (openclaw-sessions-refresh)))

(provide 'openclaw-sessions)

;;; openclaw-sessions.el ends here
