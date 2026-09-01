;;; openclaw-sessions-test.el --- Tests for openclaw-sessions -*- lexical-binding: t; -*-

(require 'ert)
(require 'openclaw-sessions)
(require 'openclaw-sessions-context)
(require 'openclaw-sessions-org)
(require 'openclaw-sessions-mu4e)
(require 'term)

;; Never consult the user's persistent registry in the test process.
(setq openclaw-sessions-context--registry nil
      openclaw-sessions-context--registry-loaded-p t)

;; Launcher tests replace the vterm entry points without loading its module.
(provide 'vterm)
(provide 'eat)

(ert-deftest openclaw-sessions-test-session-parts ()
  (should (equal (openclaw-sessions--session-parts
                  "agent:main:issue-2540-navigation-layout")
                 '("main" "issue-2540-navigation-layout")))
  (should (equal (openclaw-sessions--session-parts
                  "agent:work:name:with:colons")
                 '("work" "name:with:colons")))
  (should-not (openclaw-sessions--session-parts "global")))

(ert-deftest openclaw-sessions-test-parse-json-buffer ()
  (with-temp-buffer
    (insert "diagnostic line\n{\"sessions\":[{\"key\":\"agent:main:test\",\"status\":\"done\"}]}")
    (let ((sessions (openclaw-sessions--parse-json-buffer)))
      (should (= (length sessions) 1))
      (should (equal (alist-get 'status (car sessions)) "done")))))

(ert-deftest openclaw-sessions-test-format-age ()
  (should (equal (openclaw-sessions--format-age '((ageMs . 12000))) "12s"))
  (should (equal (openclaw-sessions--format-age '((ageMs . 120000))) "2m"))
  (should (equal (openclaw-sessions--format-age '((ageMs . 7200000))) "2h")))

(ert-deftest openclaw-sessions-test-format-tokens ()
  (should (equal (openclaw-sessions--format-tokens
                  '((totalTokens . 50000) (contextTokens . 200000)))
                 "50k/200k (25%)"))
  (should (equal (openclaw-sessions--format-tokens '()) "—")))

(ert-deftest openclaw-sessions-test-mode-line-counts-managed-statuses ()
  (let ((openclaw-sessions--sessions
         '(((key . "agent:main:topic")
            (kind . "direct") (status . "running"))))
        (openclaw-sessions-dashboard-scope 'managed))
    (with-temp-buffer
      (setq-local openclaw-sessions--session-name "topic"
                  openclaw-sessions--session-key "agent:main:topic")
      (should (equal (substring-no-properties
                      (openclaw-sessions-mode-line-string))
                     "   OC:1▶ 0✓")))))

(ert-deftest openclaw-sessions-test-mode-line-respects-direct-scope ()
  (let ((openclaw-sessions--sessions
         '(((key . "agent:main:direct")
            (kind . "direct") (status . "running"))
           ((key . "agent:main:cron")
            (kind . "cron") (status . "done"))))
        (openclaw-sessions-dashboard-scope 'direct))
    (should (equal (substring-no-properties
                    (openclaw-sessions-mode-line-string))
                   "   OC:1▶ 0✓"))))

(ert-deftest openclaw-sessions-test-mode-line-respects-all-scope ()
  (let ((openclaw-sessions--sessions
         '(((key . "agent:main:direct")
            (kind . "direct") (status . "running"))
           ((key . "agent:main:cron")
            (kind . "cron") (status . "done"))))
        (openclaw-sessions-dashboard-scope 'all))
    (should (equal (substring-no-properties
                    (openclaw-sessions-mode-line-string))
                   "   OC:1▶ 1✓"))))

(ert-deftest openclaw-sessions-test-mode-line-shows-unreviewed-count ()
  (let ((openclaw-sessions--sessions
         '(((key . "agent:main:topic")
            (kind . "direct") (status . "done"))))
        (openclaw-sessions--unseen-completions
         (make-hash-table :test #'equal))
        (openclaw-sessions-dashboard-scope 'direct))
    (puthash "agent:main:topic" "done"
             openclaw-sessions--unseen-completions)
    (should (equal (substring-no-properties
                    (openclaw-sessions-mode-line-string))
                   "   OC:0▶ 1✓ 1●"))))

(ert-deftest openclaw-sessions-test-cycle-scope-is-global ()
  (let ((openclaw-sessions-dashboard-scope 'managed))
    (cl-letf (((symbol-function 'openclaw-sessions--update-dashboard) #'ignore)
              ((symbol-function 'force-mode-line-update) #'ignore))
      (openclaw-sessions-cycle-scope)
      (should (eq openclaw-sessions-dashboard-scope 'direct))
      (openclaw-sessions-cycle-scope)
      (should (eq openclaw-sessions-dashboard-scope 'all))
      (openclaw-sessions-cycle-scope)
      (should (eq openclaw-sessions-dashboard-scope 'managed)))))

(ert-deftest openclaw-sessions-test-agent-reader-uses-completion ()
  (let (completion-arguments)
    (cl-letf (((symbol-function 'openclaw-sessions--agent-candidates)
               (lambda () '("main" "work")))
              ((symbol-function 'completing-read)
               (lambda (&rest arguments)
                 (setq completion-arguments arguments)
                 "work")))
      (should (equal (openclaw-sessions-read-agent) "work"))
      (should (equal (nth 1 completion-arguments) '("main" "work")))
      (should-not (nth 3 completion-arguments)))))

(ert-deftest openclaw-sessions-test-agent-reader-allows-automatic ()
  (cl-letf (((symbol-function 'openclaw-sessions--agent-candidates)
             (lambda () '("main")))
            ((symbol-function 'completing-read)
             (lambda (&rest _) "")))
    (should-not (openclaw-sessions-read-agent))))

(ert-deftest openclaw-sessions-test-auto-backend-preference ()
  (let ((openclaw-sessions-terminal-backend 'auto)
        available)
    (cl-letf (((symbol-function 'openclaw-sessions--backend-available-p)
               (lambda (backend) (memq backend available))))
      (setq available '(vterm eat term))
      (should (eq (openclaw-sessions--resolved-terminal-backend) 'vterm))
      (setq available '(eat term))
      (should (eq (openclaw-sessions--resolved-terminal-backend) 'eat))
      (setq available '(term))
      (should (eq (openclaw-sessions--resolved-terminal-backend) 'term)))))

(ert-deftest openclaw-sessions-test-custom-backend-contract ()
  (let (received
        created-buffer)
    (unwind-protect
        (let ((openclaw-sessions-terminal-backend
               (lambda (name executable arguments directory)
                 (setq received (list name executable arguments directory)
                       created-buffer (generate-new-buffer " *oc-custom*"))
                 created-buffer)))
          (should (eq (openclaw-sessions--launch-terminal
                       "work/topic" "/usr/bin/openclaw"
                       '("tui" "--session" "agent:work:topic") "/tmp/")
                      created-buffer))
          (should (equal received
                         '("work/topic" "/usr/bin/openclaw"
                           ("tui" "--session" "agent:work:topic")
                           "/tmp/"))))
      (when (buffer-live-p created-buffer)
        (kill-buffer created-buffer)))))

(ert-deftest openclaw-sessions-test-eat-backend-passes-argv ()
  (let (received
        created-buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'eat-make)
                   (lambda (name executable startfile &rest arguments)
                     (setq received
                           (list name executable startfile arguments)
                           created-buffer
                           (generate-new-buffer " *oc-eat*"))
                     created-buffer))
                  ((symbol-function 'eat-char-mode) #'ignore)
                  ((symbol-function 'pop-to-buffer) #'ignore))
          (should (eq (openclaw-sessions--launch-eat
                       "topic" "/usr/bin/openclaw"
                       '("tui" "--session" "topic") "/tmp/")
                      created-buffer))
          (should (equal received
                         '("openclaw:topic" "/usr/bin/openclaw" nil
                           ("tui" "--session" "topic")))))
      (when (buffer-live-p created-buffer)
        (kill-buffer created-buffer)))))

(ert-deftest openclaw-sessions-test-term-backend-passes-argv ()
  (let (received
        created-buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'make-term)
                   (lambda (name executable startfile &rest arguments)
                     (setq received
                           (list name executable startfile arguments)
                           created-buffer
                           (generate-new-buffer " *oc-term*"))
                     created-buffer))
                  ((symbol-function 'term-mode) #'ignore)
                  ((symbol-function 'term-char-mode) #'ignore)
                  ((symbol-function 'pop-to-buffer) #'ignore))
          (should (eq (openclaw-sessions--launch-term
                       "topic" "/usr/bin/openclaw"
                       '("tui" "--session" "topic") "/tmp/")
                      created-buffer))
          (should (equal received
                         '("openclaw:topic" "/usr/bin/openclaw" nil
                           ("tui" "--session" "topic")))))
      (when (buffer-live-p created-buffer)
        (kill-buffer created-buffer)))))

(ert-deftest openclaw-sessions-test-managed-dashboard-filter ()
  (let ((openclaw-sessions--sessions
         '(((key . "agent:main:managed")
            (kind . "direct") (status . "running"))
           ((key . "agent:main:other")
            (kind . "direct") (status . "done"))))
        (openclaw-sessions-dashboard-scope 'managed))
    (with-temp-buffer
      (setq-local openclaw-sessions--session-name "managed"
                  openclaw-sessions--session-key "agent:main:managed")
      (let ((rows (openclaw-sessions--dashboard-entries)))
        (should (= (length rows) 1))
        (should (equal (caar rows) "agent:main:managed"))))))

(ert-deftest openclaw-sessions-test-notifies-running-to-terminal-only ()
  (let ((openclaw-sessions--sessions
        '(((key . "agent:main:test") (status . "done"))))
        (openclaw-sessions--statuses (make-hash-table :test #'equal))
        (openclaw-sessions--unseen-completions
         (make-hash-table :test #'equal))
        (openclaw-sessions-notify-on-completion t)
        notified)
    (with-temp-buffer
      (setq-local openclaw-sessions--session-name "test"
                  openclaw-sessions--session-key "agent:main:test")
      (puthash "agent:main:test" "running" openclaw-sessions--statuses)
      (cl-letf (((symbol-function 'openclaw-sessions--notify)
                 (lambda (&rest _) (setq notified t))))
        (openclaw-sessions--record-status-transitions)
        (should notified)))))

(ert-deftest openclaw-sessions-test-completion-notification-does-not-expire ()
  (require 'notifications)
  (let (notification-arguments)
    (cl-letf (((symbol-function 'notifications-notify)
               (lambda (&rest arguments)
                 (setq notification-arguments arguments))))
      (openclaw-sessions--notify
       '((key . "agent:main:test") (status . "done"))
       "done")
      (should (equal (plist-get notification-arguments :timeout) 0)))))

(ert-deftest openclaw-sessions-test-running-to-terminal-becomes-unreviewed ()
  (let ((openclaw-sessions--sessions
         '(((key . "agent:main:test") (status . "done"))))
        (openclaw-sessions--statuses (make-hash-table :test #'equal))
        (openclaw-sessions--unseen-completions
         (make-hash-table :test #'equal))
        (openclaw-sessions-notify-on-completion nil))
    (openclaw-sessions--record-status-transitions)
    (should-not (openclaw-sessions--unseen-p "agent:main:test"))
    (puthash "agent:main:test" "running" openclaw-sessions--statuses)
    (openclaw-sessions--record-status-transitions)
    (should (equal (openclaw-sessions--unseen-p "agent:main:test")
                   "done"))))

(ert-deftest openclaw-sessions-test-review-state-can-be-changed-explicitly ()
  (let ((openclaw-sessions--unseen-completions
         (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'openclaw-sessions--update-dashboard) #'ignore)
              ((symbol-function 'force-mode-line-update) #'ignore))
      (openclaw-sessions--set-unseen "agent:main:test" t)
      (should (openclaw-sessions--unseen-p "agent:main:test"))
      (openclaw-sessions--set-unseen "agent:main:test" nil)
      (should-not (openclaw-sessions--unseen-p "agent:main:test")))))

(ert-deftest openclaw-sessions-test-visiting-managed-buffer-reviews-completion ()
  (let ((openclaw-sessions--unseen-completions
         (make-hash-table :test #'equal)))
    (with-temp-buffer
      (setq-local openclaw-sessions--session-key "agent:main:test")
      (puthash openclaw-sessions--session-key "done"
               openclaw-sessions--unseen-completions)
      (openclaw-sessions--prepare-managed-buffer)
      (should (memq #'openclaw-sessions--review-current-buffer-completion
                    post-command-hook))
      (cl-letf (((symbol-function 'openclaw-sessions--update-dashboard) #'ignore)
                ((symbol-function 'force-mode-line-update) #'ignore))
        (openclaw-sessions--review-current-buffer-completion))
      (should-not (openclaw-sessions--unseen-p
                   openclaw-sessions--session-key)))))

(ert-deftest openclaw-sessions-test-launches-name-without-directory-prompt ()
  (let ((openclaw-sessions-default-agent nil)
        (openclaw-sessions-launch-directory nil)
        (openclaw-sessions-terminal-backend 'vterm)
        (default-directory "/tmp/")
        sent-command
        created-buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'openclaw-sessions--executable)
                   (lambda () "/usr/bin/openclaw"))
                  ((symbol-function 'openclaw-sessions-monitor-mode)
                   (lambda (&optional _)))
                  ((symbol-function 'vterm)
                   (lambda (name)
                     (setq sent-command vterm-shell)
                     (setq created-buffer (get-buffer-create name))
                     (set-buffer created-buffer))))
          (openclaw-sessions-start "my-topic")
          (should (equal sent-command
                         "/usr/bin/openclaw tui --session my-topic"))
          (should (equal
                   (buffer-local-value 'openclaw-sessions--session-name
                                       created-buffer)
                   "my-topic"))
          (should-not
           (buffer-local-value 'openclaw-sessions--session-agent
                               created-buffer)))
      (when (buffer-live-p created-buffer)
        (kill-buffer created-buffer)))))

(ert-deftest openclaw-sessions-test-explicit-agent-uses-full-key ()
  (let ((openclaw-sessions-default-agent nil)
        (openclaw-sessions-launch-directory "/tmp/")
        (openclaw-sessions-terminal-backend 'vterm)
        sent-command
        created-buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'openclaw-sessions--executable)
                   (lambda () "/usr/bin/openclaw"))
                  ((symbol-function 'openclaw-sessions-monitor-mode)
                   (lambda (&optional _)))
                  ((symbol-function 'vterm)
                   (lambda (name)
                     (setq sent-command vterm-shell)
                     (setq created-buffer (get-buffer-create name))
                     (set-buffer created-buffer))))
          (openclaw-sessions-start "my-topic" "work")
          (should (equal sent-command
                         "/usr/bin/openclaw tui --session agent\\:work\\:my-topic"))
          (should (equal
                   (buffer-local-value 'openclaw-sessions--session-key
                                       created-buffer)
                   "agent:work:my-topic")))
      (when (buffer-live-p created-buffer)
        (kill-buffer created-buffer)))))

(ert-deftest openclaw-sessions-test-initial-message-is-passed-as-argv ()
  (let ((openclaw-sessions-default-agent nil)
        (openclaw-sessions-launch-directory "/tmp/")
        (openclaw-sessions-terminal-backend 'eat)
        received
        created-buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'openclaw-sessions--executable)
                   (lambda () "/usr/bin/openclaw"))
                  ((symbol-function 'openclaw-sessions-monitor-mode)
                   (lambda (&optional _)))
                  ((symbol-function 'eat-make)
                   (lambda (_name _executable _startfile &rest arguments)
                     (setq received arguments
                           created-buffer
                           (generate-new-buffer " *oc-message*"))
                     created-buffer))
                  ((symbol-function 'eat-char-mode) #'ignore)
                  ((symbol-function 'pop-to-buffer) #'ignore))
          (openclaw-sessions-start "mail-task" nil "Inspect this email")
          (should (equal received
                         '("tui" "--session" "mail-task"
                           "--message" "Inspect this email"))))
      (when (buffer-live-p created-buffer)
        (kill-buffer created-buffer)))))

(ert-deftest openclaw-sessions-test-context-name-is-stable-and-bounded ()
  (let* ((openclaw-sessions-context-name-max-length 32)
         (context (openclaw-sessions-context-create
                   :title "A very long heading with punctuation!"
                   :source-id "org:stable-id"))
         (first (openclaw-sessions-context-default-name context)))
    (should (equal first (openclaw-sessions-context-default-name context)))
    (should (<= (length first) 32))
    (should (string-match-p
             "\\`a-very-long-heading-wit-[0-9a-f]\\{8\\}\\'" first))))

(ert-deftest openclaw-sessions-test-region-provider-precedes-buffer ()
  (with-temp-buffer
    (insert "before selected text after")
    (goto-char 8)
    (push-mark 21 t t)
    (let ((transient-mark-mode t)
          (context (openclaw-sessions-context-at-point)))
      (should (eq (openclaw-sessions-context-type context) 'buffer))
      (should (string-match-p "selected text"
                              (openclaw-sessions-context-message context))))))

(ert-deftest openclaw-sessions-test-org-heading-context ()
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/work.org")
    (insert "* Project\n** TODO Fix refunds :finance:\n:PROPERTIES:\n:ID: task-42\n:EFFORT: 2:00\n:END:\nCheck duplicate charges.\n")
    (goto-char (point-min))
    (search-forward "Fix refunds")
    (let ((context (openclaw-sessions-org-context)))
      (should (equal (openclaw-sessions-context-title context)
                     "Fix refunds"))
      (should (equal (openclaw-sessions-context-type context) 'org))
      (should (string-match-p "TODO state: TODO"
                              (openclaw-sessions-context-message context)))
      (should (string-match-p "Check duplicate charges"
                              (openclaw-sessions-context-message context)))
      (should (equal (plist-get
                      (openclaw-sessions-context-location context)
                      :outline-path)
                     '("Project" "Fix refunds"))))))

(ert-deftest openclaw-sessions-test-mu4e-message-context ()
  (let ((major-mode 'mu4e-view-mode)
        (message
         '(:subject "Production error"
           :message-id "message@example.test"
           :from ((:name "Alice" :email "alice@example.test"))
           :to ((:email "ops@example.test"))
           :date (0 0 0 0)
           :body-txt "Please investigate.\n> quoted history\n-- \nSignature"
           :attachments ((:name "error.log"))
           :path "/tmp/mail/message")))
    (cl-letf (((symbol-function 'mu4e-message-at-point)
               (lambda (&optional _) message))
              ((symbol-function 'mu4e-message-field)
               (lambda (msg field) (plist-get msg field))))
      (provide 'mu4e-message)
      (let ((context (openclaw-sessions-mu4e-context)))
        (should (equal (openclaw-sessions-context-title context)
                       "Production error"))
        (should (eq (openclaw-sessions-context-type context) 'mu4e))
        (should (string-match-p "Alice <alice@example.test>"
                                (openclaw-sessions-context-message context)))
        (should (string-match-p "Attachments: error.log"
                                (openclaw-sessions-context-message context)))
        (should-not (string-match-p "quoted history"
                                    (openclaw-sessions-context-message
                                     context)))))))

(ert-deftest openclaw-sessions-test-context-registry-persists-association ()
  (let* ((registry-file (make-temp-file "openclaw-context-registry-"))
         (openclaw-sessions-context-registry-file registry-file)
         (openclaw-sessions-context--registry nil)
         (openclaw-sessions-context--registry-loaded-p t)
         (context (openclaw-sessions-context-create
                   :title "Task"
                   :source-id "org:task"
                   :source-label "Org: Task"
                   :type 'org
                   :location '(:file "/tmp/work.org" :position 1)))
         buffer)
    (unwind-protect
        (progn
          (setq buffer (generate-new-buffer " *oc-registry*"))
          (with-current-buffer buffer
            (setq-local openclaw-sessions--session-key "agent:main:task"))
          (openclaw-sessions-context--record context "task" "main" buffer)
          (should (member "agent:main:task"
                          (openclaw-sessions-context-session-keys)))
          (should (equal
                   (openclaw-sessions-context-source-label-for-key
                    "agent:main:task")
                   "Org: Task"))
          (should (> (nth 7 (file-attributes registry-file)) 0)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (file-exists-p registry-file) (delete-file registry-file)))))

(ert-deftest openclaw-sessions-test-existing-context-does-not-resend-message ()
  (let* ((context (openclaw-sessions-context-create
                   :title "Task" :source-id "org:task"
                   :source-label "Org: Task" :message "Initial"))
         (openclaw-sessions-context--registry
          '((:source-id "org:task" :session-name "task" :agent "main")))
         (openclaw-sessions-context--registry-loaded-p t)
         received)
    (cl-letf (((symbol-function 'openclaw-sessions-context-at-point)
               (lambda () context))
              ((symbol-function 'openclaw-sessions-start)
               (lambda (&rest arguments) (setq received arguments)))
              ((symbol-function 'openclaw-sessions-context--record) #'ignore))
      (openclaw-sessions-start-at-point)
      (should (equal received '("task" "main"))))))

(ert-deftest openclaw-sessions-test-new-context-launches-and-registers ()
  (let* ((registry-file (make-temp-file "openclaw-context-new-"))
         (openclaw-sessions-context-registry-file registry-file)
         (openclaw-sessions-context--registry nil)
         (openclaw-sessions-context--registry-loaded-p t)
         (openclaw-sessions-context-confirm-before-send 'never)
         (openclaw-sessions-default-agent "main")
         (context (openclaw-sessions-context-create
                   :title "Fix task" :source-id "org:new-task"
                   :source-label "Org: Fix task" :message "Initial context"
                   :directory "/tmp/" :type 'org
                   :location '(:file "/tmp/work.org" :position 1)))
         received
         buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'openclaw-sessions-context-at-point)
                   (lambda () context))
                  ((symbol-function 'openclaw-sessions-start)
                   (lambda (&rest arguments)
                     (setq received arguments
                           buffer (generate-new-buffer " *oc-new-context*"))
                     (with-current-buffer buffer
                       (setq-local openclaw-sessions--session-key
                                   "agent:main:fix-task"))
                     buffer)))
          (openclaw-sessions-start-at-point)
          (should (equal (cdr received) '("main" "Initial context")))
          (should (equal
                   (openclaw-sessions-context-source-label-for-key
                    "agent:main:fix-task")
                   "Org: Fix task")))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (file-exists-p registry-file) (delete-file registry-file)))))

(ert-deftest openclaw-sessions-test-dashboard-shows-context-source ()
  (let ((openclaw-sessions-context--registry
         '((:source-id "org:task" :session-key "agent:main:task"
            :source-label "Org: Fix task")))
        (openclaw-sessions-context--registry-loaded-p t))
    (let* ((row (openclaw-sessions--session-row
                 '((key . "agent:main:task") (status . "running"))))
           (cells (cadr row)))
      (should (equal (aref cells 8) "Org: Fix task")))))

(ert-deftest openclaw-sessions-test-forget-context-keeps-session-separate ()
  (let* ((registry-file (make-temp-file "openclaw-context-forget-"))
         (openclaw-sessions-context-registry-file registry-file)
         (openclaw-sessions-context--registry
          '((:source-id "org:task" :session-key "agent:main:task")))
         (openclaw-sessions-context--registry-loaded-p t)
         updated)
    (unwind-protect
        (cl-letf (((symbol-function 'openclaw-sessions--update-dashboard)
                   (lambda () (setq updated t)))
                  ((symbol-function 'message) #'ignore))
          (openclaw-sessions-forget-context "agent:main:task")
          (should updated)
          (should-not openclaw-sessions-context--registry))
      (when (file-exists-p registry-file) (delete-file registry-file)))))

(provide 'openclaw-sessions-test)

;;; openclaw-sessions-test.el ends here
