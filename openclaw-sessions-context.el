;;; openclaw-sessions-context.el --- Context-aware OpenClaw sessions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Federico Stilman

;; Author: Federico Stilman <fstilman@gmail.com>
;; Maintainer: Federico Stilman <fstilman@gmail.com>
;; URL: https://github.com/fstilman/openclaw-sessions
;; Version: 0.3.0
;; Keywords: tools, processes, terminals
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Turn the semantic object at point into a named OpenClaw session.  Context
;; providers extract a stable identity, an initial message, and enough source
;; information to return to the object from the sessions dashboard.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'openclaw-sessions)

(autoload 'openclaw-sessions-org-context "openclaw-sessions-org")
(autoload 'openclaw-sessions-mu4e-context "openclaw-sessions-mu4e")

(declare-function mu4e-view-message-with-message-id "mu4e-view" (msgid))
(declare-function org-find-olp "org" (path &optional this-buffer))
(declare-function org-show-context "org" (&optional key))

(defgroup openclaw-sessions-context nil
  "Create OpenClaw sessions from the object at point."
  :group 'openclaw-sessions
  :prefix "openclaw-sessions-context-")

(cl-defstruct (openclaw-sessions-context
               (:constructor openclaw-sessions-context-create))
  "Context extracted from an Emacs object."
  title source-id source-label message directory agent type location)

(defcustom openclaw-sessions-context-functions
  '(openclaw-sessions-region-context
    openclaw-sessions-org-context
    openclaw-sessions-mu4e-context
    openclaw-sessions-buffer-context)
  "Ordered functions used to extract context at point.

Each function takes no arguments and returns an
`openclaw-sessions-context' object or nil when it does not apply."
  :type 'hook)

(defcustom openclaw-sessions-context-max-characters 12000
  "Maximum number of source characters placed in an initial message."
  :type 'integer)

(defcustom openclaw-sessions-context-name-max-length 64
  "Maximum length of generated session names."
  :type 'integer)

(defcustom openclaw-sessions-context-confirm-before-send 'email
  "When to confirm before sending extracted context to OpenClaw.

The value `email' confirms only mu4e contexts.  The values `always' and
`never' apply to every provider."
  :type '(choice (const :tag "Email contexts only" email)
                 (const :tag "Every context" always)
                 (const :tag "Never" never)))

(defcustom openclaw-sessions-context-registry-file
  (locate-user-emacs-file "openclaw-sessions-contexts.el")
  "File used to persist associations between sources and sessions."
  :type 'file)

(defvar openclaw-sessions-context--registry nil)
(defvar openclaw-sessions-context--registry-loaded-p nil)

(defun openclaw-sessions-context--truncate (text)
  "Return TEXT limited to `openclaw-sessions-context-max-characters'."
  (let ((clean (string-trim (substring-no-properties (or text "")))))
    (if (> (length clean) openclaw-sessions-context-max-characters)
        (concat (substring clean 0 openclaw-sessions-context-max-characters)
                "\n\n[Context truncated by openclaw-sessions]")
      clean)))

(defun openclaw-sessions-context--slug (text)
  "Return a session-name-safe slug made from TEXT."
  (let ((slug (downcase (string-trim (or text "session")))))
    (setq slug (replace-regexp-in-string "[^[:alnum:]]+" "-" slug)
          slug (replace-regexp-in-string "\\`-+\\|-+\\'" "" slug))
    (if (string-empty-p slug) "session" slug)))

(defun openclaw-sessions-context-default-name (context)
  "Return a stable, readable session name for CONTEXT."
  (let* ((suffix (substring
                  (secure-hash 'sha1
                               (openclaw-sessions-context-source-id context))
                  0 8))
         (available (max 1 (- openclaw-sessions-context-name-max-length
                              (length suffix) 1)))
         (slug (openclaw-sessions-context--slug
                (openclaw-sessions-context-title context))))
    (format "%s-%s" (substring slug 0 (min available (length slug))) suffix)))

(defcustom openclaw-sessions-context-name-function
  #'openclaw-sessions-context-default-name
  "Function called with a context to produce its session name."
  :type 'function)

(defun openclaw-sessions-context--load-registry ()
  "Load the context registry once."
  (unless openclaw-sessions-context--registry-loaded-p
    (setq openclaw-sessions-context--registry-loaded-p t
          openclaw-sessions-context--registry
          (when (file-readable-p openclaw-sessions-context-registry-file)
            (condition-case nil
                (with-temp-buffer
                  (insert-file-contents
                   openclaw-sessions-context-registry-file)
                  (read (current-buffer)))
              (error nil)))))
  openclaw-sessions-context--registry)

(defun openclaw-sessions-context--save-registry ()
  "Persist the context registry."
  (let ((directory (file-name-directory
                    (expand-file-name openclaw-sessions-context-registry-file))))
    (make-directory directory t)
    (with-temp-file openclaw-sessions-context-registry-file
      (let ((print-length nil)
            (print-level nil))
        (prin1 openclaw-sessions-context--registry (current-buffer))
        (insert "\n")))
    (set-file-modes openclaw-sessions-context-registry-file #o600)))

(defun openclaw-sessions-context--entry-for-source (source-id)
  "Return the registry entry for SOURCE-ID."
  (cl-find source-id (openclaw-sessions-context--load-registry)
           :key (lambda (entry) (plist-get entry :source-id))
           :test #'equal))

(defun openclaw-sessions-context--entry-for-key (session-key)
  "Return the registry entry for SESSION-KEY."
  (cl-find session-key (openclaw-sessions-context--load-registry)
           :key (lambda (entry) (plist-get entry :session-key))
           :test #'equal))

(defun openclaw-sessions-context--record (context session-name agent buffer)
  "Associate CONTEXT with SESSION-NAME, AGENT, and BUFFER."
  (let* ((source-id (openclaw-sessions-context-source-id context))
         (entry (or (openclaw-sessions-context--entry-for-source source-id)
                    (list :source-id source-id))))
    (setq entry
          (plist-put entry :session-name session-name)
          entry (plist-put entry :agent agent)
          entry (plist-put entry :source-label
                           (openclaw-sessions-context-source-label context))
          entry (plist-put entry :type
                           (openclaw-sessions-context-type context))
          entry (plist-put entry :location
                           (openclaw-sessions-context-location context)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq-local openclaw-sessions--context-source-id source-id
                    openclaw-sessions--context-source-label
                    (openclaw-sessions-context-source-label context))
        (when openclaw-sessions--session-key
          (setq entry (plist-put entry :session-key
                                 openclaw-sessions--session-key)))))
    (setq openclaw-sessions-context--registry
          (cons entry
                (cl-remove source-id openclaw-sessions-context--registry
                           :key (lambda (item) (plist-get item :source-id))
                           :test #'equal)))
    (openclaw-sessions-context--save-registry)
    entry))

(defun openclaw-sessions-context-resolve-buffer (buffer)
  "Record the canonical session key resolved for BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((source-id openclaw-sessions--context-source-id)
                  (session-key openclaw-sessions--session-key)
                  (entry (openclaw-sessions-context--entry-for-source
                          source-id)))
        (setq entry (plist-put entry :session-key session-key)
              openclaw-sessions-context--registry
              (cons entry
                    (cl-remove source-id openclaw-sessions-context--registry
                               :key (lambda (item)
                                      (plist-get item :source-id))
                               :test #'equal)))
        (openclaw-sessions-context--save-registry)))))

(defun openclaw-sessions-context-session-keys ()
  "Return canonical keys for all registered contextual sessions."
  (delq nil
        (mapcar (lambda (entry) (plist-get entry :session-key))
                (openclaw-sessions-context--load-registry))))

(defun openclaw-sessions-context-source-label-for-key (session-key)
  "Return the source label registered for SESSION-KEY."
  (when-let ((entry (openclaw-sessions-context--entry-for-key session-key)))
    (plist-get entry :source-label)))

(defun openclaw-sessions-region-context ()
  "Return a context for the active region, or nil."
  (when (use-region-p)
    (let* ((start (region-beginning))
           (end (region-end))
           (file (buffer-file-name))
           (title (if file
                      (format "Selection in %s" (file-name-nondirectory file))
                    (format "Selection in %s" (buffer-name))))
           (selected (buffer-substring-no-properties start end))
           (identity (format "%s:%d:%d:%s"
                             (or file (buffer-name)) start end
                             (secure-hash 'sha1 selected))))
      (openclaw-sessions-context-create
       :title title
       :source-id (concat "region:" (secure-hash 'sha1 identity))
       :source-label title
       :message (format
                 "Work with the following selected text from Emacs.\n\nSource: %s\n\n--- BEGIN SELECTION ---\n%s\n--- END SELECTION ---"
                 (or file (buffer-name))
                 (openclaw-sessions-context--truncate
                  selected))
       :directory default-directory
       :type (if file 'file 'buffer)
       :location (if file
                     (list :file file :position start)
                   (list :buffer (buffer-name) :position start))))))

(defun openclaw-sessions-buffer-context ()
  "Return a fallback context around point in the current buffer."
  (let* ((file (buffer-file-name))
         (buffer-name-value (buffer-name))
         (half (/ openclaw-sessions-context-max-characters 2))
         (start (max (point-min) (- (point) half)))
         (end (min (point-max) (+ (point) half)))
         (title (if file (file-name-nondirectory file) buffer-name-value))
         (source (or file buffer-name-value)))
    (openclaw-sessions-context-create
     :title (format "Work on %s" title)
     :source-id (format "%s:%s"
                        (if file "file" "buffer")
                        (if file (expand-file-name file) buffer-name-value))
     :source-label title
     :message (format
               "Work on the following Emacs buffer context.\n\nSource: %s\nMajor mode: %s\nPoint: %d\n\n--- BEGIN CONTEXT ---\n%s\n--- END CONTEXT ---"
               source major-mode (point)
               (openclaw-sessions-context--truncate
                (buffer-substring-no-properties start end)))
     :directory default-directory
     :type (if file 'file 'buffer)
     :location (if file
                   (list :file file :position (point))
                 (list :buffer buffer-name-value :position (point))))))

(defun openclaw-sessions-context-at-point ()
  "Return the first context recognized at point."
  (or (run-hook-with-args-until-success
       'openclaw-sessions-context-functions)
      (user-error "No OpenClaw context provider applies here")))

(defun openclaw-sessions-context--confirm-p (context)
  "Return non-nil when CONTEXT may be sent according to user confirmation."
  (let ((confirm
         (or (eq openclaw-sessions-context-confirm-before-send 'always)
             (and (eq openclaw-sessions-context-confirm-before-send 'email)
                  (eq (openclaw-sessions-context-type context) 'mu4e)))))
    (or (not confirm)
        (yes-or-no-p
         (format "Send %d characters from %s to OpenClaw? "
                 (length (openclaw-sessions-context-message context))
                 (openclaw-sessions-context-source-label context))))))

;;;###autoload
(defun openclaw-sessions-start-at-point (&optional edit)
  "Create or visit an OpenClaw session for the object at point.

With prefix argument EDIT, prompt to edit the initial message before creating
a new session.  The session name and agent are selected as usual."
  (interactive "P")
  (let* ((context (openclaw-sessions-context-at-point))
         (source-id (openclaw-sessions-context-source-id context))
         (existing (openclaw-sessions-context--entry-for-source source-id)))
    (if existing
        (let ((buffer
               (openclaw-sessions-start (plist-get existing :session-name)
                                        (plist-get existing :agent))))
          (openclaw-sessions-context--record
           context (plist-get existing :session-name)
           (plist-get existing :agent) buffer)
          buffer)
      (let* ((name (funcall openclaw-sessions-context-name-function context))
             (agent (or (openclaw-sessions-context-agent context)
                        openclaw-sessions-default-agent))
             (message-text
              (if edit
                  (read-from-minibuffer
                   "Initial message: "
                   (openclaw-sessions-context-message context))
                (openclaw-sessions-context-message context))))
        (when (openclaw-sessions-context--confirm-p context)
          (let ((openclaw-sessions-launch-directory
                 (or openclaw-sessions-launch-directory
                     (openclaw-sessions-context-directory context))))
            (let ((buffer (openclaw-sessions-start
                           name agent message-text)))
              (openclaw-sessions-context--record
               context name agent buffer)
              buffer)))))))

(defun openclaw-sessions-context--visit-entry (entry)
  "Visit the source represented by registry ENTRY."
  (let ((type (plist-get entry :type))
        (location (plist-get entry :location)))
    (pcase type
      ('org
       (require 'org)
       (if-let ((file (plist-get location :file)))
           (find-file file)
         (let ((buffer (get-buffer (plist-get location :buffer))))
           (unless buffer
             (user-error "Source Org buffer no longer exists"))
           (pop-to-buffer buffer)))
       (widen)
       (goto-char (point-min))
       (unless (org-find-olp (plist-get location :outline-path) t)
         (goto-char (min (point-max)
                         (or (plist-get location :position) 1))))
       (org-show-context))
      ('mu4e
       (unless (require 'mu4e-view nil t)
         (user-error "Mu4e is not available"))
       (mu4e-view-message-with-message-id
        (plist-get location :message-id)))
      ('file
       (find-file (plist-get location :file))
       (goto-char (min (point-max)
                       (or (plist-get location :position) 1))))
      ('buffer
       (let ((buffer (get-buffer (plist-get location :buffer))))
         (unless buffer
           (user-error "Source buffer no longer exists"))
         (pop-to-buffer buffer)
         (goto-char (min (point-max)
                         (or (plist-get location :position) 1)))))
      (_ (user-error "This session has no visitable source")))))

;;;###autoload
(defun openclaw-sessions-visit-source (&optional session-key)
  "Visit the source associated with SESSION-KEY.

Interactively, use the current dashboard row or managed session buffer."
  (interactive)
  (let* ((key (or session-key
                  (and (derived-mode-p 'openclaw-sessions-mode)
                       (tabulated-list-get-id))
                  openclaw-sessions--session-key))
         (entry (and (stringp key)
                     (openclaw-sessions-context--entry-for-key key))))
    (unless entry
      (user-error "No source is registered for this session"))
    (openclaw-sessions-context--visit-entry entry)))

;;;###autoload
(defun openclaw-sessions-forget-context (&optional session-key)
  "Forget the source association for SESSION-KEY without deleting the session.

Interactively, use the dashboard row or managed session buffer.  Outside
those buffers, forget the association for the context at point."
  (interactive)
  (let* ((key (or session-key
                  (and (derived-mode-p 'openclaw-sessions-mode)
                       (tabulated-list-get-id))
                  openclaw-sessions--session-key))
         (entry
          (if (stringp key)
              (openclaw-sessions-context--entry-for-key key)
            (let ((context (openclaw-sessions-context-at-point)))
              (openclaw-sessions-context--entry-for-source
               (openclaw-sessions-context-source-id context))))))
    (unless entry
      (user-error "No context association was found"))
    (setq openclaw-sessions-context--registry
          (delq entry openclaw-sessions-context--registry))
    (openclaw-sessions-context--save-registry)
    (openclaw-sessions--update-dashboard)
    (message "OpenClaw context association removed; session left intact")))

(provide 'openclaw-sessions-context)

;;; openclaw-sessions-context.el ends here
